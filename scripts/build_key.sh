#!/usr/bin/env bash
# Content build key:
#   scripts/build_key.sh VERSIONS_FILE EDGE_IMAGE EDGE_METADATA GEN_IMAGE GEN_METADATA
# Prints "sha256:<hex>". CI compares it with the org.kickedro.build-key label of the published :latest images to
# decide whether a tested build is worth publishing. It describes what is IN the built images, so it stays the same
# from one day to the next while nothing meaningful changed, although the images are rebuilt every day (the
# SECURITY_EPOCH build argument re-runs the upgrade layers, so image digests and timestamps change daily: they are
# deliberately not inputs, and neither is SECURITY_EPOCH).
#
# Inputs, hashed as one canonical text in this order:
#   versions     every line of VERSIONS_FILE (all resolved upstream versions), sorted
#   source       git object ids at HEAD of edge/, gen/, pins.env and .github/workflows/build.yml (Dockerfiles,
#                configuration, build arguments, labels). Uncommitted changes are not seen: run it on a clean
#                checkout, as CI does.
#   materials    what each build fetched, with digests, from buildx's metadata file (--metadata-file, or
#                build-push-action's metadata output; "buildx.build.provenance" materials): the base images the
#                FROM lines resolved to and downloaded files. The Dockerfile frontend (docker/dockerfile) is left
#                out: it is how the build runs, not what the image contains.
#   per image    the Debian packages with their versions (dpkg-query), and the sha256 of the files no package owns
#                that the build compiles: edge's libmodsecurity and ModSecurity nginx module, gen's docker-gen
#                binary (which also covers its Go version and module versions).
# The images must be present locally; they are run with --pull=never and no network.
# BUILD_KEY_INPUTS=FILE also writes the canonical text to FILE (CI prints it, so the reason for a new key can be read
# in the log). Exit 0 with the key, 1 on any failure (unreadable file, missing image or binary, no base image in a
# metadata file): never a partial key.
set -euo pipefail

[ $# -eq 5 ] || { echo "usage: scripts/build_key.sh VERSIONS_FILE EDGE_IMAGE EDGE_METADATA GEN_IMAGE GEN_METADATA" >&2; exit 1; }
versions=$1 edge=$2 edge_md=$3 gen=$4 gen_md=$5
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v jq >/dev/null || { echo "build_key: jq is required" >&2; exit 1; }
for f in "$versions" "$edge_md" "$gen_md"; do
  [ -r "$f" ] || { echo "build_key: cannot read $f" >&2; exit 1; }
done
grep -q '^NGINX_VERSION=' "$versions" || { echo "build_key: $versions is not a versions file" >&2; exit 1; }

text=$(mktemp)
trap 'rm -f "$text"' EXIT

in_image() { # IMAGE COMMAND ARGS...
  docker run --rm --pull=never --network none --entrypoint "$2" "$1" "${@:3}"
}

materials() { # METADATA_FILE: "<uri> sha256:<hex>" lines, fails without a base image or with a malformed entry
  jq -r '.["buildx.build.provenance"].materials
    | if type != "array" or (map(select(.uri | startswith("pkg:docker/"))) | length) == 0
      then error("no base image in the provenance materials") else . end
    | .[] | select(.uri | startswith("pkg:docker/docker/dockerfile@") | not)
    | if (.digest.sha256 | type) == "string" and (.digest.sha256 | test("^[0-9a-f]{64}$"))
      then "\(.uri) sha256:\(.digest.sha256)" else error("malformed material: \(.)") end' "$1" | LC_ALL=C sort -u
}

image_section() { # NAME IMAGE FILE...
  local name=$1 image=$2
  shift 2
  echo "[$name packages]"
  # shellcheck disable=SC2016 # dpkg-query's own ${field} syntax, not shell expansion
  in_image "$image" dpkg-query -W -f '${db:Status-Abbrev} ${binary:Package} ${Version}\n' | LC_ALL=C sort
  echo "[$name files]"
  in_image "$image" sha256sum "$@"
}

{
  echo "edge-proxy build key v1"
  echo "[versions]"
  LC_ALL=C sort "$versions"
  echo "[source]"
  for p in edge gen pins.env .github/workflows/build.yml; do
    id=$(git -C "$root" rev-parse --verify "HEAD:$p")
    echo "$p $id"
  done
  echo "[edge materials]"
  materials "$edge_md"
  echo "[gen materials]"
  materials "$gen_md"
  image_section edge "$edge" /usr/local/lib/libmodsecurity.so.3 /usr/lib/nginx/modules/ngx_http_modsecurity_module.so
  image_section gen "$gen" /usr/local/bin/docker-gen
} > "$text"

if [ -n "${BUILD_KEY_INPUTS:-}" ]; then
  cp "$text" "$BUILD_KEY_INPUTS"
fi
sum=$(sha256sum "$text")
echo "sha256:${sum%% *}"
