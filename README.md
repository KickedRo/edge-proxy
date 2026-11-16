# edge-proxy

**Start here: the [settings table](docs/settings.md)**, every setting of the `edge` image with its default and what
you lose by weakening it.

Two container images for the front door of a Docker host: a hardened nginx with a web application firewall, and the
config generator that goes with it. They replace the images of the "separate containers" layout of
[nginx-proxy](https://github.com/nginx-proxy/nginx-proxy): your backends keep their `VIRTUAL_HOST` variables, and
nginx-proxy's own template writes the configuration. What is new is the firewall in front. Its defaults let common
legitimate traffic through (REST methods, WordPress's method override, `Expect: 100-continue` uploads, forms up to
1 MiB) and each of these is one setting to tighten; raw-file uploads and WebDAV methods are still refused until you
allow them. See [what the WAF lets through](docs/configuration.md#what-the-waf-lets-through-by-default).

| Image | What it is |
|---|---|
| `ghcr.io/kickedro/edge-proxy` (`edge`) | Current nginx mainline, ModSecurity v3 and the OWASP Core Rule Set 4. Hardened by default; every protection is one documented environment variable. |
| `ghcr.io/kickedro/edge-proxy-gen` (`gen`) | [docker-gen](https://github.com/nginx-proxy/docker-gen) built from source, with nginx-proxy's own template at a pinned commit. It watches Docker and writes the nginx configuration for `edge`. |

Both images are built for `linux/amd64` only; there are no `arm64` images yet. Tags: `latest`, and a release tag for
each publish that never moves (`<nginx>-modsec<version>-crs<version>-<YYYYMMDD>` for `edge`; a second publish on the
same day gets `.2`, then `.3`), see [verifying](docs/verify.md).

## Why not the upstream nginx-proxy image

- **Freshness.** Both images are rebuilt every day against the newest nginx, ModSecurity, CRS and docker-gen, with
  the Debian security updates. A changed build is tested, scanned and published; an unchanged one is only published on Mondays. A
  published `latest` is never older than about a week, and an alarm opens an issue if it is. nginx-proxy's template
  is moved to a new commit by hand, after review; an issue opens when upstream's template has changed for a week.
- **A WAF in front of every site.** Requests are inspected by the OWASP Core Rule Set (paranoia level 1, blocking
  from the first request). Upstream nginx-proxy has no WAF.
- **Hardened defaults.** Short client timeouts, no version in the `Server` header, backend software headers
  removed, security headers added, a block page that carries a reference to the audit log entry. The start-up check
  prints a `SECURITY:` line for every setting you weaken and refuses values it does not understand.
- **Verifiable.** Images are signed and come with build provenance and an SBOM, see [docs/verify.md](docs/verify.md).

The upstream template is used unchanged, so per-container variables, `vhost.d` snippets, certificates and
proxy-wide `conf.d` files work as in nginx-proxy's separate-containers layout. What differs is the firewall and the
stricter defaults; and where a proxy-wide `conf.d` file sets a directive the image also sets, the file's value applies
and the start-up log says so. See [migrating](docs/configuration.md#migrating-from-an-existing-nginx-proxy-setup).

## Quick start

[`examples/docker-compose.yml`](examples/docker-compose.yml) is the whole layout: `edge`, `gen`, the
[acme-companion](https://github.com/nginx-proxy/acme-companion) for Let's Encrypt certificates, and a test backend.
Copy it, change the example host names and the e-mail address, then:

```sh
docker compose up -d
```

Backends join the same network and set `VIRTUAL_HOST` (and `ACME_HOST` for a certificate; `LETSENCRYPT_HOST` is its older name, which acme-companion still accepts) as they would with
nginx-proxy. Look at the start-up output of `edge`: it shows any `SECURITY:` line.

Before you use it for real, read the [configuration guide](docs/configuration.md). The points that most often
matter: [what the WAF lets through by default](docs/configuration.md#what-the-waf-lets-through-by-default) and what it
still blocks, the audit log (it holds request headers, treat it as sensitive), and how to add site-specific WAF
exclusions.

## Documentation

- [docs/settings.md](docs/settings.md): every environment variable (generated from `edge/settings.tsv`).
- [docs/configuration.md](docs/configuration.md): mount points, exclusions, what the WAF lets through, logs, block
  page, proxy-wide files, migrating, the `gen` image.
- [docs/verify.md](docs/verify.md): check signatures and provenance, pin by digest.
- [examples/](examples/): the compose file and how to write exclusions.
- [docs/maintenance.md](docs/maintenance.md): how the build pipeline works (for maintainers).
- [docs/going-public.md](docs/going-public.md): the repository protections that are switched on.
- [SECURITY.md](SECURITY.md): how to report a vulnerability.

## Status

Maintained by KickedRo for its own use and published in case it helps others. There is no support promise: issues
and pull requests are welcome, but they are handled when time allows, and changes that do not fit our own needs may
be declined.

## Licence

MIT, see [LICENSE](LICENSE). The images contain third-party software under its own licences, see
[NOTICE](NOTICE).
