#!/usr/bin/env bash
#
# use_my_zsh - make zsh the login shell for you and for root, and install the
# zshrc from NullAngst/shell_functions for both, with the Kawaii Dark prompt
# by default. Installs zsh first if it's missing.
#
# Usage: sudo use_my_zsh [-u USER] [-t THEME] [-R] [-n] [-k] [-y]
#   -u USER    set up this user (default: whoever ran sudo)
#   -t THEME   prompt theme to make the default (default: kawaii-dark)
#              kawaii-dark kawaii-light amber blurple modern-dark modern-light verdigris-copper
#   -R         leave root alone, only set up the user
#   -n         also make zsh the default shell for accounts created later
#   -k         also install the matching kitty theme for the user, from
#              NullAngst/kitty-themes (needs git)
#   -y         don't ask before installing zsh
#   -h         show this help
#
# An existing ~/.zshrc is backed up as ~/.zshrc.bak-<date> before it's replaced.

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'use_my_zsh: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=use_my_zsh
ZSHRC_URL="https://raw.githubusercontent.com/NullAngst/shell_functions/main/zshrc"
KITTY_REPO="https://github.com/NullAngst/kitty-themes.git"
THEMES="kawaii-dark kawaii-light amber blurple modern-dark modern-light verdigris-copper"
TMP_DIR=""

if [ -t 1 ]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_RST=""
fi

say() { printf '%s\n' "$*"; }
ok() { printf '%s%s%s\n' "$C_GRN" "$*" "$C_RST"; }
warn() { printf '%sWarning:%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die() { printf '%s%s:%s %s\n' "$C_RED" "$prog" "$C_RST" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    sed -n '3,19p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || printf 'Usage: sudo %s [-u USER] [-t THEME] [-R] [-n] [-k] [-y]\n' "$prog"
}

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf -- "$TMP_DIR"
    fi
}

ask_yes() {
    local reply
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    printf '%s [y/N]: ' "$1"
    read -r reply || reply=""
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
    esac
    return 1
}

# Field N of a passwd entry. Args: user field
passwd_field() {
    getent passwd "$1" | cut -d: -f"$2"
}

