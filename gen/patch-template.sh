#!/bin/sh
# Build-time patch of nginx-proxy's template for gen's hard off switches EDGE_HTTP2 and EDGE_HTTP3 (on or off, default
# on; kickedro-entrypoint.sh refuses any other value): patch-template.sh TEMPLATE_FILE (edited in place; gen/Dockerfile
# runs it on the template at NGINX_PROXY_REF).
# nginx-proxy's ENABLE_HTTP2 and ENABLE_HTTP3 are only defaults: a backend's label turns either protocol back on for
# its site, and the catch-all server (unknown names, connections without SNI) has "http2 on" whatever ENABLE_HTTP2 says.
# Three changes:
#  1. two config keys after enable_http3: edge_http2 and edge_http3, true unless the variable is "off";
#  2. each site's HTTP/2 and HTTP/3 decision (its label, else ENABLE_HTTP2 / ENABLE_HTTP3) is and-ed with its switch,
#     so no label wins over "off". The catch-all server's HTTP/3 (http3 on, quic) and the sites' alt-svc header follow
#     these decisions already;
#  3. the catch-all server's "http2 on;" is wrapped in the HTTP/2 switch.
# With both switches on, the template renders exactly what the unpatched one does (tests/split_smoke.sh compares them).
# Every line the patch relies on must be found exactly once, the three "http2 on;" lines exactly where expected, and
# every replaced line must be gone afterwards. Otherwise the patch prints "patch-template: <what>", exits 1 and leaves
# the file as it was: a template update that moves these lines stops the build instead of silently dropping a switch.
# The quotes and $ in the lines below are template text, not shell.
# shellcheck disable=SC2016,SC2089,SC2090
set -eu

die() { echo "patch-template: $*" >&2; exit 1; }

tmpl=${1:-}
[ -n "$tmpl" ] || die "usage: patch-template.sh TEMPLATE_FILE"
if [ ! -f "$tmpl" ] || [ ! -r "$tmpl" ]; then die "cannot read the template file '$tmpl'"; fi

# The exact lines (passed to awk through the environment, which keeps every character as it is).
P_ANCHOR='{{- $_ := set $config "enable_http3" ($globals.Env.ENABLE_HTTP3 | default "false") }}'
P_ADD2='{{- $_ := set $config "edge_http2" (ne ($globals.Env.EDGE_HTTP2 | default "on") "off") }}'
P_ADD3='{{- $_ := set $config "edge_http3" (ne ($globals.Env.EDGE_HTTP3 | default "on") "off") }}'
P_OLD2='    {{- $http2_enabled := groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http2.enable" | keys | first | default $globals.config.enable_http2 | parseBool }}'
P_NEW2='    {{- $http2_enabled := and $globals.config.edge_http2 (groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http2.enable" | keys | first | default $globals.config.enable_http2 | parseBool) }}'
P_OLD3='    {{- $http3_enabled := groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http3.enable" | keys | first | default $globals.config.enable_http3 | parseBool }}'
P_NEW3='    {{- $http3_enabled := and $globals.config.edge_http3 (groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http3.enable" | keys | first | default $globals.config.enable_http3 | parseBool) }}'
P_CATCHALL='server_name _; # This is just an invalid value'
P_HTTP2='    http2 on;'
P_SITE_IF='{{- if $vhost.http2_enabled }}'
P_WRAP_IF='    {{- if $globals.config.edge_http2 }}'
P_WRAP_END='    {{- end }}'
export P_ANCHOR P_ADD2 P_ADD3 P_OLD2 P_NEW2 P_OLD3 P_NEW3 P_CATCHALL P_HTTP2 P_SITE_IF P_WRAP_IF P_WRAP_END

# The result goes to a file next to the template (with its mode, so the image ships it as before) and replaces it
# only after every check below has passed.
tmp=$(mktemp "$tmpl.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cp -p "$tmpl" "$tmp"

awk '
function die(what) { print "patch-template: " what > "/dev/stderr"; exit 1 }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
{ line[NR] = $0 }
END {
    for (i = 1; i <= NR; i++) {
        if (line[i] == ENVIRON["P_ANCHOR"]) n_anchor++
        if (line[i] == ENVIRON["P_OLD2"]) n_old2++
        if (line[i] == ENVIRON["P_OLD3"]) n_old3++
        if (index(line[i], ENVIRON["P_CATCHALL"])) { n_catchall++; catchall = i }
        if (line[i] == ENVIRON["P_HTTP2"]) http2[++n_http2] = i
    }
    if (n_anchor != 1) die("the enable_http3 config line occurs " n_anchor + 0 " times, expected once")
    if (n_old2 != 1) die("the per-site HTTP/2 decision line occurs " n_old2 + 0 " times, expected once")
    if (n_old3 != 1) die("the per-site HTTP/3 decision line occurs " n_old3 + 0 " times, expected once")
    if (n_catchall != 1) die("the catch-all server_name line occurs " n_catchall + 0 " times, expected once")
    if (n_http2 != 3) die("\"http2 on;\" occurs " n_http2 + 0 " times, expected 3")
    # The catch-all server'\''s "http2 on;" is the first one after its server_name; the other two are the sites'\'' own.
    wrap = 0
    for (k = 1; k <= n_http2; k++) if (http2[k] > catchall) { wrap = http2[k]; break }
    if (!wrap) die("no \"http2 on;\" after the catch-all server_name line")
    for (k = 1; k <= n_http2; k++) {
        i = http2[k]
        if (i == wrap) continue
        if (trim(line[i - 1]) != ENVIRON["P_SITE_IF"] || trim(line[i + 1]) != "{{- end }}")
            die("\"http2 on;\" on line " i " is not the catch-all server'\''s and not inside " ENVIRON["P_SITE_IF"])
    }
    for (i = 1; i <= NR; i++) {
        if (i == wrap) { print ENVIRON["P_WRAP_IF"]; print line[i]; print ENVIRON["P_WRAP_END"]; continue }
        if (line[i] == ENVIRON["P_OLD2"]) { print ENVIRON["P_NEW2"]; continue }
        if (line[i] == ENVIRON["P_OLD3"]) { print ENVIRON["P_NEW3"]; continue }
        print line[i]
        if (line[i] == ENVIRON["P_ANCHOR"]) { print ENVIRON["P_ADD2"]; print ENVIRON["P_ADD3"] }
    }
}' "$tmpl" > "$tmp" || exit 1

# The result, checked on its own: every new line is there once, no replaced line is left, and every "http2 on;" comes
# right after the condition that guards it.
count() { grep -c -x -F -- "$1" "$tmp" || true; }
for new in "$P_ADD2" "$P_ADD3" "$P_NEW2" "$P_NEW3" "$P_WRAP_IF"; do
    [ "$(count "$new")" = 1 ] || die "after patching, this line does not occur exactly once: $new"
done
for old in "$P_OLD2" "$P_OLD3"; do
    [ "$(count "$old")" = 0 ] || die "after patching, a replaced line is still there: $old"
done
unguarded=$(awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    $0 == ENVIRON["P_HTTP2"] {
        n++
        if (trim(prev) != ENVIRON["P_SITE_IF"] && trim(prev) != trim(ENVIRON["P_WRAP_IF"])) printf " line %d", NR
    }
    { prev = $0 }
    END { if (n != 3) printf " %d times instead of 3", n }' "$tmp")
[ -z "$unguarded" ] || die "after patching, \"http2 on;\" is not guarded:$unguarded"

mv "$tmp" "$tmpl"
