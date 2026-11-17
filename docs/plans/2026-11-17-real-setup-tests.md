# Tests for certificates, long-lived connections and HTTP/3: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CI proves, on every build, that certificates are issued and renewed through `edge`, that long-lived
connections work through the WAF, that HTTP/3 works and is inspected like HTTP/1.1 and HTTP/2, and that http-level
errors reach a mounted `error.log` from the first start.

**Architecture:** One image fix (an entrypoint script) and three Docker-only test scripts in the existing smoke-test
style (`PASS <name>` per assertion, stop at the first failure, everything removed on exit), each run by the
`build-test` job. The ACME test runs `examples/docker-compose.yml` itself plus a test override, against a local
Pebble. Test helpers are pinned by digest and written with Python's standard library or shell.

**Tech Stack:** bash, Docker / Docker Compose (`!override` / `!reset` tags), Python 3 standard library, Pebble,
acme-companion, Debian trixie's curl (HTTP/3), GitHub Actions.

**Spec:** `docs/design/2026-11-17-real-setup-tests.md`

## Global Constraints

- No test contacts the internet beyond pulling pinned images (no Let's Encrypt, no staging, no public resolver).
- Every helper image is pinned by digest (`name@sha256:…`, with the tag in a comment), like `tests/edge_smoke.sh`.
- Tests create and remove only their own containers, volumes, networks and images: per-run names (`<script>-$$-$RANDOM`),
  a per-run nginx label (as `tests/compose.smoke.yml`), `trap cleanup EXIT`; never a fixed container name or a label
  another nginx-proxy setup on the same Docker host could match.
- Host ports only on 127.0.0.1, from `PORT_1`..`PORT_9` when set, else Docker picks; prefer clients on the test network
  (no host port at all).
- Timing assertions use margins a slow runner cannot miss (at least 3x the expected value), never exact durations.
- Output style: `PASS <name>` / `FAIL <name>: <why>` on stderr and exit 1, as the existing smoke tests.
- `shellcheck` clean; `actionlint` clean for `.github/workflows/build.yml`.
- Docker for every build and test; no internal names in any file (the repository is public).
- Commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` only.
- Each task adds its line under `## [Unreleased]` in `CHANGELOG.md` (`### Fixed` for Task 1, `### Added` for tests
  and docs). `VERSION` stays `0.1` (no feature, no changed default).

## Review Focus

1. **A shared Docker host.** acme-companion and gen read the whole Docker socket: other setups' containers with
   `VIRTUAL_HOST`/`LETSENCRYPT_HOST`/`com.github.nginx-proxy.*` labels must not be signalled or used as "the nginx".
   Task 4 asserts acme-companion names the test's own edge container.
2. **A failure half-way.** Every script must leave nothing behind when it fails after `up` (containers, volumes,
   networks, the built HTTP/3 client image). Each task's cleanup removes by run-specific name, never by pattern.
3. **The stderr fix without a mounted log directory.** With the image's default symlinks, start-up errors must still
   appear in `docker logs`. Task 1 tests both cases.
4. **HTTP/3 request bodies without Content-Length** (streamed from stdin): still inspected by the WAF. Task 3 tests it.
5. **Slow CI runners.** Streaming "arrives early" checks compare against the backend's total duration with a wide
   margin (Task 2), and every wait has a bounded timeout with logs dumped on failure.

---

### Task 1: http-level errors reach a mounted error.log from the first start

**Files:**
- Create: `edge/docker-entrypoint.d/95-kickedro-error-log.envsh`
- Modify: `tests/edge_smoke.sh` (new section at the end), `docs/configuration.md` (a "Log files on the host" note
  near "## Audit log"), `CHANGELOG.md`

**Interfaces:** none (sourced by the official `/docker-entrypoint.sh`, after the other `kickedro` scripts).

