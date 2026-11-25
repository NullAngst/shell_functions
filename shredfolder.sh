#!/usr/bin/env bash
#
# shredfolder - run shred against every file in a directory, then remove the
# directory, after a confirmation prompt.
#
# shred overwrites the blocks a file currently sits on. On SSDs (wear
# leveling) and copy-on-write filesystems like Btrfs or ZFS the old data can
# live somewhere else entirely, so treat this as best effort there.
#
# Usage: shredfolder [-h] [--] <folderpath>

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'shredfolder: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=shredfolder

usage() {
    printf 'Usage: %s [-h] [--] <folderpath>\n' "$prog"
    printf '  Overwrites every file in the folder with shred, then deletes the folder.\n'
    printf '  Not reliable on SSDs or copy-on-write filesystems such as Btrfs and ZFS.\n'
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
    need_cmds shred find rm

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

    local target="${1%/}" response
    [ -n "$target" ] || target="/"

    if [ "$target" = "/" ] || [ "$target" = "." ] || [ "$target" = ".." ]; then
        printf '%s: refusing to shred "%s"\n' "$prog" "$target" >&2
        exit 1
    fi
    # A symlink to a directory would get the link removed and nothing shredded,
    # since find does not descend into a symlinked starting point.
    if [ -L "$target" ]; then
        printf '%s: "%s" is a symlink, pass the real directory path instead\n' "$prog" "$target" >&2
        exit 1
    fi
    if [ ! -d "$target" ]; then
        printf '%s: "%s" not found or is not a directory\n' "$prog" "$target" >&2
        exit 1
    fi
    # find takes a leading - as an expression, so make such a name a path
    case "$target" in
        -*) target="./$target" ;;
    esac

    printf 'Shred every file in folder "%s" and delete it? shred is not reliable on SSDs or copy-on-write filesystems (y/N): ' "$target"
    read -r response || response=""

    case "$response" in
        [yY][eE][sS]|[yY])
            # Only regular files hold data worth overwriting. Symlinks inside
            # are removed by rm below without touching what they point at.
            if ! find "$target" -type f -exec shred -vzu -- {} +; then
                printf '%s: shred failed on at least one file, "%s" was left in place so you can check what is left\n' "$prog" "$target" >&2
                exit 1
            fi
            rm -rf -- "$target"
            printf 'Folder shredded.\n'
            ;;
        *)
            printf 'Aborted.\n'
            ;;
    esac
}

main "$@"
