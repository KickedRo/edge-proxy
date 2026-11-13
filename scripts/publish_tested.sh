#!/usr/bin/env bash
# Publishing steps of build.yml's publish job. tests/publish_rehearsal.sh runs the same steps against a local
# registry in every CI build, so they are exercised before they ever run against the real registry.
#
#   scripts/publish_tested.sh identity IMAGE
#     Prints (JSON, sorted keys) what makes a local image what it is: OS, architecture and variant, the layer diff IDs
#     (sha256 of each uncompressed layer, i.e. the filesystem bit for bit) and the runtime configuration as
#     `docker image inspect` shows it (env, entrypoint, cmd, user, working dir, labels, ...), without the
#     org.kickedro.build-key label, which only exists after testing. Timestamps and image ids are not part of it.
#
#   scripts/publish_tested.sh decide KEY WEEKDAY FORCE_PUBLISH FORCE_SKIP_CHECK REPOSITORY...
#     Prints "true" (publish) or "false" (skip); the reasons go to stderr. Publish when the :latest of any
#     REPOSITORY does not carry KEY as its org.kickedro.build-key label (a missing or unreadable :latest counts as
#     different), or WEEKDAY (ISO 8601, 1 = Monday, UTC) is 1 and FORCE_SKIP_CHECK is not true (weekly publish), or
#     FORCE_PUBLISH is true.
#
#   scripts/publish_tested.sh push ARCHIVE TESTED_IDENTITY REPOSITORY KEY
#     Publishes the tested image without rebuilding it. ARCHIVE is `docker save` of the tested image (an OCI image
#     layout since Docker 25); a one-line Dockerfile `FROM tested`, with the archive as the named build context
#     "tested", adds the org.kickedro.build-key label (a configuration change, no layer) and is pushed by digest
#     only (no tag), with buildx's SBOM attestation (syft scanner pinned below) and provenance (mode=max; builder id
#     from PROVENANCE_BUILDER_ID when set). Then `check` must pass. Prints the pushed digest (of the manifest index).
#
#   scripts/publish_tested.sh check TESTED_IDENTITY REF KEY
#     The same-bits check: pulls REF and requires its org.kickedro.build-key label to be KEY and its identity (see
#     above) to equal TESTED_IDENTITY, the identity of the image the smoke tests and the Trivy gate ran on. Prints
#     the difference otherwise. The pulled image is removed again.
#
#   scripts/publish_tested.sh tag REPOSITORY DIGEST TAG...
#     Points each TAG at DIGEST (`docker buildx imagetools create` with a single manifest-index source re-tags it
#     unchanged) and verifies that every tag now resolves to DIGEST.
#
# The buildx builder is the current one (BUILDX_BUILDER selects another); registry credentials come from
# `docker login`. Exit 0 on success, 2 on usage errors, another non-zero status on any failure.
set -euo pipefail

# BuildKit's SBOM generator, docker/buildkit-syft-scanner 1.12.1 (the stable-1 tag on 2026-11-13), pinned by digest.
SBOM_GENERATOR=docker/buildkit-syft-scanner@sha256:873a7458c3c8ac8e32c7b796c10e1600b07b963d2aa000a72a2d97aaaa2d6315
KEY_LABEL=org.kickedro.build-key

