#!/usr/bin/env bash
# Smoke test for the edge image's hardened defaults and settings: tests/hardening_smoke.sh IMAGE
# Checks the start-up validation and SECURITY: summary (edge/settings.tsv), the rendered defaults, the security and
# hidden headers, the client header timeout, the rate-limit zones and the block page, with the image in front of a
# plain nginx backend (tests/fixtures/headers-backend.conf) on a private Docker network.
# Prints "PASS <name>" per assertion, stops at the first failure. Every container, network and temp file it creates
# is removed on exit (also on failure).
set -euo pipefail

IMAGE=${1:?usage: tests/hardening_smoke.sh IMAGE}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Test helpers, pinned by digest: plain nginx as the backend, curl (busybox: sh, nc, timeout) as the client.
BACKEND_IMAGE=nginx@sha256:165ddde8751e75a1c907d24ef10d9f6deb08b57e0fe56caf67512486aff76d82
CLIENT_IMAGE=curlimages/curl@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40

command -v jq >/dev/null || { echo "FAIL setup: jq is required on the host" >&2; exit 1; }

RUN="hardtest-$$-$RANDOM"
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
security_count() { grep -c '^SECURITY:' <<<"$1" || true; }

XSS_Q='q=<script>alert(1)</script>'

# ---- test data ----------------------------------------------------------------------------------------------
mkdir -p "$WORK/conf.d"
cat > "$WORK/conf.d/test.conf" <<'CONF'
proxy_cache_path /var/cache/nginx/test_cache levels=1 keys_zone=test_cache:1m;
server {
    listen 80 default_server;
    server_name app.example.com;
    location / {
        proxy_pass http://backend:80;
    }
    # A location with an add_header of its own: by default nginx would drop the http-level headers here.
    location /location-header {
        add_header X-Location-Test 1;
        proxy_pass http://backend:80/;
    }
    # The image's rate-limit zones are usable from vhost configuration.
    location /login {
        limit_req zone=kickedro_login_1rs;
        proxy_pass http://backend:80/;
    }
    # Cached proxying, as a vhost snippet may set up: a response from the cache has no upstream status of its own.
    location /cached/ {
        proxy_cache test_cache;
        proxy_cache_valid any 1m;
        add_header X-Cache-Status $upstream_cache_status always;
        proxy_pass http://backend:80/;
    }
}
CONF
# A custom block page with characters nginx would otherwise interpret ($, quotes, backslash), two placeholders,
# near-misses that must stay literal, and a line longer than nginx's 4 KiB limit for one configuration token.
{
  printf '<!-- custom block page -->\n<p>Blocked. Reference: {{request_id}}.</p>\n'
  printf '%s\n' '<p>Literal: $5, $request_id, ${host}, "double quotes", back\slash, {{request_id} and {request_id}}.</p>'
  printf '<p>%s</p>\n' "$(head -c 6000 /dev/zero | tr '\0' 'x')"
  printf '<p>Again: {{request_id}}</p>\n'
} > "$WORK/block-page.html"
chmod 644 "$WORK/block-page.html"

# ---- 1. start-up validation (the entrypoint runs its scripts before 'nginx -t' / 'nginx -T') -------------------
# An invalid value stops the container with a message naming the variable and the allowed values.
CONTAINERS+=("$RUN-invalid")
docker run -d --name "$RUN-invalid" --network none -e MODSEC_RULE_ENGINE=Maybe "$IMAGE" >/dev/null \
  || fail invalid_refuses "could not start the container"
for _ in $(seq 1 50); do
  [ "$(docker inspect -f '{{.State.Running}}' "$RUN-invalid")" = false ] && break
  sleep 0.2
