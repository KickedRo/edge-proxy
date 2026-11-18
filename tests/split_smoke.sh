#!/usr/bin/env bash
# Smoke test for the separate-containers layout: tests/split_smoke.sh EDGE_IMAGE GEN_IMAGE
# Runs the edge image (nginx + ModSecurity) and the gen image (docker-gen + nginx-proxy's template, with its real
# default command) the way nginx-proxy's docker-compose-separate-containers.yml does, in front of a tiny echo backend
# and a plain nginx backend that sends headers of its own. HTTP/3 is tested from a client container on the test network
# (the per-run image ${RUN}-h3client, built from tests/fixtures/h3-client.Dockerfile, removed on exit). The last section
# recreates gen with its hard off switches (EDGE_HTTP2, EDGE_HTTP3), and compares its template's output with that of
# nginx-proxy's template at the pinned commit, which it downloads from GitHub.
# Prints "PASS <name>" per assertion, stops at the first failure. The compose project, its volumes, containers
# and every temp file are removed on exit (also on failure). Host ports: 127.0.0.1 only, taken from PORT_1 and
# PORT_2 when they are set, else picked by Docker.
set -euo pipefail

EDGE=${1:?usage: tests/split_smoke.sh EDGE_IMAGE GEN_IMAGE}
GEN=${2:?usage: tests/split_smoke.sh EDGE_IMAGE GEN_IMAGE}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Test helpers, pinned by digest: whoami (same as edge_smoke.sh), and plain nginx sending headers of its own
# (tests/fixtures/headers-backend.conf, same as hardening_smoke.sh).
BACKEND_IMAGE=traefik/whoami@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab
HEADERS_BACKEND_IMAGE=nginx@sha256:165ddde8751e75a1c907d24ef10d9f6deb08b57e0fe56caf67512486aff76d82

command -v jq >/dev/null || { echo "FAIL setup: jq is required on the host" >&2; exit 1; }
command -v curl >/dev/null || { echo "FAIL setup: curl is required on the host" >&2; exit 1; }

RUN="splittest-$$-$RANDOM"
WORK=$(mktemp -d)
export RUN BACKEND_IMAGE HEADERS_BACKEND_IMAGE EDGE_IMAGE=$EDGE GEN_IMAGE=$GEN HTTP_PORT=${PORT_1:-} HTTPS_PORT=${PORT_2:-}
# gen's switches stay at their default (on) until section 5 sets them, whatever the calling shell has.
unset EDGE_HTTP2 EDGE_HTTP3
compose() { docker compose -p "$RUN" --profile '*' -f "$HERE/compose.smoke.yml" "$@"; }
notice_restarts() { # container -> a NOTICE line when edge's restart policy restarted it (compose.smoke.yml says why), so
  # a crash the policy hid still shows in the CI log, with nginx's errors from before its last start
  local info n errors
  info=$(docker inspect -f '{{.RestartCount}} {{.State.StartedAt}}' "$1" 2>/dev/null) || return 0
  n=${info%% *}
  [ "$n" -gt 0 ] 2>/dev/null || return 0
  errors=$(docker logs --until "${info#* }" "$1" 2>&1 | grep -E '\[(emerg|alert|crit)\]' | tail -5) || true
  echo "NOTICE: edge restarted $n time(s) at start${errors:+; errors before its last start:}" >&2
  [ -z "$errors" ] || printf '%s\n' "$errors" >&2
}
cleanup() {
  notice_restarts "$RUN-edge"
  compose down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
  # Anything compose could not remove (a failed 'up' before the project existed).
  docker rm -f -v "$RUN-edge" "$RUN-gen" "$RUN-whoami" "$RUN-broken" "$RUN-headers" "$RUN-h3" >/dev/null 2>&1 || true
  docker rmi -f "$RUN-h3client" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+: $2}" >&2; exit 1; }
expect_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }

