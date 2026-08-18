#!/usr/bin/env bash
#
# vcp - verbose file copy using rsync, skipping files that already exist
# at the destination.
#
# Usage: vcp <source> [source...] <destination>

vcp() {
    if [ "$#" -lt 2 ]; then
        echo "Usage: vcp <source> [source...] <destination>"
        return 1
    fi
    rsync -vpartlXEHhP --info=progress2 --ignore-existing "$@"
}

_vcp_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT} in
        *:file) _vcp_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _vcp_sourced=1
    fi
fi

if [ "$_vcp_sourced" -eq 0 ]; then
    vcp "$@"
fi
unset _vcp_sourced
