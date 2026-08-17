#!/usr/bin/env bash
#
# vmv - verbose file move using rsync. Removes source files as they
# transfer and cleans up any empty source directories left behind.
#
# Setup:
# create file at /usr/local/bin/vmv.sh (or ~/.local/bin/vmv.sh for a
# single user)
# chmod +x /usr/local/bin/vmv.sh
#
# Add:
# source /usr/local/bin/vmv.sh
# to your bashrc or zshrc
#
# Usage: vmv <source> [source...] <destination>

vmv() {
    if [ "$#" -lt 2 ]; then
        echo "Usage: vmv <source> [source...] <destination>"
        return 1
    fi

    local args=("$@")
    local dest="${args[-1]}"
    local sources=("${args[@]:0:$# - 1}")

    rsync -vpartlXEHhP --info=progress2 --remove-source-files "${sources[@]}" "$dest"
    local rsync_status=$?

    if [ $rsync_status -eq 0 ]; then
        for src in "${sources[@]}"; do
            if [ -d "$src" ]; then
                # Delete deepest empty dirs first, working up to (and including)
                # the source dir itself if it ended up empty.
                find "$src" -type d -empty -delete 2>/dev/null
            fi
        done
    fi

    return $rsync_status
}

_vmv_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT} in
        *:file) _vmv_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _vmv_sourced=1
    fi
fi

if [ "$_vmv_sourced" -eq 0 ]; then
    vmv "$@"
fi
unset _vmv_sourced
