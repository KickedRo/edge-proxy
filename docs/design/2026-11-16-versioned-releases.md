# Versioned releases and project-style documentation

Status: draft for the maintainers' approval (2026-11-16).

## Why

Today every publish gets a date-based tag (`1.31.8-modsec3.0.17-crs4.30.0-20261116.3`) and nothing else: there is no
version number, no list of releases, and no single page that says what an image contains or what changed since the
previous one. The maintainers want to *track versions*: every image anyone runs has a version number and a GitHub
Releases page that says what is in it and what changed. The documentation should follow the style of a project the
maintainers like: a README that says up front what the project is, what state it is in and what
works, a Keep-a-Changelog `CHANGELOG.md`, contributor guidance, and issue/PR templates.

## Goals

1. **One SemVer version per publish**, `MAJOR.MINOR.PATCH`, shared by both images (`edge` and `gen` are built,
   tested and published together under one build key).
2. **Every version has a GitHub Release**: git tag `vX.Y.Z` on the commit that was built, and release notes that
   say what changed (details below).
3. **Our own changes set MAJOR.MINOR; the pipeline sets PATCH.** A `VERSION` file holds `MAJOR.MINOR` (starting at
   `0.1`). A pull request with a new feature or a changed default bumps it (`0.1` → `0.2`); merging it publishes
   `0.2.0`. Every later publish with changed image content, whether from our own fix or from an upstream or security
   update, becomes the next patch (`0.2.1`, `0.2.2`, ...) automatically.
4. **Image tags**: `X.Y.Z` (never moves, never re-used), `X.Y` (moves to the newest patch of that line) and `latest`.
   The date-based release tags stop; the tags already published stay where they are.
5. **`CHANGELOG.md`** in Keep a Changelog 1.1.0 format with SemVer, written by hand for our own changes: entries go
   under `[Unreleased]` in the PR that makes the change; a `VERSION` bump turns `[Unreleased]` into `[X.Y.0] -
   date`. Breaking or behaviour-changing releases carry an **Upgrading** note at the top of their section.
   Automatic patch releases are not written into the file (the pipeline never commits to `main`); the changelog says
   so and points to the Releases page.
6. **Documentation in the style above** (details below), built on the existing docs, which stay.

## Non-goals

- Changing what is in the images, the hardening, the WAF defaults or the supported layout.
- arm64 images, a documentation website, a sponsorship link.
- Rewriting or deleting tags, images or history that are already public.

## Anti-goals (a failure even if it works)

