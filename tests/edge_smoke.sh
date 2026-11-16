#!/usr/bin/env bash
# Smoke test for the edge image: tests/edge_smoke.sh IMAGE
# Starts the image in front of a tiny echo backend on private Docker networks and checks
# ModSecurity + CRS behaviour. Prints "PASS <name>" per assertion, stops at the first failure.
# Every container, network and temp file it creates is removed on exit (also on failure).
set -euo pipefail

IMAGE=${1:?usage: tests/edge_smoke.sh IMAGE}
# Test helpers, pinned by digest.
BACKEND_IMAGE=traefik/whoami@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab
CLIENT_IMAGE=curlimages/curl@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40

command -v jq >/dev/null || { echo "FAIL setup: jq is required on the host" >&2; exit 1; }

RUN="edgetest-$$-$RANDOM"
WORK=$(mktemp -d)
chmod 755 "$WORK"
CONTAINERS=()
NETWORKS=()
cleanup() {
  local c n
  for c in ${CONTAINERS[@]+"${CONTAINERS[@]}"}; do docker rm -f -v "$c" >/dev/null 2>&1 || true; done
  for n in ${NETWORKS[@]+"${NETWORKS[@]}"}; do docker network rm "$n" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+: $2}" >&2; exit 1; }
expect_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }

# ---- test data ------------------------------------------------------------------------------
mkdir -p "$WORK/conf.d" "$WORK/empty-custom" "$WORK/empty-after" "$WORK/empty-plugins"
cat > "$WORK/conf.d/test.conf" <<'CONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    # Plain-text HTTP/2 (h2c) so the test can speak HTTP/2 without a certificate.
    listen 81;
    http2 on;
    server_name app.example.com;
    # nginx refuses bodies above 1m by default; real deployments set this through nginx-proxy.
    # Raised here so the 20 MB upload test reaches ModSecurity and proves ITS limits allow it.
    client_max_body_size 64m;
    location / {
        proxy_pass http://backend:80;
        proxy_set_header Host $host;
    }
}
CONF
# 20 MB of random letters (base64 of random bytes, digits and symbols removed).
# Every stage reads its input to the end (no early-closing head in the pipe), so there is no SIGPIPE noise:
# 20 MB of random bytes give about 21.7 MB of letters, which are then cut to 20 MB.
head -c 20000000 /dev/urandom | base64 -w0 | tr -dc 'a-zA-Z' > "$WORK/upload.full"
head -c 20000000 "$WORK/upload.full" > "$WORK/upload.txt"
rm -f "$WORK/upload.full"
[ "$(stat -c %s "$WORK/upload.txt")" -ge 20000000 ] || fail setup "could not generate the upload file"
chmod 644 "$WORK/upload.txt"
# Request bodies without attack content that hit ModSecurity's own limits: 230 KB of form data (the limit without files
# is 128 KiB), a form with 1000 fields (the argument limit), and one with 999.
{ printf 'a='; head -c 230000 /dev/zero | tr '\0' a; } > "$WORK/form-230k.txt"
fields() { seq -s '&' 0 $(($1 - 1)) | sed 's/[0-9][0-9]*/f&=1/g'; }
fields 1000 > "$WORK/form-1000.txt"
fields 999 > "$WORK/form-999.txt"
chmod 644 "$WORK"/form-*.txt
# A tiny OWASP CRS plugin: proves the plugins mount loads *-config.conf, then *-before.conf before the CRS rules, then
# *-after.conf after them. Each phase-1 rule appends a letter: b only before the CRS's initialisation has run (its
# rule 901200 sets tx.blocking_inbound_anomaly_score), a only after it. Only the order c, b, a answers 418.
mkdir -p "$WORK/plugins"
cat > "$WORK/plugins/order-test-config.conf" <<'RULES'
SecAction "id:10901,phase:1,pass,nolog,setvar:'tx.order_test=c'"
RULES
cat > "$WORK/plugins/order-test-before.conf" <<'RULES'
SecRule &TX:blocking_inbound_anomaly_score "@eq 0" "id:10902,phase:1,pass,nolog,setvar:'tx.order_test=%{tx.order_test}b'"
RULES
cat > "$WORK/plugins/order-test-after.conf" <<'RULES'
SecRule &TX:blocking_inbound_anomaly_score "@eq 1" "id:10903,phase:1,pass,nolog,setvar:'tx.order_test=%{tx.order_test}a'"
SecRule TX:order_test "@streq cba" "id:10904,phase:1,deny,status:418,log,msg:'plugin files loaded in order'"
RULES
chmod -R a+rX "$WORK/plugins"

