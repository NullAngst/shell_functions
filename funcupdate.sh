#!/usr/bin/env bash
#
# funcupdate - re-pull NullAngst/shell_functions and redeploy it system-wide.
#
# Layout (the README's system-wide install):
#   /usr/local/lib/shell-functions/*.sh   the scripts
#   /usr/local/bin/<name>                 one symlink per command
#
# Usage: sudo funcupdate [-l | --log]
#   -l, --log   also append output to /var/log/system-update.log
#
# Everything lives inside main(), which bash parses in full before running.
# That matters because this script replaces its own file on disk mid-run.

REPO_URL="https://github.com/NullAngst/shell_functions.git"
LIB_DIR="/usr/local/lib/shell-functions"
BIN_DIR="/usr/local/bin"
LOG_FILE="/var/log/system-update.log"

main() {
    if [[ "$1" == "-l" || "$1" == "--log" ]]; then
        touch "$LOG_FILE" 2>/dev/null || { echo "Cannot write to $LOG_FILE. Run with sudo."; exit 1; }
        exec > >(tee -a "$LOG_FILE") 2>&1
        echo "==== funcupdate started at $(date) ===="
    elif [[ -n "$1" ]]; then
        echo "Usage: sudo funcupdate [-l | --log]"
        exit 1
    fi

    if [[ $EUID -ne 0 ]]; then
        echo "This script writes to $LIB_DIR and $BIN_DIR. Run it with sudo."
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git is not installed."
        exit 1
    fi

    local tmp
    tmp=$(mktemp -d) || exit 1
    trap 'rm -rf "$tmp"' EXIT

    echo "Pulling latest scripts from GitHub..."
    if ! git clone -q --depth 1 "$REPO_URL" "$tmp"; then
        echo "Error: failed to clone $REPO_URL"
        exit 1
    fi

    # Clear out the previous deployment first, so a script that was renamed
    # or removed upstream doesn't leave a stale file or dead command behind.
    # Only symlinks that point into LIB_DIR are touched.
    echo "Removing previous deployment..."
    mkdir -p "$LIB_DIR"
    find "$BIN_DIR" -maxdepth 1 -type l -lname "$LIB_DIR/*" -delete
    rm -f "$LIB_DIR"/*.sh

    echo "Deploying to $LIB_DIR..."
    cp "$tmp"/*.sh "$LIB_DIR"/
    chmod 755 "$LIB_DIR"/*.sh

    # Most files expose one command named after the file. A file that exposes
    # several declares them in a "# COMMANDS: name1 name2" header line
    # (e.g. audio_convert_functions.sh) and gets one symlink per name.
    local f name names
    for f in "$LIB_DIR"/*.sh; do
        names=$(grep -m1 '^# COMMANDS:' "$f" | cut -d: -f2-)
        [[ -z "$names" ]] && names=$(basename "$f" .sh)
        for name in $names; do
            ln -sf "$f" "$BIN_DIR/$name"
            echo "Symlinked: $name -> $f"
        done
    done

    echo "Update complete. The latest functions are available system-wide."
}

main "$@"
exit
