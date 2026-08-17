#!/usr/bin/env bash
#
# shredfile - runs shred against a single file with sane arguments, after
# an interactive confirmation. Note: shred does not reliably wipe data on
# SSDs due to wear leveling.
#
# Setup:
# create file at /usr/local/bin/shredfile.sh (or ~/.local/bin/shredfile.sh
# for a single user)
# chmod +x /usr/local/bin/shredfile.sh
#
# Add:
# source /usr/local/bin/shredfile.sh
# to your bashrc or zshrc
#
# Usage: shredfile <filepath>

shredfile() {
    if [ -z "$1" ]; then
        echo "Usage: shredfile <filepath>"
        return 1
    fi

    local target="$1"

    if [ ! -f "$target" ]; then
        echo "Error: '$target' not found or is not a regular file."
        return 1
    fi

    printf 'confirm you want to shred file "%s" and understand that shred does not properly work if ran on an ssd (y/n): ' "$target"
    read -r response

    case "$response" in
        [yY][eE][sS]|[yY])
            # -v: verbose, -z: add final zero overwrite, -u: remove file after shredding
            shred -vzu "$target"
            echo "File shredded."
            ;;
        *)
            echo "Aborted."
            ;;
    esac
}

_shredfile_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT} in
        *:file) _shredfile_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _shredfile_sourced=1
    fi
fi

if [ "$_shredfile_sourced" -eq 0 ]; then
    shredfile "$@"
fi
unset _shredfile_sourced
