# Maintenance notes

For the people who run this repository. Users: see the [README](../README.md) and the [configuration guide](configuration.md).

Contents: [The pipeline](#how-the-pipeline-works) · [Versions](#versions) ·
[Cutting a minor or major release](#cutting-a-minor-or-major-release) ·
[A failed release](#a-failed-release-release-vxyz-is-missing) · [The freshness alarm](#the-freshness-alarm) ·
[60-day stop](#scheduled-workflows-stop-after-60-days) · [Pins](#pins-that-are-updated-by-hand) ·
[nginx-proxy pin](#moving-the-nginx-proxy-pin) · [CRS default lists](#a-crs-release-that-changes-a-default-list) ·
[Trivy](#trivy-exceptions) · [Dependabot](#dependabot) · [Releasing a change](#releasing-a-change)

## How the pipeline works

Two workflows, both in `.github/workflows/`:

**`build.yml`**: on pull requests, on every push to `main`, on manual dispatch, and **daily at 03:17 UTC**.

1. `resolve`: `scripts/resolve_versions.py` looks up the newest nginx mainline, ModSecurity, ModSecurity-nginx, CRS,
   docker-gen and Go, within the major versions in `pins.env`. Every later job of the run uses that one result.
   The nginx-proxy commit (`NGINX_PROXY_REF` in `pins.env`) is **not** looked up: it is moved by hand, after
   reading what changed in nginx-proxy's template ([below](#moving-the-nginx-proxy-pin)). The job also reads the
   release line from `VERSION` (`scripts/publish_tested.sh line`), so a malformed `VERSION` fails every run, pull
   requests included.
2. `build-test`: builds both images, runs the unit tests (with `tests/release_test.sh`), the three smoke tests
   (`tests/edge_smoke.sh`, `tests/split_smoke.sh`, `tests/hardening_smoke.sh`) and the Trivy scan, computes the
   **build key**, lists what is inside the images (upstream versions, Debian packages, docker-gen's Go modules), and
   rehearses publishing against a throw-away local registry. The daily `SECURITY_EPOCH` build argument re-runs only
   the security-upgrade layers (apt upgrade; docker-gen's vulnerability-driven module upgrades), so the expensive
   ModSecurity compile stays cached. The images built here carry the version label `X.Y-dev`; the version is chosen
   when they are published.
3. `publish` (only on `main`, never for pull requests, only after `build-test` passed; most steps are in
   `scripts/publish_tested.sh`):
   1. **Decide.** It reads the git tags `v*` of the repository on GitHub (`git ls-remote`, see
      [the tag lookup](#the-tag-lookup-needs-a-public-repository)) and the labels of the published `latest` images. It
      publishes when the **build key** differs from the one on a published `latest` (a content hash, see
      [verify.md](verify.md): the daily rebuild changes digests but not the key unless something meaningful changed),
      when the `VERSION` line has no release yet, or when `force_publish` is set. Otherwise it logs "unchanged,
      skipped", checks that the version `latest` carries has its Release (`released`,
      [below](#a-failed-release-release-vxyz-is-missing)), and stops there.
   2. **Version.** The next patch of the `VERSION` line: one more than the highest `X.Y.N` among the git tags `vX.Y.Z`
      and the version labels of the `latest` images, or `X.Y.0` when the line has none. A number that either image
      repository already has as a tag is skipped, so a version is never used twice. The run fails when `VERSION` is
      lower than a released version, or when the registry cannot tell whether a tag exists.
   3. **Push.** It pushes **the archives that were tested and scanned**, not a rebuild, by digest only (no tag yet),
      with SBOM and provenance and with two labels added (the build key, and the version), then checks that the pushed
      images have the same layers and configuration (the "same-bits check").
   4. **Sign and attest.** A keyless cosign signature and the GitHub provenance attestation for both digests.
   5. **Manifest.** `scripts/release_notes.py manifest` writes `manifest.json` (version, commit, build key, digests,
      upstream versions, package lists, Go modules) and stores it as the run's artifact `release-manifest`, kept 30
      days (as long as GitHub lets a run be re-run).
   6. **Tag**, last: `X.Y.Z`, `X.Y` and `latest`, on `edge`, then on `gen`. Only `latest` and `X.Y` may move;
      `scripts/publish_tested.sh tag` refuses to move any other tag.
4. `release` (only when `publish` published): the only job with `contents: write`, and it gets no registry
   credentials. It checks that the `release-manifest` artifact describes what was published, finds the previous
   release (the highest published `vX.Y.Z` below this one) and its `manifest.json`, asks GitHub for the pull requests
   merged since (`scripts/release.sh notes-inputs`), and writes the notes (`scripts/release_notes.py notes`; for
   `X.Y.0` with the Upgrading note of `CHANGELOG.md`). Then `scripts/release.sh` creates the Release `vX.Y.Z` as a
   **draft** on the built commit, uploads `manifest.json`, and publishes it, marked latest. Publishing creates the git
   tag `vX.Y.Z` on that commit. The job is idempotent: it creates what is missing and changes nothing that exists and
   matches (see [a failed release](#a-failed-release-release-vxyz-is-missing)).
5. `report` (scheduled runs): opens a "Build failed" issue when a scheduled run failed or timed out, and closes it
   when a later one passes.
6. `keepalive` (scheduled runs): [below](#scheduled-workflows-stop-after-60-days).

Manual dispatch inputs of `build.yml`: `security_epoch` (re-run the upgrade layers) and `force_publish` (publish a
new patch version even if the build key is unchanged; on `main` only).

There is no Monday publish any more, no publish because `latest` is a few days old, and no `force_skip_check`. With
versions, an image whose content did not change gets no new version, so `latest` can be weeks old while everything
is fine. The freshness alarm watches the daily build instead ([below](#the-freshness-alarm)).

**`freshness.yml`**: daily at 05:47 UTC. Two checks, each with its own issue, opened by the workflow when the check
does not pass and closed by it when the check passes again:

- `scripts/check_freshness.py` fails, with the issue "Image stale or behind upstream", in the cases described in
  [the freshness alarm](#the-freshness-alarm).
- `scripts/check_template_pin.py` compares `NGINX_PROXY_REF` with nginx-proxy's `main` and fails, with the issue
  "nginx-proxy template moved past the pin", when `main` has commits the pin does not have that touch what the
  images take from it (`nginx.tmpl`, `app/` and `Dockerfile.dockergen` for `gen`; `network_internal.conf` and
  `Dockerfile.debian` for `edge`), and the oldest of them is more than 7 days old. The week lets upstream settle (a
  change and its fix often come close together). The run's summary lists the commits.

## Versions

Both images share one version, `MAJOR.MINOR.PATCH`. [`VERSION`](../VERSION) holds `MAJOR.MINOR` (one line, two numbers
without leading zeros); the publish job adds the patch. Image tags: `X.Y.Z` (never moves, never re-used), `X.Y` (the
newest patch of that line) and `latest`. Git tags: `vX.Y.Z`, made only by publishing a Release. The pipeline never
commits or pushes to `main`, so `CHANGELOG.md` covers the `X.Y.0` releases only, and the patches are recorded on the
Releases page. Tags published before 0.1.0 keep their date-based names; nothing touches them.

The number is chosen when the publish job runs, not when the pull request was tested, and runs on `main` take turns.
So a `VERSION` bump and the daily build never race: whichever run publishes first after the merge makes the line's
`.0`.

## Cutting a minor or major release

For a new feature or a changed default (see [CONTRIBUTING.md](../CONTRIBUTING.md#versions-and-the-changelog)):

1. In the pull request that makes the change, or in a pull request of its own: bump `VERSION` (`0.1` → `0.2`, or
   `1.4` → `2.0`), rename `## [Unreleased]` in `CHANGELOG.md` to `## [0.2.0] - YYYY-MM-DD` (the day you merge), add an
   empty `## [Unreleased]` above it, and update the link references at the bottom (`[Unreleased]` compares from
   `v0.2.0`; `[0.2.0]` links to its Release). If users have to act, start the section with a quote whose first line
   is `> **Upgrading:** ...`.
2. Merge it. The push run publishes `0.2.0`, **even when the image content did not change**: the line has no release
   yet. The release notes start with the Upgrading note and a link to the section, both read from `CHANGELOG.md` at
   the built commit (a missing section only prints a warning; it never stops a release).
3. Check the run and the new Release, then [verify](verify.md) the images.

`VERSION` never goes back: a line lower than a released version fails the run.

## A failed release: "Release vX.Y.Z is missing"

The publish job and the release job are separate, so a release can stop half-way. What a stop leaves, and what to do:

**The release job failed** (a GitHub hiccup, for example). The images are published, signed and tagged, but the
Release `vX.Y.Z` and its git tag are missing or incomplete. The run is red, and on a scheduled run the "Build failed"
issue opens. The next runs publish nothing (the build key now equals `latest`'s) and fail on purpose at "The published
version has its Release", with:

```
publish_tested: Release vX.Y.Z is missing: re-run the failed release job of the run that published it (see docs/maintenance.md)
```

So the issue stays open, and after a failed push run the next scheduled run opens it. To fix it:

1. Find the run that published `X.Y.Z` (its publish job's summary says `published version X.Y.Z`).
2. Use **Re-run failed jobs** on that run, **within 30 days** of it: GitHub does not re-run older runs. The re-run
   release job uses the publish job's outputs, which a re-run keeps, and the run's `release-manifest` artifact (kept
   for those 30 days). It is idempotent: it creates what is missing (the draft, the asset, the publication and with it
   the git tag) and leaves alone what exists and matches.
3. If it stops on something that exists but differs (a tag on another commit, another `manifest.json`, an upload
   that did not complete, several drafts for one tag), it changes nothing and says what it found. Fix that by hand as
   the message says (for example delete the extra draft, or the incomplete asset of the draft), then re-run again.
4. The "Build failed" issue closes with the next passing scheduled run.

**After 30 days** the run can no longer be re-run. Publish a new patch instead: run `build.yml` on `main` by hand
with `force_publish`. The new version gets its Release; `X.Y.Z` stays without one, and its images stay as they are.

**A newer version came first.** The check above runs only when a run publishes nothing. If the content changes before
anyone re-runs the failed release job, the next run publishes `X.Y.Z+1` with its Release as usual, and `vX.Y.Z` stays
without a Release until someone re-runs its release job (within the 30 days). The notes of `X.Y.Z+1` compare with
the newest version that has a Release.

**The publish job failed.** Before the Tag step nothing is visible: the pushed digests have no tag, and a re-run (or
the next run) publishes the same version number. If it failed between tagging `edge` and tagging `gen`, `edge` has the
tag `X.Y.N` (and `X.Y` and `latest` point to it) while `gen` does not, and there is no git tag or Release. The next
publish, a re-run or the next run, publishes `X.Y.N+1` for both images: numbers are never re-used. The `edge` tag
`X.Y.N` stays behind without a Release; leave it.

### The tag lookup needs a public repository

The publish job lists the git tags `v*` with `git ls-remote` against the repository on GitHub, without credentials
(the checkout has no tags and keeps no credentials). That works because the repository is public. If it ever turns
private, the lookup fails and the publish job stops before it publishes anything (it fails closed); the step then
needs the job's token.

## The freshness alarm

`freshness.yml` opens "Image stale or behind upstream" when any of these is true (its run summary has one line each):

- the newest completed scheduled run of `build.yml` on `main` did not succeed, or is older than 2 days (`BUILD:`):
  the daily build is the signal that the pipeline lives;
- a published `latest` was created more than 30 days ago (`STALE`; the `max_age_days` input changes it for a manual
  run): a backstop, since Debian security updates alone change the content more often than that;
- the nginx of a published `latest` is older than upstream's current mainline (`BEHIND`).

It is independent of the build workflow, so it also catches a build that silently stopped.

## Scheduled workflows stop after 60 days

GitHub disables scheduled workflows of a public repository after 60 days without repository activity, which would
stop the daily build **and** the freshness alarm without a sound. Each scheduled run therefore ends with a
`keepalive` job that re-enables both workflows through the API. GitHub does not document that enabling an enabled
workflow resets the 60-day timer, so treat this as a best effort. **Backstop:** monitor from outside GitHub (for
example a daily check, through GitHub's public API, that the newest scheduled `build.yml` run on `main` succeeded in
the last two days), and make a commit now and then.

**Pausing.** To pause the pipeline, **disable both workflows** (`gh workflow disable build.yml` and
`gh workflow disable freshness.yml`). Disabling only one is undone by the keep-alive of the other, since they
re-enable each other.

## Pins that are updated by hand

- **BuildKit** (`BUILDKIT_IMAGE` in `build.yml`): pinned by digest because it holds the registry credentials and
  writes the SBOM and provenance that get signed. Update it to the release that Docker's `buildx-stable-1` tag
  points to (`docker buildx imagetools inspect moby/buildkit:buildx-stable-1`), by version and digest.
- **govulncheck** (version in `gen/Dockerfile`): the scanner that picks module upgrades for docker-gen.
- **Trivy** (`TRIVY_IMAGE` in `build.yml`): the official image, by digest.
- **`NGINX_PROXY_REF`** in `pins.env` ([moving the nginx-proxy pin](#moving-the-nginx-proxy-pin)), and the major
  versions in the same file (a new major of ModSecurity, CRS or docker-gen needs a review, then a change here).
- **GitHub Actions**: pinned by full commit SHA with the version in a comment. Dependabot opens the pull requests
  (below).

## Moving the nginx-proxy pin

`gen` runs nginx-proxy's template, entrypoint and scripts at the commit `NGINX_PROXY_REF`, and `edge` takes
`network_internal.conf`, the licence and the `nginx.conf` changes of nginx-proxy's `Dockerfile.debian` from the same
commit. The template turns container labels and environment variables (read from the Docker socket) into nginx
configuration, so a new commit is reviewed like code before it is used. Do it when the "nginx-proxy template moved past
the pin" issue opens, or when an nginx-proxy release has a fix you want:

1. Read what changed since the pin: `https://github.com/nginx-proxy/nginx-proxy/compare/<NGINX_PROXY_REF>...main`.
   Look at `nginx.tmpl`, `app/` and `Dockerfile.dockergen` (what `gen` uses), `Dockerfile.debian` and
   `network_internal.conf` (what `edge` copies). Pick the commit to move to: the newest commit of `main` you reviewed,
   or a release's commit.
2. Carry over what the images copy by hand, if it changed: the `ENV`, `ENTRYPOINT` and `CMD` of `Dockerfile.dockergen`
   into `gen/Dockerfile` (and `UPSTREAM_CMD` in `tests/split_smoke.sh`, which checks it), and the `nginx.conf` edits of
   `Dockerfile.debian` into `edge/Dockerfile`.
3. Set `NGINX_PROXY_REF` in `pins.env` to the full 40-character SHA, in a pull request. CI builds both images from it
   and runs the split-layout smoke test, which also checks that `gen` carries the pinned commit. If the template
   changes what users see, add a changelog entry (and bump `VERSION` for a changed default).
4. After the merge the push run publishes a new version (a change to `pins.env` changes the build key), and the next
   freshness run closes the issue.

## A CRS release that changes a default list

Three settings of `edge` default to the CRS's own policy lists, with the image's documented differences:
`MODSEC_ALLOWED_METHODS` (the CRS's methods plus `PUT PATCH DELETE`), `MODSEC_ALLOWED_REQUEST_CONTENT_TYPE` (the CRS's
list) and `MODSEC_RESTRICTED_HEADERS_BASIC` (the CRS's list without the three method-override headers and `Expect`).
The drift tests in `tests/edge_smoke.sh` (`crs_policy_default_allowed_methods`,
`crs_policy_default_allowed_request_content_type`, `crs_policy_default_restricted_headers_basic`) compare these
defaults with the lists that the built CRS sets (rules 901160, 901162 and 901165 of `REQUEST-901-INITIALIZATION.conf`).

The daily build takes a new CRS minor release by itself. When that release changes one of the lists, its drift test
fails, `build-test` is red, the "Build failed" issue opens, and **nothing is published** until it is fixed, security
updates included. So fix it soon:

1. Read the CRS change: what was added or removed from the list, and why.
2. Update the default in `edge/settings.tsv`, keeping the image's differences above, and check the texts in the same
   line (and in [configuration.md](configuration.md#what-the-waf-lets-through-by-default), which quotes the CRS lists).
3. Regenerate the settings table: `python3 scripts/gen_settings_doc.py edge/settings.tsv > docs/settings.md`.
4. Add a changelog entry under `[Unreleased]`: what the image now allows or refuses, and that it follows the CRS.
5. A list that changed what it allows or refuses is a changed default: bump `VERSION` in the same pull request (see
   [cutting a minor release](#cutting-a-minor-or-major-release)). A change that leaves the image's behaviour the same
   (the same items in another order, for example) needs no bump.

## Trivy exceptions

CI fails on any fixable HIGH or CRITICAL finding in either image. The normal fix is a rebuild: the images run a
security upgrade, so a fixed Debian package arrives with the next run. If a finding really has to be accepted for a
while, add an entry to `.trivyignore.yaml` with the ID, a `statement` saying why, and `expired_at`. **At most 30 days
ahead**: `scripts/check_trivyignore.py` fails CI for a missing reason, a past date or a date further out. The file is
empty by default.

Findings that only exist as GitHub advisories (GHSA) can turn the gate red for a Go module although `govulncheck` finds
nothing to upgrade (it reads the Go vulnerability database). Such a finding always names a fixed version (Trivy runs
with `--ignore-unfixed`, so an advisory without a fix never fails the gate); docker-gen does not use that version yet
because `govulncheck` does not know the advisory. Then, in this order of preference: wait (the Go vulnerability
database often catches up within days, and the next run passes); or, if the advisory does not apply to how docker-gen
uses the module, add an exception in `.trivyignore.yaml` with the advisory ID, a statement that says why, and an expiry
at most 30 days ahead; or pin the fixed module version by hand in the docker-gen step of `gen/Dockerfile` (`go get
<module>@<fixed version>`), and remove the pin when the automatic upgrade covers it.

## Dependabot

`.github/dependabot.yml` updates the GitHub Actions weekly, with a 7-day cooldown: a new release of an action
waits a week before a pull request is opened for it. Review the changes to the action (and its new commit SHA) like
any other code, because the actions run with the repository's publishing permissions. The versions of nginx,
ModSecurity, CRS, docker-gen and Go are **not** managed by Dependabot; the daily resolver covers them.

## Releasing a change

Changes go through a pull request (`main` is protected, see [going-public.md](going-public.md)); both checks, `resolve`
and `build-test`, must pass. After the merge, the push run publishes when the build key changed (a change to `edge/`,
`gen/`, `pins.env`, `build.yml`, `LICENSE` or `NOTICE` always does), as the next patch version, or as `X.Y.0` when the
pull request bumped `VERSION`. A change to anything else (documentation, scripts, tests, `freshness.yml`) does not
change the key by itself; the run still publishes when upstream content changed since the last version. Check the run
and the new Release, then [verify](verify.md) the new version.
