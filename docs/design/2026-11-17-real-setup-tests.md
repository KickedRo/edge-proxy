# Tests for certificates, long-lived connections and HTTP/3

Status: approved 2026-11-17.

## Why

The images are meant to replace nginx-proxy in front of real sites, and three things those sites depend on have no
test today:

1. **Certificates.** `examples/docker-compose.yml` adds acme-companion and says its part "is not exercised by those
   tests". Issuing a certificate crosses every container: acme-companion writes the challenge file, `edge` (read-only
   mounts, no Docker socket, WAF on) serves it, gen rewrites the configuration once the certificate exists and
   reloads `edge`. A break anywhere means sites lose HTTPS when their certificates expire.
2. **Long-lived connections.** WebSockets, server-sent events (SSE), long polling and streamed pages go through the
   WAF and through timeouts this image shortens. Reading the ModSecurity-nginx connector (v1.0.4) shows it passes
   response data on as it arrives, so it should not hold streams back, but nothing proves it.
3. **HTTP/3.** `edge`'s nginx has `--with-http_v3_module` and gen's template turns HTTP/3 on per site (label
   `com.github.nginx-proxy.nginx-proxy.http3.enable=true`, or `ENABLE_HTTP3=true` on gen). Whether the WAF inspects
   requests that arrive over QUIC (URL, headers and body) has not been checked; a gap there is a WAF bypass for every
   site that turns HTTP/3 on.

The images are rebuilt daily from moving upstreams, so these are regression tests that CI runs on every build, not a
one-time check.

## Goals

- A certificate is issued and renewed through `edge` in the documented example layout, with no internet access.
- Legitimate long-lived traffic works through `edge` with the default settings, and attacks inside it are still
  blocked.
- HTTP/3 works when a site turns it on, and the WAF blocks the same attacks over HTTP/3 as over HTTP/1.1 and HTTP/2.
- The published example and the docs say what is tested, and how to turn HTTP/3 on.

## Non-goals

- Load or performance tests; DNS-01 challenges; ACME clients other than acme-companion; arm64.
- Changing defaults or image content, unless a test shows legitimate traffic breaks (below).

## Anti-goals (a failure even if it works)

