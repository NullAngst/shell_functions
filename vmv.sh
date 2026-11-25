#!/usr/bin/env bash
#
# vmv - verbose move using rsync. Removes source files as they transfer,
# then deletes any source directories left empty.
#
# Usage: vmv [-h] [--] <source> [source...] <destination>

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'vmv: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=vmv

usage() {
    printf 'Usage: %s [-h] [--] <source> [source...] <destination>\n' "$prog"
    printf '  Moves with rsync, then removes source directories left empty.\n'
    printf '  Put -- before a source whose name starts with -.\n'
}

need_cmds() {
    local missing=() cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf '%s: missing required commands: %s\n' "$prog" "${missing[*]}" >&2
        exit 1
    fi
}

main() {
    need_cmds rsync find

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

    local args=("$@")
    local dest="${args[$# - 1]}"
    local sources=("${args[@]:0:$# - 1}")
    local src rc=0

    # -- ends rsync's option parsing too, so a source named "-n" is a path
    rsync -vpartlXEHhP --info=progress2 --remove-source-files -- "${sources[@]}" "$dest" || rc=$?

    if [ "$rc" -ne 0 ]; then
        printf '%s: rsync exited with %d, source directories left as they are\n' "$prog" "$rc" >&2
        exit "$rc"
    fi

    for src in "${sources[@]}"; do
        # A trailing slash means "the contents of", which still leaves the
        # directory itself behind, so the same cleanup applies. A symlink to
        # a directory was moved as a link and is already gone.
        if [ -d "$src" ] && [ ! -L "$src" ]; then
            # -empty and -delete are not POSIX, but GNU, BSD and BusyBox find
            # all have them. -delete implies -depth, so the deepest empty
            # dirs go first, up to the source dir itself if it ended up empty.
            find "$src" -type d -empty -delete 2>/dev/null || true
        fi
    done
}

main "$@"
