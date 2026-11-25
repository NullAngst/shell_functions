#!/usr/bin/env bash
#
# decode - print every plausible decoding of one string: base64 (standard
# and URL-safe), base32, base85/Z85, hex, octal, decimal, binary,
# URL/percent, ROT13, ROT47, Atbash, HTML entities, and all 25 Caesar shifts.
# Schemes the input can't be are left blank.
#
# Usage: decode [-h] [--] '<string>'

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'decode: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=decode

usage() {
    printf "Usage: %s [-h] [--] '<string>'\n" "$prog"
    printf '  Prints every plausible decoding of the string. Put -- before a string\n'
    printf '  that starts with -.\n'
}

# Byte-level tr and regex ranges, independent of the user's locale
export LC_ALL=C

# Print one byte given its value (0-255).
byte_out() {
    printf '%b' "\\x$(printf '%02x' "$1")"
}

# Print the UTF-8 encoding of a Unicode code point.
utf8_out() {
    local cp=$1
    if [ "$cp" -le 127 ]; then
        byte_out "$cp"
    elif [ "$cp" -le 2047 ]; then
        byte_out "$(( 0xC0 | (cp >> 6) ))"
        byte_out "$(( 0x80 | (cp & 0x3F) ))"
    elif [ "$cp" -le 65535 ]; then
        byte_out "$(( 0xE0 | (cp >> 12) ))"
        byte_out "$(( 0x80 | ((cp >> 6) & 0x3F) ))"
        byte_out "$(( 0x80 | (cp & 0x3F) ))"
    else
        byte_out "$(( 0xF0 | (cp >> 18) ))"
        byte_out "$(( 0x80 | ((cp >> 12) & 0x3F) ))"
        byte_out "$(( 0x80 | ((cp >> 6) & 0x3F) ))"
        byte_out "$(( 0x80 | (cp & 0x3F) ))"
    fi
}

