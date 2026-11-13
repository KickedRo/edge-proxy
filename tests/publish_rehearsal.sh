#!/usr/bin/env bash
# Rehearsal of the publish job against a throwaway local registry; nothing leaves the machine:
#   tests/publish_rehearsal.sh EDGE_ARCHIVE EDGE_IDENTITY GEN_ARCHIVE GEN_IDENTITY BUILD_KEY
# *_ARCHIVE is `docker save` of a tested image, *_IDENTITY `scripts/publish_tested.sh identity` of it, BUILD_KEY
# `scripts/build_key.sh`'s key. Runs the same scripts/publish_tested.sh steps as build.yml's publish job (decide,
# push by digest with SBOM and provenance plus the same-bits check, tag) and the cases they must refuse. Signing and
# the GitHub provenance attestation need GitHub's OIDC token, so they only run in the publish job itself.
# BUILDKIT_IMAGE (required) is the BuildKit image the publish job uses, build.yml's pin, so the rehearsal runs the
# BuildKit that publishes. The GEN_ARCHIVE image is loaded into Docker if it is not there yet (removed again after).
# Prints "PASS <name>" per assertion and stops at the first failure. The registry container (and its volume), the
# buildx builder, the images it creates and the temp files are removed on exit (also on failure). The registry listens
# on 127.0.0.1 only, on $PORT_1 when set (devbox), else on a port Docker picks.
set -euo pipefail

