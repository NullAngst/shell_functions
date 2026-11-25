#!/usr/bin/env bash
#
# ffile - forensic file analysis. Pulls every available piece of metadata
# and content hinting from a file to help identify what it is, who or what
# made it, and when: stat, checksums, attributes, ACLs, hex header and tail,
# strings, exiftool metadata, binwalk signatures, and entropy.
#
# Usage: ffile [-h] [--] <filepath>
#
# Optional tools for fuller output: exiftool, binwalk, xxd or hexdump,
# strings, getfattr, getfacl, lsattr, lsof, ent (or python3 as a fallback
# for the entropy estimate). A missing optional tool just means less output.

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'ffile: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=ffile
sep="================================================================================"

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    printf 'Usage: %s [-h] [--] <filepath>\n' "$prog"
    printf '  Prints everything that can be learned about a file: stat, type,\n'
    printf '  checksums, attributes, hex dumps, strings, metadata and entropy.\n'
}

header() {
    printf '\n%s\n  %s\n%s\n' "$sep" "$1" "$sep"
}

# Raw file content can carry terminal escape sequences that would rewrite the
# screen. Anything outside printable ASCII, tab and newline becomes a dot.
printable_only() {
    LC_ALL=C tr -c '[:print:]\t\n' '.'
}

# Absolute path with symlinks resolved, without GNU readlink -f.
resolve_path() {
    local p="$1" dir base link i=0
    if have realpath; then
        realpath -- "$p" 2>/dev/null && return 0
    fi
    # Fallback: walk the symlink chain by hand, capped so a loop can't hang
    while [ -L "$p" ] && [ "$i" -lt 40 ]; do
        link="$(readlink -- "$p")"
        case "$link" in
            /*) p="$link" ;;
            *) p="$(dirname -- "$p")/$link" ;;
        esac
        i=$((i + 1))
    done
    dir="$(dirname -- "$p")"
    base="${p##*/}"
    if dir="$(cd -P -- "$dir" 2>/dev/null && pwd -P)"; then
        printf '%s\n' "${dir%/}/$base"
    else
        printf '%s\n' "$p"
    fi
}

entropy_python() {
    python3 - "$1" <<'PYEOF'
import collections
import math
import sys

# Read in 1 MiB chunks so a multi-GB file doesn't get loaded into RAM at once
counts = collections.Counter()
total = 0
try:
    with open(sys.argv[1], "rb") as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            counts.update(chunk)
            total += len(chunk)
except OSError as e:
    print(f"  Entropy calculation failed: {e}")
    sys.exit(0)

if total == 0:
    print("  File is empty.")
    sys.exit(0)

entropy = -sum((c / total) * math.log2(c / total) for c in counts.values())
print(f"  Byte entropy : {entropy:.4f} bits/byte  (max 8.0)")
print(f"  Total bytes  : {total}")
print(f"  Unique bytes : {len(counts)}")
if entropy > 7.5:
    print("  Interpretation: very high entropy, likely compressed, encrypted, or packed.")
elif entropy > 6.0:
    print("  Interpretation: moderate-high entropy, possibly compressed or binary data.")
elif entropy < 1.0:
    print("  Interpretation: very low entropy, highly repetitive or near-empty file.")
else:
    print("  Interpretation: entropy consistent with normal text or structured binary.")
PYEOF
}

