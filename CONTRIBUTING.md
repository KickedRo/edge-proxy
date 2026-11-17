# Contributing

Thank you for looking. Issues and pull requests are welcome. Please read this page first: it says what to expect,
how to build and test, and what a pull request needs.

## What to expect

- KickedRo maintains this project for its own use and publishes it in case it helps others. There is no support
  promise and no response time. Issues and pull requests are handled when time allows.
- A good change can still be declined when it does not fit the project's direction or its maintainers' needs.
- **Open an issue first** for anything that adds a setting, a mount point, an image, a dependency or any other
  surface that has to be documented, tested and kept working. Agree on the idea before you write the code. A small fix
  with a test can come straight as a pull request.
- **Security problems do not go in issues.** Use private vulnerability reporting, see [SECURITY.md](SECURITY.md).

## Scope and opinions

- **Secure defaults that let common traffic through.** A default that breaks ordinary sites gets the WAF switched
  off, and then it protects nobody. A default that lets everything through protects nobody either. The defaults sit
  between the two, and the reasons are written down in [docs/configuration.md](docs/configuration.md).
- **One setting per protection.** Every protection is one environment variable with a secure default, a list of
  allowed values, and a sentence on what you lose by weakening it. Weakening it prints a `SECURITY:` line at start.
  No setting without that.
- **nginx-proxy's template, unchanged.** The images are a drop-in for nginx-proxy's separate-containers layout.
  The template is not patched; the image's behaviour comes from the nginx and ModSecurity configuration around it.
- **Fresh by default.** The build takes the newest upstream versions within the major versions in `pins.env`, every
  day. Only nginx-proxy's commit is moved by hand, after review.
- **Nothing site-specific.** No host names, addresses, customer names or exclusions for particular sites. Examples
  use `example.com` and the documentation address ranges (RFC 5737, RFC 3849).
- **Out of scope for now:** `arm64` images, other proxy layouts, a documentation website.

## Development

You need Docker with buildx, bash, git, `jq` and Python 3. Every image build and every smoke test runs in Docker.

### Build

```sh
python3 scripts/resolve_versions.py --out build/versions.env   # the newest upstream versions, as CI resolves them
docker buildx build --load --build-context repo=. -t edge-proxy:dev $(sed 's/^/--build-arg /' build/versions.env) edge
docker buildx build --load --build-context repo=. -t edge-proxy-gen:dev $(sed 's/^/--build-arg /' build/versions.env) \
  --build-arg SECURITY_EPOCH=$(date -u +%Y%m%d) gen
```

`build/` is ignored by git. `--build-context repo=.` is required: both images ship the repository's `LICENSE` and
`NOTICE`. `gen` needs `SECURITY_EPOCH` (CI passes the UTC date to both images, so the security-upgrade layers are
rebuilt once a day). `scripts/resolve_versions.py` asks the GitHub API; set `GITHUB_TOKEN` if you hit its rate limit.
The first `edge` build compiles ModSecurity and takes a while; later builds use the cache.

### Test

These are the commands CI's `build-test` job runs, in this order (see `.github/workflows/build.yml`):

```sh
python3 -m unittest discover -s tests -p 'test_*.py' -v
tests/release_test.sh
python3 scripts/check_trivyignore.py .trivyignore.yaml
tests/edge_smoke.sh edge-proxy:dev
tests/split_smoke.sh edge-proxy:dev edge-proxy-gen:dev
tests/streaming_smoke.sh edge-proxy:dev edge-proxy-gen:dev
tests/acme_e2e.sh edge-proxy:dev edge-proxy-gen:dev
tests/hardening_smoke.sh edge-proxy:dev
```

The smoke tests start containers and networks of their own and remove everything they create, also on failure.

- **Ports.** `tests/split_smoke.sh` and `tests/streaming_smoke.sh` publish two ports on `127.0.0.1`: they take them
  from `PORT_1` and `PORT_2` when they are set, otherwise Docker picks them. `tests/acme_e2e.sh` publishes none.
