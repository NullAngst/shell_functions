#!/usr/bin/env bash
#
# vcp - verbose copy using rsync, skipping files that already exist at the
# destination.
#
# Usage: vcp [-h] [--] <source> [source...] <destination>

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'vcp: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=vcp

usage() {
    printf 'Usage: %s [-h] [--] <source> [source...] <destination>\n' "$prog"
    printf '  Copies with rsync and never overwrites a file that already exists.\n'
    printf '  Put -- before a source whose name starts with -.\n'
}

main() {
    if ! command -v rsync >/dev/null 2>&1; then
        printf '%s: missing required commands: rsync\n' "$prog" >&2
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

    if [ "$#" -lt 2 ]; then
        usage >&2
        exit 1
    fi

    # -- ends rsync's option parsing too, so a source named "-n" is a path
    rsync -vpartlXEHhP --info=progress2 --ignore-existing -- "$@"
}

main "$@"