done
[ "$(docker inspect -f '{{.State.Running}}' "$RUN-invalid")" = false ] || fail invalid_refuses "still running after 10 s"
CODE=$(docker inspect -f '{{.State.ExitCode}}' "$RUN-invalid")
LOGS=$(docker logs "$RUN-invalid" 2>&1)
[ "$CODE" != 0 ] && grep 'MODSEC_RULE_ENGINE' <<<"$LOGS" | grep -qF 'On|DetectionOnly|Off' \
  && pass invalid_refuses || fail invalid_refuses "exit code $CODE, log: $LOGS"

# The settings check itself stops the container: a value that nginx and ModSecurity would accept (anything but "on"
# just switches the headers off) must still stop it, before any later entrypoint script and before nginx starts.
CONTAINERS+=("$RUN-invalid2")
docker run -d --name "$RUN-invalid2" --network none -e EDGE_SECURITY_HEADERS=yes "$IMAGE" >/dev/null \
  || fail invalid_stops_entrypoint "could not start the container"
for _ in $(seq 1 50); do
  [ "$(docker inspect -f '{{.State.Running}}' "$RUN-invalid2")" = false ] && break
  sleep 0.2
done
[ "$(docker inspect -f '{{.State.Running}}' "$RUN-invalid2")" = false ] || fail invalid_stops_entrypoint "still running after 10 s"
CODE=$(docker inspect -f '{{.State.ExitCode}}' "$RUN-invalid2")
LOGS=$(docker logs "$RUN-invalid2" 2>&1)
[ "$CODE" != 0 ] && grep 'EDGE_SECURITY_HEADERS' <<<"$LOGS" | grep -qF 'on|off' \
  && ! grep -qE '18-kickedro-render|start worker process' <<<"$LOGS" \
  && pass invalid_stops_entrypoint || fail invalid_stops_entrypoint "exit code $CODE, log: $LOGS"

# Every value form is validated: one invalid value per form, all reported before the container stops.
INVALID=(MODSEC_PARANOIA=5 MODSEC_ANOMALY_INBOUND=0 MODSEC_REQ_BODY_LIMIT=12ab MODSEC_AUDIT_LOG=relative.log
  MODSEC_DENY_STATUS=200 EDGE_CLIENT_HEADER_TIMEOUT=10 EDGE_LARGE_HEADER_BUFFERS=4 EDGE_SECURITY_HEADERS=yes)
ARGS=(); for kv in "${INVALID[@]}"; do ARGS+=(-e "$kv"); done
OUT=$(docker run --rm "${ARGS[@]}" "$IMAGE" nginx -t 2>&1) && fail invalid_values_refused "accepted: $OUT"
for kv in "${INVALID[@]}"; do
  grep -q "^ERROR: ${kv%%=*}=" <<<"$OUT" || fail invalid_values_refused "no error for ${kv%%=*} in: $OUT"
done
pass invalid_values_refused
# Header buffers smaller than nginx accepts are refused by the settings check (1k is the smallest size), not by nginx.
OUT=$(docker run --rm -e EDGE_LARGE_HEADER_BUFFERS='4 1023' "$IMAGE" nginx -t 2>&1) && fail buffers_minimum "accepted: $OUT"
grep -q "^ERROR: EDGE_LARGE_HEADER_BUFFERS=" <<<"$OUT" || fail buffers_minimum "not refused by the settings check: $OUT"
OUT=$(docker run --rm -e EDGE_LARGE_HEADER_BUFFERS='4 1k' "$IMAGE" nginx -t 2>&1) || fail buffers_minimum "4 1k refused: $OUT"
pass buffers_minimum

# Values at or stricter than the defaults print nothing.
OUT=$(docker run --rm -e EDGE_CLIENT_HEADER_TIMEOUT=5s -e EDGE_SEND_TIMEOUT=500ms -e EDGE_LARGE_HEADER_BUFFERS='2 8k' \
  -e MODSEC_ANOMALY_INBOUND=3 -e EDGE_KEEPALIVE_TIMEOUT=0 -e MODSEC_AUDIT_LOG=/var/tmp/audit.log \
  -e MODSEC_DENY_STATUS=406 -e MODSEC_PARANOIA=2 -e MODSEC_AUDIT_FORMAT=Native -e EDGE_BLOCK_PAGE=off \
  "$IMAGE" nginx -t 2>&1) || fail stricter_values_quiet "nginx -t failed: $OUT"