- **Network.** `tests/split_smoke.sh` builds its HTTP/3 client from Debian's `curl` package, so it needs Debian's
  package mirror. `tests/acme_e2e.sh` runs on internal Docker networks, so nothing in it can connect to a real CA.
  Outside DNS is blocked there too on Docker Engine 26.0 and later (CVE-2024-29018, also fixed in 25.0.5); older
  engines may still forward DNS queries from internal networks to the host's resolvers.
- **A shared Docker host.** `tests/acme_e2e.sh` refuses to run while any container carries one of acme-companion's
  discovery labels (`com.github.nginx-proxy.nginx`, `com.github.nginx-proxy.docker-gen` and their older
  `com.github.jrcs.letsencrypt_nginx_proxy_companion.*` forms): the acme-companion it starts would signal that
  container.

Without Python on the host, run the unit tests in a container:

```sh
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/w -w /w python:3.13-slim python3 -m unittest discover -s tests -p 'test_*.py'
```

After that, CI also scans both images with Trivy (any fixable HIGH or CRITICAL finding fails the build, see
[Trivy exceptions](docs/maintenance.md#trivy-exceptions)), computes the build key and tests it
(`tests/build_key_test.sh`), and rehearses publishing against a throw-away local registry
(`tests/publish_rehearsal.sh`). The workflow file has those commands. If you change a workflow, lint it:

```sh
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:latest
```

## House conventions

- **Settings live in `edge/settings.tsv`.** Its header describes the seven fields. `docs/settings.md` is generated
  from it: never edit it by hand, regenerate it with
  `python3 scripts/gen_settings_doc.py edge/settings.tsv > docs/settings.md`. A unit test fails when it is stale.
- **Every behaviour change has a test** that fails without the change: an assertion in a smoke test, or a unit test
  for a script.
- **Comments explain why**, not what the next line does.
- **Fail closed.** A script that cannot tell (a registry or API error) stops with a message; it never guesses.
- **Pin what runs in the pipeline.** GitHub Actions by full commit SHA with the version in a comment, helper images
  by digest, nginx-proxy by its full commit SHA. No new third-party actions: the repository allows only GitHub's own
  and a short list of Docker and Sigstore actions.
- **Plain English, short sentences**, in documentation, log lines and error messages.
- **Commit messages and pull request titles** start with a type: `feat:`, `fix:`, `docs:`, `ci:`, `test:` or
  `chore:`, optionally with the image (`fix(edge): ...`). Pull requests are squash-merged, so the title becomes the
  commit on `main`.

## Versions and the changelog

Both images share one version, `MAJOR.MINOR.PATCH`. The pipeline sets the patch; you set the rest. See
[Versions and releases](README.md#versions-and-releases) for the whole scheme.

- **Every pull request that changes behaviour adds an entry** to [CHANGELOG.md](CHANGELOG.md) under
  `## [Unreleased]`, in the right section (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`). Start
  with a short bold phrase, then say what changed and why.
- **A new feature or a changed default bumps the minor version** in [`VERSION`](VERSION) (`0.1` → `0.2`; a breaking
  change after 1.0 bumps the major and resets the minor: `1.4` → `2.0`). In the same pull request, rename
  `## [Unreleased]` to `## [X.Y.0] - YYYY-MM-DD`, add a new empty `## [Unreleased]` above it, and update the two link
  references at the bottom of the file. Merging publishes `X.Y.0`, even when the image content did not change.
- **A release that needs action from users starts with an Upgrading note.** Put it directly under the version's
  heading, as a quote whose first line starts with `> **Upgrading:**` and whose every line starts with `>`. The
  release notes copy it, so use full URLs there, not relative links.
- **A fix without a version bump** ships in the next automatic patch release; its entry stays under `[Unreleased]`
  until the next minor release.
- **`VERSION` never goes back.** A line lower than a released version fails the build. The pipeline makes all tags;
  never push a tag by hand.

## Pull requests

- Branch from `main`, one topic per pull request. Fill in the template's checklist.
- The checks `resolve` and `build-test` must pass, and the branch must be up to date with `main`. Workflows of pull
  requests from forks run after a maintainer approves them.
- A maintainer squash-merges. When the change touches the image content, the run on `main` that follows the merge
  builds, tests and publishes a new version.
