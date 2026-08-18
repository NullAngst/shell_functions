#!/usr/bin/env bash
#
# shredfolder - runs shred against every file in a directory, then removes
# the directory, after an interactive confirmation. Note: shred does not
# reliably wipe data on SSDs due to wear leveling.
#
# Usage: shredfolder <folderpath>

shredfolder() {
    if [ -z "$1" ]; then
        echo "Usage: shredfolder <folderpath>"
        return 1
    fi

    local target="$1"

    if [ ! -d "$target" ]; then
        echo "Error: '$target' not found or is not a directory."
        return 1
    fi

    printf 'confirm you want to shred folder "%s" and understand that shred does not properly work if ran on an ssd (y/n): ' "$target"
    read -r response

    case "$response" in
        [yY][eE][sS]|[yY])
            # Find and shred all files inside the directory
            find "$target" -type f -exec shred -vzu {} +
            # Remove the now-empty directory structure
            rm -rf "$target"
            echo "Folder shredded."
            ;;
        *)
            echo "Aborted."
            ;;
    esac
}

_shredfolder_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT} in
        *:file) _shredfolder_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _shredfolder_sourced=1
    fi
fi

if [ "$_shredfolder_sourced" -eq 0 ]; then
    shredfolder "$@"
fi
unset _shredfolder_sourced
