#!/usr/bin/env bash
# Test for scripts/build_key.sh, the content key that decides whether CI publishes a build.
#   tests/build_key_test.sh VERSIONS EDGE EDGE_METADATA GEN GEN_METADATA [EDGE2 EDGE2_METADATA GEN2 GEN2_METADATA]
# VERSIONS is the versions file the images were built from, *_METADATA the buildx metadata files of their builds
# (--metadata-file, or build-push-action's metadata output). The optional second set is the same source built again
# with another SECURITY_EPOCH: the test then also requires the image ids to differ (the upgrade layers re-ran) and
# the key to stay the same.
# Prints "PASS <name>" per assertion and stops at the first failure. The derived images and temp files it creates
# are removed on exit (also on failure). Needs docker and jq; run from a git checkout (the key reads HEAD).
set -euo pipefail

usage="usage: tests/build_key_test.sh VERSIONS EDGE EDGE_METADATA GEN GEN_METADATA [EDGE2 EDGE2_METADATA GEN2 GEN2_METADATA]"
[ $# -eq 5 ] || [ $# -eq 9 ] || { echo "$usage" >&2; exit 2; }
VERSIONS=$1 EDGE=$2 EDGE_MD=$3 GEN=$4 GEN_MD=$5
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KEY="$ROOT/scripts/build_key.sh"
command -v jq >/dev/null || { echo "FAIL setup: jq is required on the host" >&2; exit 1; }

RUN="keytest-$$-$RANDOM"
TMP=$(mktemp -d)
cleanup() {
  docker image rm -f "$RUN-edge-pkg" "$RUN-gen-pkg" "$RUN-gen-bin" "$RUN-edge-lib" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2" >&2; exit 1; }
key() { "$KEY" "$@"; }

# derive NEW_IMAGE IMAGE SHELL_COMMAND: IMAGE with one change made inside it (docker commit, no build needed).
derive() {
  local c
  c=$(docker create --pull=never --network none --entrypoint sh "$2" -c "$3")
  docker start -a "$c" >/dev/null
  docker commit "$c" "$1" >/dev/null
  docker rm "$c" >/dev/null
}
bump_first_package_version='sed -i "0,/^Version: /s/^Version: .*$/&+keytest/" /var/lib/dpkg/status'

base=$(BUILD_KEY_INPUTS="$TMP/inputs" key "$VERSIONS" "$EDGE" "$EDGE_MD" "$GEN" "$GEN_MD")
[[ $base =~ ^sha256:[0-9a-f]{64}$ ]] || fail format "not sha256:<64 hex>: $base"
again=$(key "$VERSIONS" "$EDGE" "$EDGE_MD" "$GEN" "$GEN_MD")
[ "$again" = "$base" ] || fail deterministic "$base then $again"
pass format_and_deterministic

for p in edge gen pins.env .github/workflows/build.yml; do
  id=$(git -C "$ROOT" rev-parse --verify "HEAD:$p")
  grep -qxF "$p $id" "$TMP/inputs" || fail source_in_inputs "no line '$p $id'"
done
for section in 'edge packages' 'gen packages' 'edge files' 'gen files' 'edge materials' 'gen materials'; do
  grep -qxF "[$section]" "$TMP/inputs" || fail sections_in_inputs "no [$section] section"
done
grep -qi 'epoch' "$TMP/inputs" && fail no_epoch_in_inputs "SECURITY_EPOCH must not be an input"
pass inputs_have_source_sections_and_no_epoch

if [ $# -eq 9 ]; then
  EDGE2=$6 EDGE2_MD=$7 GEN2=$8 GEN2_MD=$9
  [ "$(docker image inspect -f '{{.Id}}' "$EDGE")" != "$(docker image inspect -f '{{.Id}}' "$EDGE2")" ] \
    || fail stable_across_epoch "the two edge builds are the same image; build the second with another SECURITY_EPOCH"
  [ "$(docker image inspect -f '{{.Id}}' "$GEN")" != "$(docker image inspect -f '{{.Id}}' "$GEN2")" ] \
    || fail stable_across_epoch "the two gen builds are the same image; build the second with another SECURITY_EPOCH"
  other=$(BUILD_KEY_INPUTS="$TMP/inputs2" key "$VERSIONS" "$EDGE2" "$EDGE2_MD" "$GEN2" "$GEN2_MD")
  [ "$other" = "$base" ] || fail stable_across_epoch "$base vs $other; diff of the inputs: $(diff "$TMP/inputs" "$TMP/inputs2" || true)"
  pass stable_across_security_epoch
fi

sed 's/^CRS_VERSION=.*/&-keytest/' "$VERSIONS" > "$TMP/versions"
cmp -s "$VERSIONS" "$TMP/versions" && fail versions_value "test setup: no CRS_VERSION line in $VERSIONS"
[ "$(key "$TMP/versions" "$EDGE" "$EDGE_MD" "$GEN" "$GEN_MD")" != "$base" ] || fail versions_value "key unchanged"
pass changes_with_a_versions_value

derive "$RUN-edge-pkg" "$EDGE" "$bump_first_package_version"
[ "$(key "$VERSIONS" "$RUN-edge-pkg" "$EDGE_MD" "$GEN" "$GEN_MD")" != "$base" ] || fail edge_package "key unchanged"
pass changes_with_an_edge_package_version

derive "$RUN-gen-pkg" "$GEN" "$bump_first_package_version"
[ "$(key "$VERSIONS" "$EDGE" "$EDGE_MD" "$RUN-gen-pkg" "$GEN_MD")" != "$base" ] || fail gen_package "key unchanged"
pass changes_with_a_gen_package_version

derive "$RUN-gen-bin" "$GEN" 'printf x >> /usr/local/bin/docker-gen'
[ "$(key "$VERSIONS" "$EDGE" "$EDGE_MD" "$RUN-gen-bin" "$GEN_MD")" != "$base" ] || fail docker_gen_binary "key unchanged"
pass changes_with_the_docker_gen_binary

derive "$RUN-edge-lib" "$EDGE" 'printf x >> /usr/local/lib/libmodsecurity.so.3'
[ "$(key "$VERSIONS" "$RUN-edge-lib" "$EDGE_MD" "$GEN" "$GEN_MD")" != "$base" ] || fail modsecurity_library "key unchanged"
pass changes_with_the_modsecurity_library

# A base image re-pushed under the same tag: other digest in the build's provenance materials.
jq '(.["buildx.build.provenance"].materials[] | select(.uri | startswith("pkg:docker/debian@")) | .digest.sha256)
    |= "0000000000000000000000000000000000000000000000000000000000000000"' "$GEN_MD" > "$TMP/gen-md"
cmp -s <(jq -S . "$GEN_MD") <(jq -S . "$TMP/gen-md") && fail base_digest "test setup: no debian material in $GEN_MD"
[ "$(key "$VERSIONS" "$EDGE" "$EDGE_MD" "$GEN" "$TMP/gen-md")" != "$base" ] || fail base_digest "key unchanged"
pass changes_with_a_base_image_digest

# The Dockerfile frontend (# syntax=docker/dockerfile:1) is how the build runs, not what the image contains.
jq '.["buildx.build.provenance"].materials += [{"uri": "pkg:docker/docker/dockerfile@1",
    "digest": {"sha256": "1111111111111111111111111111111111111111111111111111111111111111"}}]' "$EDGE_MD" > "$TMP/edge-md"
[ "$(key "$VERSIONS" "$EDGE" "$TMP/edge-md" "$GEN" "$GEN_MD")" = "$base" ] || fail frontend "key changed"
pass ignores_the_dockerfile_frontend

jq 'del(.["buildx.build.provenance"])' "$EDGE_MD" > "$TMP/edge-md-none"
if key "$VERSIONS" "$EDGE" "$TMP/edge-md-none" "$GEN" "$GEN_MD" >/dev/null 2>&1; then
  fail no_base_digests "a key was printed without base image digests"
fi
if key "$VERSIONS" "$EDGE" "$EDGE_MD" "$RUN-missing-image" "$GEN_MD" >/dev/null 2>&1; then
  fail missing_image "a key was printed for a missing image"
fi
pass fails_without_base_digests_or_image

echo "ALL PASS"