- A release that needs a person: upstream and security updates must keep shipping unattended.
- A version tag (git or image) that ever moves or is re-used.
- Release notes that do not match the image they describe.
- A second way to publish that skips the pull request + CI path (for example a tag push that triggers a publish).
- New third-party GitHub Actions: the repository allows only GitHub-owned actions plus a short list of docker/* and
  sigstore actions, pinned by full SHA.
- Anything internal to the maintainers' own deployment in the public repository.

## Constraints from the repository as it is

- `main` is protected (pull request, checks `resolve` + `build-test`, up to date, linear history, squash merges);
  nobody pushes to `main`, so the pipeline cannot commit (no automatic changelog or `VERSION` updates).
- The default `GITHUB_TOKEN` is read-only; each job asks only for the permissions it needs.
- Publishing pushes the exact tested archives, checks the pushed images are the same bits, signs them (cosign
  keyless), attests provenance, and moves tags last. All of that stays; the version is assigned within this flow and
  tags (image and git) are created only after signing and attestation.
- The publish decision uses the content build key (`scripts/build_key.sh`): only changed content publishes.

## Approaches considered

1. **`VERSION` file + automatic patch (chosen).** `MAJOR.MINOR` lives in the repository and changes through a
   reviewed PR; the publish job computes the patch from the existing release tags. One path to publish (PR → CI →
   merge, or the daily build), no manual tag pushes. Trade-off: the patch number is decided by the pipeline, and a
   hand-written changelog covers only `X.Y.0` releases.
2. **Manual tag pushes for our releases (the reference project's model) + automatic patches for rebuilds.** Familiar, but adds a
   second publish trigger next to the daily build, and a tag push bypasses the PR + required-checks path the
   repository is protected around.
3. **A release bot deriving versions and changelog from commit messages.** Needs a third-party action (blocked by the
   Actions allow-list) or a home-grown equivalent, and commit-message discipline the squash merges do not enforce.

## Decided parts of the how

### Versions

- `VERSION` at the repository root: one line `MAJOR.MINOR` (`0.1` at the start). Validated strictly (two
  non-negative integers, no leading zeros).
- The first release is `v0.1.0`, published by the merge of this work (the image content changes anyway: the version
  label). 0.x signals beta until the images have run on real sites; `1.0.0` is a later, deliberate bump.
- Next version at publish time: the highest `MAJOR.MINOR.N` for the line in `VERSION`, taken over **both** the git
  tags `vX.Y.Z` and the image version tags in the registry, → `N+1`; none → `MAJOR.MINOR.0`. Taking the maximum of
  both means a release left half-finished (image tags pushed, git tag or Release missing) never causes a re-used
  number. A `VERSION` lower than an existing released line (for example `0.1` after `0.2.x` exists) fails the run, so
  only the highest line ever publishes and `latest` is always the highest version.
- The number is computed when the publish job runs, not when the PR is tested: a scheduled build that publishes after
  a `VERSION` bump was merged simply is the line's `.0` release; there is no race between a bump PR and the daily
  build. Publish runs on `main` are serialised (concurrency group, no cancellation outside PRs).

### Publish decision

- Publish when the content build key differs from `latest`'s, **or the `VERSION` line has no release yet** (so a PR
  that only bumps `VERSION` and dates the changelog still publishes `X.Y.0`), or on `force_publish`. The Monday
  publish and the "older than 6 days" publish are removed: with versions, an unchanged image gets no new release.
  (`VERSION` is not added to the build key: the key describes image content.)
- The freshness alarm (`freshness.yml`) can no longer use a one-week age of `latest` as its health signal (an
  unchanged image may legitimately be weeks old). It checks instead that the last scheduled `build` run on `main`
  succeeded and is not older than 2 days (the daily build ran and found nothing to publish), keeps the
  upstream-version comparison and the template-pin alarm, and keeps a long backstop: `latest` older than 30 days
  raises the alarm too (Debian security updates alone change the content more often than that).

### Order of the publish steps, and recovery

1. Compute the version (above). 2. Push both images by digest (no tags yet), same-bits check, sign, attest — as
today. 3. Tag the images `X.Y.Z`, `X.Y`, `latest` (tags last, as today). 4. A separate job with `contents: write`
creates the git tag and the Release as a **draft**, uploads `manifest.json`, then publishes the Release (this flow is
used whether or not GitHub's release immutability is switched on).

If step 4 fails, the run is red and the existing "Build failed" issue opens. The next scheduled run does not publish
(the build key now equals `latest`'s), so nothing collides; a maintainer uses "Re-run failed jobs" on that run. The
release job is idempotent: it creates whatever is missing (tag, draft, asset, publication) and succeeds when
everything already exists and points at the same commit and digests; anything that exists but differs is an error,
never overwritten.

### Image metadata

- `org.opencontainers.image.version` = `X.Y.Z` (today it holds the date-based tag). `org.kickedro.versions` and
  `org.kickedro.build-key` stay.

### The Release

Created by the publish workflow with the `gh` CLI on the runner (no new action), after the images are pushed,
signed, attested and tagged. The workflow job that creates tags and the Release is the only one with
`contents: write`; the job that holds the registry credentials does not get it.

- Tag `vX.Y.Z` on the commit that was built; title `vX.Y.Z`; marked latest when it is the highest version.
- Asset `manifest.json`: version, commit, build key, both image digests, the resolved upstream versions
  (`versions.env`), the Debian package list of each image, docker-gen's Go module list. It is the input for the next
  release's notes and a record of what the version contains.
- Notes, generated from this release's manifest and the previous release's (downloaded from that Release):
  1. **Changes in this repository**: the PRs merged since the previous release (GitHub's generate-notes API, which is
     GitHub's own), or "none, rebuild for upstream changes".
  2. **Upstream**: nginx, ModSecurity, the connector, CRS, docker-gen, Go, nginx-proxy's template ref, old → new
     (only the ones that changed, plus a full table).
  3. **Packages**: Debian packages per image that were added, removed or changed version; docker-gen's Go modules
     that changed. Long lists collapse (`<details>`).
  4. **Images**: both references by version tag and digest, and the `cosign verify` / `gh attestation verify`
     commands from `docs/verify.md`, filled in.
  5. For `X.Y.0`: a link to the version's `CHANGELOG.md` section, and its Upgrading note copied in.
- The first release (`v0.1.0`) has no previous manifest: the notes list the full contents instead of a diff.

### Documentation

- **README.md**, in this order: centred title, one-line tagline, badges (build workflow status, latest release,
  licence); **What it is** (the two images, why, what is different from upstream nginx-proxy); **Read this before
  you install it** (GitHub alert boxes: 0.x is beta; the WAF is on and blocks some legitimate traffic until
  configured; maintained for its maintainers' own use, no support promise); **Install** (quick start with the
  compose example; pin a version: `X.Y.Z` or `X.Y` plus digest); **What works today** (a feature list grouped
  like the reference project's: WAF, hardening, freshness/pipeline, supply chain); **Versions and releases** (scheme, tags, where
  release notes are); **Security** (summary + SECURITY.md); **Documentation** (links to the existing docs);
  **Development** (pointer to CONTRIBUTING.md); **License**.
- **CHANGELOG.md**: header as in Keep a Changelog; `[Unreleased]`; `[0.1.0] - <release date>` summarising what the
  first versioned release contains (from the existing docs and merged PRs), with link references at the bottom.
- **CONTRIBUTING.md**: scope and opinions (secure defaults that let common traffic through, one setting per
  protection, upstream template unchanged); development (Docker builds incl. `--build-context repo=.`, the test
  scripts CI runs); house conventions (settings in `edge/settings.tsv`, `docs/settings.md` generated, comments
  explain why, every behaviour change has a test, no site-specific content); versioning duties (bump `VERSION` for
  features and changed defaults, `[Unreleased]` entry in every PR that changes behaviour).
- **.github/ISSUE_TEMPLATE/**: `bug_report.yml` (image version and digests, compose excerpt, `edge` start-up lines
  incl. `SECURITY:`/`NOTICE:` lines, audit-log rule IDs with sensitive data removed), `feature_request.yml`,
  `config.yml` (security reports go to private vulnerability reporting, not issues).
- **.github/PULL_REQUEST_TEMPLATE.md**: what and why; checklist (tests, docs, settings.md regenerated, changelog
  entry, `VERSION` bump when needed).
- **docs/verify.md** and **docs/maintenance.md**: the tag scheme, pinning by version + digest, how versions and
  Releases are produced, how to cut a minor/major (a PR that bumps `VERSION` and dates the changelog section), the
  freshness signal. **docs/going-public.md** gains the release-related settings below.

### Repository settings (maintainers, by hand)

- A tag ruleset for `v*`: no deletion, no update (tags never move).
- GitHub's release immutability setting, if available: a published Release's tag and assets cannot be changed. The
  workflow's draft → upload → publish flow works with it on or off.

## Calls made by the author of this design (not discussed with the maintainers)

- `VERSION` file + automatic patch (approach 1); start at `0.1.0`; one version for both images.
- The date-based tags stop; `X.Y` tag added.
- A `VERSION` line without a release publishes even when the content is unchanged.
- Next version = maximum over git tags and registry tags; a lower `VERSION` line fails the run.
- Release job is separate, idempotent, draft-first; recovery by re-running the failed job.
- Freshness: last scheduled build ≤ 2 days old, plus a 30-day backstop on `latest`'s age.
- Automatic patch releases are recorded on the Releases page only, not in `CHANGELOG.md`.

## Left to the builder

- Where version computation and note generation live (a script under `scripts/` with unit tests and fixtures, in
  the existing style), and how the package lists travel from `build-test` to the release job (they are already
  computed for the build key).
- The exact layout of the notes, within the sections above.
- How the publish rehearsal covers the new steps without contacting GitHub (for example a fake previous manifest and
  a dry-run mode that prints the notes).
- Whether the pipeline also writes the version into the job summary and the `report` issue texts.
