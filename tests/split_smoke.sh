#!/usr/bin/env bash
# Smoke test for the separate-containers layout: tests/split_smoke.sh EDGE_IMAGE GEN_IMAGE
# Runs the edge image (nginx + ModSecurity) and the gen image (docker-gen + nginx-proxy's template, with its real
# default command) the way nginx-proxy's docker-compose-separate-containers.yml does, in front of a tiny echo backend.
# Prints "PASS <name>" per assertion, stops at the first failure. The compose project, its volumes, containers
# and every temp file are removed on exit (also on failure). Host ports: 127.0.0.1 only, taken from $PORT_1 and
# $PORT_2 when set (devbox), else picked by Docker.
set -euo pipefail

EDGE=${1:?usage: tests/split_smoke.sh EDGE_IMAGE GEN_IMAGE}
GEN=${2:?usage: tests/split_smoke.sh EDGE_IMAGE GEN_IMAGE}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Test helper, pinned by digest (same as edge_smoke.sh).
BACKEND_IMAGE=traefik/whoami@sha256:200689790a0a0ea48ca45992e0450bc26ccab5307375b41c84dfc4f2475937ab

command -v jq >/dev/null || { echo "FAIL setup: jq is required on the host" >&2; exit 1; }
command -v curl >/dev/null || { echo "FAIL setup: curl is required on the host" >&2; exit 1; }

RUN="splittest-$$-$RANDOM"
export RUN BACKEND_IMAGE EDGE_IMAGE=$EDGE GEN_IMAGE=$GEN HTTP_PORT=${PORT_1:-} HTTPS_PORT=${PORT_2:-}
compose() { docker compose -p "$RUN" --profile '*' -f "$HERE/compose.smoke.yml" "$@"; }
cleanup() {
  compose down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
  # Anything compose could not remove (a failed 'up' before the project existed).
  docker rm -f -v "$RUN-edge" "$RUN-gen" "$RUN-whoami" "$RUN-broken" >/dev/null 2>&1 || true
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
http_status() { # path [curl args...]
  local p=$1; shift
  curl -s -g -o /dev/null -w '%{http_code}' --max-time 10 --resolve "app.example.com:$HTTP_HOST_PORT:127.0.0.1" \
    "$@" "http://app.example.com:$HTTP_HOST_PORT$p" || true
}
wait_until() { # seconds name command...
  local secs=$1 what=$2 i; shift 2
  for i in $(seq 1 $((secs * 5))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; done
  docker logs "$RUN-gen" 2>&1 | tail -20 >&2 || true
  docker logs "$RUN-edge" 2>&1 | tail -20 >&2 || true
  fail "$what" "not true after ${secs}s"
}
edge_conf_has() { docker exec "$RUN-edge" grep -q -- "$1" /etc/nginx/conf.d/default.conf; }
edge_conf_lacks() { ! edge_conf_has "$1"; }
https_is_200() { [ "$(https_status /)" = 200 ]; }
http_is_301() { [ "$(http_status /)" = 301 ]; }
volume_run() { # volume-suffix docker-run-args... -> runs a throwaway gen-image container as root with the volume at /v
  local vol="${RUN}_$1"; shift
  docker run --rm -v "$vol:/v" "$@"
}
worker_pids() { # sorted PIDs of the edge's nginx worker processes (the image has no ps/pgrep)
  docker exec "$RUN-edge" sh -c 'for p in /proc/[0-9]*; do
    case "$(tr "\0" " " < "$p/cmdline" 2>/dev/null)" in "nginx: worker"*) echo "${p#/proc/}";; esac; done' | sort -n
}
audit_has() { # marker -> true when the edge's audit log (stdout, JSON) has an entry whose request uri contains marker
  docker logs "$RUN-edge" 2>/dev/null | grep '^{"transaction"' \
    | jq -e --arg m "$1" 'select((.transaction.request.uri // "") | contains($m))' >/dev/null 2>&1
}
# An attack request must be refused with 403 AND be logged by ModSecurity: a 403 from anything else would not do.
expect_waf_block() { # name marker
  expect_eq "$1" "$(https_status "/?t=$2&q=<script>alert(1)</script>")" 403
  wait_until 10 "$1" audit_has "t=$2"
}

# ---- 0. the image's own configuration ---------------------------------------------------------------------
# Entrypoint and default command are those of nginx-proxy's Dockerfile.dockergen at the pinned ref; the test runs them
# unchanged (compose sets no command), only NGINX_CONTAINER_LABEL is set per run.
UPSTREAM_CMD='["/app/docker-entrypoint.sh"] ["docker-gen","-watch","-wait","100ms:500ms","-event-filter","event=connect","-event-filter","event=disconnect","-notify-filter","label=$NGINX_CONTAINER_LABEL","/app/nginx.tmpl","/etc/nginx/conf.d/default.conf"]'
ACTUAL=$(docker inspect "$GEN" --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' 2>&1) \
  || fail default_command "cannot inspect $GEN: $ACTUAL"
expect_eq default_command "$ACTUAL" "$UPSTREAM_CMD"

PINNED_REF=$(sed -n 's/^NGINX_PROXY_REF=//p' "$HERE/../pins.env")
[ -n "$PINNED_REF" ] || fail nginx_proxy_ref "NGINX_PROXY_REF not found in pins.env"
ENVS=$(docker inspect "$GEN" --format '{{range .Config.Env}}{{println .}}{{end}}') || fail nginx_proxy_ref "cannot inspect $GEN"
expect_eq nginx_proxy_ref "$(sed -n 's/^NGINX_PROXY_VERSION=//p' <<<"$ENVS")" "$PINNED_REF"

# ---- 1. bring the layout up ---------------------------------------------------------------------------------
# Create (not start) first, so the volumes exist and the certificates can be put in before anything runs.
OUT=$(compose up --no-start 2>&1) || fail compose_create "$OUT"
OUT=$(volume_run nginx_certs --entrypoint sh "$GEN" -c '
  set -e; cd /v
  for h in app.example.com broken.example.com; do
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$h" -addext "subjectAltName=DNS:$h" \
      -keyout "$h.key" -out "$h.crt" 2>/dev/null
    chmod 600 "$h.key"
  done' 2>&1) || fail setup "could not create the self-signed certificates: $OUT"
OUT=$(compose up -d whoami nginx-proxy nginx-proxy-gen 2>&1) || fail compose_up "$OUT"

HTTP_HOST_PORT=$(compose port nginx-proxy 80 | sed 's/.*://')
HTTPS_HOST_PORT=$(compose port nginx-proxy 443 | sed 's/.*://')
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

# The reload docker-gen triggers (SIGHUP) must take effect, and ModSecurity must come up again with it. A rejected
# reload leaves the old workers serving (see the broken snippet below), so a 403 alone proves nothing: require new
# worker processes, no nginx error since the signal, then a logged block.
OLD_PIDS=$(worker_pids)
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

echo "ALL PASS"
