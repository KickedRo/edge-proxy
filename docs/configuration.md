# Configuration guide

This guide covers everything beyond the settings themselves. For the environment variables of the `edge` image,
their defaults and what you lose by weakening them, see the **[settings table](settings.md)**. Quick facts:

- Every setting is one environment variable with a secure default. An empty variable counts as unset.
- At start the container checks every value. A value that is not allowed **stops the container**, with a message
  naming the variable and the allowed values.
- A value that is weaker than the default prints one line starting with `SECURITY:` saying what protection is lost,
  and linking to the settings table. Check `docker logs` after changing a setting.

Contents: [Mount points](#mount-points-for-your-own-rules-and-config) ·
[ACME exemption](#the-acme-challenge-exemption) · [First-use false positives](#first-use-false-positives) ·
[Expect: 100-continue](#expect-100-continue-is-blocked) · [Audit log](#audit-log) · [Block page](#block-page) ·
[Headers](#security-headers-and-hidden-backend-headers) · [Proxy-wide files](#proxy-wide-files-in-confd) ·
[A replaced nginx.conf](#a-replaced-nginxconf) · [Migrating](#migrating-from-an-existing-nginx-proxy-setup) ·
[Read-only filesystem](#read-only-root-filesystem) · [The gen image](#the-gen-image)

## Mount points for your own rules and config

| Path in the `edge` container | Purpose |
|---|---|
| `/etc/nginx/modsec/custom.d/` | Your ModSecurity files (`*.conf`), loaded **before** the Core Rule Set. For exclusions that must be in place before a rule runs, and for your own rules. |
| `/etc/nginx/modsec/after.d/` | Your ModSecurity files (`*.conf`), loaded **after** the Core Rule Set. For things that must come after the rules exist, such as `SecRuleRemoveById` or response exclusions. |
| `/etc/nginx/modsec/plugins/` | [CRS plugins](#crs-plugins): the files of a plugin's `plugins/` directory, loaded in the CRS's order. |
| `/etc/nginx/kickedro/block-page.html` | Your own [block page](#block-page). |
| `/etc/nginx/templates/` | The official nginx image's template mechanism (`*.template` files, rendered at start) is still in the image, but **in the split layout it does nothing useful**: `nginx.conf` includes only `conf.d/*.conf` at http level and `toplevel.conf.d/*.conf` at main level, and `conf.d` belongs to `gen` and is read-only on `edge`. For your own nginx settings use nginx-proxy's `vhost.d` snippets, or a file in the `conf.d` volume that `gen` mounts writable. |

The three ModSecurity directories may be empty or not mounted at all. The image's own settings are rendered at start
from its own templates (kept apart from `/etc/nginx/templates`) and loaded in this order: ModSecurity's fixed
settings, the CRS setup, the settings from the environment variables, the [ACME exemption](#the-acme-challenge-exemption),
the plugins' `*-config.conf` and `*-before.conf`, `custom.d`, the CRS rules, the plugins' `*-after.conf`, the status
setting that needs the rules, `after.d`.

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

## First-use false positives

With the WAF on (`MODSEC_RULE_ENGINE=On`, the default), the OWASP CRS's default policy and ModSecurity's body limits
refuse some legitimate requests out of the box. These are the usual ones; each has a setting or a small file. They get
the deny status and the [block page](#block-page), whose reference finds the audit entry, which names the rule.

| Refused | Rule | Typical clients | What to do |
|---|---|---|---|
| Methods other than `GET`, `HEAD`, `POST` and `OPTIONS` | 911100 | REST APIs and single-page applications (`PUT`, `PATCH`, `DELETE`); WebDAV, CalDAV and Nextcloud (`PROPFIND`, `MKCOL`, ...) | [`MODSEC_ALLOWED_METHODS`](settings.md#modsec_allowed_methods), or for one site the snippet below |
| Request bodies of other types than forms, multipart, XML and JSON | 920420 | `application/octet-stream` uploads (WebDAV, file sync, container registries) | [`MODSEC_ALLOWED_REQUEST_CONTENT_TYPE`](settings.md#modsec_allowed_request_content_type) |
| Method-override headers (`X-HTTP-Method-Override` and two others) | 920450 | WordPress's block editor: it sends updates and deletes as `POST` with `X-HTTP-Method-Override` | the snippet below |
| `Expect: 100-continue` | 920450 | `curl` and some API clients | see [below](#expect-100-continue-is-blocked) |
| Form, JSON or XML bodies over 128 KiB (file uploads not counted) | 200002 | editors that save a whole page at once, webhooks with large payloads | [`MODSEC_REQ_BODY_NOFILES_LIMIT`](settings.md#modsec_req_body_nofiles_limit) |
| 1000 arguments or more (query string and form fields together) | 200007 | WordPress menus with many items, shop products with many variations | [`MODSEC_ARGUMENTS_LIMIT`](settings.md#modsec_arguments_limit) |

**A first week in detection-only mode.** On a new site, start with `MODSEC_RULE_ENGINE=DetectionOnly`: nothing is
refused, and the audit log records what would have been. Look for the rule IDs above (and any other), set what your
applications need, add narrow exclusions, then switch back to `On`.

**The settings** apply to every site behind the `edge`. Each replaces the CRS's list, so give the whole list, and each
prints a `SECURITY:` line at start, because it allows more than the default:

```yaml
    environment:
      MODSEC_ALLOWED_METHODS: "GET HEAD POST OPTIONS PUT PATCH DELETE"
      MODSEC_ALLOWED_REQUEST_CONTENT_TYPE: "|application/x-www-form-urlencoded| |multipart/form-data| |text/xml| |application/xml| |application/soap+xml| |application/json| |application/octet-stream|"
      MODSEC_REQ_BODY_NOFILES_LIMIT: "1048576"
      MODSEC_ARGUMENTS_LIMIT: "5000"
```

**One site only.** A file in `custom.d` can set the CRS's own variable for one host, which is narrower than a setting.
This one allows `PUT`, `PATCH` and `DELETE` on `app.example.com` (every other host keeps the default):

```
# custom.d/app-example-com-methods.conf
SecRule REQUEST_HEADERS:Host "@streq app.example.com" \
    "id:10120,\
    phase:1,\
    pass,\
    nolog,\
    setvar:'tx.allowed_methods=GET HEAD POST OPTIONS PUT PATCH DELETE'"
```

**WordPress's method override.** This file allows the `X-HTTP-Method-Override` header on `app.example.com`. It is the
CRS's default list of restricted headers without `/x-http-method-override/`; the other two override headers and
`Expect` stay blocked:

```
# custom.d/app-example-com-method-override.conf
SecRule REQUEST_HEADERS:Host "@streq app.example.com" \
    "id:10110,\
    phase:1,\
    pass,\
    nolog,\
    setvar:'tx.restricted_headers_basic=/content-encoding/ /proxy/ /lock-token/ /content-range/ /if/ /x-http-method/ /x-method-override/ /x-middleware-subrequest/ /expect/'"
```

The risk: on that host the application acts on a method the WAF does not see. ModSecurity checks the request as a
`POST`, while the application handles it as `PUT` or `DELETE`, so the method policy (911100) no longer applies there.
Keep it to the hosts that need it. Like the `Expect` file below, it freezes the CRS 4.30 list: check the CRS changelog
when you update, and copy a changed default list. Both files set the same variable, so to allow `Expect` on that host
as well, leave `/expect/` out of this line instead of adding the other file.

### CRS plugins

The CRS project publishes rule-exclusion plugins for common applications, for example for
[WordPress](https://github.com/coreruleset/wordpress-rule-exclusions-plugin) and
[Nextcloud](https://github.com/coreruleset/nextcloud-rule-exclusions-plugin). The image contains none. Take a release
you have reviewed, and mount the files of its `plugins/` directory at `/etc/nginx/modsec/plugins/` (read-only is
fine). They are loaded in the CRS's order: every `*-config.conf`, then every `*-before.conf` before the CRS rules, and
every `*-after.conf` after them. Read the plugin's README: some need a setting in their `*-config.conf`, and some
apply to every host unless you narrow them.

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
  (`MODSEC_AUDIT_LOG=/var/log/modsec/audit.json`), and rotate that file yourself. Mount the directory writable. **Rotating:** use logrotate's `copytruncate` (checked: the
  file then starts clean), or rename the file and **restart** the container. A plain rename followed by an nginx reload
  does not work: ModSecurity keeps writing to the renamed file.
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

## Proxy-wide files in `conf.d`

nginx-proxy's documentation suggests a file in `conf.d` for proxy-wide settings, for example `my_proxy.conf` with
`server_tokens off;` and `client_max_body_size 100m;`. Such a file is included at http level, where the image also
sets some directives from its settings, and nginx refuses a directive that is set twice at one level. So the image gives
way: at start it lets nginx check the configuration, and for each of these directives that a `conf.d` file sets, it
drops its own line and the file's value applies.

| Directive | Otherwise set from |
|---|---|
| `server_tokens` | [`EDGE_SERVER_TOKENS`](settings.md#edge_server_tokens) |
| `client_header_timeout`, `client_body_timeout`, `send_timeout`, `keepalive_timeout` | the `EDGE_*_TIMEOUT` settings |
| `large_client_header_buffers` | [`EDGE_LARGE_HEADER_BUFFERS`](settings.md#edge_large_header_buffers) |
| `add_header_inherit` | [`EDGE_SECURITY_HEADERS`](settings.md#edge_security_headers) (the image sets `merge`) |
| `msie_padding` | [`EDGE_BLOCK_PAGE`](settings.md#edge_block_page) (the image sets `off` while the block page is on) |

The start-up log names the file and line of each, and the setting that no longer applies:

- `NOTICE:` when the file's value is as strict as the setting's default (`server_tokens off`);
- `SECURITY:` when it is weaker (`server_tokens on`, `large_client_header_buffers 4 32k`), or when the image cannot
  compare it with the default (an nginx time such as `1m30s`, a directive spread over several lines).

Only the image's own generated files change, never yours. Any other error in a `conf.d` file, such as an unknown
directive or a duplicate of a directive the image does not set (`sendfile` is in the stock `nginx.conf`), stops nginx
as it would without the image. Setting the value through the `EDGE_*` variable instead keeps the start-up check of the
settings.

The check runs at container start. A conflicting file added while the container runs makes the next reload fail
(nginx keeps serving the configuration it has), like any broken `conf.d` file: restart the container. After you remove
such a file, the directive stays unset, so nginx's own default applies (for `server_tokens` that is `on`), until the
next restart.

## A replaced `nginx.conf`

The image's `/etc/nginx/nginx.conf` loads the ModSecurity module (`load_module modules/ngx_http_modsecurity_module.so;`
at the top) and includes `/etc/nginx/modsecurity-http.conf` (the WAF) and `/etc/nginx/modsec/rendered/hardening.conf`
(the `EDGE_*` settings) in its http block, before `conf.d`. If you mount your own `nginx.conf`, keep those three lines.
Without the includes nginx still starts, but the WAF or the hardening is off, and the start-up log has a `SECURITY:`
line for each one that is missing.

## Migrating from an existing nginx-proxy setup

Replace the images and keep your `VIRTUAL_HOST` backends. What differs:

1. **The WAF.** It blocks attacks, and also some legitimate requests (REST methods, some upload types, large forms):
   see [first-use false positives](#first-use-false-positives). Look for `SECURITY:` lines and 403s in the logs after
   the move; start with `MODSEC_RULE_ENGINE=DetectionOnly` on a busy site to see the false positives before blocking.
2. **Stricter defaults.** Timeouts are 10 s, keep-alive is 15 s (the stock `nginx.conf` has 65 s), and request bodies
   over 128 MiB are refused (nginx's own `client_max_body_size`, 1m unless you raise it for a vhost in nginx-proxy's
   usual way, refuses larger bodies first: ModSecurity's limit only applies below it).
3. **Proxy-wide files in `conf.d`** keep working: where one sets a directive the image also sets, the file's value
   applies, and the log says so with a `NOTICE:` or `SECURITY:` line, see [proxy-wide files](#proxy-wide-files-in-confd).

Your `vhost.d` and `vhost.d/<host>_location` snippets, `htpasswd`, certificates and per-container variables work as
before, because the template is nginx-proxy's own.

## Read-only root filesystem

The `edge` container runs with a read-only root filesystem if you give it these writable places:

| Path | Why |
|---|---|
| `/etc/nginx/modsec/rendered` (tmpfs) | The settings, block page and hardening config written at start (and changed at start for [proxy-wide files](#proxy-wide-files-in-confd)). |
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
  shared `html` volume, and signals both `gen` and the `edge` container (SIGHUP). The `gen` image sets the `DOCKER_GEN_VERSION` variable acme-companion looks
  for. This combination is **not exercised by the smoke tests**; [`examples/docker-compose.yml`](../examples/docker-compose.yml)
  follows acme-companion's documentation for the layout. Its HTTP-01 requests fit the
  [ACME exemption](#the-acme-challenge-exemption).
