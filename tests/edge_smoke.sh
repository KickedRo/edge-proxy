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
head -c 20000000 /dev/urandom | base64 -w0 | tr -dc 'a-zA-Z' | head -c 20000000 > "$WORK/upload.txt" || true
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
  docker run -d --name "$name" --network "$net" "$@" >/dev/null
  CONTAINERS+=("$name")
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
audit_lines() { # container marker -> audit JSON lines whose request uri contains marker
  docker exec "$1" cat /var/log/nginx/modsec_audit.log 2>/dev/null \
    | jq -c --arg m "$2" 'select((.transaction.request.uri // "") | contains($m))' 2>/dev/null || true
}
wait_audit() { # container marker -> prints the lines once present (up to 5 s)
  local i out
  for i in $(seq 1 25); do
    out=$(audit_lines "$1" "$2")
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

DUMP=$(docker run --rm "$IMAGE" nginx -T 2>&1)
grep -q '^load_module modules/ngx_http_modsecurity_module.so;' <<<"$DUMP" \
  && grep -q 'modsecurity on;' <<<"$DUMP" || fail module_loaded
pass module_loaded

grep -q 'worker_connections  10240;' <<<"$DUMP" && grep -q 'worker_rlimit_nofile 20480;' <<<"$DUMP" \
  && grep -q 'include /etc/nginx/toplevel.conf.d/\*.conf;' <<<"$DUMP" \
  && docker run --rm --entrypoint sh "$IMAGE" -c 'test -d /etc/nginx/toplevel.conf.d && test -d /etc/nginx/dhparam && test -d /etc/nginx/certs && test -d /usr/share/nginx/html/errors && test -s /etc/nginx/network_internal.conf' \
  || fail nginx_proxy_layout
pass nginx_proxy_layout

docker run --rm --entrypoint sh "$IMAGE" -c '! command -v gcc cc g++ c++ make >/dev/null' || fail no_compilers "build tools in the final image"
pass no_compilers

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
# (Expect: is cleared because curl adds "Expect: 100-continue" to large uploads, which CRS rule 920450 restricts.)
expect_eq large_upload "$(docker cp "$WORK/upload.txt" "$CLIENT:/tmp/upload.txt" >/dev/null && status "http://$RUN-on/" -H 'Expect:' -F 'file=@/tmp/upload.txt;type=application/octet-stream' --max-time 120)" 200

# ACME HTTP-01 challenges are exempt: no block, no audit entry.
ACME='/.well-known/acme-challenge/x?t=acme1&q=<script>alert(1)</script>'
ACME_CODE=$(status "http://$RUN-on$ACME")
[ "$ACME_CODE" != 403 ] && [ "$ACME_CODE" = 200 ] || fail acme_exempt "status $ACME_CODE"
# A later blocked request proves the (serial) audit log has caught up before we look for the ACME entry.
status "http://$RUN-on/?t=xss2&q=<script>alert(2)</script>" >/dev/null
wait_audit "$RUN-on" 't=xss2' >/dev/null || fail acme_exempt "audit log did not catch up"
[ -z "$(audit_lines "$RUN-on" 't=acme1')" ] && pass acme_exempt || fail acme_exempt "audit entry exists for the ACME request"

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
expect_eq audit_off_blocks "$(status "http://$RUN-auditoff$XSS")" 403
sleep 1
[ -z "$(docker exec "$RUN-auditoff" sh -c 'cat /var/log/nginx/modsec_audit.log 2>/dev/null' || true)" ] \
  && pass audit_off || fail audit_off "audit log has content with MODSEC_AUDIT_LOG=off"

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
