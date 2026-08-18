#!/usr/bin/env bash
#
# scrmgr - single entry point for managing GNU screen sessions.
# Combines what used to be five separate aliases/functions:
#   sss (start), srs (reattach), sks (kill), sls (list), swp (wipe)
#
# Usage:
#   scrmgr start <name>    Start a new named session      (was: sss)
#   scrmgr resume <name>   Reattach to an existing session (was: srs)
#   scrmgr kill <name>     Kill a session from the outside (was: sks)
#   scrmgr list            List active sessions            (was: sls alias)
#   scrmgr wipe            Remove dead sessions             (was: swp alias)

scrmgr() {
    local cmd="$1"
    [ "$#" -gt 0 ] && shift

    case "$cmd" in
        start)
            if [ -z "$1" ]; then
                echo "Usage: scrmgr start <session_name>"
                return 1
            fi
            screen -S "$1"
            ;;
        resume)
            if [ -z "$1" ]; then
                echo "Usage: scrmgr resume <session_name>"
                return 1
            fi
            # -d -r detaches the session elsewhere first, then reattaches it here
            screen -d -r "$1"
            ;;
        kill)
            if [ -z "$1" ]; then
                echo "Usage: scrmgr kill <session_name>"
                return 1
            fi
            screen -X -S "$1" quit
            ;;
        list)
            screen -list
            ;;
        wipe)
            screen -wipe
            ;;
        *)
            echo "Usage: scrmgr <start|resume|kill|list|wipe> [session_name]"
            echo "  start <name>   Start a new named session"
            echo "  resume <name>  Reattach to an existing session"
            echo "  kill <name>    Kill a session from the outside"
            echo "  list           List active sessions"
            echo "  wipe           Remove dead sessions from the list"
            echo "  exit kill      CTRL + A (then) \\"
            echo "  exit nokill    CTRL + A (then) d"
            return 1
            ;;
    esac
}

_scrmgr_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT} in
        *:file) _scrmgr_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _scrmgr_sourced=1
    fi
fi

if [ "$_scrmgr_sourced" -eq 0 ]; then
    scrmgr "$@"
fi
unset _scrmgr_sourced
