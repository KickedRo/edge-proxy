<h1 align="center">edge-proxy</h1>

<p align="center">
  <b>A hardened nginx with a web application firewall, as a drop-in for nginx-proxy's separate-containers layout.</b>
</p>

<p align="center">
  <a href="https://github.com/KickedRo/edge-proxy/actions/workflows/build.yml?query=branch%3Amain"><img src="https://github.com/KickedRo/edge-proxy/actions/workflows/build.yml/badge.svg?branch=main" alt="build"></a>
  <a href="https://github.com/KickedRo/edge-proxy/releases"><img src="https://img.shields.io/github/v/release/KickedRo/edge-proxy?sort=semver" alt="latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/KickedRo/edge-proxy" alt="license: MIT"></a>
</p>

## What it is

Two container images for the front door of a Docker host: a hardened nginx with a web application firewall (WAF), and
the config generator that goes with it. They replace the images of the "separate containers" layout of
[nginx-proxy](https://github.com/nginx-proxy/nginx-proxy). Your backends keep their `VIRTUAL_HOST` variables, and
nginx-proxy's own template writes the configuration. What is new is the firewall in front, and stricter defaults.

| Image | What it is |
|---|---|
| `ghcr.io/kickedro/edge-proxy` (`edge`) | Current nginx mainline, ModSecurity v3 and the OWASP Core Rule Set 4. Hardened by default; every protection is one documented environment variable. |
| `ghcr.io/kickedro/edge-proxy-gen` (`gen`) | [docker-gen](https://github.com/nginx-proxy/docker-gen) built from source, with nginx-proxy's own template at a pinned commit. It watches Docker and writes the nginx configuration for `edge`. |

How it differs from the upstream nginx-proxy image:

- **A WAF in front of every site.** Requests are inspected by the OWASP Core Rule Set (paranoia level 1, blocking from
  the first request). Upstream nginx-proxy has no WAF.
- **Hardened defaults.** Short client timeouts, no version in the `Server` header, backend software headers removed,
  security headers added, and a block page that carries a reference to the audit log entry. The start-up check prints
  a `SECURITY:` line for every setting you weaken, and refuses values it does not understand.
- **Fresh.** Both images are rebuilt every day against the newest nginx, ModSecurity, CRS and docker-gen, with the
  Debian security updates. A build whose content changed is tested, scanned and published as a new version.
- **Verifiable.** Images are signed and come with build provenance, an SBOM and a list of everything inside them,
  see [docs/verify.md](docs/verify.md).

The upstream template is used unchanged. Per-container variables, `vhost.d` snippets, certificates and proxy-wide
`conf.d` files work as in nginx-proxy's separate-containers layout.

## Read this before you install it

> [!WARNING]
> **This is beta software (0.x).** The images have not yet run on many real sites. Until 1.0, a minor version
> (0.1 → 0.2) may change a default or a setting. The [changelog](CHANGELOG.md) says what changed, and what to do when
> an upgrade needs action.

> [!IMPORTANT]
> **The WAF is on, and it blocks some legitimate traffic until you configure it.** The defaults let common traffic
> through: REST methods, WordPress's method override, `Expect: 100-continue` uploads, and forms up to 1 MiB. Raw-file
> uploads (`application/octet-stream`: WebDAV, file sync), WebDAV methods, `text/plain` beacons and CSP reports are
> still refused until you allow them. Each of these is one setting, see
> [what the WAF lets through](docs/configuration.md#what-the-waf-lets-through-by-default). On a busy site, start with
> `MODSEC_RULE_ENGINE=DetectionOnly` and read the audit log before you block.

> [!CAUTION]
> **Opinionated, and with no support promise.** KickedRo maintains this for its own use and publishes it in case it
> helps others. It does one layout (nginx-proxy's separate containers) one way: secure defaults, one setting per
> protection, upstream's template unchanged. Issues and pull requests are welcome, but they are handled when time
> allows, and changes that do not fit may be declined. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Install

You need Docker with Compose on a `linux/amd64` host. Both images are built for `linux/amd64` only; there are no
`arm64` images yet.

### Quick start

[`examples/docker-compose.yml`](examples/docker-compose.yml) is the whole layout: `edge`, `gen`, the
[acme-companion](https://github.com/nginx-proxy/acme-companion) for Let's Encrypt certificates, and a test backend.
Copy it, change the example host names and the e-mail address, then:

```sh
docker compose up -d
```

Backends join the same network and set `VIRTUAL_HOST`, as they would with nginx-proxy. For a certificate they also set
`ACME_HOST` (`LETSENCRYPT_HOST` is its older name, which acme-companion still accepts). Look at the start-up output of
`edge`: it shows any `SECURITY:` line.

Before you use it for real, read the [settings table](docs/settings.md) (every setting, its default, and what you lose
by weakening it) and the [configuration guide](docs/configuration.md). The points that most often matter:
[what the WAF lets through by default](docs/configuration.md#what-the-waf-lets-through-by-default) and what it still
blocks, the audit log (it holds request headers, so treat it as sensitive), and how to add site-specific WAF exclusions.

### Pin a version

The example uses `latest` to stay short. For a real deployment, pick a version from the
[Releases](https://github.com/KickedRo/edge-proxy/releases) page, [verify](docs/verify.md) it, and pin it by version
and digest. Docker pulls by the digest; the version is there for you to read.

```yaml
services:
  nginx-proxy:
    image: ghcr.io/kickedro/edge-proxy:0.1.0@sha256:<the digest you verified>
  nginx-proxy-gen:
    image: ghcr.io/kickedro/edge-proxy-gen:0.1.0@sha256:<the digest you verified>
```

Use the same version for both images: they are built, tested and released together. If you would rather follow the
upstream and security updates without editing the file, use the line tag `0.1`. It moves to each new patch of 0.1,
but never to 0.2, which may change a default. A patch can still bring a new CRS release, whose rules may block
something they did not before; the release notes name every upstream version that changed.

### Coming from nginx-proxy

Replace the two images and keep your `VIRTUAL_HOST` backends. What differs is the firewall and the stricter defaults.
Where a proxy-wide `conf.d` file sets a directive the image also sets, the file's value applies and the start-up log
says so. See [migrating](docs/configuration.md#migrating-from-an-existing-nginx-proxy-setup).

## What works today

**Web application firewall**
- ModSecurity v3 with the OWASP Core Rule Set 4, paranoia level 1, blocking from the first request.
- Defaults that let common legitimate traffic through: `PUT`, `PATCH` and `DELETE`, the method-override headers,
  `Expect: 100-continue`, form and JSON bodies up to 1 MiB, up to 2999 arguments. Each is one setting to tighten.
- Your own rules and site exclusions in `custom.d` (before the CRS) and `after.d` (after it), and CRS plugins
  mounted from a reviewed release.
- An audit log in JSON on stdout, with a reference on the block page to find the entry.
- A narrow exemption for Let's Encrypt HTTP-01 validation requests, so a rule cannot block certificate issuance.
- Detection-only mode, to find false positives on a new site before blocking.

**Hardening**
- Every protection is one environment variable with a secure default, listed in the [settings table](docs/settings.md).
- A start-up check that stops the container on a value it does not understand, and prints a `SECURITY:` line for
  each weakened setting.
- Client timeouts of 10 s and keep-alive of 15 s, no version in the `Server` header, backend software headers
  (`X-Powered-By`, `Server`, ...) removed, and security headers added unless the response has them.
- A block page with a reference instead of nginx's plain 403 page, or your own page.
- Proxy-wide `conf.d` files keep working: the image gives way, and logs a `NOTICE:` or `SECURITY:` line.
- `edge` can run with a read-only root filesystem (with a few tmpfs mounts) and never gets the Docker socket. `gen`
  needs no network at all.

**Freshness and pipeline**
- A daily build against the newest nginx mainline, ModSecurity, the connector, CRS, docker-gen and Go, within pinned
  major versions, with the Debian security updates.
- Every build runs unit tests, the smoke tests and a Trivy scan that fails on any fixable HIGH or CRITICAL finding.
- Tested in CI with the WAF on: certificates issued and renewed through `edge` (the example compose file, with a local
  test CA), long-lived connections (WebSocket, server-sent events, long polling) and HTTP/3.
- Only a build whose content changed is published, as the next patch version. An unchanged build publishes nothing.
- Alarms open an issue when a scheduled build fails, when the daily build stops, when `latest` is older than 30 days
  or behind upstream nginx, and when nginx-proxy's template has moved past the pin for a week.

**Supply chain**
- Upstream sources are checked: nginx, ModSecurity, the connector and CRS against their projects' PGP signing keys
  (pinned by fingerprint), nginx-proxy by its full commit SHA.
- The images that are published are the archives that were tested and scanned, not a rebuild, and a check confirms
  the pushed images are the same bits.
- A cosign signature (keyless, recorded in the public Sigstore log), a GitHub build provenance attestation, an SBOM
  and buildx provenance for each image.
- A GitHub Release for every version, with notes on what changed and a `manifest.json` of everything inside.
- GitHub Actions pinned by full commit SHA, a read-only default token, and only the release job may write the
  repository's contents (its tag and Release).

## Versions and releases

Both images share one version, `MAJOR.MINOR.PATCH`, and every version has a
[GitHub Release](https://github.com/KickedRo/edge-proxy/releases) with the git tag `vX.Y.Z`.

- **Our changes set MAJOR.MINOR.** The [`VERSION`](VERSION) file holds it. A new feature or a changed default bumps
  it in a pull request, and merging that publishes `X.Y.0`.
- **The pipeline sets PATCH.** Every later publish with changed content, from an upstream release, a Debian security
  update or one of our fixes, becomes the next patch (`0.1.1`, `0.1.2`, ...) without anyone's help.
- **Image tags.** `X.Y.Z` names one image and never moves. `X.Y` moves to the newest patch of its line. `latest`
  moves to the newest version. Tags published before 0.1.0 keep their date-based names.
- **Release notes** list the pull requests merged since the previous release, the upstream versions (old → new), the
  Debian packages and Go modules that changed, and both image references with the commands to verify them. Each
  Release has `manifest.json` attached: the full list of what is inside.
- **[CHANGELOG.md](CHANGELOG.md)** covers the `X.Y.0` releases, written by hand. Automatic patch releases are listed
  on the Releases page only.

[docs/verify.md](docs/verify.md) has the details.

## Security

Report a vulnerability privately, through GitHub's private vulnerability reporting, not in an issue; see
[SECURITY.md](SECURITY.md). Only the newest release is supported. Fixes ship as a new patch release.

The audit log holds request headers, including `Cookie` and `Authorization`. Treat it like your secrets.

**Known limitation: acme-companion holds the Docker socket.** As in nginx-proxy's own layout, acme-companion mounts
the Docker socket (to find the containers and signal them) and reaches the internet (to talk to Let's Encrypt).
Whoever controls the Docker socket controls the host, and mounting it read-only does not change that. So a compromise
of acme-companion is a compromise of the host. This project keeps the socket away from the part that faces the
internet: `edge` never gets it, and in the example layout `gen` has it but no network. acme-companion is upstream's
image, unchanged. The risk is known and accepted for now.

## Documentation

- [docs/settings.md](docs/settings.md): every environment variable (generated from `edge/settings.tsv`).
- [docs/configuration.md](docs/configuration.md): mount points, exclusions, what the WAF lets through, logs, block
  page, proxy-wide files, migrating, the `gen` image.
- [docs/verify.md](docs/verify.md): tags and versions, signatures and provenance, release notes and `manifest.json`,
  pinning.
- [examples/](examples/): the compose file and how to write exclusions.
- [CHANGELOG.md](CHANGELOG.md): what changed in each minor release.
- [docs/maintenance.md](docs/maintenance.md): how the build and release pipeline works (for maintainers).
- [docs/going-public.md](docs/going-public.md): the repository protections that are switched on.
- [SECURITY.md](SECURITY.md): how to report a vulnerability.

## Development

Everything is built and tested in Docker. [CONTRIBUTING.md](CONTRIBUTING.md) has the commands CI runs, the house
conventions, and what a pull request needs (a test, a changelog entry, a `VERSION` bump when a default changes).

## License

MIT, see [LICENSE](LICENSE). The images contain third-party software under its own licences, see [NOTICE](NOTICE).
