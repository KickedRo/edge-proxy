# shellcheck shell=sh
# Value rules of the edge image's settings (edge/settings.tsv): which values a setting allows, and which are weaker
# than its default. Functions only, sourced from /usr/local/share/kickedro/settings-lib.sh by
# docker-entrypoint.d/05-kickedro-settings.envsh (the settings check at start) and 90-kickedro-config-check.sh (judging
# a conf.d value the image gives way to), so both apply the same rules. The forms are described at the top of
# settings.tsv. POSIX sh: every function keeps its working variables under names of its own (no "local").

is_int() { # value max-digits -> true for a whole number from 1 with at most max-digits digits
    case $1 in ''|0*|*[!0-9]*) return 1;; esac
    [ "${#1}" -le "$2" ]
}
ms() { # <time> or 0 -> milliseconds
    case $1 in
        0) echo 0; return 0;;
        *ms) n=${1%ms} f=1;;
        *s) n=${1%s} f=1000;;
        *m) n=${1%m} f=60000;;
        *h) n=${1%h} f=3600000;;
        *) return 1;;
    esac
    is_int "$n" 9 || return 1
    echo $((n * f))
}
bytes() { # size in bytes, or with k or m -> bytes
    case $1 in
        *[kK]) n=${1%?} f=1024;;
        *[mM]) n=${1%?} f=1048576;;
        *) n=$1 f=1;;
    esac
    is_int "$n" 7 || return 1
    echo $((n * f))
}
items_are() { # value item-check -> true when value is 1 to 100 items separated by single spaces, each passing
    # item-check (a function name). Splitting on single spaces: a leading, trailing or double space makes an empty
    # item, which no check accepts.
    [ "${#1}" -le 2000 ] || return 1
    items_rest=$1 items_count=0
    while :; do
        items_item=${items_rest%% *}
        "$2" "$items_item" || return 1
        items_count=$((items_count + 1))
        [ "$items_count" -le 100 ] || return 1
        [ "$items_item" != "$items_rest" ] || return 0
        items_rest=${items_rest#* }
    done
}
method_item() { # an HTTP method: 1 to 32 capital letters and -, starting with a letter (PUT, VERSION-CONTROL)
    case $1 in ''|[!A-Z]*|*[!A-Z-]*) return 1;; esac
    [ "${#1}" -le 32 ]
}
content_type_item() { # |type/subtype| in lower case: letters, digits and . + _ -, each part starting with one of
    # the first two
    case $1 in '|'?*'|') ;; *) return 1;; esac
    ct=${1#|}
    ct=${ct%|}
    case $ct in
        */*/*|*[!a-z0-9./+_-]*) return 1;;
        [a-z0-9]*/[a-z0-9]*) [ "${#ct}" -le 127 ];;
        *) return 1;;
    esac
}
header_item() { # /name/: a header name in lower case, 1 to 64 letters, digits and -, starting with a letter or digit
    case $1 in '/'?*'/') ;; *) return 1;; esac
    hn=${1#/}
    hn=${hn%/}
    case $hn in ''|[!a-z0-9]*|*[!a-z0-9-]*) return 1;; esac
    [ "${#hn}" -le 64 ]
}
matches() { # value alternative -> true when value is that literal value or has that <form>
    case $2 in
        '<integer>') is_int "$1" 15;;
        '<time>') [ "$1" != 0 ] && ms "$1" >/dev/null;;
        '<buffers>') # nginx refuses a size below connection_pool_size (512 on 64-bit): at least 1k
            case $1 in
                *' '*' '*) return 1;;
                *' '*) is_int "${1%% *}" 4 && size=$(bytes "${1#* }") && [ "$size" -ge 1024 ];;
                *) return 1;;
            esac;;
        '<path>')
            case $1 in
                /|*[!A-Za-z0-9._/-]*) return 1;;
                /*) return 0;;
                *) return 1;;
            esac;;
        '<methods>') items_are "$1" method_item;;
        '<content-types>') items_are "$1" content_type_item;;
        '<headers>') items_are "$1" header_item;;
        *) [ "$1" = "$2" ];;
    esac
}
one_of() { # value alternatives -> true when value matches one of the |-separated alternatives
    rest=$2
    while :; do
        alt=${rest%%|*}
        if matches "$1" "$alt"; then return 0; fi
        [ "$alt" != "$rest" ] || return 1
        rest=${rest#*|}
    done
}
above() { # value threshold -> true when value is above the threshold (same form: number, time or buffers)
    case $2 in
        *' '*) [ "${1%% *}" -gt "${2%% *}" ] || [ "$(bytes "${1#* }")" -gt "$(bytes "${2#* }")" ];;
        *[0-9]) [ "$1" -gt "$2" ];;
        *) [ "$(ms "$1")" -gt "$(ms "$2")" ];;
    esac
}
adds_items() { # list other -> true when list has an item (separated by single spaces) that other does not have
    adds_rest=$1
    while :; do
        adds_item=${adds_rest%% *}
        case " $2 " in *" $adds_item "*) ;; *) return 0;; esac
        [ "$adds_item" != "$adds_rest" ] || return 1
        adds_rest=${adds_rest#* }
    done
}
weaker() { # value WEAKER_IF default -> true when value is weaker than the default (value must be allowed)
    case $2 in
        -) return 1;;
        '>'*) above "$1" "${2#>}";;
        +) adds_items "$1" "$3";;
        '<') adds_items "$3" "$1";; # a list that lacks an item of the default
        *) one_of "$1" "$2";;
    esac
}
explain() { # ALLOWED -> the forms it uses, explained (as in the header of settings.tsv)
    case $1 in *'<integer>'*) printf ' <integer> is a whole number from 1, at most 15 digits.';; esac
    case $1 in *'<time>'*) printf ' <time> is a whole number from 1, at most 9 digits, with the unit ms, s, m or h, e.g. 10s.';; esac
    case $1 in *'<buffers>'*) printf ' <buffers> is a count (1 to 4 digits) and a size of at least 1k (bytes, or with k or m, at most 7 digits), e.g. 4 8k.';; esac
    case $1 in *'<path>'*) printf ' <path> is an absolute file path (letters, digits and . _ / - only).';; esac
    case $1 in *'<methods>'*) printf ' <methods> is a list of HTTP methods separated by single spaces, each of capital letters and -, e.g. GET HEAD POST OPTIONS PUT.';; esac
    case $1 in *'<content-types>'*) printf ' <content-types> is a list of |type/subtype| items in lower case separated by single spaces, e.g. |application/json| |text/plain|.';; esac
    case $1 in *'<headers>'*) printf ' <headers> is a list of /name/ items (header names in lower case: letters, digits and -) separated by single spaces, e.g. /proxy/ /if/.';; esac
}