die() { echo "publish_tested: $*" >&2; exit 1; }
usage() { grep '^#   scripts/publish_tested.sh ' "$0" | sed 's/^#   /usage: /' >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

identity() {
  docker image inspect "$1" | jq -S --arg l "$KEY_LABEL" '.[0] | {
    Os, Architecture, Variant: (.Variant // ""),
    DiffIDs: .RootFS.Layers,
    Config: (.Config | .Labels = ((.Labels // {}) | del(.[$l])))}'
}

latest_key() { # REPOSITORY: the build key of REPOSITORY:latest, or nothing
  local out
  if ! out=$(docker buildx imagetools inspect "$1:latest" --format '{{json .Image}}' 2>&1); then
    echo "$1:latest: not readable (${out//$'\n'/ })" >&2
    return 0
  fi
  jq -r --arg l "$KEY_LABEL" '.config.Labels[$l] // empty' <<<"$out" 2>/dev/null || true
}

decide() {
  [ $# -ge 5 ] || usage
  local key=$1 weekday=$2 force_publish=$3 force_skip_check=$4 publish=false repo current
  shift 4
  [[ $weekday =~ ^[1-7]$ ]] || die "WEEKDAY must be 1-7, got '$weekday'"
  [[ $force_publish =~ ^(true|false)$ && $force_skip_check =~ ^(true|false)$ ]] \
    || die "FORCE_PUBLISH and FORCE_SKIP_CHECK must be true or false"
  for repo in "$@"; do
    current=$(latest_key "$repo")
    if [ "$current" = "$key" ]; then
      echo "unchanged: $repo:latest has this build's key $key" >&2
    else
      publish=true
      echo "changed: $repo:latest has build key '${current:-none}', this build $key" >&2
    fi
  done
  if [ "$weekday" = 1 ]; then
    if [ "$force_skip_check" = true ]; then
      echo "Monday, but force_skip_check: no weekly publish" >&2
    else
      publish=true
      echo "Monday: weekly publish" >&2
    fi
  fi
  if [ "$force_publish" = true ]; then
    publish=true
    echo "force_publish" >&2
  fi
  echo "$publish"
}

image_manifest() { # LAYOUT_DIR: digest of the single image manifest in an OCI layout of one image
  local dir=$1 top type
  [ "$(jq '.manifests | length' "$dir/index.json")" = 1 ] || die "expected exactly one image in the archive"
  top=$(jq -r '.manifests[0].digest' "$dir/index.json")
  type=$(jq -r '.manifests[0].mediaType' "$dir/index.json")
  case "$type" in
    application/vnd.oci.image.manifest.v1+json | application/vnd.docker.distribution.manifest.v2+json)
      echo "$top" ;;
    application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json)
      # An index of one image plus attestation manifests (what Docker's containerd image store saves).
      jq -r '[.manifests[] | select(.annotations["vnd.docker.reference.type"] != "attestation-manifest")]
        | if length == 1 then .[0].digest else error("expected one image manifest in the index") end' \
        "$dir/blobs/sha256/${top#sha256:}" ;;
    *) die "unexpected media type in the archive: $type" ;;
  esac
}

check() {
  [ $# -eq 3 ] || usage
  local tested=$1 ref=$2 key=$3 got
  [ -r "$tested" ] || die "cannot read $tested"
  docker pull -q "$ref" >/dev/null
  got=$(docker image inspect -f "{{index .Config.Labels \"$KEY_LABEL\"}}" "$ref")
  identity "$ref" > "$WORK/pushed-identity.json"
  docker image rm "$ref" >/dev/null 2>&1 || true
  [ "$got" = "$key" ] || die "$ref: build key label is '$got', expected $key"
  if ! diff -u <(jq -S . "$tested") "$WORK/pushed-identity.json" >&2; then
    die "$ref differs from the tested image (diff above: - tested, + pushed)"
  fi
  echo "same bits: $ref has the tested image's $(jq '.DiffIDs | length' "$tested") layers and configuration," \
    "plus build key $key" >&2
}

push() {
  [ $# -eq 4 ] || usage
  local archive=$1 tested=$2 repo=$3 key=$4 manifest digest
  [ -r "$archive" ] || die "cannot read $archive"
  [ -r "$tested" ] || die "cannot read $tested"
  [[ $key =~ ^sha256:[0-9a-f]{64}$ ]] || die "KEY must be sha256:<64 hex digits>"
  mkdir "$WORK/layout" "$WORK/context"
  tar -xf "$archive" -C "$WORK/layout"
  [ -f "$WORK/layout/oci-layout" ] && [ -f "$WORK/layout/index.json" ] \
    || die "$archive is not an OCI image layout (docker save of Docker 25 or later)"
  manifest=$(image_manifest "$WORK/layout")
  printf 'FROM tested\n' > "$WORK/context/Dockerfile"
  docker buildx build --progress plain \
    --build-context "tested=oci-layout://$WORK/layout@$manifest" \
    --label "$KEY_LABEL=$key" \
    --sbom "generator=$SBOM_GENERATOR" \
    --provenance "mode=max${PROVENANCE_BUILDER_ID:+,builder-id=$PROVENANCE_BUILDER_ID}" \
    --output "type=image,name=$repo,push-by-digest=true,name-canonical=true,push=true,compression=gzip,force-compression=true,oci-mediatypes=true" \
    --metadata-file "$WORK/metadata.json" "$WORK/context" >&2
  digest=$(jq -r '."containerimage.digest" // empty' "$WORK/metadata.json")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "no image digest in the build metadata"
  check "$tested" "$repo@$digest" "$key"
  echo "$digest"
}

tag() {
  [ $# -ge 3 ] || usage
  local repo=$1 digest=$2 t got
  shift 2
  local args=()
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "DIGEST must be sha256:<64 hex digits>"
  for t in "$@"; do
    [[ $t =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "not a valid tag: '$t'"
    args+=(--tag "$repo:$t")
  done
  docker buildx imagetools create "${args[@]}" "$repo@$digest" >&2
  for t in "$@"; do
    got=$(docker buildx imagetools inspect "$repo:$t" --format '{{json .Manifest}}' | jq -r '.digest')
    [ "$got" = "$digest" ] || die "$repo:$t resolves to $got, expected $digest"
    echo "tagged: $repo:$t -> $digest" >&2
  done
}

[ $# -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  identity) [ $# -eq 1 ] || usage; identity "$1" ;;
  decide) decide "$@" ;;
  push) push "$@" ;;
  check) check "$@" ;;
  tag) tag "$@" ;;
  *) usage ;;
esac