# This script's real directory, following symlinks without GNU readlink -f.
# An installed copy is a symlink in /usr/local/bin pointing into the lib dir,
# and the bundled zshrc sits next to the real file.
script_dir() {
    local p="$0" link i=0
    while [ -L "$p" ] && [ "$i" -lt 40 ]; do
        link="$(readlink -- "$p")"
        case "$link" in
            /*) p="$link" ;;
            *) p="$(dirname -- "$p")/$link" ;;
        esac
        i=$((i + 1))
    done
    (cd -P -- "$(dirname -- "$p")" && pwd -P)
}

install_zsh() {
    local -a cmd=()
    if have apt-get; then
        cmd=(apt-get install -y zsh)
    elif have dnf; then
        cmd=(dnf install -y zsh)
    elif have yum; then
        cmd=(yum install -y zsh)
    elif have zypper; then
        cmd=(zypper -n install zsh)
    elif have pacman; then
        cmd=(pacman -S --needed --noconfirm zsh)
    elif have apk; then
        cmd=(apk add zsh)
    elif have xbps-install; then
        cmd=(xbps-install -y zsh)
    elif have emerge; then
        cmd=(emerge --noreplace app-shells/zsh)
    elif have eopkg; then
        cmd=(eopkg install -y zsh)
    else
        die "zsh is not installed and no supported package manager was found. Install zsh yourself, then run this again."
    fi

    ask_yes "zsh is not installed. Install it with: ${cmd[*]}?" || die "zsh is needed. Nothing was changed."
    say "Installing zsh..."
    if [ "${cmd[0]}" = apt-get ]; then
        # The package lists may be stale or missing on a fresh install
        apt-get update -q || warn "apt-get update failed, trying the install anyway"
    fi
    "${cmd[@]}" || die "installing zsh failed"
}

# Put the zshrc to install into $TMP_DIR/zshrc, with the chosen theme as default.
fetch_zshrc() {
    local here src="" theme="$1"
    here="$(script_dir)"
    if [ -f "$here/zshrc" ]; then
        src="$here/zshrc"
        say "Using the bundled zshrc from $here"
        cp -- "$src" "$TMP_DIR/zshrc.src"
    else
        say "Downloading zshrc from $ZSHRC_URL"
        if have curl; then
            curl -fsSL --max-time 30 -o "$TMP_DIR/zshrc.src" "$ZSHRC_URL" || die "download failed"
        elif have wget; then
            wget -q -T 30 -O "$TMP_DIR/zshrc.src" "$ZSHRC_URL" || die "download failed"
        else
            die "no bundled zshrc next to this script, and neither curl nor wget is installed to download it"
        fi
    fi

    # Make sure this really is the shell_functions zshrc before it goes live
    # shellcheck disable=SC2016  # a literal ${ZSH_PROMPT_THEME line, not an expansion
    grep -q '^: \${ZSH_PROMPT_THEME:=' "$TMP_DIR/zshrc.src" \
        || die "the zshrc doesn't look like the shell_functions one (no ZSH_PROMPT_THEME line), stopping"

    sed "s/^: \${ZSH_PROMPT_THEME:=[a-z-]*}/: \${ZSH_PROMPT_THEME:=$theme}/" "$TMP_DIR/zshrc.src" > "$TMP_DIR/zshrc"
    "$ZSH_PATH" -n "$TMP_DIR/zshrc" || die "the zshrc has a syntax error, stopping"
}

# /etc/shells lists the shells chsh accepts. Add zsh if it's not there.
register_shell() {
    if [ -f /etc/shells ] && grep -qxF -- "$ZSH_PATH" /etc/shells; then
        return 0
    fi
    say "Adding $ZSH_PATH to /etc/shells"
    printf '%s\n' "$ZSH_PATH" >> /etc/shells
}

# Install the zshrc for one account. Args: user
install_rc() {
    local user="$1" home group dest stamp
    home="$(passwd_field "$user" 6)"
    [ -n "$home" ] && [ -d "$home" ] || { warn "$user has no home directory, skipping their zshrc"; return 1; }
    group="$(id -gn -- "$user")"
    dest="$home/.zshrc"
    stamp="$(date +%Y%m%d-%H%M%S)"

    if [ -f "$dest" ] && cmp -s -- "$dest" "$TMP_DIR/zshrc"; then
        say "$dest is already up to date"
        return 0
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        mv -- "$dest" "$dest.bak-$stamp"
        say "Backed up the old $dest to $dest.bak-$stamp"
    fi
    cp -- "$TMP_DIR/zshrc" "$dest"
    chmod 644 -- "$dest"
    chown -- "$user:$group" "$dest"
    ok "Installed $dest"
}

# Make zsh the login shell of one account. Args: user
set_login_shell() {
    local user="$1" current
    current="$(passwd_field "$user" 7)"
    if [ "$current" = "$ZSH_PATH" ]; then
        say "$user already logs in with $ZSH_PATH"
        return 0
    fi
    if have usermod; then
        usermod -s "$ZSH_PATH" "$user"
    elif have chsh; then
        chsh -s "$ZSH_PATH" "$user"
    else
        warn "neither usermod nor chsh is installed. Set the shell for $user to $ZSH_PATH in /etc/passwd by hand."
        return 1
    fi
    if [ "$(passwd_field "$user" 7)" = "$ZSH_PATH" ]; then
        ok "Login shell for $user is now $ZSH_PATH (was ${current:-unset})"
    else
        # LDAP/SSSD accounts aren't in /etc/passwd and need changing at the source
        warn "the shell for $user still shows as $(passwd_field "$user" 7). If this account comes from LDAP or similar, change it there."
        return 1
    fi
}

set_default_for_new_users() {
    if have useradd && useradd -D -s "$ZSH_PATH" >/dev/null 2>&1; then
        ok "New accounts made with useradd will get $ZSH_PATH"
    elif [ -f /etc/default/useradd ]; then
        if grep -q '^SHELL=' /etc/default/useradd; then
            sed "s|^SHELL=.*|SHELL=$ZSH_PATH|" /etc/default/useradd > "$TMP_DIR/useradd"
        else
            { cat /etc/default/useradd; printf 'SHELL=%s\n' "$ZSH_PATH"; } > "$TMP_DIR/useradd"
        fi
        cat "$TMP_DIR/useradd" > /etc/default/useradd
        ok "Set SHELL=$ZSH_PATH in /etc/default/useradd"
    else
        warn "no useradd defaults to change on this system, skipping -n"
    fi
    if [ -f /etc/adduser.conf ]; then
        # Debian's adduser has its own default
        if grep -q '^DSHELL=' /etc/adduser.conf; then
            sed "s|^DSHELL=.*|DSHELL=$ZSH_PATH|" /etc/adduser.conf > "$TMP_DIR/adduser.conf"
            cat "$TMP_DIR/adduser.conf" > /etc/adduser.conf
            ok "Set DSHELL=$ZSH_PATH in /etc/adduser.conf"
        fi
    fi
}

# Run a command as the target user with their HOME. Args: user cmd...
as_user() {
    local user="$1" home
    shift
    home="$(passwd_field "$user" 6)"
    if have runuser; then
        runuser -u "$user" -- env HOME="$home" "$@"
    elif have sudo; then
        sudo -H -u "$user" -- "$@"
    else
        warn "neither runuser nor sudo is available to run as $user"
        return 1
    fi
}

install_kitty_theme() {
    local user="$1" theme="$2"
    have git || { warn "git is not installed, skipping the kitty theme"; return 1; }
    say "Fetching kitty themes from $KITTY_REPO"
    git clone -q --depth 1 "$KITTY_REPO" "$TMP_DIR/kitty-themes" || { warn "could not clone $KITTY_REPO"; return 1; }
    # The user runs the installer, so their files stay theirs
    chmod -R a+rX -- "$TMP_DIR"
    if as_user "$user" bash "$TMP_DIR/kitty-themes/install.sh" "$theme"; then
        ok "kitty theme $theme installed for $user"
    else
        warn "the kitty theme installer failed"
        return 1
    fi
}

main() {
    local target_user="" theme="kawaii-dark" skip_root=0 new_users=0 kitty=0 opt rc=0
    ASSUME_YES=0

    local missing=() cmd
    for cmd in getent cut cp mv chmod chown cmp grep id mktemp sed date; do
        have "$cmd" || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "missing required commands: ${missing[*]}"
    fi

    while getopts ':u:t:Rnkyh' opt; do
        case "$opt" in
            u) target_user="$OPTARG" ;;
            t) theme="$(printf '%s' "$OPTARG" | tr '[:upper:] _' '[:lower:]--')" ;;
            R) skip_root=1 ;;
            n) new_users=1 ;;
            k) kitty=1 ;;
            y) ASSUME_YES=1 ;;
            h) usage; exit 0 ;;
            :) die "option -$OPTARG needs a value" ;;
            *) die "unknown option -$OPTARG (see -h)" ;;
        esac
    done
    shift $((OPTIND - 1))
    [ "$#" -eq 0 ] || die "unexpected argument: $1 (see -h)"

    case " $THEMES " in
        *" $theme "*) ;;
        *) die "unknown theme '$theme'. Pick one of: $THEMES" ;;
    esac

    [ "$EUID" -eq 0 ] || die "this changes login shells and /etc/shells, so it needs root. Run it with sudo."

    if [ -z "$target_user" ]; then
        target_user="${SUDO_USER:-}"
        [ "$target_user" != root ] || target_user=""
    fi
    if [ -n "$target_user" ]; then
        getent passwd "$target_user" >/dev/null || die "no such user: $target_user"
    elif [ "$skip_root" -eq 1 ]; then
        die "-R leaves only the regular user, but none was given. Run it with sudo from your account, or pass -u USER."
    else
        warn "no regular user found (not run through sudo, no -u), so only root gets set up"
    fi

    # Check before touching anything that zsh is installed and actually runs
    ZSH_PATH="$(command -v zsh || true)"
    if [ -z "$ZSH_PATH" ]; then
        install_zsh
        hash -r
        ZSH_PATH="$(command -v zsh || true)"
        [ -n "$ZSH_PATH" ] || die "zsh still isn't on PATH after installing it"
    fi
    "$ZSH_PATH" -c 'exit 0' || die "$ZSH_PATH is installed but doesn't run"
    ok "Found zsh at $ZSH_PATH ($("$ZSH_PATH" --version 2>/dev/null || printf 'version unknown'))"

    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/use_my_zsh.XXXXXX")"
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    fetch_zshrc "$theme"
    register_shell

    local -a accounts=()
    if [ -n "$target_user" ]; then
        accounts+=("$target_user")
    fi
    if [ "$skip_root" -eq 0 ]; then
        accounts+=(root)
    fi

    local user
    for user in "${accounts[@]}"; do
        say ""
        say "Setting up $user"
        install_rc "$user" || rc=1
        set_login_shell "$user" || rc=1
    done

    if [ "$new_users" -eq 1 ]; then
        say ""
        set_default_for_new_users || rc=1
    fi

    if [ "$kitty" -eq 1 ]; then
        say ""
        if [ -n "$target_user" ]; then
            install_kitty_theme "$target_user" "$theme" || rc=1
        else
            warn "-k needs a regular user to install the kitty theme for, skipping"
            rc=1
        fi
    fi

    say ""
    if [ "$rc" -eq 0 ]; then
        ok "Done. Log out and back in (or just run zsh) to start using it. Prompt theme: $theme."
    else
        warn "Finished, but some steps above didn't go through. Look over the warnings."
    fi
    exit "$rc"
}

main "$@"
