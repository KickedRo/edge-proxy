#!/usr/bin/env bash
# Certificates end to end: tests/acme_e2e.sh EDGE_IMAGE GEN_IMAGE
# Runs the published example (examples/docker-compose.yml: edge, gen, acme-companion, whoami) itself, through the
# override tests/compose.acme.yml, so the example cannot rot unnoticed. The override points acme-companion at a local
# Pebble (Let's Encrypt's test CA) instead of Let's Encrypt. Pebble validates HTTP-01 on port 80 of app.example.com,
# which is a network alias of edge: the challenge request really goes through edge and its WAF. Checks that a
# certificate is issued, that edge serves it (verified against Pebble's root), and that a forced renewal is served
# without edge being restarted.
# Prints "PASS <name>" per assertion, stops at the first failure. The compose project, its volumes, networks,
# containers and every temp file are removed on exit (also on failure). No host port is published: every client is a
# throwaway container on the test's network, and both test networks are internal (nothing in the test reaches the
# internet; images are pulled before).
set -euo pipefail

EDGE=${1:?usage: tests/acme_e2e.sh EDGE_IMAGE GEN_IMAGE}
GEN=${2:?usage: tests/acme_e2e.sh EDGE_IMAGE GEN_IMAGE}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
EXAMPLE=$HERE/../examples/docker-compose.yml
# Test helper, pinned by digest (curlimages/curl:8.17.0, same as edge_smoke.sh): plain HTTP requests from the network.
CLIENT_IMAGE=curlimages/curl@sha256:935d9100e9ba842cdb060de42472c7ca90cfe9a7c96e4dacb55e79e560b3ff40

RUN="acmetest-$$-$RANDOM"
WORK=$(mktemp -d)
chmod 755 "$WORK"
# PEBBLE_CA_FILE: Pebble's API certificate is signed by the CA in its image (test/certs/pebble.minica.pem); the test
# copies that file out of the pinned image, so acme-companion's CA_BUNDLE always matches the Pebble that runs.
export RUN EDGE_IMAGE=$EDGE GEN_IMAGE=$GEN FIXTURES=$HERE/fixtures PEBBLE_CA_FILE=$WORK/pebble.minica.pem
compose() { docker compose -p "$RUN" -f "$EXAMPLE" -f "$HERE/compose.acme.yml" "$@"; }
SERVICES=(nginx-proxy nginx-proxy-gen acme-companion whoami pebble)
VOLUMES=(nginx_conf nginx_vhost nginx_certs nginx_htpasswd nginx_errors nginx_dhparam nginx_html acme_state)
cleanup() {
  local s
  # The client first: one still running (killed docker CLI, CI cancel) keeps the network in use.
  docker rm -f -v "$RUN-client" >/dev/null 2>&1 || true
  compose down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
  # Whatever compose could not remove (a failed 'up', a file it could not parse), by this run's names only.
  for s in "${SERVICES[@]}"; do docker rm -f -v "$RUN-$s" >/dev/null 2>&1 || true; done
  for s in "${VOLUMES[@]}"; do docker volume rm "${RUN}_$s" >/dev/null 2>&1 || true; done
  docker network rm "${RUN}_proxy" "${RUN}_default" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+: $2}" >&2; exit 1; }
dump_logs() {
  local s
  for s in pebble acme-companion nginx-proxy-gen nginx-proxy; do
    echo "---- last log lines of $RUN-$s" >&2
    docker logs "$RUN-$s" 2>&1 | grep -v '^{"transaction"' | tail -25 >&2 || true
  done
}
fail_logs() { dump_logs; fail "$@"; }

