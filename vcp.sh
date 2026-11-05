#!/usr/bin/env bash
#
# vcp - verbose copy using rsync, skipping files that already exist at the
# destination.
#
# Usage: vcp <source> [source...] <destination>

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'vcp: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=vcp

usage() {
    printf 'Usage: %s <source> [source...] <destination>\n' "$prog"
}

main() {
    if ! command -v rsync >/dev/null 2>&1; then
        printf '%s: missing required commands: rsync\n' "$prog" >&2
        exit 1
    fi

    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac
    if [ "$#" -lt 2 ]; then
        usage >&2
        exit 1
    fi

    # -- ends option parsing so a source named like "-n" is a path, not a flag
    rsync -vpartlXEHhP --info=progress2 --ignore-existing -- "$@"
}

main "$@"