- A test that contacts the internet (Let's Encrypt, its staging server, any public resolver).
- A test that depends on tight timing and fails now and then on a slow runner.
- A test that touches containers, volumes or ports it did not create (a shared Docker host may run other
  nginx-proxy setups and allow only some ports: the scripts take theirs from `PORT_1`..`PORT_9`).
- A changed default without a setting to get the old behaviour back (the project's one-setting-per-protection rule).

## Approaches considered

1. **Regression tests in CI (chosen).** Three scripts in `tests/`, run by the `build-test` job next to the existing
   smoke tests, entirely in Docker on the runner. Trade-off: a few minutes more per build, and Pebble plus a test
   client image to pin.
2. **A one-time manual check before the first deployment.** Cheaper now, but stale after the next upstream release.
3. **Testing against Let's Encrypt staging.** Real CA, but needs public DNS and inbound port 80 to the runner, and
   fails when staging is down.

## Decided parts of the how

### Certificates (`tests/acme_e2e.sh`)

- Runs `examples/docker-compose.yml` itself, with a test override file (`tests/compose.acme.yml`), so the published
  example cannot rot unnoticed. The override changes only what a test must change: unique container names per run, a
  per-run nginx label (as `tests/compose.smoke.yml` does), host ports from the caller (or none), the images under
  test, and acme-companion pointed at a local Pebble (`ACME_CA_URI`, `CA_BUNDLE`; acme-companion's own test suite
  uses Pebble the same way).
- Pebble (Let's Encrypt's test CA, `ghcr.io/letsencrypt/pebble`, pinned by version and digest) validates HTTP-01
  challenges on port 80 of the vhost's name, which resolves to `edge` through a Docker network alias: the challenge
  request really goes through `edge` and its WAF.
- Checks: acme-companion obtains a certificate for the test vhost; `edge` serves it over HTTPS (verified against
  Pebble's root, fetched from Pebble's management API); HTTP redirects to HTTPS; a forced renewal
  (`/app/force_renew` in acme-companion) produces a new certificate (different serial) that `edge` serves without
  being restarted (same container start time).

### Long-lived connections (`tests/streaming_smoke.sh`)

- A small test backend written with Python's standard library only (no packages), run in the Python image the unit
  tests already use, offering: a WebSocket echo, an SSE stream (an event per second, `X-Accel-Buffering: no` as
  well-behaved SSE servers send), a long poll that answers after 25 seconds, and a chunked `text/html` page streamed
  over several seconds (a type the WAF inspects in responses).
- Checks, with the default settings and the WAF on: the first SSE event and the first HTML chunk reach the client
  well before the backend finishes; WebSocket messages go both ways, also after 20 seconds of silence (longer than
  every timeout this image shortens); the long poll completes with its body. An attack in the WebSocket handshake's
  query string and one in the SSE request are blocked with the deny status.

### HTTP/3 (in the split-layout smoke test or a script of its own)

- One vhost with the HTTP/3 label; the client is Debian trixie's curl (built with HTTP/3; the `curlimages/curl` and
  Alpine curl builds are not), run on the test network so no UDP port has to be published on the host.
- Checks: a GET over HTTP/3 only (`--http3-only`) answers 200 and reports HTTP/3; the `alt-svc` header is sent over
  HTTP/2; over HTTP/3, an attack in the URL, one in a header and one in a POST body are each blocked, a legitimate
  POST passes, and a body over the request body limit is refused, just as over HTTP/1.1.

### When a test finds a real problem

A fix that fits the project's pattern (a setting with a secure default, `docs/settings.md` regenerated, a test) goes
into the same pull request, with a `VERSION` bump if it changes a default. Anything else (a change of approach, a
default that has to loosen security) is brought to the maintainers before it is built.

### Found in a real deployment: http-level errors and a mounted log directory

nginx-proxy's template sets `error_log /dev/stderr;` at http level. nginx opens that path while it reads its
configuration and only afterwards points its own stderr at the main-level error log (`/var/log/nginx/error.log`). So
when that directory is a mounted folder (as many nginx-proxy setups do, to keep log files on the host), errors such
as "access forbidden by rule" go to the container's output after `edge` starts, and to `error.log` only after the
first reload. nginx-proxy's single container hides this, because its built-in docker-gen reloads nginx right after
every start; in the split layout gen only reloads `edge` when the configuration changes. Fix, without a setting: when
`/var/log/nginx/error.log` is not the image's symlink (the directory is mounted), the entrypoint sends nginx's stderr
to that file before it starts nginx, so these lines land in `error.log` from the first request on, as with
nginx-proxy. Start-up messages of the entrypoint itself stay in the container output.

### Documentation

- `examples/docker-compose.yml`: the "not exercised" sentence goes; a commented `443:443/udp` port with a line on
  HTTP/3.
- `docs/configuration.md`: how to turn HTTP/3 on (label or `ENABLE_HTTP3`, the UDP port).
- README "What works today" and `CHANGELOG.md` `[Unreleased]`: what is now tested.

## Calls made by the author of this design (not discussed with the maintainers)

- The ACME test runs the published example file plus an override, not a separate compose file.
- Python's standard library for the streaming backend and the WebSocket client; Debian's curl for HTTP/3.
- 25-second long poll and 20-second WebSocket silence: longer than the shortened timeouts, shorter than nginx's
  default 60-second `proxy_read_timeout`, which the image keeps.

## Left to the builder

- Whether HTTP/3 extends `tests/split_smoke.sh` (it already makes certificates and vhosts) or gets its own script.
- How the compose override replaces the example's fixed ports and names (Compose's `!override` / `!reset` tags, or
  a documented reason the example cannot be reused, in which case a test compose file that mirrors it).
- Pebble's configuration (HTTP port 80, `PEBBLE_VA_NOSLEEP`, nonce rejection off) and how the root is fetched.
- Exact margins for "well before the backend finishes", chosen so a slow runner cannot fail the test.
