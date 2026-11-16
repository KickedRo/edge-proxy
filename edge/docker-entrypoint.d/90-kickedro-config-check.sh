#!/bin/sh
# Checks the finished nginx configuration at container start, with nginx's own parser (nginx -T). Runs after every
# script that writes nginx configuration: the image's 18-kickedro-render.sh and 19-kickedro-block-page.sh, and the
# official 20-envsubst-on-templates.sh and 30-tune-worker-processes.sh.
#
# 1. Proxy-wide files in conf.d. conf.d/*.conf is included at http level, like the image's hardening
#    (/etc/nginx/modsec/rendered/hardening.conf and block-page.conf), and nginx refuses a directive of that kind that
#    is set twice at the same level, whatever the order ("directive is duplicate"). So a proxy-wide file that sets one
#    of the directives the image sets from a setting would stop nginx (nginx-proxy's own documented example sets
#    server_tokens). Instead the image gives way: while nginx -T fails with
#      "<directive>" directive is duplicate in /etc/nginx/conf.d/<file>:<line>
#    for one of those directives, the directive is commented out of the image's rendered file and nginx is asked again
#    (at most once per directive). Once nginx accepts the configuration, one line per directive given up, naming the
#    file and line and the setting that is no longer applied: NOTICE when the file's value is as strict as the
#    setting's default, SECURITY when it is weaker or cannot be compared (the rules of settings.tsv, from
#    settings-lib.sh, as at the settings check). Any other failure is left alone: nginx then refuses to start with its
#    own message, as without this script. Only the image's rendered files are changed, never conf.d.
# 2. The image's includes. A replaced /etc/nginx/nginx.conf that does not include the WAF (modsecurity-http.conf) or
#    the hardening (hardening.conf) runs without them: that prints a SECURITY line, and nginx still starts.
#
# It runs at start only: a conflicting file added later makes the next reload fail (the running configuration keeps
# serving), and after removing such a file the directive stays unset until the next start.
set -eu

tsv=/usr/local/share/kickedro/settings.tsv
rendered=/etc/nginx/modsec/rendered
settings_docs=https://github.com/KickedRo/edge-proxy/blob/main/docs/settings.md
config_docs=https://github.com/KickedRo/edge-proxy/blob/main/docs/configuration.md
tab=$(printf '\t')
# The value rules of the settings (one_of, weaker), shared with 05-kickedro-settings.envsh.
. /usr/local/share/kickedro/settings-lib.sh

setting_of() { # directive -> the setting the image sets it from (fails for a directive the image does not manage)
    case $1 in
        server_tokens) echo EDGE_SERVER_TOKENS;;
        client_header_timeout) echo EDGE_CLIENT_HEADER_TIMEOUT;;
        client_body_timeout) echo EDGE_CLIENT_BODY_TIMEOUT;;
        send_timeout) echo EDGE_SEND_TIMEOUT;;
        keepalive_timeout) echo EDGE_KEEPALIVE_TIMEOUT;;
        large_client_header_buffers) echo EDGE_LARGE_HEADER_BUFFERS;;
        add_header_inherit) echo EDGE_SECURITY_HEADERS;;
        msie_padding) echo EDGE_BLOCK_PAGE;;
        *) return 1;;
    esac
}

as_setting() { # directive value -> that value in the terms of the directive's setting (unchanged if there is none)
    case $1 in
        client_header_timeout|client_body_timeout|send_timeout|keepalive_timeout)
            # The first argument (keepalive_timeout's second one is the Keep-Alive header's value). A bare number is
            # seconds to nginx.
            t=${2%% *}
            case $t in
                0|''|*[!0-9]*) printf '%s\n' "$t";;
                *) printf '%ss\n' "$t";;
            esac;;
        add_header_inherit) # merge is what the image sets; on and off drop the http-level headers wherever a server
            # or location adds headers of its own, as EDGE_SECURITY_HEADERS=off drops them everywhere
            case $2 in merge) echo on;; on|off) echo off;; *) printf '%s\n' "$2";; esac;;
        msie_padding) # either value leaves the block page on; without "off" it is padded for MSIE and Chrome
            case $2 in on|off) echo on;; *) printf '%s\n' "$2";; esac;;
        *) printf '%s\n' "$2";;
    esac
}

