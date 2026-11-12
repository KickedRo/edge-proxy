#!/bin/sh
# Renders the image's own ModSecurity templates (/etc/nginx/modsec/templates) into
# /etc/nginx/modsec/rendered at container start, substituting only the MODSEC_* variables listed here.
# Independent of the official NGINX_ENVSUBST_* mechanism (20-envsubst-on-templates.sh), which stays
# available for users' own templates in /etc/nginx/templates. Runs before it.
# No value validation here: that is the job of the settings check.
set -eu

src=/etc/nginx/modsec/templates
out=/etc/nginx/modsec/rendered

# MODSEC_AUDIT_LOG=off turns audit logging off; derive the engine and a harmless file name for it.
if [ "${MODSEC_AUDIT_LOG}" = "off" ]; then
    MODSEC_AUDIT_ENGINE=Off
    MODSEC_AUDIT_LOG=/dev/null
else
    MODSEC_AUDIT_ENGINE=RelevantOnly
fi
export MODSEC_AUDIT_ENGINE MODSEC_AUDIT_LOG

vars='${MODSEC_RULE_ENGINE} ${MODSEC_PARANOIA} ${MODSEC_ANOMALY_INBOUND} ${MODSEC_ANOMALY_OUTBOUND}'
vars="$vars"' ${MODSEC_REQ_BODY_LIMIT} ${MODSEC_AUDIT_ENGINE} ${MODSEC_AUDIT_LOG} ${MODSEC_AUDIT_FORMAT}'
vars="$vars"' ${MODSEC_DENY_STATUS}'

for template in "$src"/*.template; do
    target="$out/$(basename "${template%.template}")"
    [ -n "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ] || echo "18-modsec-render.sh: rendering $template to $target"
    envsubst "$vars" < "$template" > "$target"
done