# ---- docker helpers ---------------------------------------------------------------------------
new_network() { # name subnet4 [subnet6]
  local name=$1; shift
  local args=(--subnet "$1"); [ -n "${2:-}" ] && args+=(--ipv6 --subnet "$2")
  docker network create "${args[@]}" "$name" >/dev/null 2>"$WORK/net.err" || return 1
  NETWORKS+=("$name")
}
start() { # container-name network [docker run args...] -- image/args
  local name=$1 net=$2; shift 2
  CONTAINERS+=("$name")   # registered first, so a failing 'docker run' cannot leak it
  docker run -d --name "$name" --network "$net" "$@" >/dev/null
}
wait_ready() { # container
  local i
  for i in $(seq 1 50); do
    if docker exec "$1" sh -c 'test -s /var/run/nginx.pid || test -s /run/nginx.pid' 2>/dev/null \
       && [ "$(docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' -H 'Host: app.example.com' "http://$1/" 2>/dev/null || true)" != 000 ]; then
      return 0
    fi
    sleep 0.2
  done
  docker logs "$1" >&2 || true
  fail "wait_ready $1" "did not come up"
}
status() { # name url [curl args...] -> http status
  local u=$1; shift
  docker exec "$CLIENT" curl -s -g -o /dev/null -w '%{http_code}' -H 'Host: app.example.com' "$@" "$u" || true
}
status_stdin() { # url [curl args...] < body -> http status
  # The body is streamed from stdin (curl -T -, docker exec -i), so curl does not know its size and
  # sends no Content-Length: chunked on HTTP/1.1, bare DATA frames on HTTP/2.
  local u=$1; shift
  docker exec -i "$CLIENT" curl -s -g -o /dev/null -w '%{http_code}' -H 'Host: app.example.com' -T - "$@" "$u" || true
}
audit_lines() { # container marker -> audit JSON objects whose request uri contains marker
  # The audit log goes to the container's stdout next to the access log, so select the audit objects
  # (lines starting with {"transaction") and parse them with jq; a line that is not valid JSON is an error.
  local logs
  logs=$(docker logs "$1" 2>/dev/null | grep '^{"transaction"' || true)
  [ -z "$logs" ] && return 0
  # Every selected line must be valid JSON; otherwise fail (non-zero), so neither a presence nor an
  # absence check can pass on a log it could not read.
  jq empty <<<"$logs" >/dev/null 2>&1 || { echo "audit_lines: invalid JSON in the audit log of $1" >&2; return 1; }
  jq -c --arg m "$2" 'select((.transaction.request.uri // "") | contains($m))' <<<"$logs"
}
audit_absent() { # container marker -> pass only if the audit log is readable and has no such entry
  local out
  out=$(audit_lines "$1" "$2") || return 1
  [ -z "$out" ]
}
wait_audit() { # container marker -> prints the lines once present (up to 5 s)
  local i out
  for i in $(seq 1 25); do
    out=$(audit_lines "$1" "$2") || return 1
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    sleep 0.2
  done
  return 1
}
edge() { # name [env args...]
  local name=$1; shift
  start "$RUN-$name" "$NET" --network-alias "$RUN-$name" \
    -v "$WORK/conf.d:/etc/nginx/conf.d:ro" "$@" "$IMAGE"
  wait_ready "$RUN-$name"
}

# ---- 1. config-only checks (no network needed) --------------------------------------------------
docker run --rm "$IMAGE" nginx -t >/dev/null 2>&1 || fail nginx_t "nginx -t failed"
docker run --rm -v "$WORK/empty-custom:/etc/nginx/modsec/custom.d:ro" \
  -v "$WORK/empty-after:/etc/nginx/modsec/after.d:ro" -v "$WORK/empty-plugins:/etc/nginx/modsec/plugins:ro" \
  "$IMAGE" nginx -t >/dev/null 2>&1 \
  || fail nginx_t "nginx -t failed with empty custom.d, after.d and plugins mounted"
pass nginx_t

DUMP=$(docker run --rm "$IMAGE" nginx -T 2>&1) || fail module_loaded "nginx -T failed: $DUMP"
grep -q '^load_module modules/ngx_http_modsecurity_module.so;' <<<"$DUMP" \
  && grep -q 'modsecurity on;' <<<"$DUMP" || fail module_loaded
pass module_loaded

grep -q 'worker_connections  10240;' <<<"$DUMP" && grep -q 'worker_rlimit_nofile 20480;' <<<"$DUMP" \
  && grep -q 'include /etc/nginx/toplevel.conf.d/\*.conf;' <<<"$DUMP" \
  && docker run --rm --entrypoint sh "$IMAGE" -c 'test -d /etc/nginx/toplevel.conf.d && test -d /etc/nginx/dhparam && test -d /etc/nginx/certs && test -d /usr/share/nginx/html/errors && test -s /etc/nginx/network_internal.conf' \
  || fail nginx_proxy_layout
pass nginx_proxy_layout

for tool in gcc cc g++ c++ make cpp ld as; do
  docker run --rm --entrypoint sh "$IMAGE" -c "! command -v $tool >/dev/null" || fail no_compilers "$tool is in the final image"
done
pass no_compilers

# The licence texts of what the image contains are shipped (Apache-2.0 section 4(a), BSD and MIT notices).
docker run --rm --entrypoint sh "$IMAGE" -c '
  for f in modsecurity/LICENSE modsecurity-nginx/LICENSE crs/LICENSE nginx/LICENSE nginx-proxy/LICENSE edge-proxy/LICENSE edge-proxy/NOTICE; do
    [ -s "/usr/share/licenses/$f" ] || { echo "missing or empty: $f"; exit 1; }
  done
  grep -q "Apache License" /usr/share/licenses/modsecurity/LICENSE && grep -q "Apache License" /usr/share/licenses/modsecurity-nginx/LICENSE' \
  >/dev/null 2>"$WORK/licenses.err" || fail licenses_shipped "$(cat "$WORK/licenses.err" 2>/dev/null)"
pass licenses_shipped

# The deny status is applied with SecRuleUpdateActionById on these CRS rules; an update on an unknown ID
# passes nginx -t silently, so make a CRS renumbering fail here (and so the build).
for id in 949110 949111 959100 959101; do
  docker run --rm --entrypoint sh "$IMAGE" -c "grep -rqE '\"id:$id,' /etc/nginx/modsec/crs/rules" \
    || fail crs_blocking_rules "CRS rule $id not found; update templates/modsecurity-after-crs.conf.template"
done
pass crs_blocking_rules

# The CRS policy settings default to the built CRS's own lists (rules 901160 and 901162 of REQUEST-901-INITIALIZATION.conf
# set them when nothing else has): a CRS release that changes them fails here, so settings.tsv follows on purpose.
CRS_INIT=$(docker run --rm --entrypoint cat "$IMAGE" /etc/nginx/modsec/crs/rules/REQUEST-901-INITIALIZATION.conf) \
  || fail crs_policy_defaults "cannot read the CRS's initialisation rules"
SETTINGS=$(docker run --rm --entrypoint cat "$IMAGE" /usr/local/share/kickedro/settings.tsv) \
  || fail crs_policy_defaults "cannot read the settings file"
crs_default() { # rule-id tx-variable -> the value that CRS rule sets
  awk -v id="\"id:$1," -v var="setvar:'tx.$2=" -v tail="'\"" '
    index($0, id) { found = 1 }
    found && (i = index($0, var)) {
      v = substr($0, i + length(var))
      if (substr(v, length(v) - 1) == tail) print substr(v, 1, length(v) - 2)
      exit
    }' <<<"$CRS_INIT"
}
for check in 901160:allowed_methods:MODSEC_ALLOWED_METHODS \
  901162:allowed_request_content_type:MODSEC_ALLOWED_REQUEST_CONTENT_TYPE; do
  IFS=: read -r id var setting <<<"$check"
  CRS=$(crs_default "$id" "$var")
  [ -n "$CRS" ] || fail crs_policy_defaults "rule $id does not set tx.$var in the CRS; update edge/settings.tsv and this test"
  expect_eq "crs_policy_default_$var" "$(awk -F '\t' -v v="$setting" '$1 == v { print $2 }' <<<"$SETTINGS")" "$CRS"
done

# User templates keep working: the official NGINX_ENVSUBST_* mechanism is untouched.
mkdir -p "$WORK/usertpl"
echo '# user template value=${USER_TPL_VALUE}' > "$WORK/usertpl/user.conf.template"
docker run --rm -e USER_TPL_VALUE=hello42 -v "$WORK/usertpl:/etc/nginx/templates:ro" "$IMAGE" nginx -T 2>&1 \
  | grep -q '^# user template value=hello42$' || fail user_template_rendered "user template not rendered into conf.d"
pass user_template_rendered

# ---- 2. live tests ------------------------------------------------------------------------------
# Random /24 from the benchmarking range (RFC 2544) and a /64 from the documentation range (RFC 3849),
# so concurrent runs on a shared machine do not collide.
NET="$RUN-net"
CLIENT_IP4=""; SUBNET4=""
for _ in $(seq 1 20); do
  SUBNET4="198.$((18 + RANDOM % 2)).$((RANDOM % 256)).0/24"
  new_network "$NET" "$SUBNET4" && break
  SUBNET4=""
done
[ -n "$SUBNET4" ] || { cat "$WORK/net.err" >&2; fail network "could not create test network"; }
CLIENT_IP4="${SUBNET4%.0/24}.100"

CLIENT="$RUN-client"
start "$CLIENT" "$NET" --ip "$CLIENT_IP4" --entrypoint sleep "$CLIENT_IMAGE" 3600
start "$RUN-backend" "$NET" --network-alias backend "$BACKEND_IMAGE"

XSS='/?t=xss1&q=<script>alert(1)</script>'
edge on -e MODSEC_RULE_ENGINE=On
edge detect -e MODSEC_RULE_ENGINE=DetectionOnly

for mode in on detect; do
  E="$RUN-$mode"
  expect_eq "clean_get_$mode" "$(status "http://$E/?q=select+the+best+plan+from+our+list")" 200
done

expect_eq url_xss_on "$(status "http://$RUN-on$XSS")" 403
expect_eq url_xss_detectiononly "$(status "http://$RUN-detect$XSS")" 200
for mode in on detect; do
  LINE=$(wait_audit "$RUN-$mode" 't=xss1') || fail "audit_line_$mode" "no audit entry for the xss request"
  pass "audit_line_$mode"
  [ "$mode" = on ] && ON_LINE=$LINE
done

# The client's address (IPv4) is in the audit entry.
[ "$(jq -r '.transaction.client_ip' <<<"$ON_LINE" | head -1)" = "$CLIENT_IP4" ] \
  && pass remote_addr_logged || fail remote_addr_logged "expected $CLIENT_IP4 in: $ON_LINE"

expect_eq body_sqli_on "$(status "http://$RUN-on/" --data-urlencode 'id=1 UNION SELECT password FROM users')" 403

# 20 MB multipart/form-data file upload of letters: ModSecurity's body limits must not refuse it.
# (The Expect header is cleared to emulate a browser upload: browsers never send "Expect: 100-continue", but
# curl adds it to large uploads and CRS 4 blocks it by default, rule 920450, as an anti-desync measure.)
expect_eq large_upload "$(docker cp "$WORK/upload.txt" "$CLIENT:/tmp/upload.txt" >/dev/null && status "http://$RUN-on/" -H 'Expect:' -F 'file=@/tmp/upload.txt;type=application/octet-stream' --max-time 120)" 200

# JSON bodies are parsed and inspected.
expect_eq body_json_sqli_on "$(status "http://$RUN-on/" -H 'Content-Type: application/json' --data '{"id":"1 UNION SELECT password FROM users"}')" 403
expect_eq body_json_xss_on "$(status "http://$RUN-on/" -H 'Content-Type: application/json' --data '{"q":"<script>alert(1)</script>"}')" 403

# ACME HTTP-01 exemption: only requests shaped like a validation (GET/HEAD, raw target exactly
# /.well-known/acme-challenge/<token>) skip the WAF. A scanner User-Agent is blocked on any other path,
# so that is the probe: blocked on /, passes on a token path.
expect_eq acme_control_blocked "$(status "http://$RUN-on/" -A nikto)" 403
expect_eq acme_exempt "$(status "http://$RUN-on/.well-known/acme-challenge/tok_en-1" -A nikto)" 200
expect_eq acme_exempt_head "$(status "http://$RUN-on/.well-known/acme-challenge/tok_en-1" -A nikto -I)" 200
# A later blocked request proves the (serial) audit log has caught up before we look for the ACME entry.
status "http://$RUN-on/?t=xss2&q=<script>alert(2)</script>" >/dev/null
wait_audit "$RUN-on" 't=xss2' >/dev/null || fail acme_exempt "audit log did not catch up"
audit_absent "$RUN-on" 'acme-challenge/tok_en-1' && pass acme_exempt_no_audit \
  || fail acme_exempt_no_audit "audit entry exists for the validation request"

# Everything else under the prefix is inspected: query strings and traversal (encoded and literal, GET and POST).
inspected() { # name marker url [curl args...]  -> 403 and an audit entry
  local name=$1 marker=$2 url=$3; shift 3
  expect_eq "$name" "$(status "$url" "$@")" 403
  wait_audit "$RUN-on" "$marker" >/dev/null || fail "$name" "no audit entry"
}
inspected_stdin() { # name marker url [curl args...] < body -> 403 and an audit entry (body sent without a length)
  local name=$1 marker=$2 url=$3; shift 3
  expect_eq "$name" "$(status_stdin "$url" "$@")" 403
  wait_audit "$RUN-on" "$marker" >/dev/null || fail "$name" "no audit entry"
}
A="http://$RUN-on/.well-known/acme-challenge"
inspected acme_query_inspected 't=aq1' "$A/x?t=aq1&q=<script>alert(1)</script>"
inspected acme_traversal_inspected_enc_get 't=tr1' "$A/%2e%2e/%2e%2e/wp-login.php?t=tr1&q=<script>alert(1)</script>" --path-as-is
inspected acme_traversal_inspected_lit_get 't=tr2' "$A/../../wp-login.php?t=tr2&q=<script>alert(1)</script>" --path-as-is
inspected acme_traversal_inspected_enc_post 't=tr3' "$A/%2e%2e/%2e%2e/wp-login.php?t=tr3" --path-as-is --data-urlencode 'log=1 UNION SELECT password FROM users'
inspected acme_traversal_inspected_lit_post 't=tr4' "$A/../../wp-login.php?t=tr4" --path-as-is --data-urlencode 'log=1 UNION SELECT password FROM users'
# Bypass attempts: REQUEST_URI is decoded and ^/$ match at %0A, so these must all be inspected.
inspected acme_bypass_anypath_newline 't=u1' "http://$RUN-on/wp-login.php?t=u1&q=<script>alert(1)</script>&z=%0A/.well-known/acme-challenge/a" -A nikto
inspected acme_bypass_token_newline 't=u2' "$A/x%0A?t=u2&q=<script>alert(1)</script>" -A nikto --path-as-is
inspected acme_bypass_fragment 't=u3' "http://$RUN-on" -A nikto --request-target '/.well-known/acme-challenge/x#?t=u3&id=1+UNION+SELECT+password+FROM+users'
inspected acme_bypass_encoded_token 'bc_e1' "$A/%41bc_e1" -A nikto --path-as-is
inspected acme_bypass_cookie 'acme-challenge/tok_ck1' "$A/tok_ck1" -A nikto -H 'Cookie: a=b'
inspected acme_bypass_post_body 'acme-challenge/tok_pb1' "$A/tok_pb1" -A nikto --data 'a=b'
# A GET with a body, one test per header that announces it on HTTP/1.1 (each guards its own chain link:
# the other header is absent, so only that link stops the exemption).
inspected acme_bypass_get_cl 'acme-challenge/tok_cl1' "$A/tok_cl1" -A nikto --http1.1 -X GET --data 'a=b'
inspected acme_bypass_get_te 'acme-challenge/tok_te1' "$A/tok_te1" -A nikto --http1.1 -X GET -H 'Transfer-Encoding: chunked' --data 'a=b'
# HTTP/2 (h2c prior knowledge on port 81; chosen over TLS to avoid a throwaway certificate): a body needs
# no Content-Length there, so the exemption is HTTP/1.x only.
inspected acme_bypass_h2_get 'acme-challenge/tok_h21' "http://$RUN-on:81/.well-known/acme-challenge/tok_h21" -A nikto --http2-prior-knowledge
# The body is streamed from stdin, so it goes out as DATA frames with no content-length and neither header
# link applies: only the protocol link stops it. (--data would send content-length and hide a missing one.)
inspected_stdin acme_bypass_h2_body 'acme-challenge/tok_h22' "http://$RUN-on:81/.well-known/acme-challenge/tok_h22" \
  -A nikto --http2-prior-knowledge -X GET -H 'Content-Type: application/json' <<<'{"id":"1 UNION SELECT password FROM users"}'
inspected acme_post_inspected 'acme-challenge/tok_po1' "$A/tok_po1" --data-urlencode 'log=1 UNION SELECT password FROM users'

# The audit entries survive a reload (the log is opened again by the new workers).
docker exec "$RUN-on" nginx -s reload >/dev/null 2>&1
sleep 1
expect_eq audit_after_reload_status "$(status "http://$RUN-on/?t=rl1&q=<script>alert(1)</script>")" 403
wait_audit "$RUN-on" 't=rl1' >/dev/null && pass audit_after_reload || fail audit_after_reload "no audit entry after nginx -s reload"

# Empty custom.d / after.d / plugins mounted over the image's: server must start and still block.
edge emptydirs -e MODSEC_RULE_ENGINE=On -v "$WORK/empty-custom:/etc/nginx/modsec/custom.d:ro" \
  -v "$WORK/empty-after:/etc/nginx/modsec/after.d:ro" -v "$WORK/empty-plugins:/etc/nginx/modsec/plugins:ro"
expect_eq empty_mounts_block "$(status "http://$RUN-emptydirs$XSS")" 403

# A custom.d rule is loaded (site exclusions go there). The other two files are the per-site snippets of
# docs/configuration.md ("First-use false positives"), word for word.
mkdir -p "$WORK/custom"
echo 'SecRule REQUEST_URI "@beginsWith /custom-test" "id:10100,phase:1,pass,nolog,ctl:ruleEngine=Off"' > "$WORK/custom/site.conf"
cat > "$WORK/custom/method-override.conf" <<'RULES'
SecRule REQUEST_HEADERS:Host "@streq app.example.com" \
    "id:10110,\
    phase:1,\
    pass,\
    nolog,\
    setvar:'tx.restricted_headers_basic=/content-encoding/ /proxy/ /lock-token/ /content-range/ /if/ /x-http-method/ /x-method-override/ /x-middleware-subrequest/ /expect/'"
RULES
cat > "$WORK/custom/api-methods.conf" <<'RULES'
SecRule REQUEST_HEADERS:Host "@streq app.example.com" \
    "id:10120,\
    phase:1,\
    pass,\
    nolog,\
    setvar:'tx.allowed_methods=GET HEAD POST OPTIONS PUT PATCH DELETE'"
RULES
chmod -R a+rX "$WORK/custom"
edge custom -e MODSEC_RULE_ENGINE=On -v "$WORK/custom:/etc/nginx/modsec/custom.d:ro"
expect_eq custom_d_loaded "$(status "http://$RUN-custom/custom-test?q=<script>alert(1)</script>")" 200

# ---- first-use false positives (docs/configuration.md): the CRS's default policy and ModSecurity's body limits -----
# Methods other than GET HEAD POST OPTIONS (911100), body types outside the allowed list (920420) and method-override
# headers (920450) are refused by default; the settings and the snippet above let them through.
WP_POST=(-H 'Content-Type: application/json' --data '{"title":"hello"}')
for m in PUT PATCH DELETE; do
  expect_eq "method_${m,,}_refused" "$(status "http://$RUN-on/api/x" -X "$m" "${WP_POST[@]}")" 403
done
expect_eq octet_stream_refused "$(status "http://$RUN-on/dav/f" -X PUT -H 'Content-Type: application/octet-stream' --data-binary 'abc')" 403
expect_eq method_override_refused "$(status "http://$RUN-on/wp-json/wp/v2/posts/1" -H 'X-HTTP-Method-Override: PUT' "${WP_POST[@]}")" 403
edge policy -e 'MODSEC_ALLOWED_METHODS=GET HEAD POST OPTIONS PUT PATCH DELETE' \
  -e 'MODSEC_ALLOWED_REQUEST_CONTENT_TYPE=|application/x-www-form-urlencoded| |multipart/form-data| |text/xml| |application/xml| |application/soap+xml| |application/json| |application/octet-stream|'
for m in PUT PATCH DELETE; do
  expect_eq "method_${m,,}_allowed" "$(status "http://$RUN-policy/api/x" -X "$m" "${WP_POST[@]}")" 200
done
expect_eq octet_stream_allowed "$(status "http://$RUN-policy/dav/f" -X PUT -H 'Content-Type: application/octet-stream' --data-binary 'abc')" 200
expect_eq method_still_refused "$(status "http://$RUN-policy/dav/f" -X PROPFIND)" 403
expect_eq method_override_snippet "$(status "http://$RUN-custom/wp-json/wp/v2/posts/1" -H 'X-HTTP-Method-Override: PUT' "${WP_POST[@]}")" 200
expect_eq method_override_snippet_other_host "$(docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' \
  -H 'Host: other.example.com' -H 'X-HTTP-Method-Override: PUT' "${WP_POST[@]}" "http://$RUN-custom/wp-json/wp/v2/posts/1" \
  || true)" 403
