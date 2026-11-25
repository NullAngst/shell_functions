#!/usr/bin/env bash
#
# funcupdate - pull the latest NullAngst/shell_functions and (re)deploy it,
# either system-wide or for just your user.
#
# Layout, system-wide (run with sudo):
#   /usr/local/lib/shell_functions/*.sh      the scripts
#   /usr/local/lib/shell_functions/zshrc     bundled shell configs, used by use_my_zsh
#   /usr/local/lib/shell_functions/bashrc
#   /usr/local/bin/<name>                    one symlink per command
#
# Layout with -u (no root needed): the same under ~/.local/lib/shell_functions
# and ~/.local/bin.
#
# Usage: funcupdate [-u] [-l] [-h]
#   -u, --user   deploy for your user only, under ~/.local
#   -l, --log    also append output to /var/log/system_update.log (system-wide)
#                or ~/.local/state/shell_functions/funcupdate.log (with -u)
#
# Everything lives inside main(), which bash parses in full before running.
# That matters because this script replaces its own file on disk mid-run.

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'funcupdate: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=funcupdate
REPO_URL="https://github.com/NullAngst/shell_functions.git"
TMP_CLONE=""

# shellcheck disable=SC2317,SC2329  # invoked via trap
cleanup() {
    if [ -n "$TMP_CLONE" ] && [ -d "$TMP_CLONE" ]; then
        rm -rf -- "$TMP_CLONE"
    fi
}

die() {
    printf '%s: %s\n' "$prog" "$*" >&2
    exit 1
}

usage() {
    printf 'Usage: %s [-u] [-l] [-h]\n' "$prog"
    printf '  Pulls the latest scripts from GitHub and redeploys them.\n'
    printf '  With no options it deploys system-wide and needs sudo.\n'
    printf '  -u, --user   deploy for your user only, under ~/.local\n'
    printf '  -l, --log    also append the output to a log file\n'
}

main() {
    local missing=() cmd
    for cmd in git cp chmod ln rm rmdir mkdir mktemp readlink sed tee touch id; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "missing required commands: ${missing[*]}"
    fi

    local user_mode=0 logging=0 opt
    while getopts ':ulh-:' opt; do
        case "$opt" in
            u) user_mode=1 ;;
            l) logging=1 ;;
            h) usage; exit 0 ;;
            -)
                case "$OPTARG" in
                    user) user_mode=1 ;;
                    log) logging=1 ;;
                    help) usage; exit 0 ;;
                    *) printf '%s: unknown option --%s\n' "$prog" "$OPTARG" >&2; usage >&2; exit 1 ;;
                esac
                ;;
            *) printf '%s: unknown option -%s\n' "$prog" "$OPTARG" >&2; usage >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    if [ "$#" -gt 0 ]; then
        usage >&2
        exit 1
    fi

    local lib_dir bin_dir old_lib_dir log_file
    if [ "$user_mode" -eq 1 ]; then
        lib_dir="$HOME/.local/lib/shell_functions"
        bin_dir="$HOME/.local/bin"
        old_lib_dir="$HOME/.local/lib/shell-functions"
        log_file="${XDG_STATE_HOME:-$HOME/.local/state}/shell_functions/funcupdate.log"
    else
        if [ "$(id -u)" -ne 0 ]; then
            die "this writes to /usr/local. Run it with sudo, or use -u to deploy for your user only."
        fi
        lib_dir="/usr/local/lib/shell_functions"
        bin_dir="/usr/local/bin"
        old_lib_dir="/usr/local/lib/shell-functions"
        log_file="/var/log/system_update.log"
    fi

    if [ "$logging" -eq 1 ]; then
        mkdir -p -- "$(dirname -- "$log_file")" 2>/dev/null || true
        touch -- "$log_file" 2>/dev/null || die "cannot write to $log_file"
        exec > >(tee -a "$log_file") 2>&1
        printf '==== funcupdate started at %s ====\n' "$(date)"
    fi

    TMP_CLONE="$(mktemp -d "${TMPDIR:-/tmp}/funcupdate.XXXXXX")"
    trap cleanup EXIT
    trap 'exit 130' INT TERM HUP

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
    # Only symlinks that point into the lib dir (or the old hyphenated one,
    # from before the rename) are touched.
    printf 'Removing previous deployment...\n'
    mkdir -p -- "$lib_dir" "$bin_dir"
    local link target
    for link in "$bin_dir"/*; do
        [ -L "$link" ] || continue
        target="$(readlink -- "$link")" || continue
        case "$target" in
            "$lib_dir"/*|"$old_lib_dir"/*) rm -f -- "$link" ;;
        esac
    done
    rm -f -- "$lib_dir"/*.sh
    if [ -d "$old_lib_dir" ]; then
        rm -f -- "$old_lib_dir"/*.sh "$old_lib_dir/zshrc" "$old_lib_dir/bashrc"
        if rmdir -- "$old_lib_dir" 2>/dev/null; then
            printf 'Removed the old %s\n' "$old_lib_dir"
        else
            printf 'Left %s in place, it still holds files this script did not put there\n' "$old_lib_dir" >&2
        fi
    fi

    printf 'Deploying to %s...\n' "$lib_dir"
    cp -- "${new_scripts[@]}" "$lib_dir"/
    chmod 755 -- "$lib_dir"/*.sh
    local rc
    for rc in zshrc bashrc; do
        if [ -f "$TMP_CLONE/repo/$rc" ]; then
            cp -- "$TMP_CLONE/repo/$rc" "$lib_dir/$rc"
            chmod 644 -- "$lib_dir/$rc"
        fi
    done

    # Most files expose one command named after the file. A file that exposes
    # several declares them in a "# COMMANDS: name1 name2" header line
    # (e.g. audio_convert_functions.sh) and gets one symlink per name.
    local f name names skipped=0
    for f in "$lib_dir"/*.sh; do
        names="$(sed -n -e '/^# COMMANDS:/{' -e 's/^# COMMANDS://p' -e 'q' -e '}' "$f")"
        if [ -z "$names" ]; then
            names="${f##*/}"
            names="${names%.sh}"
        fi
        # Unquoted on purpose: the COMMANDS line is a space-separated list
        for name in $names; do
            case "$name" in
                */*|.*|-*) printf 'Skipping odd command name "%s" in %s\n' "$name" "$f" >&2; continue ;;
            esac
            # Every link this script made was removed above, so anything still
            # there belongs to something else. Leave it alone.
            if [ -e "$bin_dir/$name" ] || [ -L "$bin_dir/$name" ]; then
                printf 'Skipping %s: %s/%s already exists and is not ours\n' "$name" "$bin_dir" "$name" >&2
                skipped=$((skipped + 1))
                continue
            fi
            ln -s -- "$f" "$bin_dir/$name"
            printf 'Symlinked: %s -> %s\n' "$name" "$f"
        done
    done

    if [ "$skipped" -gt 0 ]; then
        printf 'Update complete, but %d command(s) were skipped. See above.\n' "$skipped"
    else
        printf 'Update complete. The latest commands are on your PATH.\n'
    fi
    if [ "$user_mode" -eq 1 ]; then
        case ":$PATH:" in
            *":$bin_dir:"*) ;;
            *) printf 'Note: %s is not on your PATH yet. See the README, step 6 of Option A.\n' "$bin_dir" ;;
        esac
    fi
}

main "$@"
exit
