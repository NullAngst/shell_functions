#!/usr/bin/env bash
#
# cleandir - remove empty directories in a directory (the current one by
# default).
#
# Usage: cleandir [-r] [dir]
#   -r   recurse: also remove empty directories in every subdirectory,
#        including parents that become empty once their children are gone

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'cleandir: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=cleandir

usage() {
    printf 'Usage: %s [-r] [dir]\n' "$prog"
    printf '  Removes empty folders in dir (default: the current directory).\n'
    printf '  -r   also remove empty folders in every subdirectory\n'
}

main() {
    local recursive=0 opt dir="."

    if ! command -v find >/dev/null 2>&1; then
        printf '%s: missing required commands: find\n' "$prog" >&2
        exit 1
    fi

    while getopts ':rRh-:' opt; do
        case "$opt" in
            r|R) recursive=1 ;;
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
    if [ "$#" -gt 1 ]; then
        usage >&2
        exit 1
    fi
    if [ "$#" -eq 1 ]; then
        dir="$1"
    fi
    if [ ! -d "$dir" ]; then
        printf '%s: "%s" is not a directory\n' "$prog" "$dir" >&2
        exit 1
    fi
    # find takes a leading - as an expression, so make such a name a path
    case "$dir" in
        -*) dir="./$dir" ;;
    esac

    # -mindepth, -maxdepth, -empty and -delete are not POSIX, but GNU, BSD
    # and BusyBox find all have them.
    if [ "$recursive" -eq 1 ]; then
        printf 'Recursively scanning "%s" for empty folders...\n' "$dir"
        # -delete implies -depth, so nested empty dirs go bottom-up and a
        # parent emptied by that is caught in the same pass
        find "$dir" -mindepth 1 -type d -empty -print -delete
    else
        printf 'Scanning "%s" for empty folders...\n' "$dir"
        find "$dir" -mindepth 1 -maxdepth 1 -type d -empty -print -delete
    fi

    printf 'Clean complete.\n'
}

main "$@"
