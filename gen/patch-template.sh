#!/bin/sh
# Build-time patch of nginx-proxy's template for gen's hard off switches EDGE_HTTP2 and EDGE_HTTP3 (on or off, default
# on; kickedro-entrypoint.sh refuses any other value): patch-template.sh TEMPLATE_FILE (edited in place; gen/Dockerfile
# runs it on the template at NGINX_PROXY_REF).
# nginx-proxy's ENABLE_HTTP2 and ENABLE_HTTP3 are only defaults: a backend's label turns either protocol back on for
# its site, and the catch-all server (unknown names, connections without SNI) has "http2 on" whatever ENABLE_HTTP2 says.
# Three changes:
#  1. two keys of the template's $globals, set right after it takes its config map: edge_http2 and edge_http3, true
#     only when the variable is "on" (or unset or empty), so even a value that bypassed kickedro-entrypoint.sh leaves
#     the protocol off. They stay out of $globals.config, which the debug endpoint prints;
#  2. each site's HTTP/2 and HTTP/3 decision (its label, else ENABLE_HTTP2 / ENABLE_HTTP3) is and-ed with its switch,
#     so no label wins over "off". The catch-all server's HTTP/3 (http3 on, quic) and the sites' alt-svc header follow
#     these decisions already;
#  3. the catch-all server's "http2 on;" is wrapped in the HTTP/2 switch.
# With both switches on, the template renders exactly what the unpatched one does, debug endpoint included
# (tests/split_smoke.sh compares them).
# Every line the patch relies on must be found exactly once (counted on the text without leading and trailing spacing,
# so a copy spaced differently counts too; the lines changed must also match exactly), the three "http2 on;" lines
# exactly where expected, and every replaced line must be gone afterwards. The HTTP/3 lines the switch relies on must
# still be the template's known ones, and no listen line may switch HTTP/2 on by itself. Otherwise the patch prints
# "patch-template: <what>", exits 1 and leaves the file as it was: a template update that moves these lines, or adds
# another way to turn HTTP/2 or HTTP/3 on, stops the build for a person to port the switch, instead of silently
# shipping without it.
# The quotes and $ in the lines below are template text, not shell.
# shellcheck disable=SC2016,SC2089,SC2090
set -eu

die() { echo "patch-template: $*" >&2; exit 1; }

tmpl=${1:-}
[ -n "$tmpl" ] || die "usage: patch-template.sh TEMPLATE_FILE"
if [ ! -f "$tmpl" ] || [ ! -r "$tmpl" ]; then die "cannot read the template file '$tmpl'"; fi

