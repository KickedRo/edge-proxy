#!/usr/bin/env bash
# Rehearsal of the publish job against a throwaway local registry; nothing leaves the machine:
#   tests/publish_rehearsal.sh EDGE_ARCHIVE EDGE_IDENTITY GEN_ARCHIVE GEN_IDENTITY BUILD_KEY
# *_ARCHIVE is `docker save` of a tested image, *_IDENTITY `scripts/publish_tested.sh identity` of it, BUILD_KEY
# `scripts/build_key.sh`'s key. Runs the same scripts/publish_tested.sh steps as build.yml's publish job (VERSION line,
# decide, next version, push by digest with SBOM and provenance plus the same-bits check, tag, the released check of a
# run that publishes nothing, a second publish that becomes the next patch) and the cases they must refuse. The git
# release tags the publish job reads with `git ls-remote` are stub files here (one tag per line); registry states the
# two published images do not reach (a `latest` of another line, a version only the registry has, a label from before
# versions) are label-only stub images. Signing and the GitHub provenance attestation need GitHub's OIDC token, so
# they only run in the publish job itself.
# BUILDKIT_IMAGE (required) is the BuildKit image the publish job uses, build.yml's pin, so the rehearsal runs the
# BuildKit that publishes. The GEN_ARCHIVE image is loaded into Docker if it is not there yet (removed again after).
# Prints "PASS <name>" per assertion and stops at the first failure. The registry container (and its volume), the
# buildx builder, the images it creates and the temp files are removed on exit (also on failure). The registry listens
# on 127.0.0.1 only, on PORT_1 when it is set, else on a port Docker picks.
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
digest() { docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' | jq -r .digest; }
# tags FILE TAG...: a stub of the git release tags as the publish job lists them (one per line).
tags() { local f=$1; shift; printf '%s\n' "$@" > "$f"; }
# stub REF KEY VERSION: a label-only image (no layers, no attestations) with this build key and version label.
mkdir "$TMP/stub"
printf 'FROM scratch\n' > "$TMP/stub/Dockerfile"
stub() {
  docker buildx build -q --provenance false --sbom false --label "org.kickedro.build-key=$2" \
    --label "org.opencontainers.image.version=$3" --output "type=image,name=$1,push=true" "$TMP/stub" >/dev/null
}

# VERSION holds the release line, MAJOR.MINOR, and nothing else.
printf '0.1\n' > "$TMP/VERSION"
[ "$("$P" line "$TMP/VERSION")" = 0.1 ] || fail line_accepts_major_minor "0.1 (with a final newline)"
printf '12.34' > "$TMP/VERSION"
[ "$("$P" line "$TMP/VERSION")" = 12.34 ] || fail line_accepts_major_minor "12.34 (without a final newline)"
pass line_accepts_major_minor
for bad in '0.01\n' '1\n' '0.2.0\n' ' 0.2\n' '0.2 \n' '0.2\r\n' '' '\n' '0.1\n0.2\n' '0.1\n\n' 'v0.2\n' '10000.0\n'; do
  printf '%b' "$bad" > "$TMP/VERSION"
  if out=$("$P" line "$TMP/VERSION" 2>"$TMP/line.log"); then
    fail line_refuses_bad_versions "accepted '$bad' as '$out'"
  fi
  [ -z "$out" ] || fail line_refuses_bad_versions "'$bad': printed '$out'"
  grep -q 'MAJOR.MINOR' "$TMP/line.log" || fail line_refuses_bad_versions "'$bad': $(cat "$TMP/line.log")"
done
if "$P" line "$TMP/no-such-file" 2>"$TMP/line.log"; then
  fail line_refuses_bad_versions "a missing VERSION file was accepted"
fi
pass line_refuses_bad_versions

# The first publish of the line: no release tag, no :latest anywhere.
: > "$TMP/no-tags"
[ "$(decide "$KEY" 0.1 "$TMP/no-tags" false "$REG/edge" "$REG/gen")" = true ] \
  || fail decide_publishes_without_latest "no :latest yet must publish"
pass decide_publishes_without_latest
[ "$("$P" next-version 0.1 "$TMP/no-tags" "$REG/edge" "$REG/gen")" = 0.1.0 ] \
  || fail next_version_first_of_line "the first version of line 0.1 must be 0.1.0"
pass next_version_first_of_line
# Only vMAJOR.MINOR.PATCH tags count: no pre-releases, other names, tags without the v or with leading zeros.
tags "$TMP/tags" v0.1.0 v0.1.1 v0.1.0-rc1 vfoo 0.1.7 v0.1.08 v1.0.0-rc1 $'v0.1.9\r'
got=$("$P" next-version 0.1 "$TMP/tags" "$REG/edge" "$REG/gen")
[ "$got" = 0.1.2 ] || fail next_version_after_tags "got '$got', expected 0.1.2"
pass next_version_after_tags
if out=$("$P" next-version 0.1 "$TMP/no-tags" "localhost:1/unreachable" 2>"$TMP/version.log"); then
  fail next_version_refuses_to_guess "a version was chosen although the registry could not be asked: '$out'"
fi
{ [ -z "$out" ] && grep -q 'cannot tell whether' "$TMP/version.log"; } \
  || fail next_version_refuses_to_guess "$(cat "$TMP/version.log")"
pass next_version_refuses_to_guess
# Without the list of git tags neither may go on (a release would look missing): fail, never assume there is none.
if out=$(decide "$KEY" 0.1 "$TMP/no-such-file" false "$REG/edge" "$REG/gen" 2>"$TMP/decide.log"); then
  fail tag_list_required "decide answered '$out' without the tag list"
fi
if out=$("$P" next-version 0.1 "$TMP/no-such-file" "$REG/edge" "$REG/gen" 2>"$TMP/version.log"); then
  fail tag_list_required "next-version answered '$out' without the tag list"
fi
{ grep -q 'cannot read' "$TMP/decide.log" && grep -q 'cannot read' "$TMP/version.log"; } \
  || fail tag_list_required "$(cat "$TMP/decide.log" "$TMP/version.log")"
pass tag_list_required

edge=$("$P" push "$EDGE_ARCHIVE" "$EDGE_ID" "$REG/edge" "$KEY" 0.1.0)
gen=$("$P" push "$GEN_ARCHIVE" "$GEN_ID" "$REG/gen" "$KEY" 0.1.0)
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

"$P" tag "$REG/edge" "$edge" 0.1.0 0.1 latest
"$P" tag "$REG/gen" "$gen" 0.1.0 0.1 latest
pass tags_point_at_the_pushed_digests

# The release job has created v0.1.0. The next day's build has the same content.
tags "$TMP/tags" v0.1.0
[ "$(decide "$KEY" 0.1 "$TMP/tags" false "$REG/edge" "$REG/gen")" = false ] \
  || fail decide_skips_unchanged "same key, released line must skip"
pass decide_skips_unchanged
# A run that publishes nothing checks that the version the :latest images carry has its Release, i.e. its git tag
# (publishing the Release creates it): a release job that failed leaves none, and the run must stay red.
"$P" released "$TMP/tags" "$REG/edge" "$REG/gen" 2>"$TMP/released.log" \
  || fail released_ok "v0.1.0 is tagged: $(cat "$TMP/released.log")"
pass released_ok
tags "$TMP/tags" v0.0.9 v0.1.0-rc1 0.1.0 # a draft of v0.1.0 has no git tag either
if "$P" released "$TMP/tags" "$REG/edge" "$REG/gen" 2>"$TMP/released.log"; then
  fail released_refuses_missing_tag "passed without the git tag v0.1.0"
fi
grep -qF 'Release v0.1.0 is missing: re-run the failed release job of the run that published it' \
  "$TMP/released.log" || fail released_refuses_missing_tag "$(cat "$TMP/released.log")"
[ "$(grep -c 'is missing' "$TMP/released.log")" = 1 ] \
  || fail released_refuses_missing_tag "one message per missing version: $(cat "$TMP/released.log")"
pass released_refuses_missing_tag
# Labels from before versions (the date-based tags) and a repository without :latest are not checked.
stub "$REG/legacy:latest" "$KEY" 1.31.8-modsec3.0.17-crs4.30.0-20261116.3
"$P" released "$TMP/no-tags" "$REG/legacy" "$REG/no-latest" 2>"$TMP/released.log" \
  || fail released_ignores_legacy_labels "$(cat "$TMP/released.log")"
pass released_ignores_legacy_labels
if "$P" released "$TMP/tags" "localhost:1/unreachable" 2>"$TMP/released.log"; then
  fail released_refuses_to_guess "passed although the registry could not be asked"
fi
grep -q 'cannot tell whether' "$TMP/released.log" || fail released_refuses_to_guess "$(cat "$TMP/released.log")"
pass released_refuses_to_guess
tags "$TMP/tags" v0.1.0
[ "$(decide "$OTHER_KEY" 0.1 "$TMP/tags" false "$REG/edge" "$REG/gen")" = true ] \
  || fail decide_publishes_a_changed_key "another key must publish"
pass decide_publishes_a_changed_key
[ "$(decide "$KEY" 0.1 "$TMP/tags" false "$REG/edge" "$REG/gen" "$REG/missing")" = true ] \
  || fail decide_publishes_if_any_latest_is_missing "a missing :latest must publish"
pass decide_publishes_if_any_latest_is_missing
[ "$(decide "$KEY" 0.1 "$TMP/tags" true "$REG/edge" "$REG/gen")" = true ] \
  || fail decide_force_publish "force_publish must publish"
pass decide_force_publish

# A pull request bumped VERSION to 0.2 without changing the content: 0.2 has no release yet, so it publishes.
stub "$REG/line-edge:latest" "$KEY" 0.1.4
stub "$REG/line-gen:latest" "$KEY" 0.1.4
tags "$TMP/tags" v0.1.0 v0.1.1 v0.1.2 v0.1.3 v0.1.4
[ "$(decide "$KEY" 0.2 "$TMP/tags" false "$REG/line-edge" "$REG/line-gen")" = true ] \
  || fail decide_publishes_a_new_line "line 0.2 without a release must publish"
[ "$(decide "$KEY" 0.1 "$TMP/tags" false "$REG/line-edge" "$REG/line-gen")" = false ] \
  || fail decide_publishes_a_new_line "the same state on line 0.1 must skip"
pass decide_publishes_a_new_line
# 0.2.0 was published and tagged, but its git tag is missing (the release job failed): not published again.
stub "$REG/half-edge:latest" "$KEY" 0.2.0
stub "$REG/half-gen:latest" "$KEY" 0.2.0
[ "$(decide "$KEY" 0.2 "$TMP/tags" false "$REG/half-edge" "$REG/half-gen")" = false ] \
  || fail decide_new_line_already_published "a line both :latest images carry must not publish again"
pass decide_new_line_already_published
# Only one image reached 0.2 (the publish failed between the two): the other still needs the line, so it publishes.
[ "$(decide "$KEY" 0.2 "$TMP/tags" false "$REG/half-edge" "$REG/line-gen")" = true ] \
  || fail decide_new_line_on_one_latest_only "a line only one :latest carries must publish"
pass decide_new_line_on_one_latest_only
# A VERSION lower than a released line fails the run, publishing or not.
if out=$(decide "$KEY" 0.1 "$TMP/tags" false "$REG/half-edge" "$REG/half-gen" 2>"$TMP/decide.log"); then
  fail decide_refuses_lower_line "decided '$out' for line 0.1 although 0.2.0 is released"
fi
grep -q 'lower than' "$TMP/decide.log" || fail decide_refuses_lower_line "$(cat "$TMP/decide.log")"
pass decide_refuses_lower_line

# The next version counts the :latest version labels too: 0.2.0 has no git tag and no 0.2.0 image tag, only the label.
got=$("$P" next-version 0.2 "$TMP/tags" "$REG/half-edge" "$REG/half-gen")
[ "$got" = 0.2.1 ] || fail next_version_after_latest_labels "got '$got', expected 0.2.1"
pass next_version_after_latest_labels
# Versions only the registry has (pushed and tagged, then the run failed) are skipped, in every repository.
stub "$REG/skip-edge:0.1.1" "$KEY" 0.1.1
stub "$REG/skip-gen:0.1.2" "$KEY" 0.1.2
tags "$TMP/tags" v0.1.0
got=$("$P" next-version 0.1 "$TMP/tags" "$REG/skip-edge" "$REG/skip-gen")
[ "$got" = 0.1.3 ] || fail next_version_skips_registry_versions "got '$got', expected 0.1.3"
pass next_version_skips_registry_versions
tags "$TMP/tags" v0.1.0 v0.2.0
if out=$("$P" next-version 0.1 "$TMP/tags" "$REG/edge" "$REG/gen" 2>"$TMP/version.log"); then
  fail next_version_refuses_lower_line "chose '$out' on line 0.1 although v0.2.0 exists"
fi
grep -q 'lower than' "$TMP/version.log" || fail next_version_refuses_lower_line "$(cat "$TMP/version.log")"
stub "$REG/high:latest" "$KEY" 0.2.3
if out=$("$P" next-version 0.1 "$TMP/no-tags" "$REG/high" 2>"$TMP/version.log"); then
  fail next_version_refuses_lower_line "chose '$out' on line 0.1 although a :latest is 0.2.3"
fi
grep -q 'lower than' "$TMP/version.log" || fail next_version_refuses_lower_line "$(cat "$TMP/version.log")"
pass next_version_refuses_lower_line

if "$P" check "$GEN_ID" "$REG/edge@$edge" "$KEY" 0.1.0 2>"$TMP/check.log"; then
  fail check_other_image "the edge image passed as the tested gen image"
fi
grep -q 'differs from the tested image' "$TMP/check.log" || fail check_other_image "$(cat "$TMP/check.log")"
if "$P" check "$EDGE_ID" "$REG/edge@$edge" "$OTHER_KEY" 0.1.0 2>"$TMP/check.log"; then
  fail check_key "a wrong build key label passed"
fi
if "$P" check "$EDGE_ID" "$REG/edge@$edge" "$KEY" 0.1.1 2>"$TMP/check.log"; then
  fail check_version "a wrong version label passed"
fi
grep -q 'version label' "$TMP/check.log" || fail check_version "$(cat "$TMP/check.log")"
pass check_refuses_other_bits_key_and_version

# A second publish on line 0.1 (the content changed): the next patch, 0.1.1. 0.1 and latest move to the new image,
# 0.1.0 stays where it was and cannot be moved.
tags "$TMP/tags" v0.1.0
next=$("$P" next-version 0.1 "$TMP/tags" "$REG/edge" "$REG/gen")
[ "$next" = 0.1.1 ] || fail second_publish "version '$next', expected 0.1.1"
gen2=$("$P" push "$GEN_ARCHIVE" "$GEN_ID" "$REG/gen" "$KEY" "$next")
[ "$gen2" != "$gen" ] || fail second_publish "the second publish has the first one's digest"
pass second_publish_gets_the_next_patch
if "$P" tag "$REG/gen" "$gen2" 0.1 latest 0.1.0 2>"$TMP/tag.log"; then
  fail tag_moves_line_and_latest_only "0.1.0 was moved to the second image"
fi
grep -q 'never moves' "$TMP/tag.log" || fail tag_moves_line_and_latest_only "$(cat "$TMP/tag.log")"
for t in 0.1.0 0.1 latest; do
  [ "$(digest "$REG/gen:$t")" = "$gen" ] || fail tag_moves_line_and_latest_only "gen:$t was moved by a refused tag"
done
"$P" tag "$REG/gen" "$gen2" "$next" 0.1 latest
for t in "0.1.0=$gen" "0.1.1=$gen2" "0.1=$gen2" "latest=$gen2"; do
  got=$(digest "$REG/gen:${t%%=*}")
  [ "$got" = "${t#*=}" ] || fail tag_moves_line_and_latest_only "gen:${t%%=*} is $got, expected ${t#*=}"
done
pass tag_moves_line_and_latest_only

if "$P" push "$EDGE_ARCHIVE" "$GEN_ID" "$REG/mismatch" "$KEY" 0.1.0 >"$TMP/push.out" 2>"$TMP/push.log"; then
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
if "$P" push "$TMP/derived.tar" "$GEN_ID" "$REG/derived" "$KEY" 0.1.0 >"$TMP/push.out" 2>"$TMP/push.log"; then
  fail one_layer "push succeeded although one layer differs from the tested image"
fi
grep -q 'differs from the tested image' "$TMP/push.log" || fail one_layer "$(tail -n 5 "$TMP/push.log")"
pass push_refuses_one_changed_layer

echo "ALL PASS"