# ---- helpers ----------------------------------------------------------------------------------------------
wait_until() { # seconds name command... -> polls once a second until the command succeeds, by the clock (a probe that
  # is slow itself does not stretch the limit); on timeout dumps the logs and fails
  local secs=$1 what=$2 end; shift 2
  end=$((SECONDS + secs))
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$end" ] || fail_logs "$what" "not true after ${secs}s"
    sleep 1
  done
}
client() { # docker-run-args... -> a throwaway container on the test's proxy network, where app.example.com is edge
  docker run --rm --name "$RUN-client" --network "${RUN}_proxy" "$@"
}
http_status() { # url -> HTTP status code, from the network (000 when there is no answer)
  client --entrypoint curl "$CLIENT_IMAGE" -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" || true
}
volume_run() { # volume-suffix docker-run-args... -> runs a throwaway container with the volume at /v
  local vol="${RUN}_$1"; shift
  docker run --rm -v "$vol:/v" "$@"
}
file_serial() { # -> serial of app.example.com.crt in the certs volume (as openssl prints it: serial=...)
  volume_run nginx_certs --entrypoint openssl "$GEN" x509 -noout -serial -in /v/app.example.com.crt
}
served_serial() { # -> serial of the certificate edge serves for app.example.com, only if it verifies against Pebble's
  # root (fetched below) and is valid for that name; fails otherwise
  # shellcheck disable=SC2016 # the script runs in the client container's shell
  client -v "$WORK/pebble-root.pem:/pebble-root.pem:ro" --entrypoint sh "$GEN" -c '
    out=$(openssl s_client -connect app.example.com:443 -servername app.example.com -verify_hostname app.example.com \
      -verify_return_error -CAfile /pebble-root.pem </dev/null 2>&1) || { printf "%s\n" "$out" | tail -5 >&2; exit 1; }
    printf "%s\n" "$out" | grep -q "^Verification: OK" || { echo "no Verification: OK" >&2; exit 1; }
    printf "%s\n" "$out" | openssl x509 -noout -serial'
}
reload_lines() { # [file] -> the lines naming the container acme-companion signals for a reload: from the file (the
  # output of a command run in acme-companion with docker exec, which does not reach its log), else from its log
  if [ -n "${1:-}" ]; then
    grep -E '^Reloading nginx' "$1" || true
  else
    docker logs "$RUN-acme-companion" 2>&1 | grep -E '^Reloading nginx' || true
  fi
}
# acme-companion signals the gen and edge containers it finds. It prefers labels, which it looks up on the whole Docker
# host, over the names the override gives it; the test's edge and gen carry none of those labels. Every reload line
# must name this run's containers, and there must be at least one for each.
OWN_EDGE_RELOAD="Reloading nginx (using separate container $RUN-nginx-proxy)..."
OWN_GEN_RELOAD="Reloading nginx docker-gen (using separate container $RUN-nginx-proxy-gen)..."
reloads_own_containers() { # reload-lines
  # shellcheck disable=SC2143 # "no other line" is decided by the output itself, never by an exit status
  grep -qxF "$OWN_EDGE_RELOAD" <<<"$1" && grep -qxF "$OWN_GEN_RELOAD" <<<"$1" \
    && [ -z "$(grep -vxF -e "$OWN_EDGE_RELOAD" -e "$OWN_GEN_RELOAD" <<<"$1")" ]
}
expect_own_reloads() { # name [file]
  local lines; lines=$(reload_lines "${2:-}")
  if reloads_own_containers "$lines"; then
    pass "$1"
  else
    fail_logs "$1" "a reload line names another container, or none names this run's edge or gen: ${lines:-none}"
  fi
}

# ---- 0. a shared Docker host --------------------------------------------------------------------------------
# acme-companion would pick any running container with one of these labels as "the nginx" or "the docker-gen" and
# signal it, instead of this test's edge and gen. Refuse to run next to such a setup rather than touch it.
for label in com.github.nginx-proxy.nginx com.github.nginx-proxy.docker-gen \
  com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy com.github.jrcs.letsencrypt_nginx_proxy_companion.docker_gen; do
  FOREIGN=$(docker ps --filter "label=$label" --format '{{.Names}}') || fail setup "cannot list the running containers"
  [ -z "$FOREIGN" ] || fail setup "container(s) $(echo "$FOREIGN" | tr '\n' ' ')carry the label $label: acme-companion would signal them; run this test on another Docker host"
done

# ---- 1. bring the example up ----------------------------------------------------------------------------------
OUT=$(compose config -q 2>&1) || fail setup "the example with the override is not a valid compose project: $OUT"
# Create (not start) Pebble and take its API CA out of the container. acme-companion is created only once the file
# exists: a missing bind-mount source would be created as a directory.
OUT=$(compose up --no-start pebble 2>&1) || fail compose_create "$OUT"
OUT=$(docker cp "$RUN-pebble:/test/certs/pebble.minica.pem" "$PEBBLE_CA_FILE" 2>&1) \
  || fail setup "cannot copy Pebble's API CA out of its image: $OUT"
