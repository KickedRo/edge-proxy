#!/bin/sh
# gen's entrypoint: checks gen's own settings, then hands the command to nginx-proxy's entrypoint
# (/app/docker-entrypoint.sh), which runs it.
# EDGE_HTTP2 and EDGE_HTTP3 are the hard off switches that patch-template.sh adds to the template: on or off, unset or
# empty means on. Any other value (a typo, "Off", " off") stops the container before docker-gen runs, so it never
# leaves a protocol on by accident. Every invalid setting is reported before the container stops, in the wording of
# edge's own settings check.
set -eu

invalid=0
check() { # name value
    case $2 in
        ''|on|off) ;;
        *)
            printf "ERROR: %s='%s' is not allowed. Allowed: on off.\n" "$1" "$2" >&2
            invalid=1
            ;;
    esac
}
check EDGE_HTTP2 "${EDGE_HTTP2:-}"
check EDGE_HTTP3 "${EDGE_HTTP3:-}"
if [ "$invalid" != 0 ]; then
    echo "ERROR: invalid settings, not starting." >&2
    exit 1
fi

exec /app/docker-entrypoint.sh "$@"
