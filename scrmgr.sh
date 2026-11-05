#!/usr/bin/env bash
#
# scrmgr - single entry point for managing GNU screen sessions.
#
# Usage:
#   scrmgr start <name>    Start a new named session
#   scrmgr resume <name>   Reattach to an existing session, detaching it elsewhere first
#   scrmgr kill <name>     Kill a session from the outside
#   scrmgr list            List active sessions
#   scrmgr wipe            Remove dead sessions from the list

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'scrmgr: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=scrmgr

usage() {
    printf 'Usage: %s <start|resume|kill|list|wipe> [session_name]\n' "$prog"
    printf '  start <name>   Start a new named session\n'
    printf '  resume <name>  Reattach to an existing session\n'
    printf '  kill <name>    Kill a session from the outside\n'
    printf '  list           List active sessions\n'
    printf '  wipe           Remove dead sessions from the list\n'
    printf '  Inside screen: CTRL+A then \\ kills the session, CTRL+A then d detaches\n'
}

need_name() {
    if [ -z "${1:-}" ]; then
        printf 'Usage: %s %s <session_name>\n' "$prog" "$2" >&2
        exit 1
    fi
}

main() {
    if ! command -v screen >/dev/null 2>&1; then
        printf '%s: missing required commands: screen\n' "$prog" >&2
        exit 1
    fi

    local cmd="${1:-}"
    if [ "$#" -gt 0 ]; then
        shift
    fi

    case "$cmd" in
        start)
            need_name "${1:-}" start
            screen -S "$1"
            ;;
        resume)
            need_name "${1:-}" resume
            # -d -r detaches the session wherever it is attached, then reattaches it here
            screen -d -r "$1"
            ;;
        kill)
            need_name "${1:-}" kill
            screen -X -S "$1" quit
            ;;
        list)
            # screen -list exits non-zero whenever there are no live sessions,
            # which is an answer, not an error
            screen -list || true
            ;;
        wipe)
            screen -wipe || true
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"