expect_eq stricter_values_quiet "$(security_count "$OUT")" 0

# Each weaker value prints exactly one SECURITY: line naming its variable (numbers, times and buffers compared).
WEAK=(EDGE_CLIENT_HEADER_TIMEOUT=1m EDGE_CLIENT_BODY_TIMEOUT=11s EDGE_LARGE_HEADER_BUFFERS='4 16k'
  MODSEC_ANOMALY_INBOUND=6 MODSEC_ANOMALY_OUTBOUND=5 EDGE_KEEPALIVE_TIMEOUT=1h MODSEC_AUDIT_LOG=off
  MODSEC_REQ_BODY_LIMIT=134217729 EDGE_HIDE_UPSTREAM_HEADERS=off)
ARGS=(); for kv in "${WEAK[@]}"; do ARGS+=(-e "$kv"); done
OUT=$(docker run --rm "${ARGS[@]}" -e EDGE_RATE_ZONES=off "$IMAGE" nginx -T 2>&1) || fail weaker_values_warn "nginx -T failed: $OUT"
expect_eq weaker_values_warn_count "$(security_count "$OUT")" "${#WEAK[@]}"
for kv in "${WEAK[@]}"; do
  [ "$(grep -c "^SECURITY: ${kv%%=*}=" <<<"$OUT")" = 1 ] || fail weaker_values_warn "no single line for ${kv%%=*}: $OUT"
done
pass weaker_values_warn
expect_eq rate_zones_off "$(grep -c '^limit_req_zone .*zone=kickedro_' <<<"$OUT" || true)" 0
OUT=$(docker run --rm -e EDGE_LARGE_HEADER_BUFFERS='8 8k' -e MODSEC_AUDIT_LOG=/dev/null "$IMAGE" nginx -t 2>&1) \
  || fail weaker_buffer_count "nginx -t failed: $OUT"
expect_eq weaker_buffer_count "$(grep -c '^SECURITY: EDGE_LARGE_HEADER_BUFFERS=' <<<"$OUT" || true)" 1
expect_eq weaker_audit_dev_null "$(grep -c '^SECURITY: MODSEC_AUDIT_LOG=' <<<"$OUT" || true)" 1

# The settings file is read strictly, like scripts/gen_settings_doc.py: a line with an extra or an empty field stops
# the container; a missing final newline does not lose the last setting.
TSV=$(docker run --rm --entrypoint cat "$IMAGE" /usr/local/share/kickedro/settings.tsv) || fail settings_file_strict "cannot read the settings file"
tsv_run() { # settings-file-content -> output of 'nginx -T' with that settings file (fails like the container does)
  printf '%s' "$1" > "$WORK/settings.tsv"; chmod 644 "$WORK/settings.tsv"
  docker run --rm -v "$WORK/settings.tsv:/usr/local/share/kickedro/settings.tsv:ro" "$IMAGE" nginx -T 2>&1
}
for bad in "$(sed '/^EDGE_SEND_TIMEOUT/s/$/\textra/' <<<"$TSV")" "$(sed '/^EDGE_SEND_TIMEOUT/s/\t10s\t/\t\t/' <<<"$TSV")"; do
  OUT=$(tsv_run "$bad"$'\n') && fail settings_file_strict "accepted a malformed line: $(grep '^EDGE_SEND_TIMEOUT' <<<"$bad")"
  grep -q 'ERROR: .*EDGE_SEND_TIMEOUT' <<<"$OUT" || fail settings_file_strict "no error naming the line: $OUT"
