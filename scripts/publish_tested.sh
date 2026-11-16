#!/usr/bin/env bash
# Publishing steps of build.yml's publish job. tests/publish_rehearsal.sh runs the same steps against a local
# registry in every CI build, so they are exercised before they ever run against the real registry.
#
#   scripts/publish_tested.sh identity IMAGE
#     Prints (JSON, sorted keys) what makes a local image what it is: OS, architecture and variant, the layer diff IDs
#     (sha256 of each uncompressed layer, i.e. the filesystem bit for bit) and the runtime configuration as
#     `docker image inspect` shows it (env, entrypoint, cmd, user, working dir, labels, ...), without the two labels
#     that are set when publishing: org.kickedro.build-key (it only exists after testing) and
#     org.opencontainers.image.version (the version, chosen at publish time). Timestamps and image ids are not part of
#     it.
#
#   scripts/publish_tested.sh line VERSION_FILE
#     Prints the release line MAJOR.MINOR that VERSION_FILE holds: exactly one line of two numbers without leading
#     zeros (at most 4 digits each), a final newline allowed; anything else (CR, spaces, a third component, a second
#     line, an empty file) fails.
#
#   scripts/publish_tested.sh decide KEY LINE TAGS_FILE FORCE_PUBLISH REPOSITORY...
#     Prints "true" (publish) or "false" (skip); the reasons go to stderr. Publish when the :latest of any
#     REPOSITORY does not carry KEY as its org.kickedro.build-key label (a missing or unreadable :latest counts as
#     different), or LINE has no release yet, or FORCE_PUBLISH is true. LINE has a release when TAGS_FILE (the git
#     tags, one per line; only vMAJOR.MINOR.PATCH ones count) has a vLINE.N tag, or the :latest of every REPOSITORY
#     carries a LINE.N version label (a release whose git tag is missing must not publish again; one that reached only
#     some of the images must). Fails when LINE is lower than a released version (see next-version).
#
#   scripts/publish_tested.sh next-version LINE TAGS_FILE REPOSITORY...
#     Prints the version of a publish now, LINE.N: N is one more than the highest PATCH of LINE among the git tags
#     vMAJOR.MINOR.PATCH in TAGS_FILE (one per line; other lines are ignored) and the version labels of each
#     REPOSITORY's :latest (when they are MAJOR.MINOR.PATCH), or 0 when there is none; then the first LINE.N, LINE.N+1,
#     ... that no REPOSITORY has as an image tag (at most 100 tried). A version is never re-used. Fails when any of
#     those versions is on a higher MAJOR.MINOR than LINE (VERSION must not go back), or when the registry cannot
#     tell whether a :latest or a tag exists.
#
#   scripts/publish_tested.sh released TAGS_FILE REPOSITORY...
#     For a run that publishes nothing: the version each REPOSITORY's :latest carries (its version label, when it is
#     MAJOR.MINOR.PATCH) must have its git tag vMAJOR.MINOR.PATCH in TAGS_FILE (as for next-version), which only
#     publishing its GitHub Release creates (a draft has none). Fails otherwise, with "Release vX.Y.Z is missing: ..."
#     once per missing version, so the run stays red until the failed release job is re-run. Other labels (the
#     date-based tags from before versions) and a missing :latest are not checked. Fails when the registry cannot tell.
#
#   scripts/publish_tested.sh push ARCHIVE TESTED_IDENTITY REPOSITORY KEY RELEASE_TAG
#     Publishes the tested image without rebuilding it. ARCHIVE is `docker save` of the tested image (an OCI image
#     layout since Docker 25); a one-line Dockerfile `FROM tested`, with the archive as the named build context
#     "tested", adds the org.kickedro.build-key label KEY and the org.opencontainers.image.version label RELEASE_TAG
#     (the version, X.Y.Z; configuration changes, no layer) and is pushed by digest only (no tag), with buildx's SBOM
#     attestation (syft scanner pinned below) and provenance (mode=max; builder id from PROVENANCE_BUILDER_ID when
#     set). Then `check` must pass. Prints the pushed digest (of the manifest index).
#
#   scripts/publish_tested.sh check TESTED_IDENTITY REF KEY RELEASE_TAG
#     The same-bits check: pulls REF and requires its org.kickedro.build-key label to be KEY, its
#     org.opencontainers.image.version label to be RELEASE_TAG, and its identity (see above) to equal TESTED_IDENTITY,
#     the identity of the image the smoke tests and the Trivy gate ran on. Prints the difference otherwise. The pulled
#     image is removed again.
#
#   scripts/publish_tested.sh tag REPOSITORY DIGEST TAG...
#     Points each TAG at DIGEST (`docker buildx imagetools create` with a single manifest-index source re-tags it
#     unchanged) and verifies that every tag now resolves to DIGEST. Only `latest` and MAJOR.MINOR tags (the newest
#     patch of a line) may move: any other TAG, a version X.Y.Z above all, that already points elsewhere is refused
#     before anything is tagged.
#
# The buildx builder is the current one (BUILDX_BUILDER selects another); registry credentials come from
# `docker login`. Exit 0 on success, 2 on usage errors, another non-zero status on any failure.
set -euo pipefail

