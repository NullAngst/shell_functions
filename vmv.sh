#!/usr/bin/env bash
#
# vmv - verbose move using rsync. Removes source files as they transfer,
# then deletes any source directories left empty.
#
# Usage: vmv <source> [source...] <destination>

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'vmv: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=vmv

usage() {
    printf 'Usage: %s <source> [source...] <destination>\n' "$prog"
}

main() {
    local missing=() cmd
    for cmd in rsync find; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf '%s: missing required commands: %s\n' "$prog" "${missing[*]}" >&2
        exit 1
    fi

    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac
    if [ "$#" -lt 2 ]; then
        usage >&2
        exit 1
    fi

    local args=("$@")
    local dest="${args[$# - 1]}"
    local sources=("${args[@]:0:$# - 1}")
    local src rc=0

    # -- ends option parsing so a source named like "-n" is a path, not a flag
    rsync -vpartlXEHhP --info=progress2 --remove-source-files -- "${sources[@]}" "$dest" || rc=$?

    if [ "$rc" -ne 0 ]; then
        printf '%s: rsync exited with %d, source directories left as they are\n' "$prog" "$rc" >&2
        exit "$rc"
    fi

    for src in "${sources[@]}"; do
        # A trailing slash means "the contents of", which still leaves the
        # directory itself behind as a source, so the same cleanup applies.
        if [ -d "$src" ]; then
            # -delete implies -depth: deepest empty dirs go first, working up
            # to the source dir itself if it ended up empty.
            find "$src" -type d -empty -delete 2>/dev/null || true
        fi
    done
}

main "$@"
