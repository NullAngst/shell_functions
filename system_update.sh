#!/usr/bin/env bash
#
# system_update - generic Linux system updater. Finds the native package
# manager, runs its full upgrade and cleanup, then updates Flatpak and Snap
# if they're installed.
#
# Usage: sudo system_update [-l] [-h]
#   -l, --log   also append everything to /var/log/system_update.log

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'system_update: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=system_update
LOG_FILE="/var/log/system_update.log"
ERRORS=0
ENABLE_LOGGING=0

usage() {
    printf 'Usage: sudo %s [-l] [-h]\n' "$prog"
    printf '  Runs a full upgrade and cleanup with the native package manager,\n'
    printf '  then updates Flatpak and Snap if they are installed.\n'
    printf '  -l, --log   also append everything to %s\n' "$LOG_FILE"
}

log() {
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$line"
    if [ "$ENABLE_LOGGING" -eq 1 ]; then
        printf '%s\n' "$line" >> "$LOG_FILE"
    fi
}

log_section() {
    log ""
    log "============================================"
    log " $*"
    log "============================================"
}

# Run one step, count it as an error if it fails, and return its status, so
# a caller can skip a cleanup that only makes sense after a good upgrade.
try_cmd() {
    log "Running: $*"
    if [ "$ENABLE_LOGGING" -eq 1 ]; then
        # Shown live and kept in the log
        if "$@" 2>&1 | tee -a "$LOG_FILE"; then
            return 0
        fi
    elif "$@"; then
        return 0
    fi
    log "ERROR: Command failed: $*"
    ERRORS=$((ERRORS + 1))
    return 1
}

# Same, for a step whose failure should not stop the rest of that section
run_cmd() {
    try_cmd "$@" || true
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# The person who ran sudo, or the first regular account, for tools that must
# not run as root (AUR helpers, single-user nix).
human_user() {
    local u="${SUDO_USER:-}"
    if [ -z "$u" ] || [ "$u" = root ]; then
        u="$(logname 2>/dev/null || true)"
    fi
    if [ -z "$u" ] || [ "$u" = root ]; then
        u="$(getent passwd | LC_ALL=C awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }' || true)"
    fi
    printf '%s' "$u"
}

user_home() {
    getent passwd "$1" | cut -d: -f6
}

# Run a command as another user with that user's HOME. runuser ships with
# util-linux, sudo is the fallback.
as_user() {
    local user="$1" home
    shift
    home="$(user_home "$user")"
    if has_cmd runuser; then
        runuser -u "$user" -- env HOME="$home" "$@"
    elif has_cmd sudo; then
        sudo -H -u "$user" -- "$@"
    else
        log "ERROR: neither runuser nor sudo is available to run as $user"
        return 1
    fi
}

# shellcheck disable=SC1091  # /etc/os-release is the system's, not part of this repo
os_id() {
    # /etc/os-release is shell syntax by spec; read it in a subshell so its
    # variables don't leak in here
    if [ -r /etc/os-release ]; then
        ( . /etc/os-release && printf '%s' "${ID:-}" )
    fi
}

# shellcheck disable=SC1091  # same file as above
os_name() {
    if [ -r /etc/os-release ]; then
        ( . /etc/os-release && printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}" )
    else
        uname -s
    fi
}

update_apt() {
    log_section "APT (Debian/Ubuntu/Mint)"

    # No interactive prompts during unattended runs. Changed config files keep
    # the local version, which is the answer apt suggests by default.
    export DEBIAN_FRONTEND=noninteractive
    local -a dpkg_opts=(
        -o Dpkg::Options::=--force-confdef
        -o Dpkg::Options::=--force-confold
    )

    # apt-get instead of apt, since apt's own output warns that its CLI isn't
    # stable for scripts
    try_cmd apt-get update -q || return 0
    if try_cmd apt-get dist-upgrade -y -q "${dpkg_opts[@]}"; then
        run_cmd apt-get autoremove -y -q
    else
        log "Skipping autoremove, since the upgrade did not finish."
    fi
    run_cmd apt-get autoclean -q

    if [ -f /var/run/reboot-required ]; then
        log "WARNING: A reboot is required to complete updates (kernel or libc changed)."
        if [ -f /var/run/reboot-required.pkgs ]; then
            log "Packages requiring reboot:"
            local pkg
            while IFS= read -r pkg; do
                log "  -> $pkg"
            done < /var/run/reboot-required.pkgs
        fi
    fi
}

update_dnf() {
    log_section "DNF (Fedora/RHEL 8+/AlmaLinux/Rocky)"
    # Works the same on dnf4 and dnf5
    if try_cmd dnf upgrade --refresh -y; then
        run_cmd dnf autoremove -y
    else
        log "Skipping autoremove, since the upgrade did not finish."
    fi
}

update_yum() {
    log_section "YUM (CentOS/RHEL 7)"
    if try_cmd yum update -y; then
        run_cmd yum autoremove -y
    else
        log "Skipping autoremove, since the upgrade did not finish."
    fi
}

zypper_autoremove() {
    local -a pkgs=()
    local name
    # Rows look like "i | repo | name | version | arch"
    while IFS= read -r name; do
        [ -n "$name" ] && pkgs+=("$name")
    done < <(LC_ALL=C zypper -q packages --unneeded 2>/dev/null \
                | awk -F'|' '$1 ~ /^i/ { gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3 }' || true)

    if [ "${#pkgs[@]}" -eq 0 ]; then
        log "No unneeded packages found. Nothing to do."
        return 0
    fi

    log "Removing ${#pkgs[@]} unneeded package(s): ${pkgs[*]}"
    run_cmd zypper -n remove --clean-deps -- "${pkgs[@]}"
}

# True when / is mounted read-only, as on MicroOS, Aeon and Kalpa, where
# packages change through transactional-update snapshots instead.
root_is_readonly() {
    local opts
    opts="$(LC_ALL=C awk '$2 == "/" { o = $4 } END { print o }' /proc/mounts 2>/dev/null || true)"
    case ",$opts," in
        *,ro,*) return 0 ;;
    esac
    return 1
}