expect_eq method_override_snippet_keeps_others "$(status "http://$RUN-custom/" -H 'X-HTTP-Method: PUT' --data 'a=1')" 403
expect_eq methods_snippet "$(status "http://$RUN-custom/api/x" -X DELETE)" 200
expect_eq methods_snippet_other_host "$(docker exec "$CLIENT" curl -s -o /dev/null -w '%{http_code}' -X DELETE \
  -H 'Host: other.example.com' "http://$RUN-custom/api/x" || true)" 403

# A body over the limit without files, and a form that reaches the argument limit, get the deny status and the block
# page, whose reference is the audit entry of the body check (rules 200002 and 200007); 999 fields pass.
block_page_for_rule() { # name rule-id marker body-file -> the deny status, the block page and that rule in the audit entry
  local name=$1 rule=$2 marker=$3 file=$4 resp code id entry
  docker cp "$WORK/$file" "$CLIENT:/tmp/$file" >/dev/null
  resp=$(docker exec "$CLIENT" curl -s -g -w '\n%{http_code}' -H 'Host: app.example.com' -H 'Expect:' \
    --data-binary "@/tmp/$file" "http://$RUN-on/?t=$marker" || true)
  code=${resp##*$'\n'}
  [ "$code" = 403 ] || fail "$name" "status $code"
  grep -q 'blocked for security reasons' <<<"$resp" || fail "$name" "not the block page: $(head -c 300 <<<"$resp")"
  id=$(grep -oE '[0-9a-f]{32}' <<<"$resp" | sort -u || true)
  [ -n "$id" ] && [ "$(wc -l <<<"$id")" = 1 ] || fail "$name" "no single reference on the page"
  entry=$(wait_audit "$RUN-on" "t=$marker") || fail "$name" "no audit entry"
  jq -e --arg id "$id" --arg rule "$rule" 'select(.transaction.unique_id == $id)
    | any(.transaction.messages[]; .details.ruleId == $rule)' <<<"$entry" >/dev/null \
    || fail "$name" "the audit entry for $id has no rule $rule: $entry"
  pass "$name"
}
block_page_for_rule body_over_nofiles_limit 200002 bl1 form-230k.txt
block_page_for_rule arguments_limit 200007 bl2 form-1000.txt
docker cp "$WORK/form-999.txt" "$CLIENT:/tmp/form-999.txt" >/dev/null
expect_eq arguments_below_limit "$(status "http://$RUN-on/" -H 'Expect:' --data-binary @/tmp/form-999.txt)" 200
edge limits -e MODSEC_REQ_BODY_NOFILES_LIMIT=262144 -e MODSEC_ARGUMENTS_LIMIT=1001
expect_eq body_nofiles_limit_raised "$(status "http://$RUN-limits/" -H 'Expect:' --data-binary @/tmp/form-230k.txt)" 200
expect_eq arguments_limit_raised "$(status "http://$RUN-limits/" -H 'Expect:' --data-binary @/tmp/form-1000.txt)" 200

# CRS plugins: the test plugin's files run in the CRS's order (config, before, the CRS rules, after).
edge plugins -v "$WORK/plugins:/etc/nginx/modsec/plugins:ro"
expect_eq plugins_loaded_in_order "$(status "http://$RUN-plugins/")" 418

edge status406 -e MODSEC_RULE_ENGINE=On -e MODSEC_DENY_STATUS=406
expect_eq deny_status_env "$(status "http://$RUN-status406$XSS")" 406

edge auditoff -e MODSEC_RULE_ENGINE=On -e MODSEC_AUDIT_LOG=off
expect_eq audit_off_blocks "$(status "http://$RUN-auditoff/?t=off1&q=<script>alert(1)</script>")" 403
sleep 1
docker logs "$RUN-auditoff" 2>&1 | grep -q -e '^{"transaction"' -e '^---.*---A--$' \
  && fail audit_off "audit entry written with MODSEC_AUDIT_LOG=off" || pass audit_off

# A file path is still possible (default is stdout).
edge auditfile -e MODSEC_AUDIT_LOG=/var/tmp/modsec_audit.log
expect_eq audit_file_status "$(status "http://$RUN-auditfile/?t=af1&q=<script>alert(1)</script>")" 403
sleep 1
docker exec "$RUN-auditfile" cat /var/tmp/modsec_audit.log | grep -q 't=af1' \
  && pass audit_file_path || fail audit_file_path "no entry in the configured file"

# MODSEC_AUDIT_FORMAT=Native writes the classic multi-part format, not JSON.
edge nativefmt -e MODSEC_AUDIT_FORMAT=Native
expect_eq audit_native_status "$(status "http://$RUN-nativefmt/?t=nf1&q=<script>alert(1)</script>")" 403
sleep 1
LOGS=$(docker logs "$RUN-nativefmt" 2>&1)
grep -q -e '^---.*---A--$' <<<"$LOGS" && ! grep -q '^{"transaction"' <<<"$LOGS" \
  && pass audit_format_native || fail audit_format_native "expected a native (---id---A--) entry and no JSON"

# MODSEC_ANOMALY_INBOUND: a very high threshold lets the XSS request through.
edge anomaly -e MODSEC_ANOMALY_INBOUND=1000
expect_eq anomaly_inbound "$(status "http://$RUN-anomaly$XSS")" 200
# MODSEC_ANOMALY_OUTBOUND: no cheap behavioural check with the echo backend; assert the rendered value.
edge outbound -e MODSEC_ANOMALY_OUTBOUND=7
docker exec "$RUN-outbound" grep -q 'outbound_anomaly_score_threshold=7' /etc/nginx/modsec/rendered/modsecurity.conf \
  && pass anomaly_outbound_rendered || fail anomaly_outbound_rendered

# MODSEC_PARANOIA: a request only a paranoia-level-2 rule blocks passes at the default level 1.
PL2='/?q=cat+/e?c/p?sswd'
expect_eq paranoia_default_pl1 "$(status "http://$RUN-on$PL2")" 200
edge pl2 -e MODSEC_PARANOIA=2
expect_eq paranoia_pl2 "$(status "http://$RUN-pl2$PL2")" 403

# MODSEC_REQ_BODY_LIMIT: with 1 MiB a 2 MiB file upload is refused (default limit allows 20 MB, see large_upload).
edge bodylimit -e MODSEC_REQ_BODY_LIMIT=1048576
head -c 2097152 "$WORK/upload.txt" > "$WORK/upload2m.txt"
docker cp "$WORK/upload2m.txt" "$CLIENT:/tmp/upload2m.txt" >/dev/null
BL=$(status "http://$RUN-bodylimit/" -H 'Expect:' -F 'file=@/tmp/upload2m.txt;type=application/octet-stream')
[ "$BL" != 200 ] && [ "$BL" != 000 ] && pass req_body_limit || fail req_body_limit "2 MiB upload got $BL with a 1 MiB limit"

# ---- 3. IPv6 client address -----------------------------------------------------------------------
NET6="$RUN-net6"
SUB6="2001:db8:$(printf '%x:%x' $((RANDOM)) $((RANDOM)))::/64"
OK6=""
for _ in $(seq 1 10); do
  S4="198.$((18 + RANDOM % 2)).$((RANDOM % 256)).0/24"
  SUB6="2001:db8:$(printf '%x:%x' $((RANDOM)) $((RANDOM)))::/64"
  if new_network "$NET6" "$S4" "$SUB6"; then OK6=1; break; fi
done
if [ -z "$OK6" ]; then
  echo "SKIP remote_addr_logged_ipv6: could not create an IPv6 test network ($(tr '\n' ' ' < "$WORK/net.err"))"
else
  C6="$RUN-client6"; IP6="${SUB6%::/64}::64"
  if start "$C6" "$NET6" --ip6 "$IP6" --entrypoint sleep "$CLIENT_IMAGE" 3600 2>"$WORK/c6.err" \
     && start "$RUN-backend6" "$NET6" --network-alias backend "$BACKEND_IMAGE" \
     && start "$RUN-edge6" "$NET6" -v "$WORK/conf.d:/etc/nginx/conf.d:ro" -e MODSEC_RULE_ENGINE=On "$IMAGE"; then
    sleep 2
    CODE6=$(docker exec "$C6" curl -6 -s -g -o /dev/null -w '%{http_code}' --retry 10 --retry-connrefused --retry-delay 1 \
      -H 'Host: app.example.com' "http://$RUN-edge6/?t=xss6&q=<script>alert(1)</script>" || true)
    expect_eq remote_addr_logged_ipv6_status "$CODE6" 403
    L6=$(wait_audit "$RUN-edge6" 't=xss6') || fail remote_addr_logged_ipv6 "no audit entry"
    [ "$(jq -r '.transaction.client_ip' <<<"$L6" | head -1)" = "$IP6" ] \
      && pass remote_addr_logged_ipv6 || fail remote_addr_logged_ipv6 "expected $IP6 in: $L6"
  else
    echo "SKIP remote_addr_logged_ipv6: could not start containers on the IPv6 network ($(tr '\n' ' ' < "$WORK/c6.err"))"
  fi
fi

echo "ALL PASS"
