#!/usr/bin/env bash
#
# shredfile - run shred against a single file after a confirmation prompt.
#
# shred overwrites the blocks a file currently sits on. On SSDs (wear
# leveling) and copy-on-write filesystems like Btrfs or ZFS the old data can
# live somewhere else entirely, so treat this as best effort there.
#
# Usage: shredfile [-h] [--] <filepath>

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'shredfile: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=shredfile

usage() {
    printf 'Usage: %s [-h] [--] <filepath>\n' "$prog"
    printf '  Overwrites the file with shred, then deletes it. Not reliable on SSDs\n'
    printf '  or copy-on-write filesystems such as Btrfs and ZFS.\n'
}

main() {
    if ! command -v shred >/dev/null 2>&1; then
        printf '%s: missing required commands: shred\n' "$prog" >&2
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

    local target="$1" response

    # shred follows a symlink and wipes the file it points at, then -u only
    # removes the link. Make the caller name the real file instead.
    if [ -L "$target" ]; then
        printf '%s: "%s" is a symlink, pass the real file path instead\n' "$prog" "$target" >&2
        exit 1
    fi
    if [ ! -f "$target" ]; then
        printf '%s: "%s" not found or is not a regular file\n' "$prog" "$target" >&2
        exit 1
    fi

    printf 'Shred file "%s"? shred is not reliable on SSDs or copy-on-write filesystems (y/N): ' "$target"
    read -r response || response=""

    case "$response" in
        [yY][eE][sS]|[yY])
            # -v verbose, -z final pass of zeros, -u remove the file afterward
            shred -vzu -- "$target"
            printf 'File shredded.\n'
            ;;
        *)
            printf 'Aborted.\n'
            ;;
    esac
}

main "$@"