update_zypper() {
    if has_cmd transactional-update && root_is_readonly; then
        log_section "transactional-update (openSUSE immutable)"
        # The new snapshot only becomes active after a reboot
        if try_cmd transactional-update --non-interactive dup; then
            log "WARNING: A reboot is required to boot into the updated snapshot."
        fi
        return 0
    fi

    log_section "Zypper (openSUSE/SLES)"
    try_cmd zypper -n ref || return 0
    # Tumbleweed and Slowroll are rolling and want dup. Leap and SLES want
    # up: dup there can pull in packages from the wrong release.
    local upgraded=0
    case "$(os_id)" in
        opensuse-tumbleweed|opensuse-slowroll)
            try_cmd zypper -n dup --no-recommends && upgraded=1 ;;
        *)
            try_cmd zypper -n up && upgraded=1 ;;
    esac
    if [ "$upgraded" -eq 1 ]; then
        zypper_autoremove
    else
        log "Skipping the unneeded-package cleanup, since the upgrade did not finish."
    fi
}

update_pacman() {
    log_section "Pacman (Arch/Manjaro)"
    if ! try_cmd pacman -Syu --noconfirm; then
        log "Skipping orphan removal, since the upgrade did not finish."
        return 0
    fi
    local -a orphans=()
    local p
    while IFS= read -r p; do
        [ -n "$p" ] && orphans+=("$p")
    done < <(LC_ALL=C pacman -Qdtq 2>/dev/null || true)
    if [ "${#orphans[@]}" -gt 0 ]; then
        log "Removing ${#orphans[@]} orphaned package(s)..."
        run_cmd pacman -Rns --noconfirm -- "${orphans[@]}"
    fi
    run_cmd pacman -Sc --noconfirm
}

update_aur() {
    local helper=""
    if has_cmd yay; then
        helper=yay
    elif has_cmd paru; then
        helper=paru
    else
        return 0
    fi

    # AUR helpers refuse to run as root
    local aur_user
    aur_user="$(human_user)"
    if [ -z "$aur_user" ]; then
        log "WARNING: Could not find an unprivileged user for $helper. Skipping AUR update."
        return 0
    fi
    log_section "AUR via $helper (user: $aur_user)"
    run_cmd as_user "$aur_user" "$helper" -Sua --noconfirm
}

update_apk() {
    log_section "APK (Alpine)"
    run_cmd apk update
    run_cmd apk upgrade
    # Only systems with a local package cache configured have anything to clean
    if [ -e /etc/apk/cache ]; then
        run_cmd apk cache clean
    fi
}

update_xbps() {
    log_section "XBPS (Void Linux)"
    # xbps has to update itself first, or the full upgrade refuses to run
    run_cmd xbps-install -Suy xbps
    if try_cmd xbps-install -Suy; then
        run_cmd xbps-remove -Oo -y
    else
        log "Skipping orphan removal, since the upgrade did not finish."
    fi
}

update_eopkg() {
    log_section "eopkg (Solus)"
    try_cmd eopkg update-repo || return 0
    if try_cmd eopkg upgrade -y; then
        run_cmd eopkg remove-orphans -y
    else
        log "Skipping orphan removal, since the upgrade did not finish."
    fi
    run_cmd eopkg delete-cache
}