file_value() { # file line directive -> the arguments of that directive on that line, separated by single spaces
    # (nothing if the line does not hold it, for example when it spans several lines)
    awk -v n="$2" -v d="$3" 'NR == n {
        sub(/#.*/, "")
        k = split($0, statements, ";")
        for (i = 1; i < k; i++) { # every statement that ends on this line
            s = statements[i]
            sub(/^.*[{}]/, "", s)
            m = split(s, words, /[ \t]+/)
            value = ""; name = ""
            for (j = 1; j <= m; j++) {
                if (words[j] == "") continue
                if (name == "") name = words[j]
                else value = (value == "") ? words[j] : value " " words[j]
            }
            if (name == d) { print value; exit }
        }
        exit
    }' "$1" 2>/dev/null | tr -d '\000-\037' | cut -c 1-200
}

give_way() { # directive -> comments it out of the image's rendered file that sets it (fails if none does)
    for f in "$rendered/hardening.conf" "$rendered/block-page.conf"; do
        if grep -q "^$1[[:space:]]" "$f" 2>/dev/null; then
            sed -i "s/^$1[[:space:]]/# set by a conf.d file instead (see the start-up log): &/" "$f"
            return 0
        fi
    done
    return 1
}

report() { # file line directive -> prints the NOTICE or SECURITY line for a directive the image gave way to
    var=$(setting_of "$3")
    value=$(file_value "$1" "$2" "$3")
    IFS=$tab read -r _ default allowed weak risk _ <<EOF
$(awk -F '\t' -v v="$var" '$1 == v' "$tsv")
EOF
    current=$(printenv "$var" || true)
    anchor=$(printf '%s' "$var" | tr '[:upper:]' '[:lower:]')
    what="$1:$2 sets \"$3${value:+ $value}\" for the whole server, so the image does not set $3 from $var=$current"
    setting=$(as_setting "$3" "$value")
    if [ -z "$value" ] || ! one_of "$setting" "$allowed"; then
        printf 'SECURITY: %s, and cannot compare that value with the default %s: %s See %s#%s\n' \
            "$what" "$default" "$risk" "$settings_docs" "$anchor"
    elif weaker "$setting" "$weak" "$default"; then
        printf 'SECURITY: %s, and that value is weaker than the default %s: %s See %s#%s\n' \
            "$what" "$default" "$risk" "$settings_docs" "$anchor"
    else
        printf 'NOTICE: %s. See %s#proxy-wide-files-in-confd\n' "$what" "$config_docs"
    fi
}

# 1. Give way to proxy-wide files, one directive per round; the first round nginx accepts ends the loop. The lines are
# printed only then: when nginx refuses the configuration anyway, its own error is the message.
rounds=0
messages=''
until out=$(nginx -T 2>&1); do
    # nginx stops at the first error, so this is the only one reported.
    duplicate=$(printf '%s\n' "$out" | sed -n \
        's|^nginx: \[emerg\] "\([a-z_]*\)" directive is duplicate in \(/etc/nginx/conf\.d/.*\):\([0-9][0-9]*\)$|\1 \3 \2|p' \
        | head -n 1)
    [ -n "$duplicate" ] || exit 0 # another error: nginx reports it when it starts
    directive=${duplicate%% *}
    place=${duplicate#* }
    line=${place%% *}
    file=${place#* }
    setting_of "$directive" >/dev/null || exit 0 # not set by the image
    give_way "$directive" || exit 0              # no longer set by the image: two conf.d files set it
    messages="$messages$(report "$file" "$line" "$directive")
"
    rounds=$((rounds + 1))
    [ "$rounds" -le 8 ] || exit 0 # each of the 8 directives can be given up once; a safeguard only
done
printf '%s' "$messages" >&2

# 2. The configuration nginx accepted: does it still include the WAF and the hardening?
included() { printf '%s\n' "$out" | grep -qxF "# configuration file $1:"; }
if ! included /etc/nginx/modsecurity-http.conf; then
    printf 'SECURITY: the nginx configuration does not include /etc/nginx/modsecurity-http.conf (a replaced /etc/nginx/nginx.conf?), so ModSecurity is off: no request is inspected or blocked by the WAF. See %s#a-replaced-nginxconf\n' \
        "$config_docs" >&2
fi
if ! included /etc/nginx/modsec/rendered/hardening.conf; then
    printf 'SECURITY: the nginx configuration does not include /etc/nginx/modsec/rendered/hardening.conf (a replaced /etc/nginx/nginx.conf?), so none of the EDGE_* settings is applied: no short client timeouts, security headers, hidden backend headers or block page. See %s#a-replaced-nginxconf\n' \
        "$config_docs" >&2
fi
exit 0
