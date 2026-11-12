#!/bin/sh
# Generates /etc/nginx/modsec/rendered/block-page.conf at container start (included by hardening.conf): the friendly
# page a request blocked by ModSecurity gets instead of nginx's plain error page (EDGE_BLOCK_PAGE). The page is
# /etc/nginx/kickedro/block-page.html when mounted, else the built-in /usr/local/share/kickedro/block-page.html;
# every {{request_id}} in it becomes the request ID, which is also ModSecurity's transaction ID
# (modsecurity_transaction_id in modsecurity-http.conf), so the reference finds the audit log entry.
#
# How: nginx-proxy's generated vhosts proxy "location /", so an error_page URI would be sent to the backend, and the
# template is not ours to change. Instead an http-level sub_filter rewrites the body of nginx's own error page for the
# deny status. Its match strings come from maps that are empty for every other response, and a sub_filter whose match
# strings are all empty leaves the response alone (no change to Content-Length, Last-Modified or ETag). The maps are
# set only when the status is the deny status and both $upstream_status and $upstream_cache_status are empty: no
# upstream answered this request, and no cache was consulted for it (with proxy_cache and the like, every outcome,
# MISS, BYPASS, HIT, STALE, UPDATING, EXPIRED or REVALIDATED, sets $upstream_cache_status; a cache HIT has no upstream
# status). So nginx itself produced the response, and the match strings are exactly nginx's built-in page: a backend's
# page with the same status, fresh or from a cache, is never touched. The page text is held in geo variables, whose
# values nginx takes literally ($ is not interpreted), in pieces well below nginx's 4 KiB limit for one configuration
# token. msie_padding is switched off, so Chrome and MSIE also get exactly the page.
set -eu

custom=/etc/nginx/kickedro/block-page.html
builtin=/usr/local/share/kickedro/block-page.html
conf=/etc/nginx/modsec/rendered/block-page.conf
max_size=32768

die() { echo "19-kickedro-block-page.sh: ERROR: $*" >&2; exit 1; }

# Titles of nginx's built-in error pages for the allowed deny statuses (src/http/ngx_http_special_response.c).
case $MODSEC_DENY_STATUS in
    400) title='400 Bad Request';;
    403) title='403 Forbidden';;
    404) title='404 Not Found';;
    405) title='405 Not Allowed';;
    406) title='406 Not Acceptable';;
    410) title='410 Gone';;
    429) title='429 Too Many Requests';;
    *) title='';; # 444: nginx closes the connection without a response
esac

if [ "$EDGE_BLOCK_PAGE" = off ]; then
    echo "# EDGE_BLOCK_PAGE=off: blocked requests get nginx's plain error page." > "$conf"
    exit 0
fi
if [ -z "$title" ]; then
    echo "# MODSEC_DENY_STATUS=$MODSEC_DENY_STATUS sends no response, so there is no block page." > "$conf"
    exit 0
fi

page=$builtin
[ -e "$custom" ] && page=$custom
[ -f "$page" ] && [ -r "$page" ] || die "$page is not a readable file"
size=$(wc -c < "$page")
[ "$size" -gt 0 ] || die "$page is empty"
[ "$size" -le "$max_size" ] || die "$page is larger than $max_size bytes"
[ "$(tr -d '\000' < "$page" | wc -c)" -eq "$size" ] || die "$page contains NUL bytes"
[ -n "${NGINX_ENTRYPOINT_QUIET_LOGS:-}" ] || echo "19-kickedro-block-page.sh: block page from $page"

# awk reads the whole page as one record (RS is a byte that HTML does not contain; if it does, it is put back).
awk -v status="$MODSEC_DENY_STATUS" -v title="$title" -v source="$page" '
    function replace_all(s, from, to,    out, i) {
        out = ""
        while ((i = index(s, from)) > 0) {
            out = out substr(s, 1, i - 1) to
            s = substr(s, i + length(from))
        }
        return out s
    }
    function quote(s) { # text -> body of a double-quoted nginx configuration string
        return replace_all(replace_all(s, "\\", "\\\\"), "\"", "\\\"")
    }
    function literal(s,    i) { # page text -> geo variables of at most 1024 bytes, appended to the replacement
        for (i = 1; i <= length(s); i += 1024) {
            pieces++
            printf "geo $kickedro_block_page_%d { default \"%s\"; }\n", pieces, quote(substr(s, i, 1024))
            replacement = replacement "${kickedro_block_page_" pieces "}"
        }
    }
    function map(name, value) { # a match string, set only for the error page nginx itself sends with the deny status
        printf "map \"$status:$upstream_status:$upstream_cache_status\" $%s {\n    volatile;\n    default \"\";\n    \"%s::\" \"%s\";\n}\n", name, status, value
    }
    BEGIN { RS = "\001" }
    { page = (NR > 1) ? page RS $0 : $0 }
    END {
        printf "# Generated at container start by 19-kickedro-block-page.sh from %s.\n", source
        placeholder = "{{request_id}}"
        while ((i = index(page, placeholder)) > 0) {
            literal(substr(page, 1, i - 1))
            replacement = replacement "${request_id}"
            page = substr(page, i + length(placeholder))
        }
        literal(page)
        if (length(replacement) > 3500) {
            print "19-kickedro-block-page.sh: ERROR: too many {{request_id}} in " source > "/dev/stderr"
            exit 1
        }
        # nginx sends its error page in parts: the head for the status, then a tail that depends on server_tokens
        # (off: "nginx", on or build: "nginx/<version>"). The head becomes the page, the tail is removed.
        map("kickedro_block_head", "<html>\\r\\n<head><title>" title "</title></head>\\r\\n<body>\\r\\n<center><h1>" title "</h1></center>\\r\\n")
        map("kickedro_block_tail", "<hr><center>nginx</center>\\r\\n</body>\\r\\n</html>\\r\\n")
        map("kickedro_block_tail_version", "<hr><center>nginx/$nginx_version</center>\\r\\n</body>\\r\\n</html>\\r\\n")
        printf "sub_filter $kickedro_block_head \"%s\";\n", replacement
        print "sub_filter $kickedro_block_tail \"\";"
        print "sub_filter $kickedro_block_tail_version \"\";"
        # nginx appends padding comments to short error pages for MSIE and Chrome ("friendly error pages").
        print "msie_padding off;"
    }
' "$page" > "$conf.tmp"
mv "$conf.tmp" "$conf"
