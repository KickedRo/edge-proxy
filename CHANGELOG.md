# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This file covers the minor and major releases (`X.Y.0`), which come from a change in this repository. Patch releases
(`X.Y.1`, `X.Y.2`, ...) are made by the build pipeline whenever the content of the images changes: a new upstream
release, a Debian security update, or a fix merged without a version bump. They are listed, with notes on what
changed, on the [Releases page](https://github.com/KickedRo/edge-proxy/releases) only. An entry under
`[Unreleased]` is merged; if it is a fix, it may already be in a patch release.

## [Unreleased]

### Added

- HTTP/3 in the split-layout smoke test (`tests/split_smoke.sh`): a site with the HTTP/3 label answers over HTTP/3,
  sends `alt-svc` over HTTP/2, and attacks in the URL, a header, a form body and a body streamed without
  `Content-Length` are blocked by the CRS over HTTP/3; rule 920280 still applies to other protocols. Documented in the
  configuration guide, with the UDP port in the example compose file.
- A smoke test for long-lived connections through the WAF (`tests/streaming_smoke.sh`): WebSocket echo across a 20 s
  idle period, server-sent events and streamed HTML arriving as they are produced, a 25 s long poll, and attacks on the
  same routes still blocked.

### Fixed

- HTTP/3 requests were refused by the WAF: the connector hands ModSecurity no Host header for them, so CRS rule 920280
  matched every request. The image now skips that rule for HTTP/3 requests only (rule 10002).
- With a host folder mounted at `/var/log/nginx`, errors logged at http level (for example by nginx-proxy's template)
  reach `error.log` from the first start, not only after the first reload.

## [0.1.0] - 2026-11-17

> **Upgrading:** images published before 0.1.0 have date-based tags (for example
> `1.31.8-modsec3.0.17-crs4.30.0-20261116`). Those tags stay where they are, but no new ones are made. If you pinned
> one, move to a version: pin `0.1.0` by version and digest, or follow `0.1` to get every patch of this line. If you
> use `latest`, nothing changes for you.

The first versioned release. It describes what the images do as of this version.

### Added

- **Two images for nginx-proxy's separate-containers layout.** `edge` is nginx mainline with ModSecurity v3 and the
  OWASP Core Rule Set 4; `gen` is docker-gen, built from source, with nginx-proxy's own template at a pinned commit.
  Backends keep their `VIRTUAL_HOST` variables, and `vhost.d` snippets, certificates and per-container variables
  work as before, because the template is upstream's, unchanged.
- **A WAF in front of every site.** The CRS inspects every request at paranoia level 1 and blocks from the first
  request (inbound anomaly threshold 5, outbound 4). Upstream nginx-proxy has none.
- **Defaults that let common legitimate traffic through.** The CRS's own lists refuse ordinary REST and upload
  traffic, and a WAF that breaks a site gets switched off. So the image allows `PUT`, `PATCH` and `DELETE`, the
  method-override headers (WordPress's block editor uses them), `Expect: 100-continue`, form and JSON bodies up to
  1 MiB and up to 2999 arguments. Each of these is one setting to tighten again. Raw-file uploads and WebDAV methods
  stay refused until you allow them.
- **One setting per protection, checked at start.** 23 environment variables, each with a secure default and a
  line in `docs/settings.md` on what you lose by weakening it. A value the check does not understand stops the
  container; a weaker value prints a `SECURITY:` line. Mistakes show up at start, not after an incident.
- **Hardened nginx.** Client timeouts of 10 s and keep-alive of 15 s, no version in the `Server` header, backend
  software headers removed, security headers added unless the response has them, and optional rate-limit zones for
  vhost snippets.
- **A block page with a reference.** A blocked request gets a short page whose reference finds its audit log entry,
  so a user can report a false positive that you can look up. The page shows no rule details.
- **Proxy-wide `conf.d` files keep working.** nginx refuses a directive set twice, so where such a file sets a
  directive the image also sets, the image drops its own line and logs a `NOTICE:` or `SECURITY:` line.
- **Your own rules and exclusions.** `custom.d` (before the CRS), `after.d` (after it) and `plugins` (CRS plugins)
  mount points, an audit log in JSON on stdout, and detection-only mode for a first period on a new site.
- **A narrow ACME exemption.** Requests that look exactly like a Let's Encrypt HTTP-01 validation are not inspected,
  so a rule cannot block certificate issuance. Anything else on that path is inspected as usual.
- **Daily rebuilds that publish only what changed.** Both images are rebuilt every day against the newest upstream
  versions within pinned majors, with the Debian security updates and docker-gen's vulnerability-driven module
  upgrades. A content key decides whether anything changed; only then is a new version published.
- **Versions and GitHub Releases.** One SemVer version for both images, set by the new `VERSION` file (`MAJOR.MINOR`)
  and the pipeline (`PATCH`). Image tags `X.Y.Z` (never moves), `X.Y` (newest patch of its line) and `latest`. Every
  version gets a Release `vX.Y.Z` with notes on what changed since the previous one and a `manifest.json` of
  everything inside. You can tell what you run and what an update brings.
- **Alarms.** An issue opens when a scheduled build fails, when the daily build stops or `latest` is older than 30
  days or behind upstream nginx, and when nginx-proxy's template has moved past the pin for a week.

### Changed

- **Version tags instead of date-based tags.** Images published before this release were tagged with their upstream
  versions and the build date. A date says when an image was built, but not what changed or whether an update needs
  action. The image label `org.opencontainers.image.version` now holds the version.
- **No weekly republish.** An unchanged image is no longer published again every Monday: with versions, the same
  content gets no new version. So `latest` can be weeks old when nothing changed. The freshness alarm now checks
  that the daily build runs and succeeds, with a 30-day backstop on the age of `latest`.

### Security

- **Checked sources.** The nginx, ModSecurity, connector and CRS downloads must carry a valid PGP signature from their
  projects' keys, pinned by fingerprint. nginx-proxy is fetched at a full commit SHA, and the build checks it.
- **What was tested is what gets published.** The publish job pushes the image archives that passed the smoke tests
  and the scan, not a rebuild, and checks that the pushed images are the same bits.
- **Signed, with provenance.** Each image has a keyless cosign signature, a GitHub build provenance attestation, an
  SBOM and buildx provenance. [docs/verify.md](docs/verify.md) shows how to check them.
- **A scan gate.** Trivy fails the build on any fixable HIGH or CRITICAL finding. An exception needs a written reason
  and expires within 30 days.
- **Least privilege.** `edge`, the container that faces the internet, never gets the Docker socket; `gen` needs no
  network. The workflows use a read-only default token and actions pinned by full commit SHA; only the release job
  can write tags and Releases, and it holds no registry credentials.

[Unreleased]: https://github.com/KickedRo/edge-proxy/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/KickedRo/edge-proxy/releases/tag/v0.1.0
