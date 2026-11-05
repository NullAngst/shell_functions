#!/usr/bin/env bash
#
# cleandir - remove empty directories in the current directory.
#
# Usage: cleandir [-r]
#   -r   recurse: also remove empty directories in every subdirectory,
#        including parents that become empty once their children are gone

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'cleandir: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=cleandir

usage() {
    printf 'Usage: %s [-r]\n' "$prog"
    printf '  -r   recursively remove empty folders in all subdirectories\n'
}

main() {
    local recursive=0 opt

    if ! command -v find >/dev/null 2>&1; then
        printf '%s: missing required commands: find\n' "$prog" >&2
        exit 1
    fi

    while getopts ':rRh' opt; do
        case "$opt" in
            r|R) recursive=1 ;;
            h) usage; exit 0 ;;
            *) usage >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    if [ "$#" -gt 0 ]; then
        usage >&2
        exit 1
    fi

    if [ "$recursive" -eq 1 ]; then
        printf 'Recursively scanning for empty directories...\n'
        # -delete implies -depth, so nested empty dirs go bottom-up and a
        # parent emptied by that is caught in the same pass
        find . -mindepth 1 -type d -empty -print -delete
    else
        printf 'Scanning current directory for empty folders...\n'
        find . -mindepth 1 -maxdepth 1 -type d -empty -print -delete
    fi

    printf 'Clean complete.\n'
}

main "$@"