update_emerge() {
    log_section "Portage/Emerge (Gentoo)"
    # --ask=n overrides an --ask in EMERGE_DEFAULT_OPTS, which would otherwise
    # sit waiting for an answer nobody is there to give
    try_cmd emerge --sync || return 0
    # depclean after a world update that stopped partway can remove things
    # the half-updated system still needs, so it only runs after a clean one
    if try_cmd emerge --ask=n -uDU --keep-going --with-bdeps=y @world; then
        run_cmd emerge --ask=n --depclean
        # Modern Portage handles this itself, revdep-rebuild only exists if
        # gentoolkit is installed
        if has_cmd revdep-rebuild; then
            run_cmd revdep-rebuild
        fi
    else
        log "Skipping depclean, since the world update did not finish."
    fi
}

update_nix() {
    log_section "Nix"
    if has_cmd nixos-rebuild; then
        # --upgrade updates the root channels first. A flake-based config
        # needs "nix flake update" in its directory instead, which this
        # can't know about.
        run_cmd nixos-rebuild switch --upgrade
    else
        # Standalone nix install (non-NixOS), owned by a regular user
        local nix_user
        nix_user="$(human_user)"
        if [ -n "$nix_user" ]; then
            run_cmd as_user "$nix_user" nix-channel --update
            run_cmd as_user "$nix_user" nix-env -u '*'
        fi
    fi
}

update_snap() {
    log_section "Snap"
    run_cmd snap refresh
}

update_flatpak() {
    log_section "Flatpak"
    if try_cmd flatpak update --system -y --noninteractive; then
        run_cmd flatpak uninstall --system --unused -y --noninteractive
    fi

    # Per-user installs, for every regular account that has some
    local username uid homedir shell
    while IFS=: read -r username _ uid _ _ homedir shell; do
        case "$uid" in
            ''|*[!0-9]*) continue ;;
        esac
        if [ "$uid" -lt 1000 ] || [ "$uid" -ge 65534 ]; then
            continue
        fi
        case "$shell" in
            */nologin|*/false) continue ;;
        esac
        [ -d "$homedir/.local/share/flatpak" ] || continue
        log "Updating Flatpak user installs for: $username"
        run_cmd as_user "$username" flatpak update --user -y --noninteractive
    done < <(getent passwd || true)
}

main() {
    local missing=() cmd
    for cmd in date awk cut getent uname tee id; do
        has_cmd "$cmd" || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf '%s: missing required commands: %s\n' "$prog" "${missing[*]}" >&2
        exit 1
    fi

    local opt
    while getopts ':lh-:' opt; do
        case "$opt" in
            l) ENABLE_LOGGING=1 ;;
            h) usage; exit 0 ;;
            -)
                case "$OPTARG" in
                    log) ENABLE_LOGGING=1 ;;
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

    if [ "$(id -u)" -ne 0 ]; then
        printf '%s: this must be run as root.\n' "$prog" >&2
        exit 1
    fi

    if [ "$ENABLE_LOGGING" -eq 1 ] && ! touch -- "$LOG_FILE" 2>/dev/null; then
        printf '%s: cannot write to %s\n' "$prog" "$LOG_FILE" >&2
        exit 1
    fi

    log_section "System Update Started"
    log "Hostname: $(uname -n)"
    log "OS: $(os_name)"
    log "Kernel: $(uname -r)"

    local found=0
    # apt-get, not apt: some distros ship an unrelated Java tool called apt
    if has_cmd apt-get && has_cmd dpkg; then found=1; update_apt; fi
    if has_cmd dnf; then
        found=1; update_dnf
    elif has_cmd yum; then
        found=1; update_yum
    fi
    if has_cmd zypper; then found=1; update_zypper; fi
    if has_cmd pacman; then found=1; update_pacman; update_aur; fi
    if has_cmd apk; then found=1; update_apk; fi
    if has_cmd xbps-install; then found=1; update_xbps; fi
    if has_cmd emerge; then found=1; update_emerge; fi
    if has_cmd eopkg; then found=1; update_eopkg; fi
    if has_cmd nix-env; then found=1; update_nix; fi

    if [ "$found" -eq 0 ]; then
        log "WARNING: No supported native package manager found."
    fi

    if has_cmd snap; then update_snap; fi
    if has_cmd flatpak; then update_flatpak; fi

    log_section "Update Complete"
    if [ "$ERRORS" -gt 0 ]; then
        if [ "$ENABLE_LOGGING" -eq 1 ]; then
            log "Finished with $ERRORS error(s). Review $LOG_FILE for details."
        else
            log "Finished with $ERRORS error(s)."
        fi
        exit 1
    fi
    log "All updates completed successfully."
}

main "$@"