# BuildKit's SBOM generator, docker/buildkit-syft-scanner 1.12.1 (the stable-1 tag on 2026-11-13), pinned by digest.
SBOM_GENERATOR=docker/buildkit-syft-scanner@sha256:873a7458c3c8ac8e32c7b796c10e1600b07b963d2aa000a72a2d97aaaa2d6315
KEY_LABEL=org.kickedro.build-key
VERSION_LABEL=org.opencontainers.image.version
TAG_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
LINE_RE='^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})$'                     # MAJOR.MINOR, as VERSION holds it
VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'          # MAJOR.MINOR.PATCH
MOVABLE_RE='^(latest|(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))$'                  # the image tags that may move

die() { echo "publish_tested: $*" >&2; exit 1; }
usage() { grep '^#   scripts/publish_tested.sh ' "$0" | sed 's/^#   /usage: /' >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

identity() {
  docker image inspect "$1" | jq -S --arg k "$KEY_LABEL" --arg v "$VERSION_LABEL" '.[0] | {
    Os, Architecture, Variant: (.Variant // ""),
    DiffIDs: .RootFS.Layers,
    Config: (.Config | .Labels = ((.Labels // {}) | del(.[$k], .[$v])))}'
}

digest_of() { # REF: the digest REF resolves to, or nothing when the registry has no such tag; fails when it cannot tell
  local out
  if out=$(docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>&1); then
    jq -er '.digest' <<<"$out" || die "$1: no digest in: $out"
  elif [[ $out == *": not found" ]]; then
    return 0
  else
    die "cannot tell whether $1 exists: ${out//$'\n'/ }"
  fi
}

latest_info() { # REPOSITORY: "<build key> <version>" labels of REPOSITORY:latest ("-" for a missing one), or nothing
  local out
  if ! out=$(docker buildx imagetools inspect "$1:latest" --format '{{json .Image}}' 2>&1); then
    echo "$1:latest: not readable (${out//$'\n'/ })" >&2
    return 0
  fi
  jq -r --arg k "$KEY_LABEL" --arg v "$VERSION_LABEL" \
    '"\(.config.Labels[$k] // "-") \(.config.Labels[$v] // "-")"' <<<"$out" 2>/dev/null || true
}

latest_version() { # REPOSITORY: the version label of REPOSITORY:latest, nothing when it has none or there is no
                   # :latest; fails when the registry cannot tell
  local out
  if out=$(docker buildx imagetools inspect "$1:latest" --format '{{json .Image}}' 2>&1); then
    jq -er --arg v "$VERSION_LABEL" '.config | objects | .Labels[$v] // ""' <<<"$out" \
      || die "$1:latest: no image configuration in: ${out//$'\n'/ }"
  elif [[ $out == *": not found" ]]; then
    return 0
  else
    die "cannot tell whether $1:latest exists: ${out//$'\n'/ }"
  fi
}

version_line() {
  [ $# -eq 1 ] || usage
  local file=$1 content re=${LINE_RE%'$'}$'\n?$' # LINE_RE, and a final newline allowed
  { [ -f "$file" ] && [ -r "$file" ]; } || die "cannot read $file"
  content=$(cat -- "$file"; echo .) # the dot keeps a final newline, which $(...) would drop
  content=${content%.}
  # The byte count catches what $(...) drops silently: NUL bytes.
  if [[ ! $content =~ $re ]] || [ "$(wc -c < "$file")" -ne "${#content}" ]; then
    die "$file must hold the release line MAJOR.MINOR (two numbers without leading zeros, e.g. 0.1) as its only" \
      "line, not $(printf '%q' "$content")"
  fi
  echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
}

tag_versions() { # TAGS_FILE: the version X.Y.Z of each git tag vX.Y.Z in it, one per line; other lines are ignored
  { [ -f "$1" ] && [ -r "$1" ]; } || die "cannot read $1"
  sed -n 's/^v//p' "$1" | LC_ALL=C grep -E "$VERSION_RE" || true
}

highest_patch() { # LINE VERSION...: the highest PATCH among the VERSIONs on LINE (others than X.Y.Z are ignored),
                  # nothing when none is; fails when one is on a higher MAJOR.MINOR than LINE
  local line=$1 v best=
  shift
  for v in "$@"; do
    [[ $v =~ $VERSION_RE ]] || continue
    local major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
    { [ ${#major} -le 9 ] && [ ${#minor} -le 9 ] && [ ${#patch} -le 9 ]; } || die "$v: version number too large"
    if (( major > ${line%.*} || (major == ${line%.*} && minor > ${line#*.}) )); then
      die "the VERSION line $line is lower than the released version $v (the line never goes back)"
    fi
    if [ "$major.$minor" = "$line" ] && { [ -z "$best" ] || [ "$patch" -gt "$best" ]; }; then
      best=$patch
    fi
  done
  echo "$best"
}

decide() {
  [ $# -ge 5 ] || usage
  local key=$1 line=$2 tags=$3 force_publish=$4 publish=false has_tag=false all_on_line=true repo current version out
  local tagged=() latest_versions=()
  shift 4
  [[ $line =~ $LINE_RE ]] || die "LINE must be MAJOR.MINOR, got '$line'"
  [[ $force_publish =~ ^(true|false)$ ]] || die "FORCE_PUBLISH must be true or false"
  out=$(tag_versions "$tags") || exit 1
  [ -z "$out" ] || mapfile -t tagged <<<"$out"
  for repo in "$@"; do
    current='' version=''
    read -r current version <<<"$(latest_info "$repo")" || true
    [ "$current" != - ] || current=''
    [ "$version" != - ] || version=''
    if [ "$current" = "$key" ]; then
      echo "unchanged: $repo:latest has this build's key $key" >&2
    else
      publish=true
      echo "changed: $repo:latest has build key '${current:-none}', this build $key" >&2
    fi
    latest_versions+=("$version")
    [[ $version =~ $VERSION_RE && ${version%.*} == "$line" ]] || all_on_line=false
  done
  highest_patch "$line" "${tagged[@]}" "${latest_versions[@]}" >/dev/null # fails when LINE went back
  for version in "${tagged[@]}"; do
    [ "${version%.*}" != "$line" ] || has_tag=true
  done
  if [ "$has_tag" = true ]; then
    echo "released: line $line has a git tag" >&2
  elif [ "$all_on_line" = true ]; then
    echo "released: every :latest is on line $line, its git tag is missing (re-run the release job)" >&2
  else
    publish=true
    echo "new line: $line has no release yet" >&2
  fi
  if [ "$force_publish" = true ]; then
    publish=true
    echo "force_publish" >&2
  fi
  echo "$publish"
}

next_version() {
  [ $# -ge 3 ] || usage
  local line=$1 tags=$2 repo version best n first got taken out
  local tagged=() latest_versions=()
  shift 2
  [[ $line =~ $LINE_RE ]] || die "LINE must be MAJOR.MINOR, got '$line'"
  out=$(tag_versions "$tags") || exit 1
  [ -z "$out" ] || mapfile -t tagged <<<"$out"
  for repo in "$@"; do
    version=$(latest_version "$repo") || exit 1 # the registry could not tell: never guess
    latest_versions+=("$version")
  done
  best=$(highest_patch "$line" "${tagged[@]}" "${latest_versions[@]}") || exit 1
  echo "highest released patch of $line (git tags, :latest labels): ${best:-none}" >&2
  first=$(( ${best:--1} + 1 ))
  for (( n = first; n < first + 100; n++ )); do
    taken=false
    for repo in "$@"; do
      got=$(digest_of "$repo:$line.$n") || exit 1 # the registry could not tell: never guess
      if [ -n "$got" ]; then
        taken=true
        echo "taken: $repo:$line.$n ($got)" >&2
      fi
    done
    if [ "$taken" = false ]; then
      echo "$line.$n"
      return 0
    fi
  done
  die "no free version from $line.$first to $line.$((first + 99))"
}

in_list() { # VALUE ITEM...: VALUE is one of the ITEMs
  local value=$1 item
  shift
  for item in "$@"; do
    if [ "$item" = "$value" ]; then return 0; fi
  done
  return 1
}

released() {
  [ $# -ge 2 ] || usage
  local tags=$1 repo version out
  local tagged=() missing=()
  shift
  out=$(tag_versions "$tags") || exit 1
  [ -z "$out" ] || mapfile -t tagged <<<"$out"
  for repo in "$@"; do
    version=$(latest_version "$repo") || exit 1 # the registry could not tell: never guess
    if [[ ! $version =~ $VERSION_RE ]]; then
      echo "not checked: $repo:latest has no MAJOR.MINOR.PATCH version label ('$version')" >&2
    elif in_list "$version" "${tagged[@]}"; then
      echo "released: $repo:latest is $version, which has its git tag v$version" >&2
    elif ! in_list "$version" "${missing[@]}"; then
      missing+=("$version")
    fi
  done
  for version in "${missing[@]}"; do
    echo "publish_tested: Release v$version is missing: re-run the failed release job of the run that published it" \
      "(see docs/maintenance.md)" >&2
  done
  [ ${#missing[@]} -eq 0 ] || exit 1
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
  [ $# -eq 4 ] || usage
  local tested=$1 ref=$2 key=$3 version=$4 got_key got_version
  [ -r "$tested" ] || die "cannot read $tested"
  docker pull -q "$ref" >/dev/null
  got_key=$(docker image inspect -f "{{index .Config.Labels \"$KEY_LABEL\"}}" "$ref")
  got_version=$(docker image inspect -f "{{index .Config.Labels \"$VERSION_LABEL\"}}" "$ref")
  identity "$ref" > "$WORK/pushed-identity.json"
  docker image rm "$ref" >/dev/null 2>&1 || true
  [ "$got_key" = "$key" ] || die "$ref: build key label is '$got_key', expected $key"
  [ "$got_version" = "$version" ] || die "$ref: version label is '$got_version', expected $version"
  if ! diff -u <(jq -S . "$tested") "$WORK/pushed-identity.json" >&2; then
    die "$ref differs from the tested image (diff above: - tested, + pushed)"
  fi
  echo "same bits: $ref has the tested image's $(jq '.DiffIDs | length' "$tested") layers and configuration," \
    "plus build key $key and version $version" >&2
}

push() {
  [ $# -eq 5 ] || usage
  local archive=$1 tested=$2 repo=$3 key=$4 version=$5 manifest digest
  [ -r "$archive" ] || die "cannot read $archive"
  [ -r "$tested" ] || die "cannot read $tested"
  [[ $key =~ ^sha256:[0-9a-f]{64}$ ]] || die "KEY must be sha256:<64 hex digits>"
  [[ $version =~ $TAG_RE ]] || die "not a valid release tag: '$version'"
  mkdir "$WORK/layout" "$WORK/context"
  tar -xf "$archive" -C "$WORK/layout"
  if [ ! -f "$WORK/layout/oci-layout" ] || [ ! -f "$WORK/layout/index.json" ]; then
    die "$archive is not an OCI image layout (docker save of Docker 25 or later)"
  fi
  manifest=$(image_manifest "$WORK/layout")
  printf 'FROM tested\n' > "$WORK/context/Dockerfile"
  docker buildx build --progress plain \
    --build-context "tested=oci-layout://$WORK/layout@$manifest" \
    --label "$KEY_LABEL=$key" --label "$VERSION_LABEL=$version" \
    --sbom "generator=$SBOM_GENERATOR" \
    --provenance "mode=max${PROVENANCE_BUILDER_ID:+,builder-id=$PROVENANCE_BUILDER_ID}" \
    --output "type=image,name=$repo,push-by-digest=true,name-canonical=true,push=true,compression=gzip,force-compression=true,oci-mediatypes=true" \
    --metadata-file "$WORK/metadata.json" "$WORK/context" >&2
  digest=$(jq -r '."containerimage.digest" // empty' "$WORK/metadata.json")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "no image digest in the build metadata"
  check "$tested" "$repo@$digest" "$key" "$version"
  echo "$digest"
}

tag() {
  [ $# -ge 3 ] || usage
  local repo=$1 digest=$2 t got
  shift 2
  local args=()
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "DIGEST must be sha256:<64 hex digits>"
  for t in "$@"; do
    [[ $t =~ $TAG_RE ]] || die "not a valid tag: '$t'"
    if [[ ! $t =~ $MOVABLE_RE ]]; then
      got=$(digest_of "$repo:$t") || exit 1 # the registry could not tell: never guess
      [ -z "$got" ] || [ "$got" = "$digest" ] || die "$repo:$t is published (at $got) and never moves"
    fi
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
  line) version_line "$@" ;;
  decide) decide "$@" ;;
  next-version) next_version "$@" ;;
  released) released "$@" ;;
  push) push "$@" ;;
  check) check "$@" ;;
  tag) tag "$@" ;;
  *) usage ;;
esac
