#!/usr/bin/env bash
#
# funcupdate - re-pull NullAngst/shell_functions and redeploy it system-wide.
#
# Layout (the README's system-wide install):
#   /usr/local/lib/shell-functions/*.sh      the scripts
#   /usr/local/lib/shell-functions/zshrc     bundled shell configs, used by use_my_zsh
#   /usr/local/lib/shell-functions/bashrc
#   /usr/local/bin/<name>                    one symlink per command
#
# Usage: sudo funcupdate [-l | --log]
#   -l, --log   also append output to /var/log/system-update.log
#
# Everything lives inside main(), which bash parses in full before running.
# That matters because this script replaces its own file on disk mid-run.

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'funcupdate: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

REPO_URL="https://github.com/NullAngst/shell_functions.git"
LIB_DIR="/usr/local/lib/shell-functions"
BIN_DIR="/usr/local/bin"
LOG_FILE="/var/log/system-update.log"
TMP_CLONE=""

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    if [ -n "$TMP_CLONE" ] && [ -d "$TMP_CLONE" ]; then
        rm -rf -- "$TMP_CLONE"
    fi
}

die() {
    printf 'funcupdate: %s\n' "$*" >&2
    exit 1
}

main() {
    local missing=() cmd
    for cmd in git cp chmod ln rm mktemp readlink sed tee touch; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "missing required commands: ${missing[*]}"
    fi

    case "${1:-}" in
        -l|--log)
            if [ "$EUID" -ne 0 ]; then
                die "this writes to $LOG_FILE, $LIB_DIR and $BIN_DIR. Run it with sudo."
            fi
            touch -- "$LOG_FILE" 2>/dev/null || die "cannot write to $LOG_FILE"
            exec > >(tee -a "$LOG_FILE") 2>&1
            printf '==== funcupdate started at %s ====\n' "$(date)"
            ;;
        -h|--help)
            printf 'Usage: sudo funcupdate [-l | --log]\n'
            exit 0
            ;;
        "") ;;
        *)
            printf 'Usage: sudo funcupdate [-l | --log]\n' >&2
            exit 1
            ;;
    esac

    if [ "$EUID" -ne 0 ]; then
        die "this writes to $LIB_DIR and $BIN_DIR. Run it with sudo."
    fi

    TMP_CLONE="$(mktemp -d "${TMPDIR:-/tmp}/funcupdate.XXXXXX")"
    trap cleanup EXIT

    printf 'Pulling latest scripts from GitHub...\n'
    if ! git clone -q --depth 1 "$REPO_URL" "$TMP_CLONE/repo"; then
        die "failed to clone $REPO_URL, the current deployment was left alone"
    fi

    local -a new_scripts=("$TMP_CLONE"/repo/*.sh)
    if [ ! -e "${new_scripts[0]}" ]; then
        die "the clone has no .sh files, the current deployment was left alone"
    fi

    # Clear out the previous deployment first, so a script that was renamed
    # or removed upstream doesn't leave a stale file or dead command behind.
    # Only symlinks that point into LIB_DIR are touched.
    printf 'Removing previous deployment...\n'
    mkdir -p -- "$LIB_DIR"
    local link target
    for link in "$BIN_DIR"/*; do
        [ -L "$link" ] || continue
        target="$(readlink -- "$link")" || continue
        case "$target" in
            "$LIB_DIR"/*) rm -f -- "$link" ;;
        esac
    done
    rm -f -- "$LIB_DIR"/*.sh

    printf 'Deploying to %s...\n' "$LIB_DIR"
    cp -- "${new_scripts[@]}" "$LIB_DIR"/
    chmod 755 -- "$LIB_DIR"/*.sh
    local rc
    for rc in zshrc bashrc; do
        if [ -f "$TMP_CLONE/repo/$rc" ]; then
            cp -- "$TMP_CLONE/repo/$rc" "$LIB_DIR/$rc"
            chmod 644 -- "$LIB_DIR/$rc"
        fi
    done

    # Most files expose one command named after the file. A file that exposes
    # several declares them in a "# COMMANDS: name1 name2" header line
    # (e.g. audio_convert_functions.sh) and gets one symlink per name.
    local f name names
    for f in "$LIB_DIR"/*.sh; do
        names="$(sed -n -e '/^# COMMANDS:/{' -e 's/^# COMMANDS://p' -e 'q' -e '}' "$f")"
        if [ -z "$names" ]; then
            names="${f##*/}"
            names="${names%.sh}"
        fi
        # Unquoted on purpose: the COMMANDS line is a space-separated list
        for name in $names; do
            case "$name" in
                */*|.*) printf 'Skipping odd command name "%s" in %s\n' "$name" "$f" >&2; continue ;;
            esac
            ln -sf -- "$f" "$BIN_DIR/$name"
            printf 'Symlinked: %s -> %s\n' "$name" "$f"
        done
    done

    printf 'Update complete. The latest commands are available system-wide.\n'
}

main "$@"
exit
