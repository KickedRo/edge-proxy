#!/bin/sh
# Renders the image's own templates (/etc/nginx/modsec/templates: the ModSecurity settings and the http-level
# hardening) into /etc/nginx/modsec/rendered at container start. Substitutes only the variables of
# /usr/local/share/kickedro/settings.tsv and the ones derived below, so nginx's own variables ($host, ...) stay.
# Independent of the official NGINX_ENVSUBST_* mechanism (20-envsubst-on-templates.sh), which stays available for
# users' own templates in /etc/nginx/templates. Runs after 05-kickedro-settings.envsh, which sets the defaults and
# validates every value.
set -eu

settings=/usr/local/share/kickedro/settings.tsv
src=/etc/nginx/modsec/templates
out=/etc/nginx/modsec/rendered

# MODSEC_AUDIT_LOG=off turns audit logging off; derive the engine and a harmless file name for it.
if [ "$MODSEC_AUDIT_LOG" = "off" ]; then
    MODSEC_AUDIT_ENGINE=Off
    MODSEC_AUDIT_LOG=/dev/null
else
    MODSEC_AUDIT_ENGINE=RelevantOnly
fi

# The on/off settings that switch lines of hardening.conf: empty when on, a comment sign when off.
line_prefix() { if [ "$1" = on ]; then echo ''; else echo '# '; fi; }
KICKEDRO_IF_SECURITY_HEADERS=$(line_prefix "$EDGE_SECURITY_HEADERS")
KICKEDRO_IF_HIDE_UPSTREAM_HEADERS=$(line_prefix "$EDGE_HIDE_UPSTREAM_HEADERS")
KICKEDRO_IF_RATE_ZONES=$(line_prefix "$EDGE_RATE_ZONES")
export MODSEC_AUDIT_ENGINE MODSEC_AUDIT_LOG \
    KICKEDRO_IF_SECURITY_HEADERS KICKEDRO_IF_HIDE_UPSTREAM_HEADERS KICKEDRO_IF_RATE_ZONES

vars=$(awk -F '\t' '/^[A-Z]/ { printf "${%s} ", $1 }' "$settings")
vars="$vars"'${MODSEC_AUDIT_ENGINE} ${KICKEDRO_IF_SECURITY_HEADERS} ${KICKEDRO_IF_HIDE_UPSTREAM_HEADERS}'
vars="$vars"' ${KICKEDRO_IF_RATE_ZONES}'

for template in "$src"/*.template; do
    target="$out/$(basename "${template%.template}")"
    [ -n "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ] || echo "18-kickedro-render.sh: rendering $template to $target"
    envsubst "$vars" < "$template" > "$target"
done