# The exact lines (passed to awk through the environment, which keeps every character as it is).
P_ANCHOR='{{- $_ := set $globals "config" $config }}'
P_ADD2='{{- $_ := set $globals "edge_http2" (eq ($globals.Env.EDGE_HTTP2 | default "on") "on") }}'
P_ADD3='{{- $_ := set $globals "edge_http3" (eq ($globals.Env.EDGE_HTTP3 | default "on") "on") }}'
P_OLD2='    {{- $http2_enabled := groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http2.enable" | keys | first | default $globals.config.enable_http2 | parseBool }}'
P_NEW2='    {{- $http2_enabled := and $globals.edge_http2 (groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http2.enable" | keys | first | default $globals.config.enable_http2 | parseBool) }}'
P_OLD3='    {{- $http3_enabled := groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http3.enable" | keys | first | default $globals.config.enable_http3 | parseBool }}'
P_NEW3='    {{- $http3_enabled := and $globals.edge_http3 (groupByLabel $vhost_containers "com.github.nginx-proxy.nginx-proxy.http3.enable" | keys | first | default $globals.config.enable_http3 | parseBool) }}'
P_CATCHALL='server_name _; # This is just an invalid value'
P_HTTP2='    http2 on;'
P_SITE_IF='{{- if $vhost.http2_enabled }}'
P_WRAP_IF='    {{- if $globals.edge_http2 }}'
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
function once(name, var, n, at) { # the line (whatever its spacing) occurs once, and exactly as given
    if (n != 1) die(name " occurs " n + 0 " times, expected once")
    if (line[at] != ENVIRON[var]) die(name " (line " at ") differs from the expected one in its spacing")
}
{ line[NR] = $0 }
END {
    for (i = 1; i <= NR; i++) {
        t = trim(line[i])
        if (t == trim(ENVIRON["P_ANCHOR"])) { n_anchor++; anchor = i }
        if (t == trim(ENVIRON["P_OLD2"])) { n_old2++; old2 = i }
        if (t == trim(ENVIRON["P_OLD3"])) { n_old3++; old3 = i }
        if (index(line[i], ENVIRON["P_CATCHALL"])) { n_catchall++; catchall = i }
        if (t ~ /^http2[ \t]+on[ \t]*;/) http2[++n_http2] = i
    }
    once("the line that sets $globals.config", "P_ANCHOR", n_anchor, anchor)
    once("the per-site HTTP/2 decision line", "P_OLD2", n_old2, old2)
    once("the per-site HTTP/3 decision line", "P_OLD3", n_old3, old3)
    if (n_catchall != 1) die("the catch-all server_name line occurs " n_catchall + 0 " times, expected once")
    if (n_http2 != 3) die("\"http2 on;\" occurs " n_http2 + 0 " times, expected 3")
    # The catch-all server'\''s "http2 on;" is the first one after its server_name; the other two are the sites'\'' own.
    wrap = 0
    for (k = 1; k <= n_http2; k++) if (http2[k] > catchall) { wrap = http2[k]; break }
    if (!wrap) die("no \"http2 on;\" after the catch-all server_name line")
    if (line[wrap] != ENVIRON["P_HTTP2"]) die("the catch-all server'\''s \"http2 on;\" (line " wrap ") is not written as expected")
    for (k = 1; k <= n_http2; k++) {
        i = http2[k]
        if (i == wrap) continue
        if (trim(line[i - 1]) != ENVIRON["P_SITE_IF"] || trim(line[i + 1]) != "{{- end }}")
            die("\"http2 on;\" on line " i " is not the catch-all server'\''s and not inside " ENVIRON["P_SITE_IF"])
    }
    for (i = 1; i <= NR; i++) {
        if (i == wrap) { print ENVIRON["P_WRAP_IF"]; print line[i]; print ENVIRON["P_WRAP_END"]; continue }
        if (i == old2) { print ENVIRON["P_NEW2"]; continue }
        if (i == old3) { print ENVIRON["P_NEW3"]; continue }
        print line[i]
        if (i == anchor) { print ENVIRON["P_ADD2"]; print ENVIRON["P_ADD3"] }
    }
}' "$tmpl" > "$tmp" || exit 1

# The result, checked on its own (lines compared without leading and trailing spacing): every new line is there once, no
# replaced line is left, and every "http2 on;" comes right after the condition that guards it. HTTP/3 is switched off
# through the per-site decision alone, so the lines it governs must be exactly the template's known ones: two
# "http3 on;", four quic listen lines and one alt-svc header (all under $vhost.http3_enabled, or the catch-all
# server's $http3_enabled, which is made from them). And no listen line may carry the old "http2" parameter, which
# would turn HTTP/2 on whatever the switch says.
problems=$(awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    BEGIN { split("P_ANCHOR P_ADD2 P_ADD3 P_NEW2 P_NEW3 P_WRAP_IF P_OLD2 P_OLD3", names, " ") }
    {
        t = trim($0)
        for (k in names) if (t == trim(ENVIRON[names[k]])) seen[names[k]]++
        if (t ~ /^http2[ \t]+on[ \t]*;/) {
            n_http2++
            if (trim(prev) != ENVIRON["P_SITE_IF"] && trim(prev) != trim(ENVIRON["P_WRAP_IF"]))
                printf "; \"http2 on;\" on line %d is not guarded", NR
        }
        if (t ~ /^http3[ \t]+on[ \t]*;/) n_http3++
        if (t ~ /^listen[ \t]/ && t ~ /[ \t]quic([ \t;]|$)/) n_quic++
        if (tolower(t) ~ /^add_header[ \t]+alt-svc[ \t]/) n_altsvc++
        if (t ~ /^listen[ \t]/ && t ~ /[ \t]http2([ \t;]|$)/) printf "; listen with \"http2\" on line %d", NR
        prev = $0
    }
    END {
        for (k in names) {
            want = (names[k] ~ /^P_OLD/) ? 0 : 1
            if (seen[names[k]] + 0 != want) printf "; %s occurs %d times, expected %d", names[k], seen[names[k]], want
        }
        if (n_http2 != 3) printf "; \"http2 on;\" occurs %d times, expected 3", n_http2
        if (n_http3 != 2) printf "; \"http3 on;\" occurs %d times, expected 2", n_http3
        if (n_quic != 4) printf "; %d quic listen lines, expected 4", n_quic
        if (n_altsvc != 1) printf "; %d alt-svc add_header lines, expected 1", n_altsvc
    }' "$tmp")
[ -z "$problems" ] || die "after patching:${problems#;}"

mv "$tmp" "$tmpl"
