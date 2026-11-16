# Configuration guide

This guide covers everything beyond the settings themselves. For the environment variables of the `edge` image,
their defaults and what you lose by weakening them, see the **[settings table](settings.md)**. Quick facts:

- Every setting is one environment variable with a secure default. An empty variable counts as unset.
- At start the container checks every value. A value that is not allowed **stops the container**, with a message
  naming the variable and the allowed values.
- A value that is weaker than the default prints one line starting with `SECURITY:` saying what protection is lost,
  and linking to the settings table. Check `docker logs` after changing a setting.

Contents: [Mount points](#mount-points-for-your-own-rules-and-config) ·
[ACME exemption](#the-acme-challenge-exemption) · [Expect: 100-continue](#expect-100-continue-is-blocked) ·
[Audit log](#audit-log) · [Block page](#block-page) · [Headers](#security-headers-and-hidden-backend-headers) ·
[Migrating](#migrating-from-an-existing-nginx-proxy-setup) · [Read-only filesystem](#read-only-root-filesystem) ·
[The gen image](#the-gen-image)

## Mount points for your own rules and config

| Path in the `edge` container | Purpose |
|---|---|
| `/etc/nginx/modsec/custom.d/` | Your ModSecurity files (`*.conf`), loaded **before** the Core Rule Set. For exclusions that must be in place before a rule runs, and for your own rules. |
| `/etc/nginx/modsec/after.d/` | Your ModSecurity files (`*.conf`), loaded **after** the Core Rule Set. For things that must come after the rules exist, such as `SecRuleRemoveById` or response exclusions. |
| `/etc/nginx/kickedro/block-page.html` | Your own [block page](#block-page). |
| `/etc/nginx/templates/` | Your nginx templates, rendered at start by the official nginx image mechanism (`*.template`, `NGINX_ENVSUBST_*`), unchanged. In the split layout `/etc/nginx/conf.d` belongs to `gen` and is read-only on `edge`, so there is nowhere for these to be written unless you set `NGINX_ENVSUBST_OUTPUT_DIR`. Per-site nginx settings normally go in nginx-proxy's `vhost.d` files instead. |

Both ModSecurity directories may be empty or not mounted at all. The image's own settings are rendered at start from
its own templates (kept apart from `/etc/nginx/templates`) and loaded in this order: ModSecurity's fixed settings, the
CRS setup, the settings from the environment variables, the [ACME exemption](#the-acme-challenge-exemption),
`custom.d`, the CRS rules, the status setting that needs the rules, `after.d`.

Use rule IDs from 10100 to 99999 for your own rules (10001 is the image's ACME exemption; the CRS uses 900000 and up).
The files must be readable by the `nginx` user. A ModSecurity syntax error in a file stops nginx from starting, and
makes a reload fail while the old configuration keeps serving.

### Example: an exclusion for one site

A false positive should be fixed with the narrowest exclusion that works. This file, mounted in `custom.d`, stops
the XSS rules from looking at the `comment` form field, for `app.example.com` only:

```
# custom.d/app-example-com.conf
SecRule REQUEST_HEADERS:Host "@streq app.example.com" \
    "id:10200,\
    phase:1,\
    pass,\
    nolog,\
    ctl:ruleRemoveTargetByTag=attack-xss;ARGS:comment"
```

The audit log entry of the blocked request tells you which rule matched (its ID and tags) and on which variable.
[`examples/custom.d/README.md`](../examples/custom.d/README.md) explains how to find the right exclusion.

Detection-only mode is the safe way to find false positives on a new site: set `MODSEC_RULE_ENGINE=DetectionOnly`,
read the audit log for a while, add exclusions, then switch back to `On`.

## The ACME challenge exemption

Requests that look exactly like a Let's Encrypt (RFC 8555) HTTP-01 validation are **not inspected and not logged**
by ModSecurity, so certificate issuance cannot be blocked by a rule. This is rule ID 10001, and it applies only when
**all** of these are true:

- the protocol is HTTP/1.0 or HTTP/1.1 (validation is plain HTTP/1.x on port 80);
- the method is GET or HEAD;
- the raw request target is exactly `/.well-known/acme-challenge/<token>`, with a token of letters, digits, `-` and
  `_`: no query string, no percent-encoding, no further slashes, no dot-segments;
- the request has no `Cookie`, `Content-Length` or `Transfer-Encoding` header.

Anything else sent to that path is inspected like every other request. The shape is this strict because a site that
routes unknown paths to an application would otherwise let a prefix match carry an uninspected attack.

To remove the exemption (for example when you use DNS validation only), mount a file in `custom.d` with:

```
SecRuleRemoveById 10001
```

## `Expect: 100-continue` is blocked

The Core Rule Set 4 blocks requests with an `Expect` header (rule 920450, an anti-request-smuggling measure). Browsers
never send it. `curl` and some API clients add `Expect: 100-continue` to larger uploads,
and those requests then get the deny status. Prefer fixing the client (`curl -H 'Expect:'` switches it off).

If you cannot, this file in `custom.d` allows `Expect` and keeps every other restricted header blocked. It is the
CRS's own default list without `/expect/`:

```
SecAction "id:10100,phase:1,pass,nolog,setvar:'tx.restricted_headers_basic=/content-encoding/ /proxy/ /lock-token/ /content-range/ /if/ /x-http-method-override/ /x-http-method/ /x-method-override/ /x-middleware-subrequest/'"
```

The risk: the `Expect` header is one of the ingredients of request desync attacks between a proxy and a backend that
handles it badly, and the list is now frozen as of CRS 4.30: check the CRS changelog when you update, and copy a changed
default list. (Removing rule 920450 with `SecRuleRemoveById` in `after.d` also works, but switches off the whole
restricted-headers check.)

## Audit log

ModSecurity's audit log records blocked requests and other relevant transactions, one JSON object per transaction
(`MODSEC_AUDIT_FORMAT`).

- **Default: stdout**, so it is in `docker logs` next to nginx's own logs, with no file permissions or rotation to
  set up. Set `MODSEC_AUDIT_LOG` to a path to write a file instead, or to `off` ([weaker](settings.md#modsec_audit_log)).
- **Treat it as sensitive.** Entries contain the request headers, including `Cookie` and `Authorization`, and parts of
  the body that matched a rule. Do not forward it to a place that more people can read than can read your secrets.
- **Rotation.** Docker's default `json-file` log driver does not rotate unless you set `max-size` (and `max-file`)
  in the container's `logging.options`, or use another driver. Without it, logs grow until the disk is full.
- **Reliable parsing.** Large audit entries written to stdout can be interleaved with access-log lines when the load
  is high. If you feed the log to a parser, write it to a file on a mounted, rotated volume instead
  (`MODSEC_AUDIT_LOG=/var/log/modsec/audit.json`), and rotate that file yourself. Mount the directory writable.
- **Finding an entry.** The reference on the [block page](#block-page) is the `unique_id` of the audit entry, and the
  `$request_id` of nginx.

## Block page

A request ModSecurity blocks gets a short page with a reference (the request ID) instead of nginx's plain error
page, so a user can quote it and you can find the audit entry. The page shows no rule details. Switch it off with
`EDGE_BLOCK_PAGE=off`.

- **Which responses get it.** Only bodies nginx itself produces with the deny status (`MODSEC_DENY_STATUS`, default
  403): ModSecurity blocks, but also nginx's own `deny` rules, `auth_request` 403s and `return 403` in snippets.
  **Never** a response from a backend, and never one served from a cache, even if it has the same status.
- **Your own page.** Mount an HTML file at `/etc/nginx/kickedro/block-page.html` (at most 32 KiB). Every
  `{{request_id}}` in it is replaced by the reference. Use no scripts or external resources if you want the page to
  work under strict content-security policies.
- **Per vhost.** A vhost snippet that sets its own `sub_filter` turns the block page off for that vhost (nginx's
  plain page is sent).
- **Padding.** With the page on, `msie_padding` is off for the whole server, so other short nginx error pages lose
  the padding comments that some old browsers want. Modern browsers do not need them.
- **Status 444** closes the connection without a response, so there is no page.

## Security headers and hidden backend headers

- `EDGE_SECURITY_HEADERS=on` adds `X-Content-Type-Options`, `Referrer-Policy` and `X-Frame-Options` to every
  response, error pages included, **unless the response already has that header** (from the backend or the vhost).
  A backend's own `X-Frame-Options: DENY` is never overridden.
- They survive a vhost's own `add_header` (for example HSTS from nginx-proxy) because the image sets
  `add_header_inherit merge`. **Do not set `add_header_inherit off` or `on` in a snippet** unless you want to drop the
  inherited headers at that place.
- `EDGE_HIDE_UPSTREAM_HEADERS=on` removes `X-Powered-By`, `Server`, `X-AspNet-Version` and `X-AspNetMvc-Version` from
  backend responses. A vhost snippet that sets its own `proxy_hide_header` or `proxy_pass_header` (or the FastCGI,
  uWSGI or gRPC variants) **replaces** this list at that place: nginx does not merge the two lists.

## Migrating from an existing nginx-proxy setup

Replace the images and keep your `VIRTUAL_HOST` backends. Two things differ.

1. **Duplicate directives.** If you have a proxy-wide file in `conf.d` (such as `my_proxy.conf`) that sets
   `server_tokens`, `client_header_timeout`, `client_body_timeout`, `send_timeout`, `keepalive_timeout`,
   `large_client_header_buffers` or `msie_padding`, nginx stops with `"directive is duplicate"`, because the image
   already sets them. Remove those lines and use the `EDGE_*` variables from the [settings table](settings.md)
   (`EDGE_SERVER_TOKENS`, `EDGE_CLIENT_HEADER_TIMEOUT`, and so on). `msie_padding` is set by the image only while `EDGE_BLOCK_PAGE` is `on`; with `off` the image does not set
   it. This may be relaxed in a later version.
2. **Stricter defaults.** Timeouts are 10 s, keep-alive is 15 s (the stock `nginx.conf` has 65 s), request
   bodies over 128 MiB are refused, and the WAF blocks attacks. Look for `SECURITY:` lines and 403s in the logs
   after the move; start with `MODSEC_RULE_ENGINE=DetectionOnly` on a busy site if you want to see the false
   positives before blocking.

Your other `conf.d` files, `vhost.d` and `vhost.d/<host>_location` snippets, `htpasswd`, certificates and per-container
variables work as before, because the template is nginx-proxy's own.

## Read-only root filesystem

The `edge` container runs with a read-only root filesystem if you give it these writable places:

| Path | Why |
|---|---|
| `/etc/nginx/modsec/rendered` (tmpfs) | The settings, block page and hardening config written at start. |
| `/var/cache/nginx` and `/run` (tmpfs) | Stock nginx paths. |
| `/var/cache/modsecurity/tmp` and `/var/cache/modsecurity/data` (tmpfs, `uid=101,gid=101`) | ModSecurity's temporary files and data, written by the `nginx` user. |
| `/etc/nginx/conf.d`, if it is not a volume | Only if you rely on the official `20-envsubst` and `10-listen-on-ipv6` scripts. |
| The directory of `MODSEC_AUDIT_LOG`, if you set a file | The audit log. |

In compose: `read_only: true` and, under `tmpfs`, `/etc/nginx/modsec/rendered`, `/var/cache/nginx`, `/run`,
`/var/cache/modsecurity/tmp:uid=101,gid=101` and `/var/cache/modsecurity/data:uid=101,gid=101`. The container was
checked to start in this configuration; the automated smoke tests do not run it read-only.

## The gen image

`gen` is docker-gen with nginx-proxy's own template and entrypoint at a pinned commit (the `NGINX_PROXY_VERSION`
variable holds it; it is printed at start). Use it like nginx-proxy's `dockergen` image. Settings of the template
(`HTTP_PORT`, `HTTPS_PORT`, `TRUST_DOWNSTREAM_PROXY` and so on) are set **on the gen container**; see
[nginx-proxy's documentation](https://github.com/nginx-proxy/nginx-proxy#readme) for the per-backend variables.

- **`NGINX_CONTAINER_LABEL`**: the label that marks the `edge` container (default
  `com.github.nginx-proxy.nginx-proxy.nginx`, as in nginx-proxy's separate-containers layout). `gen` takes the
  networks of the labelled container as the ones to proxy to, and signals it to reload when the configuration
  changes. Put the label on the `edge` container and set the variable to the same name. On a Docker host with other
  nginx-proxy setups, use a label of your own, or `gen` may pick the wrong container.
- **`RESOLVERS`**: with `network_mode: none` (recommended, `gen` needs no network) the container's `resolv.conf`
  holds the **host's** resolvers, not Docker's `127.0.0.11`, and those would end up in nginx's `resolver`. Set
  `RESOLVERS` explicitly, for example `127.0.0.11`.
- **`DHPARAM_SKIP`** defaults to `true`, as in nginx-proxy's image, so it works without a shared dhparam volume. Set it
  to `false` to copy a pre-generated RFC 7919 group (`DHPARAM_BITS` 2048, 3072 or 4096 (default)) to
  `/etc/nginx/dhparam/dhparam.pem`; that directory must then be a volume shared with `edge` (writable in `gen`,
  read-only in `edge`).
- **`TRUST_DOWNSTREAM_PROXY`**: nginx-proxy's default is `true` (trust `X-Forwarded-*` from a proxy in front). If
  nothing is in front, set it to `false` explicitly: it also silences a start-up warning.
- **The Docker socket** is expected at `/tmp/docker.sock` inside `gen` (`DOCKER_HOST=unix:///tmp/docker.sock`).
  Mount your host's socket there, read-only: `/var/run/docker.sock` for rootful Docker; rootless Docker and Docker
  Desktop use another path (for example `$XDG_RUNTIME_DIR/docker.sock`). Only `gen` and acme-companion get the
  socket; `edge` never does.
- **acme-companion** works as with nginx-proxy's separate-containers layout: it finds `edge` by the label
  `com.github.nginx-proxy.nginx` and `gen` by `com.github.nginx-proxy.docker-gen` (or the `NGINX_PROXY_CONTAINER` and
  `NGINX_DOCKER_GEN_CONTAINER` variables), writes certificates to the shared `certs` volume and challenge files to the
  shared `html` volume, and signals `gen`. The `gen` image sets the `DOCKER_GEN_VERSION` variable acme-companion looks
  for. This combination is **not exercised by the smoke tests**; [`examples/docker-compose.yml`](../examples/docker-compose.yml)
  follows acme-companion's documentation for the layout. Its HTTP-01 requests fit the
  [ACME exemption](#the-acme-challenge-exemption).
