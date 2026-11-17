#!/usr/bin/env bash
# Long-lived connections through the WAF: tests/streaming_smoke.sh EDGE_IMAGE GEN_IMAGE
# Runs the split layout (as tests/split_smoke.sh) in front of a backend that streams (tests/fixtures/stream_backend.py)
# and checks that WebSocket, server-sent events, a long poll and streamed HTML work through the edge with the WAF on,
# and that attacks on the same routes are still blocked.
# Prints "PASS <name>" per assertion, stops at the first failure. The compose project, its volumes, containers
# and every temp file are removed on exit (also on failure). Host ports: 127.0.0.1 only, taken from PORT_1 and
# PORT_2 when they are set, else picked by Docker.
set -euo pipefail

EDGE=${1:?usage: tests/streaming_smoke.sh EDGE_IMAGE GEN_IMAGE}
GEN=${2:?usage: tests/streaming_smoke.sh EDGE_IMAGE GEN_IMAGE}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Test helper, pinned by digest (python:3.13-slim, multi-platform index): runs the streaming backend and the WebSocket
# client from tests/fixtures (standard library only, nothing is installed).
STREAM_IMAGE=python@sha256:e48f59cdba69a3cbd9ed2cf0f348d90d45a8d350d98134cf1070bc106ee9ed90

command -v curl >/dev/null || { echo "FAIL setup: curl is required on the host" >&2; exit 1; }
command -v jq >/dev/null || { echo "FAIL setup: jq is required on the host" >&2; exit 1; }
command -v awk >/dev/null || { echo "FAIL setup: awk is required on the host" >&2; exit 1; }

RUN="streamtest-$$-$RANDOM"
WORK=$(mktemp -d)
# compose.smoke.yml requires an image variable for every service, started or not; the services this test does not
# start never get created or pulled, so the helper image stands in for them.
BACKEND_IMAGE=$STREAM_IMAGE HEADERS_BACKEND_IMAGE=$STREAM_IMAGE
export RUN STREAM_IMAGE BACKEND_IMAGE HEADERS_BACKEND_IMAGE EDGE_IMAGE=$EDGE GEN_IMAGE=$GEN HTTP_PORT=${PORT_1:-} HTTPS_PORT=${PORT_2:-}
# Only the named services are started (see "up" below), so services other tests add to compose.smoke.yml stay out.
compose() { docker compose -p "$RUN" --profile '*' -f "$HERE/compose.smoke.yml" -f "$HERE/compose.streaming.yml" "$@"; }
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
  # The WebSocket client first: a client still running (killed docker CLI, CI cancel) keeps the network in use, and
  # 'compose down' could not remove it.
  docker rm -f -v "$RUN-ws" >/dev/null 2>&1 || true
  compose down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
  # Anything compose could not remove (a failed 'up' before the project existed).
  docker rm -f -v "$RUN-edge" "$RUN-gen" "$RUN-stream" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS $1${2:+ ($2)}"; }
fail() { echo "FAIL $1${2:+: $2}" >&2; exit 1; }
dump_logs() {
  docker logs "$RUN-gen" 2>&1 | tail -20 >&2 || true
  docker logs "$RUN-edge" 2>&1 | tail -20 >&2 || true
}
fail_logs() { dump_logs; fail "$@"; }

