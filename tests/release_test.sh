#!/usr/bin/env bash
# Test for scripts/release.sh, the GitHub Release steps of build.yml's release job.
#   tests/release_test.sh
# A fake `gh`, first on PATH, keeps the repository's Releases, their assets and its git tags in files and logs every
# call; it answers only the calls it knows (exact arguments) and fails on any other, so each case proves which calls
# the script makes. Nothing touches the network or a real repository. Release states are set up with the fake gh
# itself (create, upload, publish), as a run that stopped part-way leaves them.
# Prints "PASS <name>" per case and stops at the first failure. Temp files are removed on exit. Needs bash and jq.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RELEASE="$ROOT/scripts/release.sh"
command -v jq >/dev/null || { echo "FAIL setup: jq is required" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
S="$TMP/state"
A=$(printf 'a%.0s' {1..40}) # the commit that was built
B=$(printf 'b%.0s' {1..40}) # another commit

mkdir "$TMP/bin" "$TMP/in"
cat > "$TMP/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# Fake gh. State in $FAKE_GH_STATE: releases.json (the Releases as the REST API lists them), assets/<release id>/<name>
# (asset bytes), tags/<tag> (the git ref as the REST API returns it), latest (the tag last marked latest), fail_ref
# (when present, the ref lookup fails like a GitHub outage), fail_upload (when present, an upload is cut off). Each
# call goes to calls.log in a short canonical form; an unknown call goes to unexpected.log and exits 99.
set -euo pipefail
S=$FAKE_GH_STATE
R=repos/example/edge-proxy
unexpected() { printf '%s\n' "$*" >> "$S/unexpected.log"; echo "fake gh: unexpected call: gh $*" >&2; exit 99; }
log() { printf '%s\n' "$*" >> "$S/calls.log"; }
if [ "${GH_REPO:-}" != example/edge-proxy ] || [ "${GH_TOKEN:-}" != fake-token ]; then
  unexpected "(GH_REPO '${GH_REPO:-}' or GH_TOKEN is not the test's) $*"
fi
edit() { # JQ_PROGRAM [JQ_ARGS...]: rewrites releases.json
  local program=$1
  shift
  jq "$@" "$program" "$S/releases.json" > "$S/releases.new"
  mv "$S/releases.new" "$S/releases.json"
}
release_id() { # TAG: the Release gh resolves TAG to (drafts included); none: gh's error; several: the script erred
  local n
  n=$(jq --arg t "$1" '[.[] | select(.tag_name == $t)] | length' "$S/releases.json")
  [ "$n" -le 1 ] || unexpected "release $1 with $n Releases for that tag (the script must refuse before acting)"
  [ "$n" -eq 1 ] || { echo "release not found" >&2; exit 1; }
  jq --arg t "$1" '.[] | select(.tag_name == $t) | .id' "$S/releases.json"
}
not_found() { echo '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }

if [ $# -eq 5 ] && [ "$1 $2 $3 $4" = "api --paginate $R/releases?per_page=100 --jq" ]; then
  log list-releases
  jq -r "$5" "$S/releases.json"
elif [ $# -eq 4 ] && [ "$1" = api ] && [[ $2 =~ ^$R/git/ref/tags/([A-Za-z0-9._-]+)$ ]] && [ "$3" = --jq ]; then
  tag=${BASH_REMATCH[1]}
  log "get-tag $tag"
  if [ -e "$S/fail_ref" ]; then
    echo '{"message":"Server Error"}'
    echo 'gh: Server Error (HTTP 502)' >&2
    exit 1
  fi
  [ -f "$S/tags/$tag" ] || not_found
  jq -r "$4" "$S/tags/$tag"
elif [ $# -ge 8 ] && [ "$1 $2 $3" = "api $R/releases/generate-notes -f" ] && [[ $4 == tag_name=* ]] \
  && [ "$5" = -f ] && [[ $6 == target_commitish=* ]] && [ "${*: -2}" = "--jq .body" ]; then
  if [ $# -eq 8 ]; then
    since="the beginning"
    log "generate-notes $4 $6"
  elif [ $# -eq 10 ] && [ "$7" = -f ] && [[ $8 == previous_tag_name=* ]]; then
    since=${8#previous_tag_name=}
    log "generate-notes $4 $6 $8"
  else
    unexpected "$@"
  fi
  printf "## What's Changed\n* pull requests for %s since %s\n" "${4#tag_name=}" "$since"
elif [ $# -eq 10 ] && [ "$1 $2" = "release create" ] && [ "$4 $5" = "--draft --target" ] && [ "$7" = --title ] \
  && [ "$9" = --notes-file ]; then
  log "create $3 draft target=$6 title=$8"
  id=$(( $(jq '[.[].id] | max // 0' "$S/releases.json") + 1 ))
  edit '. + [{id: $id, tag_name: $t, draft: true, prerelease: false, target_commitish: $c, name: $n, body: $b,
    assets: []}]' --argjson id "$id" --arg t "$3" --arg c "$6" --arg n "$8" --rawfile b "${10}"
  echo "https://github.com/example/edge-proxy/releases/tag/untagged-$id"
elif [ $# -eq 4 ] && [ "$1 $2" = "release upload" ]; then
  id=$(release_id "$3")
  name=$(basename "$4")
  log "upload $3 $name"
  if [ -e "$S/assets/$id/$name" ]; then
    echo "asset under the same name already exists: [$name]" >&2
    exit 1
  fi
  state=uploaded
  [ ! -e "$S/fail_upload" ] || state=starter # an upload cut off: GitHub keeps the asset record, without its bytes
  edit 'map(if .id == $id then .assets += [{id: (.id * 100 + (.assets | length)), name: $n, state: $s}]
    else . end)' --argjson id "$id" --arg n "$name" --arg s "$state"
  if [ "$state" = starter ]; then
    echo 'gh: Server Error (HTTP 502)' >&2
    exit 1
  fi
  mkdir -p "$S/assets/$id"
  cp "$4" "$S/assets/$id/$name"
elif [ $# -eq 5 ] && [ "$1 $2" = "release edit" ] && [ "$4 $5" = "--draft=false --latest" ]; then
  id=$(release_id "$3")
  log "publish $3 latest"
  target=$(jq -r --argjson id "$id" '.[] | select(.id == $id) | .target_commitish' "$S/releases.json")
  edit 'map(if .id == $id then .draft = false else . end)' --argjson id "$id"
  if [ ! -f "$S/tags/$3" ]; then # publishing creates the tag at the target; an existing tag stays as it is
    jq -n --arg t "$3" --arg c "$target" '{ref: ("refs/tags/" + $t), object: {type: "commit", sha: $c}}' \
      > "$S/tags/$3"
  fi
  echo "$3" > "$S/latest"
  echo "https://github.com/example/edge-proxy/releases/tag/$3"
elif [ $# -eq 7 ] && [ "$1 $2" = "release download" ] && [ "$4 $5 $6" = "--pattern manifest.json --dir" ]; then
  id=$(release_id "$3")
  log "download $3 $5"
  [ -f "$S/assets/$id/$5" ] || { echo "no assets match the file pattern" >&2; exit 1; }
  mkdir -p "$7"
  [ ! -e "$7/$5" ] || { echo "$7/$5 already exists" >&2; exit 1; }
  cp "$S/assets/$id/$5" "$7/$5"
else
  unexpected "$@"
fi
FAKE
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_REPO=example/edge-proxy GH_TOKEN=fake-token FAKE_GH_STATE="$S"
[ "$(command -v gh)" = "$TMP/bin/gh" ] || { echo "FAIL setup: the fake gh is not first on PATH" >&2; exit 1; }

# Inputs: this release's manifest (deliberately not named manifest.json: the asset must be), another manifest of the
# same version and commit, the previous release's manifest, the notes.
M="$TMP/in/release-manifest.json"
jq -n --arg k "sha256:$(printf '1%.0s' {1..64})" --arg c "$A" '{build_key: $k, commit: $c, version: "0.1.0"}' > "$M"
OTHER="$TMP/in/other-manifest.json"
jq -n --arg k "sha256:$(printf '2%.0s' {1..64})" --arg c "$A" '{build_key: $k, commit: $c, version: "0.1.0"}' \
  > "$OTHER"
PREV="$TMP/in/previous/manifest.json"
mkdir "$TMP/in/previous"
jq -n --arg c "$B" '{commit: $c, version: "0.0.9"}' > "$PREV"
NOTES="$TMP/in/notes.md"
printf '## Changes in this repository\n\nnotes of this run\n' > "$NOTES"
OLD_NOTES="$TMP/in/old-notes.md"
printf 'notes of the attempt that stopped part-way\n' > "$OLD_NOTES"

pass() { echo "PASS $1"; }
fail() {
  echo "FAIL $1: $2" >&2
  if [ -s "$TMP/err" ]; then
    echo "--- stderr of the script:" >&2
    cat "$TMP/err" >&2
  fi
  exit 1
}
reset() { # empty repository: no Release, no tag, no call logged
  rm -rf "$S"
  mkdir -p "$S/tags" "$S/assets"
  echo '[]' > "$S/releases.json"
  : > "$S/calls.log"
  : > "$TMP/err"
}
setup_done() { : > "$S/calls.log"; } # forget the calls that set up the state
draft() { gh release create "$1" --draft --target "$2" --title "$1" --notes-file "${3:-$OLD_NOTES}" >/dev/null; }
upload() { mkdir -p "$TMP/up"; cp "$2" "$TMP/up/manifest.json"; gh release upload "$1" "$TMP/up/manifest.json"; }
publish() { gh release edit "$1" --draft=false --latest >/dev/null; }
tag_at() { # TAG COMMIT: a git tag without a Release
  jq -n --arg t "$1" --arg c "$2" '{ref: ("refs/tags/" + $t), object: {type: "commit", sha: $c}}' > "$S/tags/$1"
}
snapshot() { (cd "$S" && find . -type f ! -name calls.log -print0 | sort -z | xargs -0 sha256sum); }
run() { # scripts/release.sh ARGS: exit status in $status, stdout in $TMP/out, stderr in $TMP/err
  status=0
  "$RELEASE" "$@" > "$TMP/out" 2> "$TMP/err" || status=$?
}
calls_are() { # NAME CALL...: the fake gh got exactly these calls, in this order, and none it did not know
  local name=$1
  shift
  [ ! -s "$S/unexpected.log" ] || fail "$name" "unexpected gh calls: $(cat "$S/unexpected.log")"
  diff <(if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi) "$S/calls.log" > "$TMP/diff" \
    || fail "$name" "gh calls differ (< expected, > made):"$'\n'"$(cat "$TMP/diff")"
}
succeeded() { [ "$status" -eq 0 ] || fail "$1" "exit status $status, expected 0"; }
refused() { # NAME TEXT: failed (status 1) with TEXT in the message
  [ "$status" -eq 1 ] || fail "$1" "exit status $status, expected 1"
  grep -qF -- "$2" "$TMP/err" || fail "$1" "no '$2' in the message"
}
complete() { # NAME BODY_FILE: one Release v0.1.0, published, marked latest, title v0.1.0, body BODY_FILE, git tag on
             # A, one asset manifest.json equal to M
  local name=$1 body=$2 r id
  [ "$(jq '[.[] | select(.tag_name == "v0.1.0")] | length' "$S/releases.json")" = 1 ] \
    || fail "$name" "not exactly one Release v0.1.0: $(jq -c . "$S/releases.json")"
  r=$(jq -c '.[] | select(.tag_name == "v0.1.0")' "$S/releases.json")
  [ "$(jq -r .draft <<<"$r")" = false ] || fail "$name" "the Release is still a draft"
  [ "$(jq -r .name <<<"$r")" = v0.1.0 ] || fail "$name" "title $(jq .name <<<"$r")"
  jq -j .body <<<"$r" | cmp -s - "$body" || fail "$name" "body $(jq .body <<<"$r"), expected the text of $body"
  [ "$(cat "$S/latest" 2>/dev/null)" = v0.1.0 ] || fail "$name" "v0.1.0 is not marked latest"
  [ "$(jq -r '.object.type + " " + .object.sha' "$S/tags/v0.1.0" 2>/dev/null)" = "commit $A" ] \
    || fail "$name" "the git tag v0.1.0 is not on $A"
  [ "$(jq -c '[.assets[] | [.name, .state]]' <<<"$r")" = '[["manifest.json","uploaded"]]' ] \
    || fail "$name" "assets $(jq -c .assets <<<"$r")"
  id=$(jq .id <<<"$r")
  cmp -s "$S/assets/$id/manifest.json" "$M" || fail "$name" "the asset manifest.json is not the manifest"
}
first_attempt=("get-tag v0.1.0" list-releases)               # what every run reads first
read_back=("get-tag v0.1.0" list-releases "download v0.1.0 manifest.json") # the check after a change

# ---- scripts/release.sh VERSION COMMIT MANIFEST NOTES --------------------------------------------------------------

reset
run 0.1.0 "$A" "$M" "$NOTES"
succeeded creates_draft_uploads_publishes
calls_are creates_draft_uploads_publishes "${first_attempt[@]}" "create v0.1.0 draft target=$A title=v0.1.0" \
  "upload v0.1.0 manifest.json" "publish v0.1.0 latest" "${read_back[@]}"
complete creates_draft_uploads_publishes "$NOTES"
pass creates_draft_uploads_publishes

reset
draft v0.1.0 "$A"
setup_done
run 0.1.0 "$A" "$M" "$NOTES"
succeeded rerun_completes_draft_without_asset
calls_are rerun_completes_draft_without_asset "${first_attempt[@]}" "upload v0.1.0 manifest.json" \
  "publish v0.1.0 latest" "${read_back[@]}"
complete rerun_completes_draft_without_asset "$OLD_NOTES" # the body is written only when the draft is created
pass rerun_completes_draft_without_asset

reset
draft v0.1.0 "$A"
upload v0.1.0 "$M"
setup_done
run 0.1.0 "$A" "$M" "$NOTES"
succeeded rerun_publishes_draft_with_asset
calls_are rerun_publishes_draft_with_asset "${first_attempt[@]}" "download v0.1.0 manifest.json" \
  "publish v0.1.0 latest" "${read_back[@]}"
complete rerun_publishes_draft_with_asset "$OLD_NOTES"
pass rerun_publishes_draft_with_asset

reset
draft v0.1.0 "$A"
upload v0.1.0 "$M"
publish v0.1.0
setup_done
before=$(snapshot)
run 0.1.0 "$A" "$M" "$NOTES"
succeeded rerun_of_published_release_changes_nothing
calls_are rerun_of_published_release_changes_nothing "${read_back[@]}"
[ "$(snapshot)" = "$before" ] || fail rerun_of_published_release_changes_nothing "the repository state changed"
complete rerun_of_published_release_changes_nothing "$OLD_NOTES"
pass rerun_of_published_release_changes_nothing

# A published Release without manifest.json (not made by this script): the asset is what is missing.
reset
draft v0.1.0 "$A"
publish v0.1.0
setup_done
run 0.1.0 "$A" "$M" "$NOTES"
succeeded rerun_uploads_missing_asset_of_published_release
calls_are rerun_uploads_missing_asset_of_published_release "${first_attempt[@]}" "upload v0.1.0 manifest.json" \
  "${read_back[@]}"
complete rerun_uploads_missing_asset_of_published_release "$OLD_NOTES"
pass rerun_uploads_missing_asset_of_published_release

# An upload cut off leaves an asset record without its bytes: the run fails, and a re-run stops there without
# changing anything (it never replaces an asset; a maintainer deletes that one).
reset
touch "$S/fail_upload"
run 0.1.0 "$A" "$M" "$NOTES"
refused stops_at_incomplete_upload "cannot upload"
calls_are stops_at_incomplete_upload "${first_attempt[@]}" "create v0.1.0 draft target=$A title=v0.1.0" \
  "upload v0.1.0 manifest.json"
rm "$S/fail_upload"
setup_done
before=$(snapshot)
run 0.1.0 "$A" "$M" "$NOTES"
refused stops_at_incomplete_upload "did not complete"
calls_are stops_at_incomplete_upload "${first_attempt[@]}"
[ "$(snapshot)" = "$before" ] || fail stops_at_incomplete_upload "the repository state changed"
pass stops_at_incomplete_upload

# The tag on another commit: alone, and of a published Release. Nothing is changed.
for setup in tag-only published; do
  reset
  if [ "$setup" = tag-only ]; then
    tag_at v0.1.0 "$B"
  else
    draft v0.1.0 "$B"
    upload v0.1.0 "$M"
    publish v0.1.0
  fi
  setup_done
  before=$(snapshot)
  run 0.1.0 "$A" "$M" "$NOTES"
  refused "refuses_tag_at_other_commit ($setup)" "$B"
  calls_are "refuses_tag_at_other_commit ($setup)" "get-tag v0.1.0"
  [ "$(snapshot)" = "$before" ] || fail "refuses_tag_at_other_commit ($setup)" "the repository state changed"
done
pass refuses_tag_at_other_commit

# A draft for another commit would put the tag there when published.
reset
draft v0.1.0 "$B"
setup_done
before=$(snapshot)
run 0.1.0 "$A" "$M" "$NOTES"
refused refuses_draft_for_other_commit "$B"
calls_are refuses_draft_for_other_commit "${first_attempt[@]}"
[ "$(snapshot)" = "$before" ] || fail refuses_draft_for_other_commit "the repository state changed"
pass refuses_draft_for_other_commit

# Another manifest.json, on a draft and on a published Release. Nothing is changed.
for setup in draft published; do
  reset
  draft v0.1.0 "$A"
  upload v0.1.0 "$OTHER"
  [ "$setup" = draft ] || publish v0.1.0
  setup_done
  before=$(snapshot)
  run 0.1.0 "$A" "$M" "$NOTES"
  refused "refuses_different_asset ($setup)" "differs"
  calls_are "refuses_different_asset ($setup)" "${first_attempt[@]}" "download v0.1.0 manifest.json"
  [ "$(snapshot)" = "$before" ] || fail "refuses_different_asset ($setup)" "the repository state changed"
done
pass refuses_different_asset

reset
draft v0.1.0 "$A"
draft v0.1.0 "$A"
setup_done
before=$(snapshot)
run 0.1.0 "$A" "$M" "$NOTES"
refused refuses_several_releases_for_the_tag "2 Releases"
calls_are refuses_several_releases_for_the_tag "${first_attempt[@]}"
[ "$(snapshot)" = "$before" ] || fail refuses_several_releases_for_the_tag "the repository state changed"
pass refuses_several_releases_for_the_tag

# A published Release whose git tag is gone: the script cannot put it back where it was.
reset
draft v0.1.0 "$A"
upload v0.1.0 "$M"
publish v0.1.0
rm "$S/tags/v0.1.0"
setup_done
run 0.1.0 "$A" "$M" "$NOTES"
refused refuses_published_release_without_tag "no git tag"
calls_are refuses_published_release_without_tag "${first_attempt[@]}"
pass refuses_published_release_without_tag

reset
touch "$S/fail_ref"
run 0.1.0 "$A" "$M" "$NOTES"
refused refuses_to_guess_when_github_fails "cannot tell"
calls_are refuses_to_guess_when_github_fails "get-tag v0.1.0"
pass refuses_to_guess_when_github_fails

# Bad input is refused before any call to GitHub.
reset
for args in "0.1 $A $M $NOTES" "v0.1.0 $A $M $NOTES" "0.01.0 $A $M $NOTES" "0.1.0 ${A:1} $M $NOTES" \
  "0.1.0 ${A^^} $M $NOTES" "0.1.0 $B $M $NOTES" "0.1.1 $A $M $NOTES" "0.1.0 $A $TMP/missing.json $NOTES" \
  "0.1.0 $A $M $TMP/missing.md" "0.1.0 $A $M"; do
  read -r -a argv <<<"$args"
  run "${argv[@]}"
  [ "$status" -ne 0 ] || fail refuses_bad_input "accepted: $args"
done
for repo in "" example "example/edge-proxy/x" "../x/y" "../x" "x/.." "-x/y"; do
  status=0
  GH_REPO=$repo "$RELEASE" 0.1.0 "$A" "$M" "$NOTES" > "$TMP/out" 2> "$TMP/err" || status=$?
  [ "$status" -ne 0 ] || fail refuses_bad_input "accepted GH_REPO '$repo'"
done
calls_are refuses_bad_input
pass refuses_bad_input

# ---- scripts/release.sh previous VERSION ---------------------------------------------------------------------------

reset
for tag in v0.1.0 v0.1.10 v0.1.9 vfoo 0.1.11 v0.1.11-rc1 v0.2.0 v1.0.0; do
  draft "$tag" "$A"
  publish "$tag"
done
draft v0.1.11 "$A"   # a draft is not a release (yet)
tag_at v0.1.12 "$A"  # a git tag without a Release is not one either
setup_done
for case in "0.1.12 v0.1.10" "0.2.0 v0.1.10" "0.1.10 v0.1.9" "0.1.1 v0.1.0" "0.1.0 -" "1.0.1 v1.0.0"; do
  read -r version want <<<"$case"
  : > "$S/calls.log"
  run previous "$version"
  succeeded previous_skips_non_release_tags
  [ "$(cat "$TMP/out")" = "${want#-}" ] \
    || fail previous_skips_non_release_tags "previous $version printed '$(cat "$TMP/out")', expected '${want#-}'"
  calls_are previous_skips_non_release_tags list-releases
done
pass previous_skips_non_release_tags

for setup in empty draft-only; do
  reset
  [ "$setup" = empty ] || draft v0.1.0 "$A"
  setup_done
  run previous 0.1.0
  succeeded "previous_none_for_first_release ($setup)"
  [ ! -s "$TMP/out" ] || fail "previous_none_for_first_release ($setup)" "printed '$(cat "$TMP/out")'"
  calls_are "previous_none_for_first_release ($setup)" list-releases
done
run previous 0.1
[ "$status" -ne 0 ] || fail previous_none_for_first_release "accepted VERSION 0.1"
pass previous_none_for_first_release

# ---- scripts/release.sh notes-inputs VERSION COMMIT DIR ------------------------------------------------------------

reset
run notes-inputs 0.1.0 "$A" "$TMP/n1"
succeeded notes_inputs_first_release
calls_are notes_inputs_first_release list-releases "generate-notes tag_name=v0.1.0 target_commitish=$A"
[ "$(cat "$TMP/n1/prs.md")" = "## What's Changed"$'\n'"* pull requests for v0.1.0 since the beginning" ] \
  || fail notes_inputs_first_release "prs.md: $(cat "$TMP/n1/prs.md")"
[ ! -e "$TMP/n1/previous.json" ] || fail notes_inputs_first_release "a previous.json without a previous release"
pass notes_inputs_first_release

reset
draft v0.0.9 "$B"
upload v0.0.9 "$PREV"
publish v0.0.9
setup_done
run notes-inputs 0.1.0 "$A" "$TMP/n2"
succeeded notes_inputs_with_previous
calls_are notes_inputs_with_previous list-releases "download v0.0.9 manifest.json" \
  "generate-notes tag_name=v0.1.0 target_commitish=$A previous_tag_name=v0.0.9"
cmp -s "$TMP/n2/previous.json" "$PREV" || fail notes_inputs_with_previous "previous.json is not v0.0.9's manifest"
[ "$(cat "$TMP/n2/prs.md")" = "## What's Changed"$'\n'"* pull requests for v0.1.0 since v0.0.9" ] \
  || fail notes_inputs_with_previous "prs.md: $(cat "$TMP/n2/prs.md")"
pass notes_inputs_with_previous

reset
draft v0.0.9 "$B"
publish v0.0.9
setup_done
run notes-inputs 0.1.0 "$A" "$TMP/n3"
succeeded notes_inputs_previous_without_manifest
calls_are notes_inputs_previous_without_manifest list-releases \
  "generate-notes tag_name=v0.1.0 target_commitish=$A previous_tag_name=v0.0.9"
[ ! -e "$TMP/n3/previous.json" ] || fail notes_inputs_previous_without_manifest "a previous.json without an asset"
grep -qF "v0.0.9 has no manifest.json" "$TMP/err" || fail notes_inputs_previous_without_manifest "no warning"
run notes-inputs 0.1.0 "$A" "$TMP/n3"
[ "$status" -ne 0 ] || fail notes_inputs_previous_without_manifest "accepted an existing DIR"
pass notes_inputs_previous_without_manifest

echo "ALL PASS"
