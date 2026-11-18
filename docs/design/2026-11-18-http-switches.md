# Hard off switches for HTTP/2 and HTTP/3 (short design)

Status: proposed 2026-11-18, for the owner's approval. Ships in 0.1.2, together with the nginx security release that
the pipeline picks up by itself.

## Intent

An operator must be able to turn HTTP/2 and HTTP/3 off for the whole front door in one place, for example while a
protocol-level nginx vulnerability is open, and be sure that nothing turns them back on. Today `gen`'s template takes
`ENABLE_HTTP2` / `ENABLE_HTTP3` only as defaults: a backend container's label can turn either back on for its site,
and the catch-all server (the one that answers unknown names and connections without SNI) always enables HTTP/2,
whatever `ENABLE_HTTP2` says. So "off" today is not off.

## Goals

- `EDGE_HTTP2=off` on `gen`: no `server` block in the generated configuration enables HTTP/2: no site, whatever its
  labels say, and not the catch-all server.
- `EDGE_HTTP3=off` on `gen`: no `server` block enables HTTP/3: no `http3 on`, no `quic` listener, no `alt-svc` header
  (so clients are not told to try it), whatever the labels say.
- `on` (the default) keeps today's behaviour exactly: the template's own settings and labels decide.
- Any other value stops `gen` at start with an error that names the variable and the allowed values, so a typo
  never leaves a protocol on by accident.

## Non-goals

- Not a rewrite of the template (a separate, larger plan).
- No change to `edge`: in nginx a server's own `http2 on` overrides any http-level setting, so `edge` cannot enforce
  this on its own; the generated configuration is the place.
- No per-site on/off beyond what the template's labels already offer.

## Approaches considered

1. **Patch the template at build time (chosen).** Three places of the pinned template change: the per-site HTTP/2
   and HTTP/3 decisions are combined ("and") with the switch, and the catch-all server's unconditional `http2 on` is
   wrapped in it. The catch-all server's HTTP/3 already follows the sites' decisions. The build checks that every
   replaced line occurs exactly once before and is gone after, and fails otherwise, the same safeguard as `edge`'s
   entrypoint patch; a template update that moves these lines therefore stops the build instead of silently
   dropping the switch. The generated configuration stays plain nginx.
2. **Filter gen's output.** A step after rendering strips every HTTP/2 / HTTP/3 line and swaps the file in whole. It
   would also make the write atomic, but it changes `gen`'s command and notification order and filters nginx
   configuration by pattern: more moving parts for this release. Kept for the separate decision on atomic writes.
3. **Do it in `edge`.** Not possible (see non-goals).

## Design

- `gen` image: build-time patch of the template as in approach 1, with the checks; a small start-up check validates
  `EDGE_HTTP2` and `EDGE_HTTP3` (`on` or `off`, default `on`) before the template's own entrypoint runs.
- Tests (`tests/split_smoke.sh`): with both switches `off`, and backends whose labels ask for HTTP/2 and HTTP/3, the
  generated configuration has no `http2 on`, no `http3 on`, no `quic` listener and no `alt-svc` header; a client
  that offers h2 gets HTTP/1.1 on a named site and no h2 on a connection without SNI; the HTTP/3 client fails. With
  the defaults, the existing HTTP/2 and HTTP/3 tests keep passing. An invalid value stops `gen` with its error.
- Docs: `docs/configuration.md` (the gen image's settings), `docs/settings.md` if it lists gen settings, and
  `CHANGELOG.md`.

## Left to the builder

The exact template expressions and the shape of the start-up check, within the above.
