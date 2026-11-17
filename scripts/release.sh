#!/usr/bin/env bash
# GitHub Release steps of build.yml's release job, with the gh CLI: GH_REPO (OWNER/REPOSITORY) names the repository,
# GH_TOKEN authenticates. tests/release_test.sh runs them against a fake gh in every CI build.
#
#   scripts/release.sh VERSION COMMIT MANIFEST NOTES
#     Makes sure the Release vVERSION exists, is published and has the asset manifest.json, byte for byte MANIFEST,
#     and that the git tag vVERSION is on COMMIT (the full commit id). What is missing is created, in an order a re-run
#     can finish after a failure part-way: a draft Release (title vVERSION, body NOTES, target COMMIT; a draft makes no
#     git tag), then the asset, then publication (it creates the tag on COMMIT), marked latest unless a published
#     Release vA.B.C has a higher version (then explicitly not: GitHub marks a newly published Release latest by
#     default). The body is written only when the draft is created. A Release that is published and complete is left
#     as it is. Anything that exists but differs is an error and is never changed: the tag on another commit, a draft
#     for another commit, another manifest.json (or one whose upload did not complete), several Releases for the tag, a
#     published Release without its tag. After a change the result is read back and checked. MANIFEST must be the
#     manifest of VERSION and COMMIT (its "version" and "commit").
#
#   scripts/release.sh previous VERSION
#     Prints the tag vX.Y.Z of the highest published Release below VERSION (the previous release), or nothing when
#     there is none (the first release). Drafts, other tags and versions from VERSION up are ignored.
#
#   scripts/release.sh notes-inputs VERSION COMMIT DIR
#     Writes what scripts/release_notes.py notes needs besides this release's manifest into DIR (created; it must not
#     exist): prs.md, GitHub's generated notes (the pull requests merged) for the tag vVERSION on COMMIT, since the
#     previous release's tag or, without a previous release, since the beginning; previous.json, the manifest.json of
#     the previous release, only when there is one and it has that asset (otherwise the notes are those of a first
#     release, with complete lists; a previous Release without the asset gets a warning).
#
# Exit 0 on success, 2 on usage errors, 1 on any other failure (message on stderr). A GitHub error that leaves a
# state unknown (anything but "not found" when looking up the tag) fails; the script never guesses.
set -euo pipefail

VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' # MAJOR.MINOR.PATCH
ASSET=manifest.json