# ---- helpers ----------------------------------------------------------------------------------------------
https_status() { # path [curl args...] -> status over HTTPS to the edge, SNI/Host app.example.com
  local p=$1; shift
  curl -s -g -k -o /dev/null -w '%{http_code}' --max-time 10 --resolve "app.example.com:$HTTPS_HOST_PORT:127.0.0.1" \
    "$@" "https://app.example.com:$HTTPS_HOST_PORT$p" || true
}
https_request() { # host path -> sets STATUS, HEAD (status line and headers) and BODY of a GET over HTTPS, CRs removed
  local resp
  resp=$(curl -s -g -k -i --max-time 10 --resolve "$1:$HTTPS_HOST_PORT:127.0.0.1" "https://$1:$HTTPS_HOST_PORT$2") || resp=''
  resp=${resp//$'\r'/}
  HEAD=${resp%%$'\n\n'*}
  case $resp in *$'\n\n'*) BODY=${resp#*$'\n\n'};; *) BODY='';; esac
  STATUS=$(sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' <<<"$HEAD")
}
header() { # name -> the values of that header in HEAD, one per line (nothing if absent)
  awk -v h="$1" 'BEGIN { h = tolower(h) ":" } tolower(substr($0, 1, length(h))) == h { sub(/^[^:]*: */, ""); print }' <<<"$HEAD"
}
http_status() { # path [curl args...]
  local p=$1; shift
  curl -s -g -o /dev/null -w '%{http_code}' --max-time 10 --resolve "app.example.com:$HTTP_HOST_PORT:127.0.0.1" \
    "$@" "http://app.example.com:$HTTP_HOST_PORT$p" || true
}
wait_until() { # seconds name command... -> polls until the command succeeds, by the clock (a probe that is slow itself
  # does not stretch the limit); on timeout dumps the logs and fails
  local secs=$1 what=$2 end; shift 2
  end=$((SECONDS + secs))
  until "$@" >/dev/null 2>&1; do
    if [ "$SECONDS" -ge "$end" ]; then
      docker logs "$RUN-gen" 2>&1 | tail -20 >&2 || true
      docker logs "$RUN-edge" 2>&1 | tail -20 >&2 || true
      fail "$what" "not true after ${secs}s"
    fi
    sleep 0.2
  done
}
edge_conf_has() { docker exec "$RUN-edge" grep -q -- "$1" /etc/nginx/conf.d/default.conf; }
edge_conf_lacks() { ! edge_conf_has "$1"; }
https_is_200() { [ "$(https_status /)" = 200 ]; }
http_is_301() { [ "$(http_status /)" = 301 ]; }
volume_run() { # volume-suffix docker-run-args... -> runs a throwaway gen-image container as root with the volume at /v
  local vol="${RUN}_$1"; shift
  docker run --rm -v "$vol:/v" "$@"
}
worker_pids() { # PIDs of the edge's nginx worker processes, sorted as comm needs (the image has no ps/pgrep)
  docker exec "$RUN-edge" sh -c 'for p in /proc/[0-9]*; do
    case "$(tr "\0" " " < "$p/cmdline" 2>/dev/null)" in "nginx: worker"*) echo "${p#/proc/}";; esac; done' | sort
}
audit_xss() { # marker [transaction-id] -> true when the edge's audit log (stdout, JSON) has an entry whose request
  # uri contains marker (and whose transaction ID is the given one) with a match of a CRS XSS rule (941xxx)
  docker logs "$RUN-edge" 2>/dev/null | grep '^{"transaction"' \
    | jq -e --arg m "$1" --arg id "${2:-}" 'select((.transaction.request.uri // "") | contains($m))
        | select($id == "" or .transaction.unique_id == $id)
        | select(any(.transaction.messages[]?; (.details.ruleId // "") | startswith("941")))' >/dev/null 2>&1
}
# An attack request must be refused with 403 AND be blocked by the CRS in ModSecurity: a 403 from anything else would
# not do.
expect_waf_block() { # name marker
  local got
  got=$(https_status "/?t=$2&q=<script>alert(1)</script>")
  [ "$got" = 403 ] || fail "$1" "expected '403', got '$got'"
  wait_until 10 "$1" audit_xss "t=$2"
  pass "$1"
}

# ---- 0. the image's own configuration ---------------------------------------------------------------------
# The default command is that of nginx-proxy's Dockerfile.dockergen at the pinned ref. The entrypoint is gen's settings
# check, which then hands the command to nginx-proxy's entrypoint (/app/docker-entrypoint.sh). The test runs them
# unchanged (compose sets no command), only NGINX_CONTAINER_LABEL is set per run.
EXPECTED_CMD='["/app/kickedro-entrypoint.sh"] ["docker-gen","-watch","-wait","100ms:500ms","-event-filter","event=connect","-event-filter","event=disconnect","-notify-filter","label=$NGINX_CONTAINER_LABEL","/app/nginx.tmpl","/etc/nginx/conf.d/default.conf"]'
ACTUAL=$(docker inspect "$GEN" --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' 2>&1) \
  || fail default_command "cannot inspect $GEN: $ACTUAL"
expect_eq default_command "$ACTUAL" "$EXPECTED_CMD"

PINNED_REF=$(sed -n 's/^NGINX_PROXY_REF=//p' "$HERE/../pins.env")
[ -n "$PINNED_REF" ] || fail nginx_proxy_ref "NGINX_PROXY_REF not found in pins.env"
ENVS=$(docker inspect "$GEN" --format '{{range .Config.Env}}{{println .}}{{end}}') || fail nginx_proxy_ref "cannot inspect $GEN"
expect_eq nginx_proxy_ref "$(sed -n 's/^NGINX_PROXY_VERSION=//p' <<<"$ENVS")" "$PINNED_REF"

# The licence texts of what the gen image contains are shipped.
LIC=$(docker run --rm --entrypoint sh "$GEN" -c '
  for f in docker-gen/LICENSE nginx-proxy/LICENSE edge-proxy/LICENSE edge-proxy/NOTICE; do
    [ -s "/usr/share/licenses/$f" ] || { echo "missing or empty: $f"; exit 1; }
  done
  echo ok' 2>&1) || fail licenses_shipped "$LIC"
expect_eq licenses_shipped "$LIC" ok

# The Go version and module list the release manifest is made from (go version -m of docker-gen).
MODULES=$(docker run --rm --pull=never --network none --entrypoint cat "$GEN" /usr/local/share/doc/docker-gen/go-modules.txt 2>&1) \
  || fail gen_go_modules_listed "cannot read go-modules.txt: $MODULES"
grep -qE '^[[:space:]]*path[[:space:]]' <<<"$MODULES" && grep -qE '^[[:space:]]*dep[[:space:]]' <<<"$MODULES" \
  && pass gen_go_modules_listed || fail gen_go_modules_listed "no path line or no dep line in go-modules.txt"

# ---- 1. bring the layout up ---------------------------------------------------------------------------------
# Create (not start) first, so the volumes exist and the certificates can be put in before anything runs.
OUT=$(compose up --no-start 2>&1) || fail compose_create "$OUT"
OUT=$(volume_run nginx_certs --entrypoint sh "$GEN" -c '
  set -e; cd /v
  for h in app.example.com broken.example.com headers.example.com h3.example.com; do
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$h" -addext "subjectAltName=DNS:$h" \
      -keyout "$h.key" -out "$h.crt" 2>/dev/null
    chmod 600 "$h.key"
  done' 2>&1) || fail setup "could not create the self-signed certificates: $OUT"
# nginx-proxy's documented proxy-wide file (its README, "Proxy-wide"), in the conf.d volume next to gen's default.conf.
OUT=$(volume_run nginx_conf --entrypoint sh "$GEN" -c \
  "{ echo 'server_tokens off;'; echo 'client_max_body_size 100m;'; } > /v/my_proxy.conf" 2>&1) \
  || fail setup "could not write my_proxy.conf: $OUT"
OUT=$(compose up -d whoami headers h3 nginx-proxy nginx-proxy-gen 2>&1) || fail compose_up "$OUT"

HTTP_HOST_PORT=$(compose port nginx-proxy 80 | sed 's/.*://') || fail setup "could not read the published HTTP port"
HTTPS_HOST_PORT=$(compose port nginx-proxy 443 | sed 's/.*://') || fail setup "could not read the published HTTPS port"
[ -n "$HTTP_HOST_PORT" ] && [ -n "$HTTPS_HOST_PORT" ] || fail setup "could not read the published ports"

# ---- 2. generation, routing, WAF ---------------------------------------------------------------------------
wait_until 30 generated edge_conf_has 'app.example.com'
pass generated
wait_until 30 https_up https_is_200
# Right after a reload, workers of the previous configuration can still answer for a moment, so wait for the
# new answer instead of sampling once.
wait_until 30 http_redirects_to_https http_is_301
expect_eq http_redirects_to_https "$(http_status /)" 301
expect_eq https_ok "$(https_status /)" 200
curl -s -k --max-time 10 --resolve "app.example.com:$HTTPS_HOST_PORT:127.0.0.1" "https://app.example.com:$HTTPS_HOST_PORT/" \
  | grep -q '^Hostname:' && pass backend_reached || fail backend_reached "response is not whoami's"

expect_waf_block waf_on_after_gen xss_gen

# The proxy-wide file works as with nginx-proxy: the edge gave way on server_tokens (NOTICE in its log), and the file's
# client_max_body_size applies to the generated vhosts (a 2 MB upload passes; nginx's default 1m would refuse it).
grep -q '^NOTICE: /etc/nginx/conf.d/my_proxy.conf:1 sets "server_tokens off"' <<<"$(docker logs "$RUN-edge" 2>&1)" \
  || fail proxy_wide_file "no NOTICE line for my_proxy.conf in the edge's log"
head -c 2000000 /dev/zero | tr '\0' a > "$WORK/upload.txt"
expect_eq proxy_wide_file "$(https_status / -H 'Expect:' -F "file=@$WORK/upload.txt;type=application/octet-stream")" 200

# Expect is allowed by default because it stays at the edge: an upload with "Expect: 100-continue" over HTTP/1.1
# passes, and whoami's echo of the request it got through the generated vhost has the probe header but no Expect.
expect_eq expect_upload "$(https_status / --http1.1 -H 'Expect: 100-continue' -F "file=@$WORK/upload.txt;type=application/octet-stream")" 200
ECHO=$(curl -s -k --http1.1 --max-time 10 --resolve "app.example.com:$HTTPS_HOST_PORT:127.0.0.1" -H 'X-Probe: expect-test' \
  -H 'Expect: 100-continue' --data 'a=1' "https://app.example.com:$HTTPS_HOST_PORT/" || true)
grep -qx 'X-Probe: expect-test' <<<"${ECHO//$'\r'/}" || fail expect_not_forwarded "not whoami's echo: $ECHO"
! grep -qi '^Expect:' <<<"$ECHO" && pass expect_not_forwarded || fail expect_not_forwarded "the backend got Expect: $ECHO"

# The edge's hardening reaches the generated vhosts. headers.example.com's backend sends version headers of its own;
# its generated HTTPS server block adds HSTS (an add_header of its own, which by default drops the http-level ones).
headers_https_is_200() { https_request headers.example.com /; [ "$STATUS" = 200 ]; }
wait_until 30 headers_vhost_up headers_https_is_200
https_request headers.example.com /
[ -n "$(header Strict-Transport-Security)" ] || fail headers_on_hsts_vhost "no HSTS header, so not the generated HTTPS vhost: $HEAD"
expect_eq headers_on_hsts_vhost "$(header X-Content-Type-Options)|$(header Referrer-Policy)|$(header X-Frame-Options)" \
  'nosniff|strict-origin-when-cross-origin|SAMEORIGIN'
expect_eq upstream_headers_hidden_generated "$(header X-Powered-By)$(header X-AspNet-Version)$(header X-AspNetMvc-Version)" ''
expect_eq server_tokens_off_generated "$(header Server)" nginx

# The block page on a generated vhost, whose "location /" proxies everything to the backend: the deny status, the
# page, and a reference that is the transaction ID of this request's audit entry (with a CRS XSS match).
https_request app.example.com '/?t=bp_gen&q=<script>alert(1)</script>'
[ "$STATUS" = 403 ] || fail block_page_generated_vhost "status $STATUS"
case "$(header Content-Type)" in text/html*) ;; *) fail block_page_generated_vhost "Content-Type: $(header Content-Type)";; esac
grep -q 'blocked for security reasons' <<<"$BODY" || fail block_page_generated_vhost "not the block page: $BODY"
REF=$(grep -oE '[0-9a-f]{32}' <<<"$BODY" | sort -u || true)
[ -n "$REF" ] && [ "$(wc -l <<<"$REF")" = 1 ] || fail block_page_generated_vhost "no single reference in: $BODY"
wait_until 10 block_page_generated_vhost audit_xss t=bp_gen "$REF"
pass block_page_generated_vhost

# The reload docker-gen triggers (SIGHUP) must take effect, and ModSecurity must come up again with it. A rejected
# reload leaves the old workers serving (see the broken snippet below), so a 403 alone proves nothing: require new
# worker processes, no nginx error since the signal, then a logged block.
OLD_PIDS=$(worker_pids) || fail reload_keeps_waf "cannot list the edge's worker processes"
[ -n "$OLD_PIDS" ] || fail reload_keeps_waf "no nginx worker found before the reload"
SINCE=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
docker kill -s HUP "$RUN-edge" >/dev/null || fail reload_keeps_waf "cannot signal the edge container"
workers_replaced() {
  local now; now=$(worker_pids)
  [ -n "$now" ] && [ -z "$(comm -12 <(echo "$OLD_PIDS") <(echo "$now"))" ]
}
wait_until 20 reload_keeps_waf workers_replaced
if docker logs --since "$SINCE" "$RUN-edge" 2>&1 | grep -E '\[(emerg|alert)\]' >&2; then
  fail reload_keeps_waf "nginx reported an error during the reload"
fi
expect_waf_block reload_keeps_waf xss_reload

# The entrypoint copied an RFC 7919 group (pre-generated in the image, not generated at start) into the shared
# volume, and the template switched ssl_dhparam on.
volume_run nginx_dhparam --entrypoint sh "$GEN" -c 'test -s /v/dhparam.pem' && pass dhparam_created \
  || fail dhparam_created "dhparam.pem is missing or empty in the dhparam volume"
edge_conf_has 'ssl_dhparam /etc/nginx/dhparam/dhparam.pem;' && pass dhparam_used || fail dhparam_used "not in default.conf"

# ---- 3. a broken per-vhost snippet is caught by 'nginx -t' ---------------------------------------------------
# nginx-proxy includes vhost.d/<VIRTUAL_HOST> into that host's server blocks. The fixture goes to a second backend's
# vhost (broken.example.com), so app.example.com's upstream is untouched.
docker exec "$RUN-edge" nginx -t >/dev/null 2>&1 || fail nginx_t_before "nginx -t fails before the broken snippet"
OUT=$(volume_run nginx_vhost -v "$HERE/fixtures/vhost.d:/f:ro" --entrypoint cp "$GEN" /f/broken.example.com /v/broken.example.com 2>&1) \
  || fail broken_snippet_caught "cannot install the fixture: $OUT"
OUT=$(compose up -d --force-recreate broken 2>&1) || fail broken_snippet_caught "cannot start the second backend: $OUT"
wait_until 30 snippet_included edge_conf_has 'include /etc/nginx/vhost.d/broken.example.com;'
if OUT=$(docker exec "$RUN-edge" nginx -t 2>&1); then fail broken_snippet_caught "nginx -t accepted the broken snippet"; fi
grep -q 'duplicate' <<<"$OUT" && pass broken_snippet_caught || fail broken_snippet_caught "unexpected nginx -t error: $OUT"
# The failed reload leaves the running configuration in place: app.example.com keeps serving, still protected.
expect_eq broken_snippet_old_config_serves "$(https_status /)" 200
expect_waf_block broken_snippet_old_config_waf xss_broken

OUT=$(volume_run nginx_vhost --entrypoint rm "$GEN" -f /v/broken.example.com 2>&1) || fail nginx_t_after_fix "cannot remove the fixture: $OUT"
OUT=$(compose up -d --force-recreate broken 2>&1) || fail nginx_t_after_fix "cannot recreate the second backend: $OUT"
wait_until 30 snippet_removed edge_conf_lacks 'include /etc/nginx/vhost.d/broken.example.com;'
OUT=$(docker exec "$RUN-edge" nginx -t 2>&1) && pass nginx_t_after_fix || fail nginx_t_after_fix "nginx -t still fails: $OUT"
wait_until 30 serves_after_fix https_is_200
expect_waf_block waf_after_fix xss_fixed

# docker-gen's own reload signal reaches the edge: broken.example.com's server block was only ever in a configuration
# that nginx refused, so it is served only after the reload gen triggers for the fixed configuration (nothing else
# signals the edge from here on).
BROKEN_HOSTNAME=$(docker inspect -f '{{.Config.Hostname}}' "$RUN-broken") || fail gen_reload_reaches_edge "cannot inspect $RUN-broken"
broken_served() {
  curl -s -k --max-time 5 --resolve "broken.example.com:$HTTPS_HOST_PORT:127.0.0.1" "https://broken.example.com:$HTTPS_HOST_PORT/" \
    | grep -q "^Hostname: $BROKEN_HOSTNAME"
}
wait_until 30 gen_reload_reaches_edge broken_served
pass gen_reload_reaches_edge

# ---- 4. HTTP/3 ------------------------------------------------------------------------------------------------
# h3.example.com's backend has the nginx-proxy label that turns HTTP/3 on for its vhost. The client is a container on
# the test network (no UDP port is published on the host); Alpine's and the curl project's images lack HTTP/3.
OUT=$(docker build -q -t "$RUN-h3client" -f "$HERE/fixtures/h3-client.Dockerfile" "$WORK" 2>&1) \
  || fail h3_client_image "cannot build the HTTP/3 client image: $OUT"
OUT=$(docker run --rm "$RUN-h3client" curl -V 2>&1) || fail h3_client_image "curl -V failed: $OUT"
grep -q '^Features:.* HTTP3\b' <<<"$OUT" && pass h3_client_image || fail h3_client_image "curl has no HTTP3 feature: $OUT"
EDGE_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${RUN}_proxy\").IPAddress}}" "$RUN-edge") || fail setup "cannot read the edge's address"
[ -n "$EDGE_IP" ] || fail setup "the edge has no address on the test network"
h3() { # curl args... -> curl over HTTP/3 only, from the client container; a body for --data-binary @- comes from stdin
  docker run --rm -i --network "${RUN}_proxy" "$RUN-h3client" \
    curl -s -g -k --http3-only --max-time 20 --resolve "h3.example.com:443:$EDGE_IP" "$@" || true
}
h3_status() { h3 -o /dev/null -w '%{http_code}' "$@" </dev/null; }
audit_rule() { # marker rule-id-prefix -> true when an audit entry for a request whose uri contains marker matched a
  # rule whose ID starts with the prefix, and none of the entry's matches is 920280 (missing Host header)
  docker logs "$RUN-edge" 2>/dev/null | grep '^{"transaction"' \
    | jq -e --arg m "$1" --arg p "$2" 'select((.transaction.request.uri // "") | contains($m))
        | select(any(.transaction.messages[]?; (.details.ruleId // "") | startswith($p)))
        | select(all(.transaction.messages[]?; .details.ruleId != "920280"))' >/dev/null 2>&1
}
wait_until 30 h3_listening edge_conf_has 'listen 443 quic'
# Short tries (curl uses the last --max-time given), so a stalled QUIC handshake still gets several within the wait.
h3_answers() { [ "$(h3_status --max-time 5 https://h3.example.com/)" = 200 ]; }
wait_until 30 h3_up h3_answers

expect_eq h3_get "$(h3 -o /dev/null -w '%{http_code} %{http_version}' https://h3.example.com/ </dev/null)" '200 3'
https_request h3.example.com /
grep -qE '(^|[ ,;])h3=' <<<"$(header Alt-Svc)" && pass h3_alt_svc || fail h3_alt_svc "no alt-svc naming h3 over HTTP/2: $HEAD"

H3_XSS='<script>alert(1)</script>'
expect_eq h3_url_attack_blocked "$(h3_status "https://h3.example.com/?t=h3_url&q=$H3_XSS")" 403
wait_until 10 h3_url_attack_blocked audit_rule t=h3_url 941

expect_eq h3_header_attack_blocked "$(h3_status -H 'User-Agent: () { :; }; echo; /bin/cat /etc/passwd' "https://h3.example.com/?t=h3_hdr")" 403
wait_until 10 h3_header_attack_blocked audit_rule t=h3_hdr 932

expect_eq h3_body_attack_blocked "$(h3_status --data "q=$H3_XSS" "https://h3.example.com/?t=h3_body")" 403
wait_until 10 h3_body_attack_blocked audit_rule t=h3_body 941

# No Content-Length: -T - uploads stdin of unknown size, which curl sends as a stream (--data-binary @- reads it all and
# sends a length). The WAF must still inspect it; the audit entry must show the request really had no length.
STREAMED=$(echo "q=$H3_XSS" | h3 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/x-www-form-urlencoded' \
  -T - "https://h3.example.com/?t=h3_stream")
expect_eq h3_streamed_body_attack_blocked "$STREAMED" 403
wait_until 10 h3_streamed_body_attack_blocked audit_rule t=h3_stream 941
audit_without_length() { # marker -> true when the audit entry for that request has no Content-Length header
  docker logs "$RUN-edge" 2>/dev/null | grep '^{"transaction"' \
    | jq -e --arg m "$1" 'select((.transaction.request.uri // "") | contains($m))
        | select([.transaction.request.headers | keys[] | ascii_downcase] | index("content-length") | not)' >/dev/null 2>&1
}
wait_until 10 h3_streamed_body_has_no_content_length audit_without_length t=h3_stream
pass h3_streamed_body_has_no_content_length

expect_eq h3_legit_post "$(h3_status --data 'name=alice' https://h3.example.com/)" 200

# A non-file body over MODSEC_REQ_BODY_NOFILES_LIMIT (1048576 bytes) is refused, as over HTTP/1.1 (compared here, so a
# change in the limit shows up as a difference between the protocols and not as a silent pass).
{ printf 'q='; head -c 1048575 /dev/zero | tr '\0' a; } > "$WORK/big_form.txt"
H1_BIG=$(https_status / --data-binary "@$WORK/big_form.txt")
expect_eq h3_body_limit "$(h3 -o /dev/null -w '%{http_code}' --data-binary @- https://h3.example.com/ < "$WORK/big_form.txt")" "$H1_BIG"
expect_eq h3_body_limit_refused "$H1_BIG" 403

# The 920280 exclusion is for HTTP/3 only: an HTTP/1.0 request without a Host header is still refused by that rule.
# The absolute-form request target lets nginx route it to app.example.com without a Host header.
expect_eq host_rule_kept_for_http1 "$(https_status / --http1.0 -H 'Host:' --request-target 'http://app.example.com/?t=h1_nohost')" 403
audit_920280() {
  docker logs "$RUN-edge" 2>/dev/null | grep '^{"transaction"' \
    | jq -e 'select((.transaction.request.uri // "") | contains("t=h1_nohost"))
        | select(any(.transaction.messages[]?; .details.ruleId == "920280"))' >/dev/null 2>&1
}
wait_until 10 host_rule_kept_for_http1 audit_920280

# ---- 5. hard off switches (EDGE_HTTP2, EDGE_HTTP3) --------------------------------------------------------------
# A value other than on or off stops gen before nginx-proxy's entrypoint runs: the two error lines are all it prints
# (no Docker socket is needed to see that).
for setting in EDGE_HTTP2=Off EDGE_HTTP3=maybe; do
  if OUT=$(docker run --rm --network none -e "$setting" "$GEN" 2>&1); then
    fail settings_refused "gen started with $setting"
  fi
  [ "$OUT" = "ERROR: ${setting%%=*}='${setting#*=}' is not allowed. Allowed: on off."$'\n'"ERROR: invalid settings, not starting." ] \
    || fail settings_refused "unexpected output for $setting: $OUT"
done
pass settings_refused

# With both switches unset, gen's template renders exactly what nginx-proxy's template at the pinned commit renders, for
# the same containers (docker-gen without a destination writes to stdout). Also with the debug endpoint on: its JSON
# holds the template's whole config map, so anything the patch kept there would show.
curl -fsS --max-time 30 -o "$WORK/upstream.tmpl" "https://raw.githubusercontent.com/nginx-proxy/nginx-proxy/$PINNED_REF/nginx.tmpl" \
  2>"$WORK/curl.err" || fail switch_on_unchanged "cannot download nginx.tmpl at $PINNED_REF: $(cat "$WORK/curl.err")"
OUT=$(docker cp "$WORK/upstream.tmpl" "$RUN-gen:/tmp/upstream.tmpl" 2>&1) || fail switch_on_unchanged "cannot copy it into gen: $OUT"
render() { # template-in-gen name [docker-exec-args...] -> $WORK/name.conf, what docker-gen renders from that template
  # with the switches unset
  local tmpl=$1 name=$2; shift 2
  docker exec "$@" "$RUN-gen" env -u EDGE_HTTP2 -u EDGE_HTTP3 docker-gen "$tmpl" > "$WORK/$name.conf" 2>"$WORK/$name.err" \
    || fail switch_on_unchanged "docker-gen $tmpl failed: $(cat "$WORK/$name.err")"
}
same_render() { # name-a name-b -> fails switch_on_unchanged unless both renders are identical
  local diff
  diff=$(diff -u "$WORK/$1.conf" "$WORK/$2.conf") || fail switch_on_unchanged "$2 differs from $1: $(head -40 <<<"$diff")"
}
render /tmp/upstream.tmpl upstream
render /app/nginx.tmpl patched
render /tmp/upstream.tmpl upstream_debug -e DEBUG_ENDPOINT=true
render /app/nginx.tmpl patched_debug -e DEBUG_ENDPOINT=true
grep -q 'server_name app.example.com;' "$WORK/patched.conf" || fail switch_on_unchanged "no app.example.com server rendered"
grep -q "/nginx-proxy-debug" "$WORK/patched_debug.conf" && grep -q "return 200 '{\"global\":{" "$WORK/patched_debug.conf" \
  || fail switch_on_unchanged "no debug location with the global config rendered with DEBUG_ENDPOINT=true"
same_render upstream patched
same_render upstream_debug patched_debug
pass switch_on_unchanged

offer_h2() { # host -> "<status> <HTTP version>" of a GET to https://host/ on the edge, from a client that offers h2;
  # 127.0.0.1 makes a connection without SNI (curl sends none for an IP address), which the catch-all server answers
  local resolve=()
  [ "$1" = 127.0.0.1 ] || resolve=(--resolve "$1:$HTTPS_HOST_PORT:127.0.0.1")
  curl -s -g -k --http2 -o /dev/null -w '%{http_code} %{http_version}' --max-time 10 "${resolve[@]}" \
    "https://$1:$HTTPS_HOST_PORT/" || true
}
# The catch-all server completes the handshake only with a default certificate; without one it refuses it, and the
# test could not tell whether that server would offer h2.
OUT=$(volume_run nginx_certs --entrypoint sh "$GEN" -c '
  set -e; cd /v
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=default" -keyout default.key -out default.crt 2>/dev/null
  chmod 600 default.key' 2>&1) || fail setup "could not create the default certificate: $OUT"
OUT=$(compose up -d --force-recreate nginx-proxy-gen 2>&1) || fail setup "cannot recreate gen: $OUT"
wait_until 30 default_cert_used edge_conf_has 'ssl_certificate /etc/nginx/certs/default.crt'
catchall_h2() { [ "$(offer_h2 127.0.0.1)" = '503 2' ]; }
wait_until 30 catchall_h2_on_by_default catchall_h2
expect_eq catchall_h2_on_by_default "$(offer_h2 127.0.0.1)" '503 2'

# Both switches off. h3.example.com's labels ask for HTTP/2 and HTTP/3, and the catch-all server has "http2 on" by
# default (it ignores ENABLE_HTTP2): none of them may offer either protocol.
OLD_PIDS=$(worker_pids) || fail switch_off_reload "cannot list the edge's worker processes"
OUT=$(EDGE_HTTP2=off EDGE_HTTP3=off compose up -d --force-recreate nginx-proxy-gen 2>&1) \
  || fail switch_off_reload "cannot recreate gen: $OUT"
wait_until 30 switch_off_generated edge_conf_lacks 'http2 on'
# Workers of the previous configuration still answer until they have finished: wait until none of them is left, so
# every answer below comes from the new configuration.
wait_until 30 switch_off_reload workers_replaced
for directive in 'http2 on' 'http3 on' 'quic' 'alt-svc'; do
  edge_conf_lacks "$directive" || fail switch_off_config "default.conf still has '$directive'"
done
pass switch_off_config
APP_H2=$(offer_h2 app.example.com)
H3_H2=$(offer_h2 h3.example.com)
[ "$APP_H2|$H3_H2" = '200 1.1|200 1.1' ] \
  || fail switch_off_named_site "app.example.com: '$APP_H2', h3.example.com: '$H3_H2', expected '200 1.1' for both"
https_request h3.example.com /
[ "$STATUS" = 200 ] || fail switch_off_named_site "h3.example.com: status $STATUS"
expect_eq switch_off_named_site "$(header Alt-Svc)" ''
expect_eq switch_off_no_sni "$(offer_h2 127.0.0.1)" '503 1.1'
H3_STATUS=$(h3_status --max-time 5 https://h3.example.com/)
[ "$H3_STATUS" != 200 ] && pass switch_off_h3 || fail switch_off_h3 "h3.example.com still answers over HTTP/3"

echo "ALL PASS"