# ---- helpers ----------------------------------------------------------------------------------------------
wait_until() { # seconds name command...
  local secs=$1 what=$2; shift 2
  for _ in $(seq 1 $((secs * 5))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.2; done
  fail_logs "$what" "not true after ${secs}s"
}
edge_conf_has() { docker exec "$RUN-edge" grep -q -- "$1" /etc/nginx/conf.d/default.conf; }
stream_https() { # curl args... -> curl against the stream vhost over HTTPS (last argument is the path)
  local p=${*: -1}
  curl -s -g -k --resolve "stream.example.com:$HTTPS_HOST_PORT:127.0.0.1" "${@:1:$#-1}" "https://stream.example.com:$HTTPS_HOST_PORT$p"
}
stream_is_up() { [ "$(stream_https -o /dev/null -w '%{http_code}' --max-time 5 /html?probe=1)" = 200 ]; }
audit_xss() { # marker -> true when the edge's audit log (stdout, JSON) has an entry whose request uri contains marker
  # with a match of a CRS XSS rule (941xxx)
  docker logs "$RUN-edge" 2>/dev/null | grep '^{"transaction"' \
    | jq -e --arg m "$1" 'select((.transaction.request.uri // "") | contains($m))
        | select(any(.transaction.messages[]?; (.details.ruleId // "") | startswith("941")))' >/dev/null 2>&1
}
# A streamed response must start arriving long before it ends: the first piece of the BODY within 3 s of a 5 s stream
# (a buffering WAF or proxy would deliver it at the end; curl's time_starttransfer would not show that, it stops at
# the response headers, which nginx can send before it holds back the body), and every one of the 5 pieces must come.
expect_streams_early() { # name path pattern-of-a-piece
  local start first="" n=0 line t
  : > "$WORK/$1.body"
  start=$EPOCHREALTIME
  while IFS= read -r line; do
    [ -n "$first" ] || first=$EPOCHREALTIME
    echo "$line" >> "$WORK/$1.body"
  done < <(stream_https -N --max-time 30 "$2" || echo "curl failed: $?")
  n=$(grep -c -- "$3" "$WORK/$1.body" || true)
  [ "$n" = 5 ] || fail_logs "$1" "expected 5 pieces, got $n: $(cat "$WORK/$1.body")"
  [ -n "$first" ] || fail_logs "$1" "no body arrived"
  t=$(awk -v a="$start" -v b="$first" 'BEGIN { printf "%.2f", b - a }')
  awk -v t="$t" 'BEGIN { exit !(t < 3) }' || fail_logs "$1" "first piece after ${t}s of a 5 s stream: buffered"
  pass "$1" "first piece after ${t}s of 5 s"
}

# ---- 1. bring the layout up ---------------------------------------------------------------------------------
# Create (not start) first, so the volumes exist and the certificate can be put in before anything runs.
OUT=$(compose up --no-start stream nginx-proxy nginx-proxy-gen 2>&1) || fail compose_create "$OUT"
OUT=$(docker run --rm -v "${RUN}_nginx_certs:/v" --entrypoint sh "$GEN" -c '
  set -e; cd /v
  h=stream.example.com
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$h" -addext "subjectAltName=DNS:$h" \
    -keyout "$h.key" -out "$h.crt" 2>/dev/null
  chmod 600 "$h.key"' 2>&1) || fail setup "could not create the self-signed certificate: $OUT"
OUT=$(compose up -d stream nginx-proxy nginx-proxy-gen 2>&1) || fail compose_up "$OUT"

HTTPS_HOST_PORT=$(compose port nginx-proxy 443 | sed 's/.*://') || fail setup "could not read the published HTTPS port"
[ -n "$HTTPS_HOST_PORT" ] || fail setup "could not read the published HTTPS port"

wait_until 30 generated edge_conf_has 'stream.example.com'
wait_until 30 stream_up stream_is_up
pass setup_up

# ---- 2. streaming through the WAF ---------------------------------------------------------------------------
expect_streams_early sse_first_event_early /sse '^data: '
expect_streams_early html_first_chunk_early /html '^<p>chunk'

# The long poll holds the connection for 25 s (nginx's default read timeout is 60 s).
OUT=$(stream_https -w '|%{http_code}' --max-time 40 /poll) || fail_logs long_poll_completes "curl failed: $OUT"
[ "$OUT" = 'polled|200' ] || fail_logs long_poll_completes "expected 'polled|200', got '$OUT'"
pass long_poll_completes

# The client stays idle for 20 s on an open connection (well under the 60 s read timeout), then must still get its echo.
OUT=$(timeout 60 docker run --rm --name "$RUN-ws" --network "${RUN}_proxy" -v "$HERE/fixtures:/f:ro" --entrypoint python3 \
  "$STREAM_IMAGE" /f/ws_client.py "wss://$RUN-edge/ws" --insecure --host stream.example.com --idle 20 2>&1) \
  || fail_logs websocket_echo "client failed: $OUT"
grep -qx 'handshake 101' <<<"$OUT" || fail_logs websocket_echo "no 'handshake 101' in: $OUT"
pass websocket_echo

# ---- 3. attacks on the same routes are still blocked ---------------------------------------------------------
OUT=$(timeout 30 docker run --rm --name "$RUN-ws" --network "${RUN}_proxy" -v "$HERE/fixtures:/f:ro" --entrypoint python3 \
  "$STREAM_IMAGE" /f/ws_client.py "wss://$RUN-edge/ws?t=ws_attack&q=<script>alert(1)</script>" --insecure \
  --host stream.example.com 2>&1) && fail_logs websocket_attack_blocked "the handshake was not refused: $OUT"
grep -qx 'handshake 403' <<<"$OUT" || fail_logs websocket_attack_blocked "expected 'handshake 403', got: $OUT"
wait_until 10 websocket_attack_blocked audit_xss t=ws_attack
pass websocket_attack_blocked

got=$(stream_https -o /dev/null -w '%{http_code}' --max-time 10 '/sse?t=sse_attack&q=<script>alert(1)</script>') || true
[ "$got" = 403 ] || fail_logs sse_attack_blocked "expected '403', got '$got'"
wait_until 10 sse_attack_blocked audit_xss t=sse_attack
pass sse_attack_blocked

echo "ALL PASS"