chmod 644 "$PEBBLE_CA_FILE"
# Pebble, the backend, edge and gen first: acme-companion asks for the certificate as soon as it starts, and a failed
# first try is retried only an hour later.
OUT=$(compose up -d pebble whoami nginx-proxy nginx-proxy-gen 2>&1) || fail compose_up "$OUT"
pebble_root() { # Pebble generates its root at start; fetch it over Pebble's management API, verified with its API CA
  client -v "$PEBBLE_CA_FILE:/pebble.minica.pem:ro" --entrypoint curl "$CLIENT_IMAGE" -sf --max-time 10 \
    --cacert /pebble.minica.pem https://pebble:15000/roots/0 > "$WORK/pebble-root.pem" \
    && grep -q 'BEGIN CERTIFICATE' "$WORK/pebble-root.pem"
}
wait_until 60 pebble_up pebble_root
chmod 644 "$WORK/pebble-root.pem"
# The vhost is generated and served over HTTP (no certificate yet): the challenge has somewhere to go.
vhost_served() { [ "$(http_status http://app.example.com/)" = 200 ]; }
wait_until 60 vhost_served vhost_served
# The example runs the WAF in blocking mode (the image's default), so the challenge below has to pass an active WAF.
WAF=$(http_status 'http://app.example.com/?q=%3Cscript%3Ealert(1)%3C/script%3E')
[ "$WAF" = 403 ] || fail_logs waf_on "an XSS probe got $WAF, expected 403"
pass waf_on
OUT=$(compose up -d acme-companion 2>&1) || fail compose_up "$OUT"

# ---- 2. issuance ----------------------------------------------------------------------------------------------
# At start, acme-companion signals the gen and edge containers it found; wait for both lines, then check whose they are.
reloads_logged() {
  local lines; lines=$(reload_lines)
  grep -q '^Reloading nginx (' <<<"$lines" && grep -q '^Reloading nginx docker-gen (' <<<"$lines"
}
wait_until 60 acme_uses_own_edge reloads_logged
expect_own_reloads acme_uses_own_edge

wait_until 120 certificate_issued file_serial
pass certificate_issued

# Pebble fetched the challenge from edge, with the WAF on (edge's access log, nginx-proxy's "vhost" format).
EDGE_LOG=$(docker logs "$RUN-nginx-proxy" 2>&1) || fail challenge_through_edge "cannot read edge's log"
if grep -qE '^app\.example\.com [^ ]+ .*"GET /\.well-known/acme-challenge/[A-Za-z0-9_-]+ HTTP/1\.1" 200 .*"LetsEncrypt-Pebble-VA' \
  <<<"$EDGE_LOG"; then
  pass challenge_through_edge
else
  fail_logs challenge_through_edge "no challenge request from Pebble answered 200 in edge's access log"
fi

# Right after the reload that follows issuance, edge can still answer with the previous configuration for a moment, so
# wait for the issued certificate instead of sampling once. The file is read again each time: acme-companion issues
# one certificate per container that asks for the name, and a second run of this test on the same Docker host has a
# backend asking for app.example.com too.
serves_file_cert() { local f; f=$(file_serial) && [ "$(served_serial)" = "$f" ] && FIRST_SERIAL=$f; }
wait_until 60 https_serves_issued_cert serves_file_cert
pass https_serves_issued_cert
# The reloads after issuance (acme-companion's service, so its log) went to this run's containers only.
expect_own_reloads issuance_reloads_own_containers

http_is_301() { [ "$(http_status http://app.example.com/)" = 301 ]; }
wait_until 30 http_redirects_to_https http_is_301
pass http_redirects_to_https

# ---- 3. renewal -----------------------------------------------------------------------------------------------
# Start time and restart count, taken now: the example's restart policy may have restarted edge before this point.
STARTED=$(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$RUN-nginx-proxy") \
  || fail renewal_served_without_restart "cannot inspect edge"
timeout 180 docker exec "$RUN-acme-companion" /app/force_renew > "$WORK/force_renew.log" 2>&1 \
  || { tail -30 "$WORK/force_renew.log" >&2; fail_logs renewal_served_without_restart "force_renew failed"; }
renewed_and_served() {
  local served file
  served=$(served_serial) && file=$(file_serial) && [ "$served" = "$file" ] && [ "$served" != "$FIRST_SERIAL" ]
}
wait_until 120 renewal_served_without_restart renewed_and_served
NOW=$(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$RUN-nginx-proxy") \
  || fail renewal_served_without_restart "cannot inspect edge"
[ "$NOW" = "$STARTED" ] \
  || fail renewal_served_without_restart "edge was restarted: '$STARTED' before, '$NOW' now (start time, restart count)"
pass renewal_served_without_restart
# The renewal's reloads went to this run's containers only. force_renew runs in the docker exec, so its reload lines are
# in its own output, not in acme-companion's log.
expect_own_reloads renewal_reloads_own_containers "$WORK/force_renew.log"

echo "ALL PASS"