# Decode a whitespace-separated list of byte tokens in a given base, if every
# token is a valid byte in that base. Args: base pattern input
decode_tokens() {
    local base="$1" pattern="$2" input="$3" token val
    local -a tokens=() values=()
    read -r -a tokens <<< "$input" || true
    [ "${#tokens[@]}" -gt 0 ] || return 0
    for token in "${tokens[@]}"; do
        [[ "$token" =~ $pattern ]] || return 0
        val=$(( ${base}#${token} ))
        [ "$val" -le 255 ] || return 0
        values+=("$val")
    done
    for val in "${values[@]}"; do
        byte_out "$val"
    done
}

decode_html() {
    local s="$1" out="" match code val
    # Named entities first. &mdash; and &ndash; become numeric references
    # here so the numeric pass below emits the real characters.
    s="$(printf '%s' "$s" | sed \
        -e 's/&lt;/</g' \
        -e 's/&gt;/>/g' \
        -e 's/&quot;/"/g' \
        -e "s/&apos;/'/g" \
        -e 's/&nbsp;/\&#160;/g' \
        -e 's/&copy;/\&#169;/g' \
        -e 's/&reg;/\&#174;/g' \
        -e 's/&trade;/\&#8482;/g' \
        -e 's/&hellip;/\&#8230;/g' \
        -e 's/&mdash;/\&#8212;/g' \
        -e 's/&ndash;/\&#8211;/g')"
    while [[ "$s" =~ \&#(x[0-9A-Fa-f]+|X[0-9A-Fa-f]+|[0-9]+)\; ]]; do
        match="${BASH_REMATCH[0]}"
        code="${BASH_REMATCH[1]}"
        out+="${s%%"$match"*}"
        # Very long digit runs would overflow arithmetic, so they stay literal
        if [ "${#code}" -gt 8 ]; then
            val=-1
        elif [[ "$code" == [xX]* ]]; then
            val=$(( 16#${code:1} ))
        else
            val=$(( 10#$code ))
        fi
        if [ "$val" -ge 0 ] && [ "$val" -le 1114111 ] && { [ "$val" -lt 55296 ] || [ "$val" -gt 57343 ]; }; then
            out+="$(utf8_out "$val")"
        else
            out+="$match"
        fi
        s="${s#*"$match"}"
    done
    out+="$s"
    # &amp; last, so "&amp;lt;" decodes to the text "&lt;" and not to "<"
    printf '%s' "$out" | sed 's/&amp;/\&/g'
}

main() {
    local missing=() cmd
    for cmd in base64 base32 tr sed; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf '%s: missing required commands: %s\n' "$prog" "${missing[*]}" >&2
        exit 1
    fi

    local opt
    while getopts ':h-:' opt; do
        case "$opt" in
            h) usage; exit 0 ;;
            -)
                case "$OPTARG" in
                    help) usage; exit 0 ;;
                    *) printf '%s: unknown option --%s (put -- before a string that starts with -)\n' "$prog" "$OPTARG" >&2; exit 1 ;;
                esac
                ;;
            *) printf '%s: unknown option -%s (put -- before a string that starts with -)\n' "$prog" "$OPTARG" >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))

    if [ "$#" -ne 1 ] || [ -z "$1" ]; then
        usage >&2
        exit 1
    fi

    local input="$1" clean pad eq i shift_n up low

    printf 'Base64 Decode: '
    clean="$(printf '%s' "$input" | tr -d ' \t\n')"
    if [[ "$clean" =~ ^[A-Za-z0-9+/]+=?=?$ ]]; then
        printf '%s' "$clean" | base64 -d 2>/dev/null || true
    fi
    printf '\n'

    printf 'Base64 URL-safe Decode: '
    clean="$(printf '%s' "$input" | tr -d ' \t\n')"
    clean="${clean//-/+}"
    clean="${clean//_//}"
    if [[ "$clean" =~ ^[A-Za-z0-9+/]+=?=?$ ]]; then
        pad=$(( (4 - ${#clean} % 4) % 4 ))
        eq="==="
        clean+="${eq:0:pad}"
        printf '%s' "$clean" | base64 -d 2>/dev/null || true
    fi
    printf '\n'

    printf 'Base32 Decode: '
    clean="$(printf '%s' "$input" | tr -d ' \t\n' | tr '[:lower:]' '[:upper:]')"
    if [[ "$clean" =~ ^[A-Z2-7]+=*$ ]]; then
        printf '%s' "$clean" | base32 -d 2>/dev/null || true
    fi
    printf '\n'

    printf 'Base85 (Z85) Decode: '
    if command -v basenc >/dev/null 2>&1; then
        clean="$(printf '%s' "$input" | tr -d ' \t\n')"
        if [ -n "$clean" ] && [ $(( ${#clean} % 5 )) -eq 0 ]; then
            printf '%s' "$clean" | basenc --z85 -d 2>/dev/null || true
        fi
    else
        printf '(needs basenc from coreutils 8.31+)'
    fi
    printf '\n'

    printf 'Hexadecimal Decode: '
    clean="$(printf '%s' "$input" | tr -d ' \t')"
    clean="${clean#0x}"
    if [[ "$clean" =~ ^[0-9A-Fa-f]+$ ]] && [ $(( ${#clean} % 2 )) -eq 0 ]; then
        for (( i = 0; i < ${#clean}; i += 2 )); do
            byte_out "$(( 16#${clean:i:2} ))"
        done
    fi
    printf '\n'

    printf 'Octal Decode: '
    decode_tokens 8 '^[0-7]{1,3}$' "$input"
    printf '\n'

    printf 'Decimal Decode: '
    decode_tokens 10 '^[0-9]{1,3}$' "$input"
    printf '\n'

    printf 'Binary Decode: '
    clean="$(printf '%s' "$input" | tr -d ' \t')"
    if [[ "$clean" =~ ^[01]+$ ]] && [ $(( ${#clean} % 8 )) -eq 0 ]; then
        for (( i = 0; i < ${#clean}; i += 8 )); do
            byte_out "$(( 2#${clean:i:8} ))"
        done
    fi
    printf '\n'

    printf 'URL Decode: '
    clean="${input//\\/\\\\}"
    clean="${clean//+/ }"
    printf '%b' "${clean//%/\\x}"
    printf '\n'

    printf 'ROT13 Decode: '
    printf '%s' "$input" | tr 'A-Za-z' 'N-ZA-Mn-za-m'
    printf '\n'

    printf 'ROT47 Decode: '
    printf '%s' "$input" | tr '!-~' 'P-~!-O'
    printf '\n'

    printf 'Atbash Decode: '
    printf '%s' "$input" | tr 'A-Za-z' 'ZYXWVUTSRQPONMLKJIHGFEDCBAzyxwvutsrqponmlkjihgfedcba'
    printf '\n'

    printf 'HTML Entity Decode: '
    decode_html "$input"
    printf '\n'

    printf -- '--- All 25 Caesar/ROT Shifts ---\n'
    up="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    low="abcdefghijklmnopqrstuvwxyz"
    for (( shift_n = 1; shift_n <= 25; shift_n++ )); do
        printf '  Shift %2d: %s\n' "$shift_n" \
            "$(printf '%s' "$input" | tr "$up$low" "${up:shift_n}${up:0:shift_n}${low:shift_n}${low:0:shift_n}")"
    done
}

# Decoded bytes can be anything, including escape sequences that a terminal
# would act on. On a terminal, control bytes other than tab and newline are
# shown as dots. Piped or redirected output stays byte-exact.
if [ -t 1 ]; then
    # 31 control bytes in, 31 dots out: equal-length sets keep tr portable
    dots="$(printf '%31s' '' | tr ' ' '.')"
    main "$@" | tr '\000-\010\013-\037\177' "$dots"
else
    main "$@"
fi
