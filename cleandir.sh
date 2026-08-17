#!/usr/bin/env bash
#
# cleandir - removes empty directories in the current directory, or
# recursively through all subdirectories.
#
# Setup:
# create file at /usr/local/bin/cleandir.sh (or ~/.local/bin/cleandir.sh for a
# single user)
# chmod +x /usr/local/bin/cleandir.sh
#
# Add:
# source /usr/local/bin/cleandir.sh
# to your bashrc or zshrc
#
# Usage: cleandir [-r]

cleandir() {
    local recursive=0

    # Parse arguments
    if [[ "$1" == "-r" || "$1" == "-R" ]]; then
        recursive=1
    elif [[ -n "$1" ]]; then
        echo "Usage: cleandir [-r]"
        echo "  -r : Recursively check and remove empty folders in all subdirectories."
        return 1
    fi

    if (( recursive )); then
        echo "Recursively scanning for empty directories..."
        # -delete automatically implies -depth, safely removing nested empty dirs bottom-up
        find . -mindepth 1 -type d -empty -print -delete
    else
        echo "Scanning current directory for empty folders..."
        # -maxdepth 1 limits the search to the current directory only
        find . -mindepth 1 -maxdepth 1 -type d -empty -print -delete
    fi

    echo "Clean complete."
}

_cleandir_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT} in
        *:file) _cleandir_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _cleandir_sourced=1
    fi
fi

if [ "$_cleandir_sourced" -eq 0 ]; then
    cleandir "$@"
fi
unset _cleandir_sourced