- [ ] **Step 1: Write the failing test** in `tests/edge_smoke.sh`: start a second edge container with
  `-v "$WORK/logs:/var/log/nginx"` (dir mode 755) and a conf.d file that has, at http level, `error_log /dev/stderr;`
  (as nginx-proxy's template) and a server whose `location /denied { deny all; }`; no reload. Request `/denied`.
  - `error_log_mounted_first_start`: `grep -q 'access forbidden by rule' "$WORK/logs/error.log"` within 10 s.
  - `error_log_mounted_not_in_container_output`: `docker logs` of that container has no `access forbidden` line.
  - `error_log_default_still_in_container_output`: the same request against a container WITHOUT the log mount shows
    the line in `docker logs` (symlink case unchanged).
- [ ] **Step 2: Run it, expect FAIL** on `error_log_mounted_first_start`:
  `tests/edge_smoke.sh edge-proxy:test` after building with
  `docker buildx build --load --build-context repo=. -t edge-proxy:test $(sed 's/^/--build-arg /' build/versions.env) edge/`.
- [ ] **Step 3: Implement** `95-kickedro-error-log.envsh` (`# shellcheck shell=sh`, comments say why): if
  `/var/log/nginx/error.log` is not a symlink, `exec 2>>/var/log/nginx/error.log`. Nothing else. Being sourced, the
  redirection carries into the `exec nginx` of the entrypoint; it is the last script, so earlier start-up lines
  (`SECURITY:`, `NOTICE:`) stay in the container output.
- [ ] **Step 4: Run the test, expect PASS**; also `tests/split_smoke.sh` and `tests/hardening_smoke.sh` still pass.
- [ ] **Step 5: Docs + changelog**: `docs/configuration.md` says that with a mounted `/var/log/nginx`, nginx's own
  errors (and the template's http-level errors) go to `error.log` from the start, and the audit log stays on stdout
  unless `MODSEC_AUDIT_LOG` says otherwise. `CHANGELOG.md` `### Fixed`.
- [ ] **Step 6: Commit** `fix: http-level errors reach a mounted error.log from the first start`.

### Task 2: Long-lived connections through the WAF (`tests/streaming_smoke.sh`)

**Files:**
- Create: `tests/fixtures/stream_backend.py`, `tests/fixtures/ws_client.py`, `tests/compose.streaming.yml`,
  `tests/streaming_smoke.sh`
- Modify: `.github/workflows/build.yml` (step after "Smoke test edge with gen (split layout)"), `CHANGELOG.md`

**Interfaces:**
- Produces: `stream_backend.py` — `python3 stream_backend.py [--port 8000]`, routes: `GET /ws` WebSocket echo (text
  frames, RFC 6455 handshake, answers pings); `GET /sse` `text/event-stream` with `X-Accel-Buffering: no`, one event
  `data: <n>` per second for 5 s; `GET /poll` answers `200 polled` after 25 s; `GET /html` chunked `text/html`, one
  chunk per second for 5 s. Standard library only.
- Produces: `ws_client.py` — `python3 ws_client.py URL --insecure --host NAME [--idle SECONDS]`: connects over TLS,
  sends `hello`, expects `hello` back, waits `--idle` seconds, sends `again`, expects `again`; prints
  `handshake <status>` and exits 0 only on success.
- Consumes: `tests/compose.smoke.yml` (edge, gen, volumes); the override adds service `stream` (the Python image the
  unit tests use, pinned by digest; runs `stream_backend.py`; `VIRTUAL_HOST: stream.example.com`,
  `VIRTUAL_PORT: "8000"`).

- [ ] **Step 1: Write the test script** (same skeleton and helpers as `tests/split_smoke.sh`: certificate for
  `stream.example.com`, `compose -f compose.smoke.yml -f compose.streaming.yml`, default settings, WAF `On`).
  Assertions (all over HTTPS):
  - `sse_first_event_early`: curl `-N` on `/sse`; `%{time_starttransfer}` < 3 s while the stream lasts 5 s, and all
    5 events arrive.
  - `html_first_chunk_early`: same for `/html` (a type the WAF inspects in responses).
  - `long_poll_completes`: `/poll` answers `200` with body `polled` (25 s; `--max-time 40`).
  - `websocket_echo`: `ws_client.py` run in the Python image on the test network, `--idle 20`, exits 0 with
    `handshake 101`.
  - `websocket_attack_blocked`: handshake to `/ws?q=<script>alert(1)</script>` answers the deny status (403) and the
    audit log has a 941xxx match for it.
  - `sse_attack_blocked`: `/sse?q=<script>alert(1)</script>` answers 403.
- [ ] **Step 2: Run it before the backend exists, expect FAIL** at setup; then write `stream_backend.py` and
  `ws_client.py`; run `tests/streaming_smoke.sh edge-proxy:test edge-proxy-gen:test`, expect all PASS.
- [ ] **Step 3: CI step** `Long-lived connections smoke test` → `tests/streaming_smoke.sh edge-proxy:ci edge-proxy-gen:ci`.
- [ ] **Step 4: Changelog** `### Added`; commit `test: long-lived connections through the WAF (WebSocket, SSE, long poll, streamed HTML)`.

### Task 3: HTTP/3 in the split-layout smoke test

**Files:**
- Create: `tests/fixtures/h3-client.Dockerfile`
- Modify: `tests/compose.smoke.yml` (service `h3`), `tests/split_smoke.sh` (new section, certificate for
  `h3.example.com`, build/remove the client image), `docs/configuration.md` (section "HTTP/3"),
  `examples/docker-compose.yml` (commented `- "443:443/udp"` with one line on HTTP/3), `CHANGELOG.md`

**Interfaces:**
- Produces: `h3-client.Dockerfile` — `FROM debian:trixie-slim@sha256:…` (pinned), installs `curl` and
  `ca-certificates` with `--no-install-recommends`; the script builds it as `${RUN}-h3client` and removes it in
  `cleanup`. The script asserts `curl -V` lists `HTTP3` before using it.
- Consumes: service `h3` = the whoami backend with `VIRTUAL_HOST: h3.example.com` and label
  `com.github.nginx-proxy.nginx-proxy.http3.enable: "true"`, on the `proxy` network.

- [ ] **Step 1: Write the assertions** (client container on the test network, `--resolve h3.example.com:443:<edge ip>`,
  `-k`):
  - `h3_get`: `curl --http3-only` GET `/` → `200`, `%{http_version}` = `3`.
  - `h3_alt_svc`: an HTTP/2 GET to `h3.example.com` has an `alt-svc` header naming `h3`.
  - `h3_url_attack_blocked`: `/?q=<script>alert(1)</script>` over HTTP/3 → 403, with a 941xxx audit entry.
  - `h3_header_attack_blocked`: header `User-Agent: () { :; }; echo; /bin/cat /etc/passwd` over HTTP/3 → 403
    (whatever CRS rule matches; the assertion is the 403 plus an audit entry for the request).
  - `h3_body_attack_blocked`: POST `q=<script>alert(1)</script>` (form) over HTTP/3 → 403.
  - `h3_streamed_body_attack_blocked`: the same body with `--data-binary @-` from stdin (no Content-Length) → 403.
  - `h3_legit_post`: POST `name=alice` over HTTP/3 → 200.
  - `h3_body_limit`: a non-file body over `MODSEC_REQ_BODY_NOFILES_LIMIT` (1 MiB + 1 byte, form type) → refused
    (403), as over HTTP/1.1.
- [ ] **Step 2: Run, expect FAIL** until the `h3` service and client exist; implement; run
  `tests/split_smoke.sh edge-proxy:test edge-proxy-gen:test`, expect all PASS.
- [ ] **Step 3: Docs**: `docs/configuration.md` "HTTP/3": turn it on per container with the label above or for every
  vhost with `ENABLE_HTTP3=true` on **gen**; publish `443:443/udp` on edge; the WAF inspects HTTP/3 requests like the
  others (tested). Example compose: the commented UDP port.
- [ ] **Step 4: Changelog** `### Added`; commit `test: HTTP/3 works and the WAF inspects it`.

### Task 4: Certificates end to end with Pebble (`tests/acme_e2e.sh`)

**Files:**
- Create: `tests/compose.acme.yml`, `tests/fixtures/pebble-config.json`, `tests/acme_e2e.sh`
- Modify: `examples/docker-compose.yml` (header: the "not exercised" sentence → it is exercised by
  `tests/acme_e2e.sh`), `README.md` ("What works today": certificates, long-lived connections and HTTP/3 are tested),
  `.github/workflows/build.yml` (step after the streaming test), `CHANGELOG.md`

**Interfaces:**
- Consumes: `examples/docker-compose.yml` unchanged in substance; the override (`compose.acme.yml`) changes only:
  `image:` of edge/gen to `${EDGE_IMAGE}`/`${GEN_IMAGE}`; every `container_name` to `${RUN}-<service>`; edge
  `ports: !reset []`; edge `labels: !override [${RUN}.nginx=true]`; gen `NGINX_CONTAINER_LABEL: ${RUN}.nginx` and
  `labels: !reset []`; acme-companion env `ACME_CA_URI: https://pebble:14000/dir`, `CA_BUNDLE` = the CA of Pebble's own API certificate
  (`test/certs/pebble.minica.pem` of the pinned Pebble version, from the image or committed as a fixture), `NGINX_PROXY_CONTAINER: ${RUN}-nginx-proxy`, `NGINX_DOCKER_GEN_CONTAINER: ${RUN}-nginx-proxy-gen`;
  edge gets the network alias `app.example.com` on `proxy`; new service `pebble`
  (`ghcr.io/letsencrypt/pebble@sha256:…`, `-config /test/my-config.json`, `PEBBLE_VA_NOSLEEP=1`,
  `PEBBLE_WFE_NONCEREJECT=0`) on `proxy` and on the network acme-companion uses.
- Produces: `pebble-config.json` — Pebble's default config with `"httpPort": 80` (HTTP-01 through edge).

- [ ] **Step 1: Write the test script**, then run it before the override exists, expect FAIL at setup.
  Assertions:
  - `acme_uses_own_edge`: acme-companion's log names `${RUN}-nginx-proxy` as the nginx container (shared hosts).
  - `certificate_issued`: within 120 s, `app.example.com.crt` exists in the certs volume.
  - `https_serves_issued_cert`: from a throwaway container on `proxy`, `openssl s_client -connect <edge>:443
    -servername app.example.com -verify_return_error -CAfile <Pebble root from https://pebble:15000/roots/0>` verifies,
    and the served serial equals the file's.
  - `http_redirects_to_https`: `http://app.example.com/` → 301.
  - `renewal_served_without_restart`: `docker exec ${RUN}-acme-companion /app/force_renew`; within 120 s the served
    serial differs from the first one and still verifies; edge's `State.StartedAt` is unchanged.
- [ ] **Step 2: Implement** the override and the Pebble config; run
  `tests/acme_e2e.sh edge-proxy:test edge-proxy-gen:test`, expect all PASS. If the example cannot be reused through an
  override, stop and report why (the spec then wants a test compose file mirroring it, with the reason written in it).
- [ ] **Step 3: CI step** `Certificates end to end (Pebble)` → `tests/acme_e2e.sh edge-proxy:ci edge-proxy-gen:ci`.
- [ ] **Step 4: Docs + changelog** (example header, README, `### Added`); commit
  `test: certificates issued and renewed through edge (acme-companion + Pebble)`.

## As built

Where the build departed from this plan, and why, so nobody retries what did not work:

- **Task 1: an entrypoint patch, not an `.envsh` script.** The official `/docker-entrypoint.sh` sources `.envsh` files
  inside a `find | sort -V | while read` loop, which runs in a subshell, so an `exec 2>>…` there never reaches the
  final `exec nginx`. The image instead inserts one guarded line before the entrypoint's single `exec "$@"`
  (`edge/Dockerfile`); the build fails unless that line occurs exactly once and the patched file is valid shell.
  `95-kickedro-error-log.envsh` does not exist.
- **Task 2: `python:3.13-slim`, pinned by digest.** The unit tests run with the runner's own Python, so there was no
  Python image to reuse. The streaming backend and the WebSocket client run in `python:3.13-slim`, pinned like the
  other helper images.
- **Task 3: the streamed body is sent with `-T -`.** `--data-binary @-` reads stdin to the end and sends a
  `Content-Length`, so it cannot test a body without one. The test sends the body with
  `-X POST -H 'Content-Type: application/x-www-form-urlencoded' -T -` and asserts that the audit entry has no
  `Content-Length` header.
- **Task 3: rule 10002.** With the WAF on, every HTTP/3 request was refused: the ModSecurity-nginx connector hands
  ModSecurity no Host header for HTTP/3 (its issue 305), so CRS rule 920280 matched. The maintainers decided to skip
  920280 for HTTP/3 requests only, with no setting, until the connector ships the fix (its pull request 364):
  `edge/modsecurity/01-http3-host.conf`, documented in `docs/configuration.md`, "HTTP/3".
