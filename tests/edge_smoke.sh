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
mkdir -p "$WORK/conf.d" "$WORK/empty-custom" "$WORK/empty-after"
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
  -v "$WORK/empty-after:/etc/nginx/modsec/after.d:ro" "$IMAGE" nginx -t >/dev/null 2>&1 \
  || fail nginx_t "nginx -t failed with empty custom.d and after.d mounted"
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

# The deny status is applied with SecRuleUpdateActionById on these CRS rules; an update on an unknown ID
# passes nginx -t silently, so make a CRS renumbering fail here (and so the build).
for id in 949110 949111 959100 959101; do
  docker run --rm --entrypoint sh "$IMAGE" -c "grep -rqE '\"id:$id,' /etc/nginx/modsec/crs/rules" \
    || fail crs_blocking_rules "CRS rule $id not found; update templates/modsecurity-after-crs.conf.template"
done
pass crs_blocking_rules

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

# Empty custom.d / after.d mounted over the image's: server must start and still block.
edge emptydirs -e MODSEC_RULE_ENGINE=On \
  -v "$WORK/empty-custom:/etc/nginx/modsec/custom.d:ro" -v "$WORK/empty-after:/etc/nginx/modsec/after.d:ro"
expect_eq empty_mounts_block "$(status "http://$RUN-emptydirs$XSS")" 403

# A custom.d rule is loaded (site exclusions go there).
mkdir -p "$WORK/custom"
echo 'SecRule REQUEST_URI "@beginsWith /custom-test" "id:10100,phase:1,pass,nolog,ctl:ruleEngine=Off"' > "$WORK/custom/site.conf"
edge custom -e MODSEC_RULE_ENGINE=On -v "$WORK/custom:/etc/nginx/modsec/custom.d:ro"
expect_eq custom_d_loaded "$(status "http://$RUN-custom/custom-test?q=<script>alert(1)</script>")" 200

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