done
pass settings_file_strict
OUT=$(tsv_run "$TSV") || fail settings_file_no_final_newline "nginx -T failed: $OUT"
grep -qxF 'limit_req_zone $binary_remote_addr zone=kickedro_login_1rs:10m rate=1r/s;' <<<"$OUT" \
  && pass settings_file_no_final_newline || fail settings_file_no_final_newline "the last setting (EDGE_RATE_ZONES) was lost"

# The defaults end up in nginx's configuration (keepalive_timeout replaces the one of the stock nginx.conf).
DUMP=$(docker run --rm "$IMAGE" nginx -T 2>&1) || fail defaults_rendered "nginx -T failed: $DUMP"
for line in 'server_tokens off;' 'client_header_timeout 10s;' 'client_body_timeout 10s;' 'send_timeout 10s;' \
  'keepalive_timeout 15s;' 'large_client_header_buffers 4 8k;' 'add_header_inherit merge;' \
  'modsecurity_transaction_id "$request_id";' \
  'limit_req_zone $binary_remote_addr zone=kickedro_perip_10rs:10m rate=10r/s;' \
  'limit_req_zone $binary_remote_addr zone=kickedro_login_1rs:10m rate=1r/s;'; do
  grep -qxF "$line" <<<"$DUMP" || fail defaults_rendered "missing: $line"
done
expect_eq defaults_rendered "$(grep -c 'keepalive_timeout' <<<"$DUMP" || true)" 1

