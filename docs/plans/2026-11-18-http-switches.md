# Hard off switches for HTTP/2 and HTTP/3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `EDGE_HTTP2=off` / `EDGE_HTTP3=off` on `gen` turn HTTP/2 / HTTP/3 off for every server block it generates,
whatever labels or the template's own defaults say; `on` (default) changes nothing; anything else stops `gen`.

**Architecture:** A build-time patch of the pinned template in `gen`'s build stage (three places, each checked to
occur exactly once), and a small entrypoint in front of the template's own entrypoint that validates the two
settings. Tested in `tests/split_smoke.sh` against the running layout.

**Tech Stack:** POSIX sh, awk, Go text/template (docker-gen), Docker, bash test scripts.

**Spec:** `docs/design/2026-11-18-http-switches.md`

## Global Constraints

- Settings: `EDGE_HTTP2` and `EDGE_HTTP3`, set on the `gen` container; allowed `on` and `off`; unset or empty = `on`.
- `off` for HTTP/2: no `http2 on` anywhere in the generated configuration (sites and the catch-all server).
- `off` for HTTP/3: no `http3 on`, no `quic` listener, no `alt-svc` header anywhere.
- `on`: the generated configuration is byte-for-byte what the unpatched template generates.
- An invalid value stops `gen` before docker-gen runs, with `ERROR: <VAR>='<value>' is not allowed. Allowed: on off.`
  on stderr and a non-zero exit (the wording of `edge`'s own settings check).
- The build fails if any patched template line is not found exactly once before patching, or is still present after.
- Public repository: no host, site, customer or person names in any file or commit message.
- Docker for every build and test; commit trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` only.

## Review Focus

- **`on` must not change output.** A whitespace slip in the wrapped `http2 on` line changes every generated
  configuration; Task 1 checks the patched template's output with `EDGE_HTTP2`/`EDGE_HTTP3` unset is unchanged for the
  live layout (existing tests keep passing, and the catch-all server still has `http2 on`).
- **Labels re-enabling a protocol.** A backend label `...http2.enable=true` / `...http3.enable=true` must not win over
  `off`; Task 1's backend carries both labels.
- **Connections without SNI.** The catch-all server is the one that ignored `ENABLE_HTTP2`; Task 1 gives it a default
  certificate so the no-SNI check really negotiates (and would see h2 if it were on).
- **Mixed case or stray spaces** (`Off`, ` off`): invalid, refused at start (Task 1 tests `Off`).
- **Template moved upstream.** A pinned-ref bump that changes the patched lines must stop the build (Task 1's checks).

---

### Task 1: The switches in the gen image, with their tests

**Files:**
- Create: `gen/patch-template.sh` (applies the three changes to a template file given as `$1`, with the checks)
- Create: `gen/kickedro-entrypoint.sh` (validates the settings, then `exec /app/docker-entrypoint.sh "$@"`)
- Modify: `gen/Dockerfile` (run the patch in the build stage after the checkout; copy the entrypoint; `ENTRYPOINT`)
- Modify: `tests/compose.smoke.yml` (gen: `EDGE_HTTP2: ${EDGE_HTTP2:-}`, `EDGE_HTTP3: ${EDGE_HTTP3:-}`; service `h3`:
  add the label `com.github.nginx-proxy.nginx-proxy.http2.enable: "true"` next to its HTTP/3 label)
- Modify: `tests/split_smoke.sh` (section 0's expected entrypoint; new section 5)

**Interfaces:**
- Produces: `gen/patch-template.sh <template-file>`: edits in place, exit 0 on success; on any failed check prints
  `patch-template: <what>` to stderr and exits 1. `ENTRYPOINT ["/app/kickedro-entrypoint.sh"]`, `CMD` unchanged.
- Template config keys added: `edge_http2`, `edge_http3` (booleans, `true` = allowed).

The three template changes (exact text; the old lines are the template's at the pinned `NGINX_PROXY_REF`):

1. After the line
   `{{- $_ := set $config "enable_http3" ($globals.Env.ENABLE_HTTP3 | default "false") }}` insert
   ```
   {{- $_ := set $config "edge_http2" (ne ($globals.Env.EDGE_HTTP2 | default "on") "off") }}
   {{- $_ := set $config "edge_http3" (ne ($globals.Env.EDGE_HTTP3 | default "on") "off") }}
   ```
2. Replace the per-site decisions (both lines start with four spaces):
   ```
       {{- $http2_enabled := groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http2.enable" | keys | first | default $globals.config.enable_http2 | parseBool }}
       {{- $http3_enabled := groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http3.enable" | keys | first | default $globals.config.enable_http3 | parseBool }}
   ```
   with
   ```
       {{- $http2_enabled := and $globals.config.edge_http2 (groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http2.enable" | keys | first | default $globals.config.enable_http2 | parseBool) }}
       {{- $http3_enabled := and $globals.config.edge_http3 (groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http3.enable" | keys | first | default $globals.config.enable_http3 | parseBool) }}
   ```
   (The catch-all server's HTTP/3, `quic` and per-site `alt-svc` all follow `$vhost.http3_enabled`.)
3. The catch-all server's unconditional `    http2 on;`: the first `    http2 on;` line after the line that contains
   `server_name _; # This is just an invalid value` becomes the three lines
   ```
       {{- if $globals.config.edge_http2 }}
       http2 on;
       {{- end }}
   ```
   Checks: exactly one `server_name _; # This is just an invalid value` line, the template has exactly three
   `    http2 on;` lines before and the wrapped one is the one after that `server_name` line (the other two are inside
   `{{- if $vhost.http2_enabled }}`).

- [ ] **Step 1: Write the failing tests in `tests/split_smoke.sh`**

  Section 0: the expected entrypoint becomes `["/app/kickedro-entrypoint.sh"]` (CMD unchanged); update the comment.

  New section `# ---- 5. hard off switches (EDGE_HTTP2, EDGE_HTTP3)` before `echo "ALL PASS"`:
  - `settings_refused`: `docker run --rm --network none -e EDGE_HTTP2=Off "$GEN"` exits non-zero and its output
    contains `EDGE_HTTP2='Off' is not allowed`; same for `EDGE_HTTP3=maybe`.
  - Put a self-signed `default.crt`/`default.key` (CN `default`) into the `nginx_certs` volume with `volume_run`, as
    section 1 does for the sites; recreate gen with the defaults (`compose up -d --force-recreate nginx-proxy-gen`);
    `wait_until 30` the edge's configuration has `ssl_certificate /etc/nginx/certs/default.crt`.
  - `catchall_h2_on_by_default`: `curl -s -k --http2 -o /dev/null -w '%{http_code} %{http_version}'` to
    `https://127.0.0.1:$HTTPS_HOST_PORT/` (an IP literal: curl sends no SNI) gives `503 2`.
  - Recreate gen with `EDGE_HTTP2=off EDGE_HTTP3=off`; `wait_until 30` the configuration lacks `http2 on`.
  - `switch_off_config`: the edge's `default.conf` lacks each of `http2 on`, `http3 on`, `quic`, `alt-svc`.
  - `switch_off_named_site`: `--http2` to `https://app.example.com:$HTTPS_HOST_PORT/` gives `200 1.1`, and to
    `h3.example.com` (labels ask for both) gives `200 1.1` with no `Alt-Svc` header (`https_request` + `header`).
  - `switch_off_no_sni`: the IP-literal request gives `503 1.1`.
  - `switch_off_h3`: `h3_status --max-time 5 https://h3.example.com/` is not `200`.

- [ ] **Step 2: Build gen from the unchanged Dockerfile and run the test to see section 0 and 5 fail**

  Build as `CONTRIBUTING.md` shows (`scripts/resolve_versions.py`, then `docker buildx build` of `edge` and `gen`),
  run `tests/split_smoke.sh edge-proxy:dev edge-proxy-gen:dev`.
  Expected: `FAIL default_command` (old entrypoint). (If the local environment refuses the layout's Docker socket
  mount, note it in the report; the PR's CI run of the same script is then the verification.)

- [ ] **Step 3: Implement `gen/patch-template.sh`, `gen/kickedro-entrypoint.sh` and the Dockerfile changes**

  Patch: POSIX sh + awk, writing to a temporary file and moving it over the template only after all checks pass.
  Dockerfile: `COPY patch-template.sh` into the build stage and run it on `/nginx-proxy/nginx.tmpl` right after the
  checkout `RUN`; in the final stage `COPY --chmod=755 kickedro-entrypoint.sh /app/` and
  `ENTRYPOINT ["/app/kickedro-entrypoint.sh"]`; update the image's header comment and the comment above `CMD`.
  Entrypoint: for each of `EDGE_HTTP2`, `EDGE_HTTP3`: empty or unset → `on`; `on`/`off` accepted; otherwise the error
  line from Global Constraints; after both are checked, if any was invalid print
  `ERROR: invalid settings, not starting.` and exit 1; else `exec /app/docker-entrypoint.sh "$@"`.

- [ ] **Step 4: Rebuild gen and run the tests**

  Run: `tests/split_smoke.sh edge-proxy:dev edge-proxy-gen:dev` (and `tests/acme_e2e.sh` and
  `tests/streaming_smoke.sh`, which also run gen).
  Expected: `ALL PASS` from each; section 5's checks all `PASS`.

- [ ] **Step 5: Commit**

  ```bash
  git add gen/patch-template.sh gen/kickedro-entrypoint.sh gen/Dockerfile tests/compose.smoke.yml tests/split_smoke.sh
  git commit -m "gen: EDGE_HTTP2 and EDGE_HTTP3 hard off switches (sites, labels and the catch-all server)"
  ```

### Task 2: Documentation

**Files:**
- Modify: `docs/configuration.md` (the gen image's settings list: `EDGE_HTTP2`, `EDGE_HTTP3`; the HTTP/3 section: one
  sentence that `EDGE_HTTP3=off` overrides the label and `ENABLE_HTTP3`)
- Modify: `CHANGELOG.md` (`[Unreleased]` → `### Added`)
- Modify: `README.md` only if it lists gen's settings (then one line)

**Interfaces:**
- Consumes: the names, values and behaviour from Task 1 and Global Constraints.

- [ ] **Step 1: Write the docs**

  Each switch: what `off` removes (as in Global Constraints), that it wins over labels, `ENABLE_HTTP2`/`ENABLE_HTTP3`
  and the catch-all server, that `on` is the default and changes nothing, that other values stop gen, and when to
  use it (a protocol-level vulnerability, or a site policy). Note that `ENABLE_HTTP2=false` alone leaves HTTP/2 on in
  the catch-all server.

- [ ] **Step 2: Check the docs build nothing broken**

  Run: `grep -n 'EDGE_HTTP2\|EDGE_HTTP3' docs/configuration.md CHANGELOG.md` shows the new entries; the internal-names
  grep from `CONTRIBUTING.md` (or the project's pre-push list) finds nothing in the branch's diff.

- [ ] **Step 3: Commit**

  ```bash
  git add docs/configuration.md CHANGELOG.md README.md
  git commit -m "docs: EDGE_HTTP2 and EDGE_HTTP3"
  ```

## As built

Where the build departed from this plan, and why:

- **Task 1: the switches are kept in `$globals`, not in `$config`.** The template's debug endpoint
  (`DEBUG_ENDPOINT=true`) prints `$globals.config` as JSON, so keys added to `$config` changed its output with the
  switches on. The two keys are `$globals.edge_http2` and `$globals.edge_http3`, set right after the template's
  `{{- $_ := set $globals "config" $config }}` (instead of after the `enable_http3` line); the per-site decisions and
  the catch-all server's wrap use them (`and $globals.edge_http2 (...)`, `{{- if $globals.edge_http2 }}`).
- **Task 1: the expression fails closed.** `(eq ($globals.Env.EDGE_HTTP2 | default "on") "on")`, not
  `(ne ... "off")`: a value that never passed the entrypoint's check (`docker exec ... docker-gen`) leaves the protocol
  off, not on.
- **Task 1: the checks count trimmed lines.** Every line the patch relies on, the `http2 on;` lines included, is
  counted on its text without leading and trailing spaces, so a copy with other indentation counts too; the lines it
  changes must still match exactly.
- **Task 1: the patch runs last in the build stage**, after the docker-gen build, not right after the checkout, so a
  change to the patch does not rebuild docker-gen.
- **Task 1: a test the plan did not have, `switch_on_unchanged`.** It downloads `nginx.tmpl` at the pinned commit from
  `raw.githubusercontent.com` and requires that gen's template, with both switches unset
  (`env -u EDGE_HTTP2 -u EDGE_HTTP3`), renders exactly what upstream's renders for the same containers, once as is and
  once with `DEBUG_ENDPOINT=true`. `settings_refused` requires the two `ERROR:` lines to be the whole output, so
  nginx-proxy's entrypoint never ran. Section 0's variable is `EXPECTED_CMD` (it was `UPSTREAM_CMD`): the entrypoint
  is no longer upstream's.
- **Task 2: more files.** `docs/maintenance.md` (moving the nginx-proxy pin), `CONTRIBUTING.md` (the template is now
  patched; the test's download) and two sentences of `README.md` that said the template is unchanged.
