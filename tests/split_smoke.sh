#!/usr/bin/env bash
# Smoke test for the separate-containers layout: tests/split_smoke.sh EDGE_IMAGE GEN_IMAGE
# Runs the edge image (nginx + ModSecurity) and the gen image (docker-gen + nginx-proxy's template) the way
# nginx-proxy's docker-compose-separate-containers.yml does, in front of a tiny echo backend.
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
compose() { docker compose -p "$RUN" -f "$HERE/compose.smoke.yml" "$@"; }
cleanup() {
  compose down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
  # Anything compose could not remove (a failed 'up' before the project existed).
  docker rm -f -v "$RUN-edge" "$RUN-gen" "$RUN-whoami" >/dev/null 2>&1 || true
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
wait_until() { # seconds description command...
  local secs=$1 what=$2 i; shift 2
  for i in $(seq 1 $((secs * 5))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; done
  docker logs "$RUN-gen" 2>&1 | tail -20 >&2 || true
  docker logs "$RUN-edge" 2>&1 | tail -20 >&2 || true
  fail "$what" "not true after ${secs}s"
}
edge_conf_has() { docker exec "$RUN-edge" grep -q -- "$1" /etc/nginx/conf.d/default.conf; }
edge_conf_lacks() { ! edge_conf_has "$1"; }
https_is_200() { [ "$(https_status /)" = 200 ]; }
volume_run() { # volume-suffix mounts... -- shell command, run as root in the gen image (openssl, sh, cp, rm)
  local vol="${RUN}_$1"; shift
  docker run --rm -v "$vol:/v" "$@"
}
recreate_backend() { compose up -d --force-recreate --no-deps whoami >/dev/null 2>&1; }

# ---- 0. the image's own configuration ---------------------------------------------------------------------
DEFAULT_CMD='["/app/docker-entrypoint.sh"] ["docker-gen","-watch","-wait","100ms:500ms","-notify-container","nginx-proxy","-notify-signal","1","/app/nginx.tmpl","/etc/nginx/conf.d/default.conf"]'
ACTUAL=$(docker inspect "$GEN" --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' 2>/dev/null) || fail default_command "image $GEN not found"
expect_eq default_command "$ACTUAL" "$DEFAULT_CMD"

PINNED_REF=$(sed -n 's/^NGINX_PROXY_REF=//p' "$HERE/../pins.env")
[ -n "$PINNED_REF" ] || fail nginx_proxy_ref "NGINX_PROXY_REF not found in pins.env"
expect_eq nginx_proxy_ref "$(docker inspect "$GEN" --format '{{range .Config.Env}}{{println .}}{{end}}' | sed -n 's/^NGINX_PROXY_VERSION=//p')" "$PINNED_REF"

# ---- 1. bring the layout up ---------------------------------------------------------------------------------
# Create (not start) first, so the volumes exist and the certificate can be put in before anything runs.
compose up --no-start >/dev/null 2>"$RUN.err" || { cat "$RUN.err" >&2; rm -f "$RUN.err"; fail compose_create; }
rm -f "$RUN.err"
volume_run nginx_certs --entrypoint sh "$GEN" -c '
  cd /v && openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=app.example.com \
    -addext subjectAltName=DNS:app.example.com -keyout app.example.com.key -out app.example.com.crt 2>/dev/null \
  && chmod 600 app.example.com.key' || fail setup "could not create the self-signed certificate"
compose up -d >/dev/null 2>&1 || { compose logs >&2 || true; fail compose_up; }

HTTP_HOST_PORT=$(compose port nginx-proxy 80 | sed 's/.*://')
HTTPS_HOST_PORT=$(compose port nginx-proxy 443 | sed 's/.*://')
[ -n "$HTTP_HOST_PORT" ] && [ -n "$HTTPS_HOST_PORT" ] || fail setup "could not read the published ports"

# ---- 2. generation, routing, WAF ---------------------------------------------------------------------------
wait_until 30 generated edge_conf_has 'app.example.com'
pass generated
wait_until 30 https_up https_is_200
# Right after a reload, workers of the previous configuration can still answer for a moment, so wait for the
# new answer instead of sampling once.
http_is_301() { [ "$(http_status /)" = 301 ]; }
wait_until 30 http_redirects_to_https http_is_301
expect_eq http_redirects_to_https "$(http_status /)" 301
expect_eq https_ok "$(https_status /)" 200
curl -s -k --max-time 10 --resolve "app.example.com:$HTTPS_HOST_PORT:127.0.0.1" "https://app.example.com:$HTTPS_HOST_PORT/" \
  | grep -q '^Hostname:' && pass backend_reached || fail backend_reached "response is not whoami's"

XSS='/?q=<script>alert(1)</script>'
expect_eq waf_on_after_gen "$(https_status "$XSS")" 403
# nginx-proxy's own reload path: docker-gen sends SIGHUP, so does the test; the WAF must survive it.
docker kill -s HUP "$RUN-edge" >/dev/null
sleep 1
expect_eq reload_keeps_waf "$(https_status "$XSS")" 403

# The entrypoint copied an RFC 7919 group (pre-generated in the image, not generated at start) into the shared
# volume, and the template switched ssl_dhparam on.
volume_run nginx_dhparam --entrypoint sh "$GEN" -c 'test -s /v/dhparam.pem' && pass dhparam_created \
  || fail dhparam_created "dhparam.pem is missing or empty in the dhparam volume"
edge_conf_has 'ssl_dhparam /etc/nginx/dhparam/dhparam.pem;' && pass dhparam_used || fail dhparam_used "not in default.conf"

# ---- 3. a broken per-vhost snippet is caught by 'nginx -t' ---------------------------------------------------
# nginx-proxy includes vhost.d/<VIRTUAL_HOST> into that host's server blocks, so the fixture is installed under
# the name of the host this test serves.
docker exec "$RUN-edge" nginx -t >/dev/null 2>&1 || fail nginx_t_before "nginx -t fails before the broken snippet"
volume_run nginx_vhost -v "$HERE/fixtures/vhost.d:/f:ro" --entrypoint cp "$GEN" /f/broken.example.com /v/app.example.com
recreate_backend
wait_until 30 snippet_included edge_conf_has 'include /etc/nginx/vhost.d/app.example.com;'
if docker exec "$RUN-edge" nginx -t >/dev/null 2>&1; then fail broken_snippet_caught "nginx -t accepted the broken snippet"; fi
pass broken_snippet_caught
# The failed reload leaves the running configuration in place: the site keeps serving, still protected.
expect_eq broken_snippet_old_config_serves "$(https_status /)" 200
expect_eq broken_snippet_old_config_waf "$(https_status "$XSS")" 403

volume_run nginx_vhost --entrypoint rm "$GEN" -f /v/app.example.com
recreate_backend
wait_until 30 snippet_removed edge_conf_lacks 'include /etc/nginx/vhost.d/app.example.com;'
docker exec "$RUN-edge" nginx -t >/dev/null 2>&1 && pass nginx_t_after_fix || fail nginx_t_after_fix "nginx -t still fails"
wait_until 30 serves_after_fix https_is_200
expect_eq waf_after_fix "$(https_status "$XSS")" 403

echo "ALL PASS"