# ---- 2. live tests ------------------------------------------------------------------------------------------
new_network() { # name subnet4
  docker network create --subnet "$2" "$1" >/dev/null 2>"$WORK/net.err" || return 1
  NETWORKS+=("$1")
}
start() { # container-name [docker run args...] image [args]
  local name=$1; shift
  CONTAINERS+=("$name")   # registered first, so a failing 'docker run' cannot leak it
  docker run -d --name "$name" --network "$NET" "$@" >/dev/null
}
status() { # url [curl args...] -> http status
  local u=$1; shift
  docker exec "$CLIENT" curl -s -g -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: app.example.com' "$@" "$u" || true
}
wait_ready() { # container
  for _ in $(seq 1 50); do
    [ "$(docker inspect -f '{{.State.Running}}' "$1")" = true ] || break
    [ "$(status "http://$1/")" = 200 ] && return 0
    sleep 0.2
  done
  docker logs "$1" >&2 || true
  fail "wait_ready $1" "did not come up"
}
request() { # url [curl args...] -> sets STATUS, HEAD (status line and headers) and BODY, with CRs removed
  local u=$1 resp; shift
  resp=$(docker exec "$CLIENT" curl -s -g -i --max-time 10 -H 'Host: app.example.com' "$@" "$u") || resp=''
  resp=${resp//$'\r'/}
  HEAD=${resp%%$'\n\n'*}
  case $resp in *$'\n\n'*) BODY=${resp#*$'\n\n'};; *) BODY='';; esac
  STATUS=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' <<<"$HEAD")
}
header() { # name -> the values of that header in HEAD, one per line (nothing if absent)
  awk -v h="$1" 'BEGIN { h = tolower(h) ":" } tolower(substr($0, 1, length(h))) == h { sub(/^[^:]*: */, ""); print }' <<<"$HEAD"
}
audit_id() { # container request-id -> that transaction's audit entry (JSON) once present (up to 5 s)
  local out
  for _ in $(seq 1 25); do
    out=$(docker logs "$1" 2>/dev/null | grep '^{"transaction"' \
      | jq -c --arg id "$2" 'select(.transaction.unique_id == $id)' 2>/dev/null || true)
    [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    sleep 0.2
  done
  return 1
}
reference() { # -> the one request ID (32 hex digits) in BODY, or nothing
  local ids
  ids=$(grep -oE '[0-9a-f]{32}' <<<"$BODY" | sort -u || true)
  [ -n "$ids" ] && [ "$(wc -l <<<"$ids")" = 1 ] && echo "$ids" || true
}

# Random /24 from the benchmarking range (RFC 2544), so concurrent runs on a shared machine do not collide.
NET="$RUN-net"
for _ in $(seq 1 20); do
  new_network "$NET" "198.$((18 + RANDOM % 2)).$((RANDOM % 256)).0/24" && break
done
[ "${#NETWORKS[@]}" = 1 ] || { cat "$WORK/net.err" >&2; fail network "could not create the test network"; }

CLIENT="$RUN-client"
start "$CLIENT" --entrypoint sleep "$CLIENT_IMAGE" 3600
start "$RUN-backend" --network-alias backend -e NGINX_ENTRYPOINT_QUIET_LOGS=1 \
  -v "$HERE/fixtures/headers-backend.conf:/etc/nginx/conf.d/backend.conf:ro" "$BACKEND_IMAGE"
edge() { # name [docker run args...]
  local name=$1; shift
  start "$RUN-$name" -v "$WORK/conf.d:/etc/nginx/conf.d:ro" "$@" "$IMAGE"
}
edge def
edge weak -e MODSEC_RULE_ENGINE=DetectionOnly -e EDGE_SECURITY_HEADERS=off -e EDGE_SERVER_TOKENS=on
edge plain -e EDGE_BLOCK_PAGE=off -e EDGE_HIDE_UPSTREAM_HEADERS=off
edge custom -e MODSEC_DENY_STATUS=406 -v "$WORK/block-page.html:/etc/nginx/kickedro/block-page.html:ro"
for e in def weak plain custom; do wait_ready "$RUN-$e"; done

# defaults_quiet: no SECURITY: line, the three security headers, no nginx version, backend headers hidden.
LOGS=$(docker logs "$RUN-def" 2>&1)
grep -q 'SECURITY:' <<<"$LOGS" && fail defaults_quiet "SECURITY: line with the defaults: $(grep 'SECURITY:' <<<"$LOGS")"
request "http://$RUN-def/"
[ "$STATUS" = 200 ] || fail defaults_quiet "status $STATUS"
expect_eq security_header_nosniff "$(header X-Content-Type-Options)" nosniff
expect_eq security_header_referrer "$(header Referrer-Policy)" strict-origin-when-cross-origin
expect_eq security_header_frame "$(header X-Frame-Options)" SAMEORIGIN
expect_eq server_tokens_off "$(header Server)" nginx
for h in X-Powered-By X-AspNet-Version X-AspNetMvc-Version; do
  [ -z "$(header "$h")" ] || fail upstream_headers_hidden "$h: $(header "$h")"
done
pass upstream_headers_hidden
pass defaults_quiet

# The backend does send them: with EDGE_HIDE_UPSTREAM_HEADERS=off they come through.
request "http://$RUN-plain/"
expect_eq hide_upstream_headers_off "$(header X-Powered-By)|$(header X-AspNet-Version)|$(header X-AspNetMvc-Version)" \
  'PHP/8.3|4.0.30319|5.2'

# A location with its own add_header still gets the security headers (add_header_inherit merge).
request "http://$RUN-def/location-header"
expect_eq headers_survive_location_add_header \
  "$(header X-Location-Test)|$(header X-Content-Type-Options)|$(header Referrer-Policy)|$(header X-Frame-Options)" \
  '1|nosniff|strict-origin-when-cross-origin|SAMEORIGIN'

# A backend's own security headers are kept, not doubled with a different value.
request "http://$RUN-def/app-headers"
expect_eq app_headers_kept "$(header X-Content-Type-Options)|$(header Referrer-Policy)|$(header X-Frame-Options)" \
  'nosniff|no-referrer|DENY'

# The block page's sub_filter is active only for nginx's own error page with the deny status: other HTML responses
# keep their Content-Length, (strong) ETag and Last-Modified.
request "http://$RUN-def/index.html"
ETAG=$(header ETag)
[ "$STATUS" = 200 ] && [ -n "$(header Content-Length)" ] && [ -n "$(header Last-Modified)" ] && [ "${ETAG:0:1}" = '"' ] \
  && pass html_responses_untouched || fail html_responses_untouched "$HEAD"

# A backend's own error page with the deny status is the backend's: it passes the edge unchanged (with its
# Content-Length), directly and from the edge's cache, where the response has no upstream status of its own.
expect_backend_page() { # name edge path -> the backend's page for path, unchanged through edge, uncached and cached
  local name=$1 edge=$2 path=$3 want_body want_len want_status
  request "http://backend$path"
  want_status=$STATUS want_body=$BODY want_len=$(header Content-Length)
  [ -n "$want_len" ] || fail "$name" "the backend sent no Content-Length: $HEAD"
  request "http://$edge$path"
  [ "$STATUS|$(header Content-Length)" = "$want_status|$want_len" ] && [ "$BODY" = "$want_body" ] \
    || fail "$name" "changed by the edge: $HEAD"$'\n'"$BODY"
  pass "$name"
  request "http://$edge/cached$path"  # stores it
  request "http://$edge/cached$path"
  [ "$(header X-Cache-Status)" = HIT ] || fail "${name}_cached" "not served from the cache: $HEAD"
  [ "$STATUS|$(header Content-Length)" = "$want_status|$want_len" ] && [ "$BODY" = "$want_body" ] \
    || fail "${name}_cached" "changed by the edge: $HEAD"$'\n'"$BODY"
  pass "${name}_cached"
}
expect_backend_page backend_deny_page_untouched "$RUN-def" /forbidden
expect_backend_page backend_deny_page_untouched_406 "$RUN-custom" /not-acceptable

# Rate-limit zone from a vhost location: the second request within the same second is refused (503).
expect_eq rate_zone_usable "$(docker exec "$CLIENT" curl -s -w '%{http_code} ' --max-time 10 -H 'Host: app.example.com' \
  -o /dev/null "http://$RUN-def/login" -o /dev/null "http://$RUN-def/login" || true)" '200 503 '

# block_page_reference: the deny status, text/html, a reference that is the audit entry's transaction ID, and no
# rule IDs or matched data in the body.
request "http://$RUN-def/?t=bp1&$XSS_Q"
expect_eq block_page_status "$STATUS" 403
case "$(header Content-Type)" in text/html*) ;; *) fail block_page_reference "Content-Type: $(header Content-Type)";; esac
grep -q 'blocked for security reasons' <<<"$BODY" || fail block_page_reference "not the built-in page: $BODY"
ID=$(reference)
[ -n "$ID" ] || fail block_page_reference "no single reference ID in: $BODY"
grep -qE '[0-9]{6}|alert\(|<script' <<<"${BODY//$ID/}" && fail block_page_reference "rule details in the body: $BODY"
ENTRY=$(audit_id "$RUN-def" "$ID") || fail block_page_reference "no audit entry with transaction ID $ID"
jq -e '(.transaction.request.uri | contains("t=bp1"))
  and any(.transaction.messages[]; .details.ruleId | startswith("941"))' <<<"$ENTRY" >/dev/null \
  || fail block_page_reference "the audit entry for $ID is not the blocked XSS request: $ENTRY"
pass block_page_reference
# The same on a cached location: ModSecurity blocks before the cache is consulted.
request "http://$RUN-def/cached/?t=bp4&$XSS_Q"
ID=$(reference)
[ "$STATUS" = 403 ] && [ -n "$ID" ] && audit_id "$RUN-def" "$ID" >/dev/null \
  && pass block_page_cached_location || fail block_page_cached_location "status $STATUS, body: $BODY"
expect_eq headers_on_block_page "$(header X-Content-Type-Options)|$(header Referrer-Policy)|$(header X-Frame-Options)" \
  'nosniff|strict-origin-when-cross-origin|SAMEORIGIN'

# EDGE_BLOCK_PAGE=off: nginx's plain error page, no reference.
request "http://$RUN-plain/?t=bp2&$XSS_Q"
[ "$STATUS" = 403 ] && grep -qF '<center><h1>403 Forbidden</h1></center>' <<<"$BODY" \
  && ! grep -qE '[0-9a-f]{32}' <<<"$BODY" && pass block_page_off || fail block_page_off "status $STATUS, body: $BODY"

# A mounted page replaces the built-in one, exactly, with every {{request_id}} replaced (deny status 406 here).
request "http://$RUN-custom/?t=bp3&$XSS_Q"
expect_eq block_page_custom_status "$STATUS" 406
ID=$(grep -oE '[0-9a-f]{32}' <<<"$BODY" | head -1 || true)
EXPECTED=$(sed "s/{{request_id}}/$ID/g" "$WORK/block-page.html")
[ -n "$ID" ] && [ "$BODY" = "$EXPECTED" ] \
  || fail block_page_custom "body differs from the page: $(diff <(echo "$EXPECTED") <(echo "$BODY") | head -c 600)"
audit_id "$RUN-custom" "$ID" >/dev/null || fail block_page_custom "no audit entry with transaction ID $ID"
pass block_page_custom
# Also for Chrome, which nginx otherwise sends padding comments after a short error page.
request "http://$RUN-custom/?t=bp5&$XSS_Q" -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'
ID=$(grep -oE '[0-9a-f]{32}' <<<"$BODY" | head -1 || true)
EXPECTED=$(sed "s/{{request_id}}/$ID/g" "$WORK/block-page.html")
[ "$STATUS" = 406 ] && [ -n "$ID" ] && [ "$BODY" = "$EXPECTED" ] \
  && pass block_page_custom_chrome || fail block_page_custom_chrome "body differs: $(diff <(echo "$EXPECTED") <(echo "$BODY") | head -c 600)"

# weakened_warns: exactly one SECURITY: line per weakened setting, and the container runs; the settings take effect.
LOGS=$(docker logs "$RUN-weak" 2>&1)
expect_eq weakened_warns_count "$(security_count "$LOGS")" 3
for v in MODSEC_RULE_ENGINE EDGE_SECURITY_HEADERS EDGE_SERVER_TOKENS; do
  [ "$(grep -c "^SECURITY: $v=" <<<"$LOGS")" = 1 ] || fail weakened_warns "no single line for $v: $LOGS"
done
[ "$(docker inspect -f '{{.State.Running}}' "$RUN-weak")" = true ] || fail weakened_warns "not running"
pass weakened_warns
request "http://$RUN-weak/?t=wk1&$XSS_Q"
expect_eq weakened_detection_only "$STATUS" 200
expect_eq weakened_no_security_headers "$(header X-Content-Type-Options)$(header Referrer-Policy)$(header X-Frame-Options)" ''
case "$(header Server)" in nginx/[0-9]*) pass weakened_server_tokens;; *) fail weakened_server_tokens "Server: $(header Server)";; esac

# slow_client_cut: headers sent one byte per second; nginx cuts the connection after client_header_timeout (10 s).
# At least 8 s shows the connection was open until then; nc is stopped after 40 s if nginx never cuts it.
SLOW=$(docker exec "$CLIENT" sh -c '
  s=$(printf "GET /?slow HTTP/1.1\r\nHost: app.example.com\r\nX-Slow: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  start=$(date +%s)
  { while [ -n "$s" ]; do printf "%s" "${s%"${s#?}"}"; s=${s#?}; sleep 1; done; } 2>/dev/null \
    | timeout 40 nc "$1" 80 >/dev/null 2>&1 || true
  echo $(( $(date +%s) - start ))' sh "$RUN-def")
[ "$SLOW" -ge 8 ] && [ "$SLOW" -le 15 ] && pass slow_client_cut || fail slow_client_cut "connection lasted ${SLOW}s"

echo "ALL PASS"