[ $# -eq 5 ] || { echo "usage: tests/publish_rehearsal.sh EDGE_ARCHIVE EDGE_IDENTITY GEN_ARCHIVE GEN_IDENTITY BUILD_KEY" >&2; exit 2; }
EDGE_ARCHIVE=$1 EDGE_ID=$2 GEN_ARCHIVE=$3 GEN_ID=$4 KEY=$5
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
P="$ROOT/scripts/publish_tested.sh"
# Distribution registry 3.1.2 (the registry:3 tag on 2026-11-13), pinned by digest.
REGISTRY_IMAGE=registry@sha256:82f6ff4a7f982960c8aa51617fea3aabc485df6e55cce80d22deb1de36f1bc3c
OTHER_KEY=sha256:$(printf '%064d' 0)
BUILDKIT_IMAGE=${BUILDKIT_IMAGE:?set BUILDKIT_IMAGE to the BuildKit image pinned in .github/workflows/build.yml}

RUN="pubtest-$$-$RANDOM"
TMP=$(mktemp -d)
LOADED=
cleanup() {
  docker buildx rm "$RUN" >/dev/null 2>&1 || true
  docker rm -f -v "$RUN-registry" >/dev/null 2>&1 || true
  docker image rm -f "$RUN-derived" ${LOADED:+"$LOADED"} >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2" >&2; exit 1; }

docker run -d --name "$RUN-registry" -p "127.0.0.1:${PORT_1:-}:5000" "$REGISTRY_IMAGE" >/dev/null
port=$(docker port "$RUN-registry" 5000/tcp | head -n 1)
port=${port##*:}
REG="localhost:$port/rehearsal"
# Plain HTTP for this registry only; host networking so BuildKit reaches 127.0.0.1. No GitHub event payload in
# the provenance, like the publish job's builder.
printf '[registry."localhost:%s"]\n  http = true\n' "$port" > "$TMP/buildkitd.toml"
docker buildx create --name "$RUN" --driver docker-container --driver-opt network=host \
  --driver-opt "image=$BUILDKIT_IMAGE" --driver-opt provenance-add-gha=false \
  --buildkitd-config "$TMP/buildkitd.toml" --bootstrap >"$TMP/builder.log" 2>&1 \
  || { cat "$TMP/builder.log" >&2; fail setup "could not create the buildx builder"; }
export BUILDX_BUILDER="$RUN"
running=$(docker inspect -f '{{.Config.Image}}' "buildx_buildkit_${RUN}0")
[ "$running" = "$BUILDKIT_IMAGE" ] || fail buildkit "the builder runs '$running', not $BUILDKIT_IMAGE"
pass builder_runs_the_pinned_buildkit

decide() { "$P" decide "$@"; }   # its reasons go to stderr, into the log
[ "$(decide "$KEY" 3 false false "$REG/edge" "$REG/gen")" = true ] || fail first_publish "no :latest yet must publish"
pass decide_publishes_without_latest

edge=$("$P" push "$EDGE_ARCHIVE" "$EDGE_ID" "$REG/edge" "$KEY")
gen=$("$P" push "$GEN_ARCHIVE" "$GEN_ID" "$REG/gen" "$KEY")
[[ $edge =~ ^sha256:[0-9a-f]{64}$ && $gen =~ ^sha256:[0-9a-f]{64}$ ]] || fail push "digests: '$edge' '$gen'"
pass push_by_digest_with_same_bits_check

for ref in "$REG/edge@$edge" "$REG/gen@$gen"; do
  n=$(docker buildx imagetools inspect "$ref" --format '{{json .SBOM}}' | jq '.SPDX.packages | length')
  [ "$n" -gt 50 ] || fail sbom "$ref: $n packages in the SBOM"
  docker buildx imagetools inspect "$ref" --format '{{json .Provenance}}' > "$TMP/provenance.json"
  jq -e '.SLSA != null' "$TMP/provenance.json" >/dev/null || fail provenance "$ref: no provenance"
  if grep -q github_event_payload "$TMP/provenance.json"; then
    fail provenance "$ref: the provenance carries the GitHub event payload"
  fi
done
pass sbom_and_provenance_attached_without_event_payload

"$P" tag "$REG/edge" "$edge" latest rehearsal-tag
"$P" tag "$REG/gen" "$gen" latest rehearsal-tag
pass tags_point_at_the_pushed_digests

[ "$(decide "$KEY" 3 false false "$REG/edge" "$REG/gen")" = false ] || fail unchanged "same key on a weekday must skip"
pass decide_skips_unchanged_on_a_weekday
[ "$(decide "$OTHER_KEY" 3 false false "$REG/edge" "$REG/gen")" = true ] || fail changed "another key must publish"
pass decide_publishes_a_changed_key
[ "$(decide "$KEY" 1 false false "$REG/edge" "$REG/gen")" = true ] || fail monday "Monday must publish"
pass decide_publishes_on_monday
[ "$(decide "$KEY" 1 false true "$REG/edge" "$REG/gen")" = false ] || fail force_skip_check "Monday ignored must skip"
pass decide_force_skip_check_ignores_monday
[ "$(decide "$KEY" 3 true false "$REG/edge" "$REG/gen")" = true ] || fail force_publish "force_publish must publish"
pass decide_force_publish
[ "$(decide "$KEY" 3 false false "$REG/edge" "$REG/gen" "$REG/missing")" = true ] || fail one_missing "a missing :latest must publish"
pass decide_publishes_if_any_latest_is_missing
# A missed weekly publish is made up: :latest more than 6 whole days old publishes, 6 days and a minute does not.
oldest=$(for r in edge gen; do
  date -u -d "$(docker buildx imagetools inspect "$REG/$r:latest" --format '{{json .Image}}' | jq -r .created)" +%s
done | sort -n | head -n 1)
[ "$(PUBLISH_DECIDE_NOW=$((oldest + 6 * 86400 + 60)) decide "$KEY" 3 false false "$REG/edge" "$REG/gen")" = false ] \
  || fail overdue "6 days old must not publish"
[ "$(PUBLISH_DECIDE_NOW=$((oldest + 7 * 86400 + 60)) decide "$KEY" 3 false false "$REG/edge" "$REG/gen")" = true ] \
  || fail overdue "7 days old must publish"
pass decide_publishes_when_latest_is_overdue

if "$P" check "$GEN_ID" "$REG/edge@$edge" "$KEY" 2>"$TMP/check.log"; then
  fail check_other_image "the edge image passed as the tested gen image"
fi
grep -q 'differs from the tested image' "$TMP/check.log" || fail check_other_image "$(cat "$TMP/check.log")"
if "$P" check "$EDGE_ID" "$REG/edge@$edge" "$OTHER_KEY" 2>"$TMP/check.log"; then
  fail check_key "a wrong build key label passed"
fi
pass check_refuses_other_bits_and_other_key

if "$P" push "$EDGE_ARCHIVE" "$GEN_ID" "$REG/mismatch" "$KEY" >"$TMP/push.out" 2>"$TMP/push.log"; then
  fail push_mismatch "push succeeded although the archive is not the tested image"
fi
[ ! -s "$TMP/push.out" ] || fail push_mismatch "a digest was printed: $(cat "$TMP/push.out")"
if docker buildx imagetools inspect "$REG/mismatch:latest" >/dev/null 2>&1; then
  fail push_mismatch "the refused image got a tag"
fi
pass push_refuses_an_archive_that_is_not_the_tested_image

# Same configuration, one more layer: the tested gen image plus one small file. Refused because of the layer diff IDs
# alone (the configuration equality is checked here first, independently of publish_tested.sh's identity).
gen_ref=$(tar -xOf "$GEN_ARCHIVE" manifest.json | jq -r '.[0].RepoTags[0] // empty')
[ -n "$gen_ref" ] || fail setup "no image name in $GEN_ARCHIVE"
if ! docker image inspect "$gen_ref" >/dev/null 2>&1; then
  docker load -q -i "$GEN_ARCHIVE" >/dev/null
  LOADED=$gen_ref
fi
mkdir "$TMP/derived"
echo "one more layer" > "$TMP/derived/extra"
printf 'FROM %s\nCOPY extra /rehearsal-extra-layer\n' "$gen_ref" > "$TMP/derived/Dockerfile"
docker buildx build --builder default -q --load -t "$RUN-derived" "$TMP/derived" >/dev/null
[ "$(docker image inspect -f '{{len .RootFS.Layers}}' "$RUN-derived")" \
  = "$(( $(docker image inspect -f '{{len .RootFS.Layers}}' "$gen_ref") + 1 ))" ] \
  || fail one_layer "test setup: the derived image does not have exactly one more layer"
cmp -s <(docker image inspect "$RUN-derived" | jq -S '.[0] | {Os, Architecture, Config}') \
       <(docker image inspect "$gen_ref" | jq -S '.[0] | {Os, Architecture, Config}') \
  || fail one_layer "test setup: the derived image's configuration differs"
docker save "$RUN-derived" -o "$TMP/derived.tar"
if "$P" push "$TMP/derived.tar" "$GEN_ID" "$REG/derived" "$KEY" >"$TMP/push.out" 2>"$TMP/push.log"; then
  fail one_layer "push succeeded although one layer differs from the tested image"
fi
grep -q 'differs from the tested image' "$TMP/push.log" || fail one_layer "$(tail -n 5 "$TMP/push.log")"
pass push_refuses_one_changed_layer

echo "ALL PASS"
