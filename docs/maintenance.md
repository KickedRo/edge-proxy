# Maintenance notes

For the people who run this repository. Users: see the [README](../README.md) and the [configuration guide](configuration.md).

## How the pipeline works

Two workflows, both in `.github/workflows/`:

**`build.yml`**: on pull requests, on every push to `main`, on manual dispatch, and **daily at 03:17 UTC**.

1. `resolve`: `scripts/resolve_versions.py` looks up the newest nginx mainline, ModSecurity, ModSecurity-nginx, CRS,
   docker-gen and Go, within the major versions in `pins.env`. Every later job of the run uses that one result.
   The nginx-proxy commit (`NGINX_PROXY_REF` in `pins.env`) is **not** looked up: it is moved by hand, after
   reading what changed in nginx-proxy's template ([below](#moving-the-nginx-proxy-pin)).
2. `build-test`: builds both images, runs the unit tests, the three smoke tests (`tests/edge_smoke.sh`,
   `tests/split_smoke.sh`, `tests/hardening_smoke.sh`) and the Trivy scan, computes the **build key**, and rehearses
   publishing against a throw-away local registry. The daily `SECURITY_EPOCH` build argument re-runs only the
   security-upgrade layers (apt upgrade; docker-gen's vulnerability-driven module upgrades), so the expensive
   ModSecurity compile stays cached.
3. `publish` (only on `main`, never for pull requests, only after `build-test` passed): decides whether to publish.
   It publishes when the **build key** differs from the one on the published `latest` (a content hash, see
   [verify.md](verify.md): the daily rebuild changes digests but not the key unless something meaningful changed),
   **on Mondays**, or when a published `latest` is more than 6 whole days old (a missed Monday is made up the next
   day). Otherwise it logs "unchanged, skipped".
4. If it publishes, it picks the release tags: the day's tag (`<versions>-<YYYYMMDD>`), or `.2`, `.3`, ... after it
   when that tag already exists in the registry, because a published release tag never moves. It pushes **the
   archives that were tested and scanned**, not a rebuild, with SBOM and provenance and with two labels added (the
   build key, and the release tag as the version), then checks that the pushed images have the same layers and
   configuration (the "same-bits check"), signs them, adds the GitHub provenance attestation, and only then tags them
   (`latest` moves; the new release tag is created, and `scripts/publish_tested.sh` refuses to move an existing one).
5. `report` (scheduled runs): opens a "Build failed" issue when a scheduled run failed or timed out, and closes it
   when a later one passes.

**`freshness.yml`**: daily at 05:47 UTC. Two checks, each with its own issue, opened by the workflow when the check
does not pass and closed by it when the check passes again:

- Reads the published `latest` images and fails, with the issue "Image stale or behind upstream", when one is older
  than 8 days or its nginx is older than upstream's current mainline. It is the alarm for a pipeline that has silently
  stopped, and is independent of the build workflow.
- `scripts/check_template_pin.py` compares `NGINX_PROXY_REF` with nginx-proxy's `main` and fails, with the issue
  "nginx-proxy template moved past the pin", when `main` has commits the pin does not have that touch what the
  images take from it (`nginx.tmpl`, `app/` and `Dockerfile.dockergen` for `gen`; `network_internal.conf` and
  `Dockerfile.debian` for `edge`), and the oldest of them is more than 7 days old. The week lets upstream settle (a
  change and its fix often come close together). The run's summary lists the commits.

Manual dispatch inputs of `build.yml`: `security_epoch` (re-run the upgrade layers), `force_publish` (publish even if
the key is unchanged), `force_skip_check` (treat today as not Monday).

## Scheduled workflows stop after 60 days

GitHub disables scheduled workflows of a public repository after 60 days without repository activity, which would
stop the daily build **and** the freshness alarm without a sound. Each scheduled run therefore ends with a
`keepalive` job that re-enables both workflows through the API. GitHub does not document that enabling an enabled
workflow resets the 60-day timer, so treat this as a best effort. **Backstop:** monitor the published images from
outside GitHub (for example a weekly check of the age of `latest`), and make a commit now and then.

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
   and runs the split-layout smoke test, which also checks that `gen` carries the pinned commit.
4. After the merge the push run publishes (a change to `pins.env` changes the build key), and the next freshness run
   closes the issue.

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
and `build-test`, must pass. After the merge, the push run builds and publishes if the build key changed (a change to
`edge/`, `gen/`, `pins.env`, `build.yml`, `LICENSE` or `NOTICE` always does). Check the run, then
[verify](verify.md) the new `latest`.