main() {
    local missing=() cmd
    for cmd in stat file wc du od dd sed tail tr cksum; do
        have "$cmd" || missing+=("$cmd")
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
                    *) printf '%s: unknown option --%s\n' "$prog" "$OPTARG" >&2; usage >&2; exit 1 ;;
                esac
                ;;
            *) printf '%s: unknown option -%s\n' "$prog" "$OPTARG" >&2; usage >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    if [ "$#" -ne 1 ] || [ -z "$1" ]; then
        usage >&2
        exit 1
    fi

    local target="$1" real safe
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        printf '%s: "%s" does not exist\n' "$prog" "$target" >&2
        exit 1
    fi
    real="$(resolve_path "$target")"
    # Some of the optional tools don't honor --, so a name starting with -
    # gets a ./ prefix for those instead.
    safe="$target"
    case "$safe" in
        -*) safe="./$safe" ;;
    esac

    header "IDENTITY"
    printf '  Provided path : %s\n' "$target"
    printf '  Resolved path : %s\n' "$real"
    if [ -L "$target" ]; then
        printf '  Symlink target: %s\n' "$(readlink -- "$target" || printf '?')"
    fi

    header "STAT (timestamps, permissions, inode)"
    stat -- "$target" || true

    header "FILE TYPE DETECTION"
    printf '[file]\n'
    file -- "$target" || true
    printf '\n[file --mime]\n'
    file --mime -- "$target" || true

    # Everything below reads content, which only makes sense for a regular file
    if [ ! -f "$target" ]; then
        header "DONE"
        printf '  "%s" is not a regular file, content checks skipped.\n\n' "$target"
        exit 0
    fi

    header "CHECKSUMS"
    for cmd in md5sum sha1sum sha256sum sha512sum b2sum; do
        if have "$cmd"; then
            "$cmd" -- "$target" 2>/dev/null || printf '  %s failed\n' "$cmd"
        fi
    done
    printf 'cksum: '
    cksum < "$target" || true

    header "SIZE / COUNTS"
    printf '  lines words bytes: %s\n' "$(wc < "$target" || printf '?')"
    du -k -- "$target" 2>/dev/null | { read -r kb _ && printf '  on-disk usage: %s KiB\n' "$kb"; } || true

    header "FILESYSTEM ATTRIBUTES (lsattr)"
    if have lsattr; then
        lsattr -- "$target" 2>/dev/null || printf '  Not supported on this filesystem.\n'
    else
        printf '  lsattr not installed.\n'
    fi

    header "EXTENDED ATTRIBUTES (getfattr)"
    if have getfattr; then
        local xattrs
        xattrs="$(getfattr -d -- "$target" 2>/dev/null || true)"
        if [ -n "$xattrs" ]; then
            printf '%s\n' "$xattrs"
        else
            printf '  No extended attributes found.\n'
        fi
    else
        printf '  getfattr not installed.\n'
    fi

    header "ACCESS CONTROL LIST (getfacl)"
    if have getfacl; then
        getfacl -- "$target" 2>/dev/null || printf '  Could not read ACLs.\n'
    else
        printf '  getfacl not installed.\n'
    fi

    header "OPEN FILE HANDLES (lsof)"
    if have lsof; then
        lsof "$real" 2>/dev/null || printf '  File is not currently open by any process you can see.\n'
    else
        printf '  lsof not installed.\n'
    fi

    header "PACKAGE OWNERSHIP"
    local checked=0
    if have dpkg; then
        checked=1
        dpkg -S "$real" 2>/dev/null || printf '  Not owned by any dpkg package.\n'
    fi
    if have rpm; then
        checked=1
        rpm -qf "$real" 2>/dev/null || printf '  Not owned by any RPM package.\n'
    fi
    if have pacman; then
        checked=1
        pacman -Qo "$real" 2>/dev/null || printf '  Not owned by any pacman package.\n'
    fi
    if have apk; then
        checked=1
        apk info --who-owns "$real" 2>/dev/null || printf '  Not owned by any apk package.\n'
    fi
    if have qfile; then
        checked=1
        qfile -- "$real" 2>/dev/null || printf '  Not owned by any Portage package.\n'
    fi
    if [ "$checked" -eq 0 ]; then
        printf '  No supported package manager found.\n'
    fi

    header "HEX HEADER (first 256 bytes)"
    if have xxd; then
        xxd -l 256 "$safe" 2>/dev/null || true
    elif have hexdump; then
        hexdump -C -n 256 "$safe" 2>/dev/null || true
    else
        od -A x -t x1 -N 256 "$safe" 2>/dev/null || true
    fi

    # tail -c seeks to near EOF instead of dumping the whole file, which on a
    # multi-GB file would take minutes.
    header "HEX TAIL (last 256 bytes)"
    if have xxd; then
        tail -c 256 -- "$target" 2>/dev/null | xxd || true
    elif have hexdump; then
        tail -c 256 -- "$target" 2>/dev/null | hexdump -C || true
    else
        tail -c 256 -- "$target" 2>/dev/null | od -A x -t x1 || true
    fi

    header "PRINTABLE STRINGS (min length 6, first 80 results)"
    if have strings; then
        # sed reads to the end, so strings never dies on a closed pipe
        strings -n 6 -- "$target" 2>/dev/null | sed -n '1,80p' || true
    else
        printf '  strings not installed.\n'
    fi

    # Only the first and last 4 KiB are looked at, so a binary with no
    # newlines can't dump gigabytes to the terminal.
    header "HEAD (first 20 lines of raw content, non-printable bytes shown as .)"
    dd if="$target" bs=4096 count=1 2>/dev/null | sed -n '1,20p' | printable_only || true
    printf '\n'

    header "TAIL (last 20 lines of raw content, non-printable bytes shown as .)"
    tail -c 4096 -- "$target" 2>/dev/null | tail -n 20 | printable_only || true
    printf '\n'

    header "EXIFTOOL METADATA"
    if have exiftool; then
        exiftool "$safe" 2>/dev/null || true
    else
        printf '  exiftool not installed. Install it for deep metadata on images, PDFs, office docs.\n'
        printf '  (Debian/Ubuntu: libimage-exiftool-perl, openSUSE/Fedora: perl-Image-ExifTool, or whichever your distro calls it)\n'
    fi

    header "BINWALK (embedded file signatures)"
    if have binwalk; then
        binwalk "$safe" 2>/dev/null || true
    else
        printf '  binwalk not installed.\n'
    fi

    header "ENTROPY ESTIMATE"
    if have ent; then
        ent "$safe" 2>/dev/null || true
    elif have python3; then
        entropy_python "$target"
    else
        printf '  Neither ent nor python3 is available for entropy calculation.\n'
    fi

    header "DONE"
    printf '  Target: %s\n\n' "$target"
}

# The file name, metadata fields and tool output can all carry escape
# sequences a terminal would act on, which is exactly what a suspicious file
# might try. On a terminal, control bytes other than tab and newline are
# shown as dots. Piped or redirected output is left alone.
if [ -t 1 ]; then
    # 31 control bytes in, 31 dots out: equal-length sets keep tr portable
    dots="$(printf '%31s' '' | tr ' ' '.')"
    main "$@" | tr '\000-\010\013-\037\177' "$dots"
else
    main "$@"
fi