die() { echo "release: $*" >&2; exit 1; }
usage() { grep '^#   scripts/release.sh ' "$0" | sed 's/^#   /usage: /' >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

check_repo() {
  { [[ ${GH_REPO:-} =~ ^[A-Za-z0-9][A-Za-z0-9-]*/([A-Za-z0-9._-]+)$ ]] && [[ ! ${BASH_REMATCH[1]} =~ ^\.\.?$ ]]; } \
    || die "GH_REPO must be OWNER/REPOSITORY"
}
check_version() { [[ $1 =~ $VERSION_RE ]] || die "VERSION must be MAJOR.MINOR.PATCH (e.g. 0.1.0), got '$1'"; }
check_commit() { [[ $1 =~ ^[0-9a-f]{40}$ ]] || die "COMMIT must be a full commit id (40 hex digits), got '$1'"; }

num_lt() { # A B: A < B for numbers without leading zeros, of any length
  [ ${#1} -lt ${#2} ] || { [ ${#1} -eq ${#2} ] && [[ $1 < $2 ]]; }
}
version_lt() { # A B (MAJOR.MINOR.PATCH): A < B
  local a b i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if num_lt "${a[i]}" "${b[i]}"; then return 0; fi
    [ "${a[i]}" = "${b[i]}" ] || return 1
  done
  return 1
}

releases() { # one line per Release: TAG <tab> ID <tab> DRAFT <tab> state of its manifest.json ("-": none) <tab> TARGET
  local filter='.[] | "\(.tag_name)\t\(.id)\t\(.draft)\t'
  filter+='\([.assets[] | select(.name == "manifest.json") | .state][0] // "-")\t\(.target_commitish)"'
  gh api --paginate "repos/$GH_REPO/releases?per_page=100" --jq "$filter"
}

previous_release() { # VERSION: "TAG <tab> ASSET_STATE" of the highest published vX.Y.Z Release below VERSION;
                     # nothing when there is none
  local version=$1 out tag id draft asset target best='' best_asset=''
  out=$(releases) || die "cannot list the Releases of $GH_REPO"
  while IFS=$'\t' read -r tag id draft asset target; do
    [ "$draft" = false ] && [[ ${tag#v} =~ $VERSION_RE ]] && [ "$tag" != "${tag#v}" ] || continue
    version_lt "${tag#v}" "$version" || continue
    if [ -z "$best" ] || version_lt "$best" "${tag#v}"; then
      best=${tag#v} best_asset=$asset
    fi
  done <<<"$out"
  [ -z "$best" ] || printf 'v%s\t%s\n' "$best" "$best_asset"
}

previous() {
  [ $# -eq 1 ] || usage
  local found
  check_version "$1"
  check_repo
  found=$(previous_release "$1") || exit 1
  [ -z "$found" ] || echo "${found%%$'\t'*}"
}

notes_inputs() {
  [ $# -eq 3 ] || usage
  local version=$1 commit=$2 dir=$3 found prev='' asset='' fields
  check_version "$version"
  check_commit "$commit"
  check_repo
  [ ! -e "$dir" ] || die "$dir exists already"
  mkdir -- "$dir"
  found=$(previous_release "$version") || exit 1
  [ -z "$found" ] || IFS=$'\t' read -r prev asset <<<"$found"
  fields=(-f "tag_name=v$version" -f "target_commitish=$commit")
  if [ -z "$prev" ]; then
    echo "no previous release: notes of a first release (complete lists), pull requests since the beginning" >&2
  else
    fields+=(-f "previous_tag_name=$prev")
    case "$asset" in
      uploaded)
        mkdir "$WORK/previous"
        gh release download "$prev" --pattern "$ASSET" --dir "$WORK/previous" >&2 \
          || die "cannot download $ASSET of $prev"
        mv -- "$WORK/previous/$ASSET" "$dir/previous.json"
        echo "previous release: $prev (its $ASSET is the base of the comparison)" >&2 ;;
      -) echo "release: warning: $prev has no $ASSET; the notes list the complete contents" >&2 ;;
      *) die "$ASSET of $prev is in state '$asset' (an upload that did not complete)" ;;
    esac
  fi
  gh api "repos/$GH_REPO/releases/generate-notes" "${fields[@]}" --jq .body > "$dir/prs.md" \
    || die "GitHub did not generate the notes for v$version"
}

tag_commit() { # TAG: the commit the git tag TAG is on, nothing when there is no such tag; fails when GitHub cannot tell
  local out
  if out=$(gh api "repos/$GH_REPO/git/ref/tags/$1" --jq '.object.type + " " + .object.sha' 2> "$WORK/err"); then
    [[ $out =~ ^commit\ ([0-9a-f]{40})$ ]] || die "the tag $1 is not a lightweight tag on a commit: $out"
    echo "${BASH_REMATCH[1]}"
  elif grep -qF '(HTTP 404)' "$WORK/err"; then
    return 0
  else
    die "cannot tell whether the tag $1 exists: $(tr '\n' ' ' < "$WORK/err")"
  fi
}

inspect() { # reads the state of the Release $TAG into TAG_AT, REL_ID, REL_DRAFT, REL_ASSET, and into NEWER the tag
            # of the highest published vA.B.C Release above VERSION (nothing when there is none); fails on what differs
  local out n=0 tag id draft asset target
  TAG_AT=$(tag_commit "$TAG") || exit 1
  [ -z "$TAG_AT" ] || [ "$TAG_AT" = "$COMMIT" ] \
    || die "the tag $TAG is on commit $TAG_AT, not on $COMMIT. A version tag is never moved or deleted (the v* tag" \
      "ruleset forbids it): leave it, and publish a new patch version instead, with a manual run of build.yml on main" \
      "with force_publish (see docs/maintenance.md)"
  out=$(releases) || die "cannot list the Releases of $GH_REPO"
  REL_ID='' REL_DRAFT='' REL_ASSET='' NEWER=''
  while IFS=$'\t' read -r tag id draft asset target; do
    if [ "$tag" != "$TAG" ]; then
      if [ "$draft" = false ] && [[ ${tag#v} =~ $VERSION_RE ]] && [ "$tag" != "${tag#v}" ] \
        && version_lt "$VERSION" "${tag#v}" && { [ -z "$NEWER" ] || version_lt "${NEWER#v}" "${tag#v}"; }; then
        NEWER=$tag
      fi
      continue
    fi
    n=$((n + 1))
    REL_ID=$id REL_DRAFT=$draft REL_ASSET=$asset
    if [ "$draft" = true ] && [ "$target" != "$COMMIT" ]; then
      die "the draft Release $TAG (id $id) targets $target, not $COMMIT; publishing it would put the tag there"
    fi
  done <<<"$out"
  [ "$n" -le 1 ] || die "$n Releases have the tag $TAG, expected at most one (delete the extra drafts, then re-run)"
  [ "$n" -eq 0 ] || [[ $REL_DRAFT =~ ^(true|false)$ ]] || die "unexpected draft flag of $TAG: '$REL_DRAFT'"
  [ "$REL_DRAFT" != false ] || [ -n "$TAG_AT" ] \
    || die "the Release $TAG is published but there is no git tag $TAG (put it back on $COMMIT by hand)"
  case "$REL_ASSET" in
    '' | -) ;;
    uploaded)
      local dir
      dir=$(mktemp -d "$WORK/download.XXXXXX")
      gh release download "$TAG" --pattern "$ASSET" --dir "$dir" >&2 || die "cannot download $ASSET of $TAG"
      cmp -s "$dir/$ASSET" "$WORK/$ASSET" \
        || die "$ASSET of the Release $TAG differs from this run's manifest (it is never replaced)" ;;
    *) die "$ASSET of the Release $TAG is in state '$REL_ASSET' (an upload that did not complete); delete that asset" \
      "of the draft, then re-run" ;;
  esac
}

release() {
  [ $# -eq 4 ] || usage
  VERSION=$1 COMMIT=$2
  local manifest=$3 notes=$4 changed=false latest
  check_version "$VERSION"
  check_commit "$COMMIT"
  check_repo
  { [ -f "$manifest" ] && [ -r "$manifest" ]; } || die "cannot read $manifest"
  { [ -f "$notes" ] && [ -r "$notes" ]; } || die "cannot read $notes"
  jq -e --arg v "$VERSION" --arg c "$COMMIT" '.version == $v and .commit == $c' "$manifest" >/dev/null 2>&1 \
    || die "$manifest is not the manifest of version $VERSION and commit $COMMIT"
  cp -- "$manifest" "$WORK/$ASSET" # the asset takes the file's name; the copy is also what gets compared
  TAG=v$VERSION
  inspect
  if [ -z "$REL_ID" ]; then
    echo "creating the draft Release $TAG (target $COMMIT)" >&2
    gh release create "$TAG" --draft --target "$COMMIT" --title "$TAG" --notes-file "$notes" >&2 \
      || die "cannot create the draft Release $TAG"
    REL_DRAFT=true REL_ASSET=- changed=true
  fi
  if [ "$REL_ASSET" = - ]; then
    echo "uploading $ASSET to $TAG" >&2
    gh release upload "$TAG" "$WORK/$ASSET" >&2 || die "cannot upload $ASSET to $TAG"
    changed=true
  fi
  if [ "$REL_DRAFT" = true ]; then
    if [ -z "$NEWER" ]; then
      echo "publishing $TAG, marked latest (creates the tag $TAG on $COMMIT)" >&2
      latest=--latest
    else # an older version completed late: the Latest marker stays on the highest version
      echo "publishing $TAG, not marked latest: $NEWER is a higher version (creates the tag $TAG on $COMMIT)" >&2
      latest=--latest=false
    fi
    gh release edit "$TAG" --draft=false "$latest" >&2 || die "cannot publish $TAG"
    changed=true
  fi
  if [ "$changed" = true ]; then
    inspect
    { [ "$REL_DRAFT" = false ] && [ "$REL_ASSET" = uploaded ] && [ "$TAG_AT" = "$COMMIT" ]; } \
      || die "read back: $TAG is not published with its $ASSET and tag on $COMMIT (draft '$REL_DRAFT'," \
        "asset '$REL_ASSET', tag on '${TAG_AT:-nothing}')"
    echo "released: $TAG on $COMMIT, with $ASSET" >&2
  else
    echo "already released: $TAG on $COMMIT, with this $ASSET; nothing changed" >&2
  fi
}

[ $# -ge 1 ] || usage
case "$1" in
  previous) shift; previous "$@" ;;
  notes-inputs) shift; notes_inputs "$@" ;;
  -*) usage ;;
  *) release "$@" ;;
esac
