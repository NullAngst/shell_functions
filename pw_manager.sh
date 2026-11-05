#!/usr/bin/env bash
#
# pw_manager - menu-driven terminal password manager.
#
# Vaults are GPG-encrypted tar archives: .gpg (one password) or .gpg2 (two
# layers, two passwords). While a vault is open it is unpacked into a
# RAM-backed directory (/dev/shm, or $XDG_RUNTIME_DIR), never to disk unless
# RAM-only mode is off and no RAM-backed directory exists.
#
# Vault entry format on disk (inside the encrypted tar), one .txt file per
# entry, newline-separated fields:
#   line 1: Title / Domain
#   line 2: URL
#   line 3: Username
#   line 4: Password
#   line 5+: Notes (may be multi-line)
#
# Usage: pw_manager

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'pw_manager: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail
shopt -s nullglob

# These paths predate the rename from pw-manager and are kept so existing
# settings and vault lists carry over.
CONFIG_FILE="$HOME/.pw-manager-config"
VAULTS_FILE="$HOME/.pw-manager-vaults"

DEFAULT_VAULT_PATH=""
BACKUP_RETENTION_DAYS=7
RAM_ONLY_STRICT="0"
SECURE_TMP=""
CSV_TMP=""
LOCK_DIR=""
MASTER_PWD_1=""
MASTER_PWD_2=""
CURRENT_VAULT=""
CURRENT_VAULT_TYPE=""
CLIP_CLEAR_PID=""
STTY_CHANGED=0
UI_STARTED=0

ENTRIES=()
DISPLAY_ENTRIES=()
SELECTED_INDEX=0
SCROLL_OFFSET=0
SEARCH_QUERY=""

KNOWN_VAULT_NAMES=()
KNOWN_VAULT_PATHS=()

# Q is left out so a vault letter never collides with Quit
LETTERS="ABCDEFGHIJKLMNOPRSTUVWXYZ"

CTRL_A=$'\x01'
CTRL_F=$'\x06'
CTRL_S=$'\x13'
ESC=$'\x1b'

GPG_COMMON=(--batch --yes --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3)
GPG_SYM=(--symmetric --cipher-algo AES256 --s2k-digest-algo SHA512 --s2k-count 65011712)

umask 077

# ---------------------------------------------------------------------------
# Terminal helpers
# ---------------------------------------------------------------------------
term() {
    if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
        tput "$@" 2>/dev/null || true
    fi
}

clear_screen() {
    if [ -t 1 ]; then
        if command -v clear >/dev/null 2>&1; then
            clear
        else
            printf '\033[H\033[2J'
        fi
    fi
}

letter_for() {
    printf '%s' "${LETTERS:$1:1}"
}

# Index of a letter in LETTERS, or -1
index_for() {
    local up rest
    up="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    case "$LETTERS" in
        *"$up"*) rest="${LETTERS%%"$up"*}"; printf '%s' "${#rest}" ;;
        *) printf '%s' "-1" ;;
    esac
}

expand_home() {
    local p="$1"
    # shellcheck disable=SC2088  # matching a literal tilde the user typed
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p#"~/"}" ;;
    esac
    printf '%s' "$p"
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
shred_dir() {
    local d="$1"
    if [ -n "$d" ] && [ -d "$d" ]; then
        if command -v shred >/dev/null 2>&1; then
            find "$d" -type f -exec shred -u -- {} + 2>/dev/null || true
        fi
        rm -rf -- "$d"
    fi
}

release_vault_lock() {
    if [ -n "$LOCK_DIR" ] && [ -d "$LOCK_DIR" ]; then
        rm -rf -- "$LOCK_DIR"
    fi
    LOCK_DIR=""
}

wipe_secure_tmp() {
    shred_dir "$SECURE_TMP"
    SECURE_TMP=""
}

wipe_csv_tmp() {
    shred_dir "$CSV_TMP"
    CSV_TMP=""
}

scrub_master_pwds() {
    MASTER_PWD_1=""
    MASTER_PWD_2=""
}

cleanup() {
    trap - EXIT
    if [ "$STTY_CHANGED" -eq 1 ]; then
        stty ixon 2>/dev/null || true
    fi
    term cnorm
    scrub_master_pwds
    wipe_secure_tmp
    wipe_csv_tmp
    release_vault_lock
    # Only wipe the screen if the menus were drawn, so a startup error stays readable
    if [ "$UI_STARTED" -eq 1 ]; then
        clear_screen
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

sanitize_display() {
    # Tabs become spaces, since entry titles end up in tab-delimited sort keys.
    # Newlines are kept (notes can be multi-line); other control bytes go.
    printf '%s' "$1" | tr '\t' ' ' | tr -d '\000-\010\013-\037\177'
}

check_dependencies() {
    local missing=() dep
    for dep in gpg tar gzip sed find mktemp tr awk cp mv; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        printf 'pw_manager: missing required commands: %s\n' "${missing[*]}" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Config and known vaults
# ---------------------------------------------------------------------------
load_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    local line1="" line2="" line3=""
    {
        IFS= read -r line1 || true
        IFS= read -r line2 || true
        IFS= read -r line3 || true
    } < "$CONFIG_FILE"
    if [ -n "$line1" ]; then
        DEFAULT_VAULT_PATH="$line1"
    fi
    if [[ "$line2" =~ ^[0-9]+$ ]]; then
        BACKUP_RETENTION_DAYS="$line2"
    fi
    if [ "$line3" = "1" ]; then
        RAM_ONLY_STRICT="1"
    else
        RAM_ONLY_STRICT="0"
    fi
}

save_config() {
    printf '%s\n%s\n%s\n' "$DEFAULT_VAULT_PATH" "$BACKUP_RETENTION_DAYS" "$RAM_ONLY_STRICT" > "$CONFIG_FILE"
    chmod 600 -- "$CONFIG_FILE"
}

load_known_vaults() {
    KNOWN_VAULT_NAMES=()
    KNOWN_VAULT_PATHS=()
    [ -f "$VAULTS_FILE" ] || return 0
    local name path
    while IFS=$'\t' read -r name path || [ -n "$name" ]; do
        if [ -z "$name" ] && [ -z "$path" ]; then
            continue
        fi
        KNOWN_VAULT_NAMES+=("$name")
        KNOWN_VAULT_PATHS+=("$path")
    done < "$VAULTS_FILE"
}

save_known_vaults() {
    local i
    {
        for ((i = 0; i < ${#KNOWN_VAULT_NAMES[@]}; i++)); do
            printf '%s\t%s\n' "${KNOWN_VAULT_NAMES[$i]}" "${KNOWN_VAULT_PATHS[$i]}"
        done
    } > "$VAULTS_FILE"
    chmod 600 -- "$VAULTS_FILE"
}

forget_known_vault() {
    local idx="$1"
    unset 'KNOWN_VAULT_NAMES[idx]'
    unset 'KNOWN_VAULT_PATHS[idx]'
    KNOWN_VAULT_NAMES=("${KNOWN_VAULT_NAMES[@]}")
    KNOWN_VAULT_PATHS=("${KNOWN_VAULT_PATHS[@]}")
    save_known_vaults
}

backup_vault() {
    local vault="$1"
    [ -f "$vault" ] || return 0

    local v_dir v_name b_dir date_str backup_file f
    v_dir="$(dirname -- "$vault")"
    v_name="${vault##*/}"
    b_dir="$v_dir/backups"

    mkdir -p -- "$b_dir"
    chmod 700 -- "$b_dir" 2>/dev/null || true
    date_str="$(date +%Y-%m-%d)"
    backup_file="$b_dir/$v_name.$date_str.bak"

    if [ ! -f "$backup_file" ]; then
        cp -- "$vault" "$backup_file"
        chmod 600 -- "$backup_file"
    fi

    # Old backups of this vault only, matched literally rather than as a glob
    for f in "$b_dir"/*.bak; do
        case "${f##*/}" in
            "$v_name".*.bak)
                if [ -n "$(find "$f" -prune -type f -mtime "+$BACKUP_RETENTION_DAYS" 2>/dev/null)" ]; then
                    rm -f -- "$f"
                fi
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# RAM-backed storage
# ---------------------------------------------------------------------------
# Filesystem type of the mount a directory sits on, from /proc/mounts
fs_type_of() {
    awk -v d="$1" '$2 == d { t = $3 } END { print t }' /proc/mounts 2>/dev/null || true
}

# First directory we can write to that's backed by RAM
ram_dir() {
    local d t
    for d in /dev/shm "${XDG_RUNTIME_DIR:-}"; do
        [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ] || continue
        t="$(fs_type_of "$d")"
        if [ "$t" = tmpfs ] || [ "$t" = ramfs ]; then
            printf '%s' "$d"
            return 0
        fi
    done
    return 1
}

print_ram_only_failure() {
    cat <<'EOF'
RAM-only mode is on, but no RAM-backed (tmpfs) storage was found at
/dev/shm or $XDG_RUNTIME_DIR. Refusing to decrypt to disk. Troubleshooting:
  - Check it's mounted:    grep /dev/shm /proc/mounts
  - Check fstab has it:    grep shm /etc/fstab
  - Try remounting it:     sudo mount -t tmpfs -o size=64m tmpfs /dev/shm
  - In a container or chroot, /dev/shm may not exist unless whoever built
    the image added it.
  - Or turn RAM-only mode off in Settings to allow the disk-backed fallback
    again (with the shred/SSD caveat that comes with it).
EOF
}

require_ram_storage_or_warn() {
    if ram_dir >/dev/null || [ "$RAM_ONLY_STRICT" != "1" ]; then
        return 0
    fi
    print_ram_only_failure
    return 1
}

# Make a private temp directory, RAM-backed when possible. Args: name-prefix
make_private_dir() {
    local prefix="$1" base
    if base="$(ram_dir)"; then
        mktemp -d "$base/$prefix.XXXXXX"
        return
    fi
    if [ "$RAM_ONLY_STRICT" = "1" ]; then
        print_ram_only_failure >&2
        return 1
    fi
    {
        printf 'WARNING: no RAM-backed temp directory found. Falling back to a\n'
        printf 'disk-backed one: decrypted contents will touch a real disk, and\n'
        printf 'shred cannot reliably erase them afterward on SSDs or\n'
        printf 'copy-on-write filesystems (Btrfs, ZFS).\n'
    } >&2
    sleep 2
    mktemp -d "${TMPDIR:-/tmp}/$prefix.XXXXXX"
}

init_secure_env() {
    SECURE_TMP="$(make_private_dir pwman)" || { SECURE_TMP=""; return 1; }
    chmod 700 -- "$SECURE_TMP"
}

init_csv_tmp() {
    CSV_TMP="$(make_private_dir pwmancsv)" || { CSV_TMP=""; return 1; }
    chmod 700 -- "$CSV_TMP"
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
acquire_vault_lock() {
    local vault="$1"
    local lock="$vault.lock" other_pid=""

    if mkdir -- "$lock" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock/pid"
        LOCK_DIR="$lock"
        return 0
    fi

    # A lock left by a process that no longer exists is stale
    if [ -f "$lock/pid" ]; then
        IFS= read -r other_pid < "$lock/pid" || true
        if [[ "$other_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$other_pid" 2>/dev/null; then
            rm -rf -- "$lock"
            if mkdir -- "$lock" 2>/dev/null; then
                printf '%s\n' "$$" > "$lock/pid"
                LOCK_DIR="$lock"
                return 0
            fi
        fi
    fi
    return 1
}

print_lock_held() {
    printf 'This vault appears to already be open elsewhere (lock present).\n'
    printf "If you're sure that's not the case, remove: %s.lock\n" "$1"
}

# ---------------------------------------------------------------------------
# Encrypt / decrypt
# ---------------------------------------------------------------------------
# Passphrases reach gpg through a pipe on fd 3 (process substitution), so
# they never show up in ps or land in a temp file the way a here-string can
# on older bash.
decrypt_vault() {
    local vault="$1" type="$2"
    init_secure_env || return 1

    if [ "$type" = "2" ]; then
        if ! gpg -d "${GPG_COMMON[@]}" "$vault" 3< <(printf '%s' "$MASTER_PWD_2") 2>/dev/null \
             | gpg -d "${GPG_COMMON[@]}" 3< <(printf '%s' "$MASTER_PWD_1") 2>/dev/null \
             | tar -xz -C "$SECURE_TMP" 2>/dev/null; then
            wipe_secure_tmp
            return 1
        fi
    else
        if ! gpg -d "${GPG_COMMON[@]}" "$vault" 3< <(printf '%s' "$MASTER_PWD_1") 2>/dev/null \
             | tar -xz -C "$SECURE_TMP" 2>/dev/null; then
            wipe_secure_tmp
            return 1
        fi
    fi

    if [ ! -f "$SECURE_TMP/.pwman_metadata" ]; then
        wipe_secure_tmp
        return 1
    fi
    return 0
}

encrypt_vault() {
    local vault="$1" type="$2" tmp_out saved=1
    tmp_out="$(mktemp "$vault.XXXXXX" 2>/dev/null)" || return 1

    backup_vault "$vault" || true

    printf 'PWMAN_SCHEMA=2\n' > "$SECURE_TMP/.pwman_metadata"
    chmod 600 -- "$SECURE_TMP/.pwman_metadata"

    if [ "$type" = "2" ]; then
        if tar -cz -C "$SECURE_TMP" . \
           | gpg "${GPG_SYM[@]}" "${GPG_COMMON[@]}" 3< <(printf '%s' "$MASTER_PWD_1") 2>/dev/null \
           | gpg "${GPG_SYM[@]}" "${GPG_COMMON[@]}" 3< <(printf '%s' "$MASTER_PWD_2") > "$tmp_out" 2>/dev/null; then
            saved=0
        fi
    else
        if tar -cz -C "$SECURE_TMP" . \
           | gpg "${GPG_SYM[@]}" "${GPG_COMMON[@]}" 3< <(printf '%s' "$MASTER_PWD_1") > "$tmp_out" 2>/dev/null; then
            saved=0
        fi
    fi

    if [ "$saved" -ne 0 ] || [ ! -s "$tmp_out" ]; then
        rm -f -- "$tmp_out"
        return 1
    fi

    chmod 600 -- "$tmp_out"
    if ! mv -f -- "$tmp_out" "$vault"; then
        rm -f -- "$tmp_out"
        return 1
    fi
    return 0
}

migrate_vault_schema() {
    local meta="$SECURE_TMP/.pwman_metadata"
    local version="0" k v

    if [ -f "$meta" ]; then
        while IFS='=' read -r k v || [ -n "$k" ]; do
            if [ "$k" = "PWMAN_SCHEMA" ]; then
                version="$v"
            fi
        done < "$meta"
    fi

    if [[ "$version" =~ ^[0-9]+$ ]] && [ "$version" -ge 2 ]; then
        return 0
    fi

    # Schema 1 had no URL line: title, username, password, notes
    local f domain user pass note
    for f in "$SECURE_TMP"/*.txt; do
        [ -f "$f" ] || continue
        domain="$(sed -n '1p' "$f")"
        user="$(sed -n '2p' "$f")"
        pass="$(sed -n '3p' "$f")"
        note="$(sed -n '4,$p' "$f")"
        printf '%s\n%s\n%s\n%s\n%s\n' "$domain" "" "$user" "$pass" "$note" > "$f"
        chmod 600 -- "$f"
    done
    printf 'PWMAN_SCHEMA=2\n' > "$meta"
    chmod 600 -- "$meta"
}

# ---------------------------------------------------------------------------
# Clipboard
# ---------------------------------------------------------------------------
clip_cmd() {
    # Pick by session type: on Wayland wl-copy, on X11 xclip or xsel. A
    # wl-copy that's merely installed fails under X11, and the other way round.
    if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
        printf 'wl-copy'
    elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then
        printf 'xclip'
    elif [ -n "${DISPLAY:-}" ] && command -v xsel >/dev/null 2>&1; then
        printf 'xsel'
    elif command -v pbcopy >/dev/null 2>&1; then
        printf 'pbcopy'
    else
        return 1
    fi
}

copy_to_clipboard() {
    local data="$1" label="$2" tool
    local -a cmd=()

    if ! tool="$(clip_cmd)"; then
        printf 'No clipboard tool for this session. Install wl-clipboard (Wayland) or xclip/xsel (X11).\n'
        sleep 2
        return 0
    fi
    case "$tool" in
        wl-copy) cmd=(wl-copy) ;;
        xclip) cmd=(xclip -selection clipboard) ;;
        xsel) cmd=(xsel --clipboard --input) ;;
        pbcopy) cmd=(pbcopy) ;;
    esac

    if [ -n "$CLIP_CLEAR_PID" ] && kill -0 "$CLIP_CLEAR_PID" 2>/dev/null; then
        kill "$CLIP_CLEAR_PID" 2>/dev/null || true
    fi
    if printf '%s' "$data" | "${cmd[@]}"; then
        printf '%s copied to clipboard. Will clear in 45 seconds...\n' "$label"
        ( sleep 45; printf '' | "${cmd[@]}" ) >/dev/null 2>&1 &
        CLIP_CLEAR_PID=$!
        disown "$CLIP_CLEAR_PID" 2>/dev/null || true
    else
        printf 'Copying to the clipboard with %s failed.\n' "$tool"
    fi
    sleep 2
}

# ---------------------------------------------------------------------------
# Entries
# ---------------------------------------------------------------------------
generate_pwd() {
    local pw=""
    # dd reads a fixed chunk and exits on its own, so nothing in this pipeline
    # gets killed by a closed pipe (which pipefail would report as failure).
    while [ "${#pw}" -lt 16 ]; do
        pw+="$(dd if=/dev/urandom bs=256 count=1 2>/dev/null | LC_ALL=C tr -dc 'a-zA-Z0-9!@#$%^&*()_+?><~')"
    done
    printf '%s' "${pw:0:16}"
}

new_entry_path() {
    local id
    while true; do
        id="$(date +%s)_${RANDOM}${RANDOM}"
        if [ ! -e "$SECURE_TMP/$id.txt" ]; then
            printf '%s' "$SECURE_TMP/$id.txt"
            return 0
        fi
    done
}

load_entries() {
    ENTRIES=()
    local f
    # Only .txt: editors can leave backup or swap files next to an entry
    for f in "$SECURE_TMP"/*.txt; do
        if [ -f "$f" ]; then
            ENTRIES+=("$f")
        fi
    done
}

filter_entries() {
    local -a sort_keys=()
    local entry domain user query hay path
    query="$(printf '%s' "$SEARCH_QUERY" | tr '[:upper:]' '[:lower:]')"
    for entry in "${ENTRIES[@]}"; do
        domain="$(sed -n '1p' "$entry")"
        if [ -n "$query" ]; then
            user="$(sed -n '3p' "$entry")"
            hay="$(printf '%s %s' "$domain" "$user" | tr '[:upper:]' '[:lower:]')"
            case "$hay" in
                *"$query"*) ;;
                *) continue ;;
            esac
        fi
        sort_keys+=("$(sanitize_display "$domain")"$'\t'"$entry")
    done

    DISPLAY_ENTRIES=()
    if [ "${#sort_keys[@]}" -gt 0 ]; then
        while IFS=$'\t' read -r _ path; do
            DISPLAY_ENTRIES+=("$path")
        done < <(printf '%s\n' "${sort_keys[@]}" | sort -f)
    fi

    if [ "${#DISPLAY_ENTRIES[@]}" -eq 0 ]; then
        SELECTED_INDEX=0
    elif [ "$SELECTED_INDEX" -ge "${#DISPLAY_ENTRIES[@]}" ]; then
        SELECTED_INDEX=$(( ${#DISPLAY_ENTRIES[@]} - 1 ))
    fi
}

add_entry() {
    local domain url user pass note file
    term cnorm
    clear_screen
    printf '=== Add New Entry ===\n'
    read -r -p "Domain / Title: " domain || domain=""
    read -r -p "URL (optional): " url || url=""
    read -r -p "Username: " user || user=""
    read -r -s -p "Password (leave blank to auto-generate): " pass || pass=""
    printf '\n'
    read -r -p "Note: " note || note=""

    domain="$(sanitize_display "$domain")"
    url="$(sanitize_display "$url")"
    user="$(sanitize_display "$user")"
    note="$(sanitize_display "$note")"

    if [ -z "$domain" ]; then
        printf 'Domain / Title cannot be empty. Entry not added.\n'
        sleep 1.5
        term civis
        return 0
    fi

    if [ -z "$pass" ]; then
        pass="$(generate_pwd)"
        printf 'Generated Password: %s\n' "$pass"
        sleep 2
    fi

    file="$(new_entry_path)"
    printf '%s\n%s\n%s\n%s\n%s\n' "$domain" "$url" "$user" "$pass" "$note" > "$file"
    chmod 600 -- "$file"

    load_entries
    term civis
}

view_entry() {
    local file="$1" key confirm domain url user pass note _
    [ -f "$file" ] || return 0

    while true; do
        clear_screen
        domain="$(sed -n '1p' "$file")"
        url="$(sed -n '2p' "$file")"
        user="$(sed -n '3p' "$file")"
        pass="$(sed -n '4p' "$file")"
        note="$(sed -n '5,$p' "$file")"

        printf '=== Entry: %s ===\n' "$(sanitize_display "$domain")"
        printf '1) URL      : %s\n' "$(sanitize_display "${url:-<none>}")"
        printf '2) Username : %s\n' "$(sanitize_display "$user")"
        printf "3) Password : [ HIDDEN - Press 'C' to copy, 'V' to view ]\n"
        printf '4) Note     : %s\n' "$(sanitize_display "$note")"
        printf -- '---------------------------------------------------------\n'
        printf '[C] Copy Pass | [U] Copy User | [L] Copy URL | [E] Edit File | [D] Delete | [ESC] Back\n'

        read -rsn1 key || return 0
        case "$key" in
            c|C) copy_to_clipboard "$pass" "Password" ;;
            u|U) copy_to_clipboard "$user" "Username" ;;
            l|L) copy_to_clipboard "$url" "URL" ;;
            v|V)
                printf '\nPassword: %s\n' "$(sanitize_display "$pass")"
                printf '(Press any key to hide...)\n'
                read -rsn1 _ || true
                ;;
            e|E)
                term cnorm
                "${EDITOR:-nano}" "$file" || true
                term civis
                # The editor may have saved under a different name or removed it
                if [ ! -f "$file" ]; then
                    load_entries
                    return 0
                fi
                ;;
            d|D)
                term cnorm
                read -r -p "Are you sure you want to delete this entry? (y/N): " confirm || confirm=""
                term civis
                case "$confirm" in
                    [yY]|[yY][eE][sS])
                        rm -f -- "$file"
                        load_entries
                        return 0
                        ;;
                esac
                ;;
            "$ESC") return 0 ;;
        esac
    done
}

vault_tui() {
    local term_lines max_visible end_idx i file domain user display_text key seq confirm
    term civis
    load_entries

    while true; do
        filter_entries
        clear_screen

        term_lines="$(tput lines 2>/dev/null || printf '24')"
        [[ "$term_lines" =~ ^[0-9]+$ ]] || term_lines=24
        max_visible=$(( term_lines - 8 ))
        if [ "$max_visible" -lt 1 ]; then
            max_visible=1
        fi

        printf '=== VAULT: %s ===\n' "${CURRENT_VAULT##*/}"
        if [ -n "$SEARCH_QUERY" ]; then
            printf "Search: '%s' (clear with CTRL+F, then Enter on an empty query)\n" "$(sanitize_display "$SEARCH_QUERY")"
        else
            printf 'Search: [None]\n'
        fi
        printf -- '---------------------------------------------------------\n'

        if [ "${#DISPLAY_ENTRIES[@]}" -eq 0 ]; then
            printf '  (No entries found)\n'
        else
            if [ "$SELECTED_INDEX" -lt "$SCROLL_OFFSET" ]; then
                SCROLL_OFFSET=$SELECTED_INDEX
            elif [ "$SELECTED_INDEX" -ge $(( SCROLL_OFFSET + max_visible )) ]; then
                SCROLL_OFFSET=$(( SELECTED_INDEX - max_visible + 1 ))
            fi

            end_idx=$(( SCROLL_OFFSET + max_visible - 1 ))
            if [ "$end_idx" -ge "${#DISPLAY_ENTRIES[@]}" ]; then
                end_idx=$(( ${#DISPLAY_ENTRIES[@]} - 1 ))
            fi

            for (( i = SCROLL_OFFSET; i <= end_idx; i++ )); do
                file="${DISPLAY_ENTRIES[$i]}"
                domain="$(sanitize_display "$(sed -n '1p' "$file")")"
                user="$(sanitize_display "$(sed -n '3p' "$file")")"
                display_text="$(printf '%-25s | %s' "${domain:0:25}" "${user:0:25}")"
                if [ "$i" -eq "$SELECTED_INDEX" ]; then
                    printf '> %s\n' "$display_text"
                else
                    printf '  %s\n' "$display_text"
                fi
            done
        fi

        printf -- '---------------------------------------------------------\n'
        printf '[CTRL+A] Add  [CTRL+F] Search  [CTRL+S] Save  [ENTER] View  [ESC] Exit\n'

        read -rsn1 key || key="$ESC"

        case "$key" in
            "$CTRL_A")
                add_entry
                ;;
            "$CTRL_S")
                clear_screen
                if encrypt_vault "$CURRENT_VAULT" "$CURRENT_VAULT_TYPE"; then
                    printf 'Vault saved successfully!\n'
                else
                    printf 'SAVE FAILED. Your on-disk vault was left untouched;\n'
                    printf "today's backup, if one exists, is your most recent copy.\n"
                fi
                sleep 2
                ;;
            "$CTRL_F")
                term cnorm
                read -r -p "Search query: " SEARCH_QUERY || SEARCH_QUERY=""
                SELECTED_INDEX=0
                SCROLL_OFFSET=0
                term civis
                ;;
            "$ESC")
                # Arrow keys arrive as ESC [ A / ESC [ B. A lone ESC means exit.
                seq=""
                read -rsn2 -t 0.1 seq || true
                if [ "$seq" = "[A" ]; then
                    if [ "$SELECTED_INDEX" -gt 0 ]; then
                        SELECTED_INDEX=$(( SELECTED_INDEX - 1 ))
                    fi
                elif [ "$seq" = "[B" ]; then
                    if [ "$SELECTED_INDEX" -lt $(( ${#DISPLAY_ENTRIES[@]} - 1 )) ]; then
                        SELECTED_INDEX=$(( SELECTED_INDEX + 1 ))
                    fi
                elif [ -z "$seq" ]; then
                    term cnorm
                    read -r -p "Save before exiting? (y = save, n = discard, Enter = stay): " confirm || confirm="n"
                    case "$confirm" in
                        [yY]|[yY][eE][sS])
                            if encrypt_vault "$CURRENT_VAULT" "$CURRENT_VAULT_TYPE"; then
                                break
                            fi
                            printf 'SAVE FAILED. Staying open so nothing is lost.\n'
                            sleep 2
                            ;;
                        [nN]|[nN][oO])
                            break
                            ;;
                    esac
                    term civis
                fi
                ;;
            "")
                if [ "${#DISPLAY_ENTRIES[@]}" -gt 0 ]; then
                    view_entry "${DISPLAY_ENTRIES[$SELECTED_INDEX]}"
                fi
                ;;
        esac
    done
    term cnorm
}

# ---------------------------------------------------------------------------
# CSV import / export (python3's csv module does the quoting rules)
# ---------------------------------------------------------------------------
csv_import_entries() {
    local src_csv="$1" dest_dir="$2"

    PWMAN_SRC_CSV="$src_csv" PWMAN_DEST_DIR="$dest_dir" python3 - <<'PYEOF'
import csv
import os
import re
import sys
import time

src = os.environ["PWMAN_SRC_CSV"]
dest = os.environ["PWMAN_DEST_DIR"]

CONTROL_RE = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]')


def norm(row):
    return {(k or "").strip().lower(): (v or "") for k, v in row.items()}


def pick(d, *keys):
    for k in keys:
        if d.get(k):
            return d[k]
    return ""


def clean_line(s):
    # Entries are newline-delimited single-line fields, so embedded CR/LF
    # would corrupt the on-disk format. Other control and escape bytes a
    # terminal could act on later are stripped too: an imported CSV is
    # untrusted input as far as that goes.
    s = s.replace("\r", " ").replace("\n", " ").replace("\t", " ").strip()
    return CONTROL_RE.sub("", s)


def clean_pw(s):
    # The password only gets the structural CR/LF fix. Stripping anything
    # else would silently change the actual password.
    return s.replace("\r", " ").replace("\n", " ").strip()


def clean_notes(s):
    # Notes may span lines. Keep newlines, strip anything a terminal could
    # read as a control sequence.
    return CONTROL_RE.sub("", s.strip())


count = 0
skipped = 0
try:
    with open(src, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        if not reader.fieldnames:
            print("ERROR:No header row found in CSV.")
            sys.exit(1)
        for row in reader:
            d = norm(row)
            title = pick(d, "name", "title")
            url = pick(d, "login_uri", "url", "uri")
            user = pick(d, "login_username", "username", "user", "login")
            pw = pick(d, "login_password", "password", "pass")
            notes = pick(d, "notes", "note")
            totp = pick(d, "login_totp", "totp")

            if not title and not user and not pw and not notes:
                skipped += 1
                continue
            if not title:
                title = user or "Untitled"

            if totp:
                notes = (notes + "\n" if notes else "") + "TOTP: " + clean_line(totp)

            uid = "%d%04d" % (time.time_ns(), count)
            path = os.path.join(dest, uid + ".txt")
            with open(path, "w", encoding="utf-8") as out:
                out.write(clean_line(title) + "\n")
                out.write(clean_line(url) + "\n")
                out.write(clean_line(user) + "\n")
                out.write(clean_pw(pw) + "\n")
                out.write(clean_notes(notes) + "\n")
            os.chmod(path, 0o600)
            count += 1
except Exception as e:
    print("ERROR:" + str(e))
    sys.exit(1)

print("OK:%d:%d" % (count, skipped))
PYEOF
}

csv_export_entries() {
    local src_dir="$1" dest_csv="$2" fmt="$3"

    PWMAN_SRC_DIR="$src_dir" PWMAN_DEST_CSV="$dest_csv" PWMAN_FMT="$fmt" python3 - <<'PYEOF'
import csv
import datetime
import glob
import os
import sys

UTC = getattr(datetime, "UTC", datetime.timezone.utc)

src = os.environ["PWMAN_SRC_DIR"]
dest = os.environ["PWMAN_DEST_CSV"]
fmt = os.environ["PWMAN_FMT"]

entries = []
for path in sorted(glob.glob(os.path.join(src, "*.txt"))):
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    while len(lines) < 5:
        lines.append("")
    title, url, user, pw = lines[0], lines[1], lines[2], lines[3]
    notes = "\n".join(lines[4:]).rstrip("\n")
    entries.append((title, url, user, pw, notes))

count = 0
try:
    with open(dest, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if fmt == "keepassxc":
            w.writerow(["Group", "Title", "Username", "Password", "URL", "Notes",
                        "TOTP", "Icon", "Last Modified", "Created"])
            now = datetime.datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
            for title, url, user, pw, notes in entries:
                w.writerow(["Root", title, user, pw, url, notes, "", "0", now, now])
                count += 1
        else:
            w.writerow(["folder", "favorite", "type", "name", "notes", "fields",
                        "reprompt", "login_uri", "login_username", "login_password",
                        "login_totp"])
            for title, url, user, pw, notes in entries:
                w.writerow(["", "0", "login", title, notes, "", "0", url, user, pw, ""])
                count += 1
    os.chmod(dest, 0o600)
except Exception as e:
    print("ERROR:" + str(e))
    sys.exit(1)

print("OK:%d" % count)
PYEOF
}

# Prompt for the password(s) of an existing vault. Args: vault path
prompt_vault_passwords() {
    if [[ "$1" == *.gpg2 ]]; then
        CURRENT_VAULT_TYPE="2"
        read -r -s -p "Enter Layer 1 Password: " MASTER_PWD_1 || MASTER_PWD_1=""
        printf '\n'
        read -r -s -p "Enter Layer 2 Password: " MASTER_PWD_2 || MASTER_PWD_2=""
        printf '\n'
    else
        CURRENT_VAULT_TYPE="1"
        read -r -s -p "Enter Vault Password: " MASTER_PWD_1 || MASTER_PWD_1=""
        printf '\n'
    fi
}

# Set and confirm one password into the named variable. Returns 1 on mismatch.
set_password() {
    local label="$1" var="$2" first second
    read -r -s -p "Set $label: " first || first=""
    printf '\n'
    read -r -s -p "Confirm $label: " second || second=""
    printf '\n'
    if [ "$first" != "$second" ]; then
        printf 'Passwords did not match. Aborting.\n'
        return 1
    fi
    if [ -z "$first" ]; then
        printf 'An empty password is not allowed. Aborting.\n'
        return 1
    fi
    printf -v "$var" '%s' "$first"
}

# Ask for name, type and password(s) of a new vault. Sets CURRENT_VAULT and
# CURRENT_VAULT_TYPE. Returns 1 if anything is wrong or the user backs out.
prompt_new_vault() {
    local target_dir="${DEFAULT_VAULT_PATH:-$PWD}" v_name v_type
    read -r -p "Enter new vault name (e.g. personal): " v_name || v_name=""
    [ -n "$v_name" ] || return 1
    if [[ ! "$v_name" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$v_name" == .* ]]; then
        printf 'Vault name can only contain letters, numbers, dots, dashes and underscores, and cannot start with a dot.\n'
        sleep 2
        return 1
    fi

    printf 'Encryption Options:\n1) Standard (1 Password, .gpg)\n2) Two-Layer (2 Passwords, .gpg2)\n'
    read -r -p "Select type (1/2): " v_type || v_type=""

    if [ "$v_type" = "2" ]; then
        CURRENT_VAULT_TYPE="2"
        CURRENT_VAULT="$target_dir/$v_name.gpg2"
    else
        CURRENT_VAULT_TYPE="1"
        CURRENT_VAULT="$target_dir/$v_name.gpg"
    fi

    if [ -e "$CURRENT_VAULT" ]; then
        printf 'A vault already exists at %s. Aborting to avoid overwriting it.\n' "$CURRENT_VAULT"
        sleep 2
        return 1
    fi

    if [ "$CURRENT_VAULT_TYPE" = "2" ]; then
        set_password "Layer 1 Password" MASTER_PWD_1 || { scrub_master_pwds; sleep 2; return 1; }
        set_password "Layer 2 Password" MASTER_PWD_2 || { scrub_master_pwds; sleep 2; return 1; }
    else
        set_password "Vault Password" MASTER_PWD_1 || { scrub_master_pwds; sleep 2; return 1; }
    fi
    return 0
}

export_csv_menu() {
    local vault_path fmt_choice fmt out_path ow csv_pwd1 csv_pwd2 plain_csv result
    clear_screen
    if ! command -v python3 >/dev/null 2>&1; then
        printf "CSV export requires python3, which isn't installed.\n"
        sleep 2
        return 0
    fi
    if ! require_ram_storage_or_warn; then
        sleep 3
        return 0
    fi

    printf '=== Export Vault to CSV (Bitwarden / KeePassXC) ===\n'
    read -r -p "Path to vault to export (.gpg or .gpg2): " vault_path || return 0
    vault_path="$(expand_home "$vault_path")"
    if [ ! -f "$vault_path" ]; then
        printf 'Vault not found.\n'
        sleep 2
        return 0
    fi

    if ! acquire_vault_lock "$vault_path"; then
        print_lock_held "$vault_path"
        sleep 3
        return 0
    fi

    prompt_vault_passwords "$vault_path"

    printf 'Decrypting...\n'
    if ! decrypt_vault "$vault_path" "$CURRENT_VAULT_TYPE"; then
        printf 'Decryption failed! Wrong password or corrupted file.\n'
        release_vault_lock
        scrub_master_pwds
        sleep 2
        return 0
    fi
    migrate_vault_schema

    printf 'Export format:\n1) Bitwarden (csv)\n2) KeePassXC (csv)\n'
    read -r -p "Select (1/2): " fmt_choice || fmt_choice=""
    fmt="bitwarden"
    if [ "$fmt_choice" = "2" ]; then
        fmt="keepassxc"
    fi

    read -r -p "Output path for the encrypted export (e.g. ~/export.csv.gpg): " out_path || out_path=""
    out_path="$(expand_home "$out_path")"
    if [ -z "$out_path" ]; then
        printf 'No output path given. Cancelled.\n'
        wipe_secure_tmp; release_vault_lock; scrub_master_pwds
        sleep 1
        return 0
    fi
    if [ -e "$out_path" ]; then
        read -r -p "File already exists. Overwrite? (y/N): " ow || ow=""
        case "$ow" in
            [yY]|[yY][eE][sS]) ;;
            *)
                wipe_secure_tmp; release_vault_lock; scrub_master_pwds
                printf 'Cancelled.\n'
                sleep 1
                return 0
                ;;
        esac
    fi

    read -r -s -p "Set a password to encrypt the exported CSV: " csv_pwd1 || csv_pwd1=""
    printf '\n'
    read -r -s -p "Confirm password: " csv_pwd2 || csv_pwd2=""
    printf '\n'
    if [ "$csv_pwd1" != "$csv_pwd2" ] || [ -z "$csv_pwd1" ]; then
        printf 'Passwords did not match (or were empty). Aborting export.\n'
        wipe_secure_tmp; release_vault_lock; scrub_master_pwds
        sleep 2
        return 0
    fi

    plain_csv="$SECURE_TMP/.export.csv"
    result="$(csv_export_entries "$SECURE_TMP" "$plain_csv" "$fmt" || true)"

    if [[ "$result" != OK:* ]]; then
        printf 'Export failed: %s\n' "${result#ERROR:}"
        wipe_secure_tmp; release_vault_lock; scrub_master_pwds
        sleep 3
        return 0
    fi

    if ! gpg "${GPG_SYM[@]}" "${GPG_COMMON[@]}" -o "$out_path" "$plain_csv" 3< <(printf '%s' "$csv_pwd1") 2>/dev/null; then
        printf 'Failed to encrypt the export file.\n'
        wipe_secure_tmp; release_vault_lock; scrub_master_pwds
        sleep 3
        return 0
    fi
    chmod 600 -- "$out_path"
    wipe_secure_tmp; release_vault_lock; scrub_master_pwds

    printf 'Exported %s entries to: %s\n' "${result#OK:}" "$out_path"
    printf 'To use it: gpg -d "%s" > entries.csv\n' "$out_path"
    if [ "$fmt" = "bitwarden" ]; then
        printf "In Bitwarden, import it choosing file format 'Bitwarden (csv)'.\n"
    else
        printf 'In KeePassXC, use Database > Import > CSV File, then map the\n'
        printf 'Title/Username/Password/URL/Notes columns (one-time, guided step).\n'
    fi
    printf "Delete the decrypted entries.csv afterwards, it's plaintext.\n"
    sleep 4
}

import_csv_menu() {
    local csv_path csv_pwd target_choice plain_csv vault_path result imported skipped
    clear_screen
    if ! command -v python3 >/dev/null 2>&1; then
        printf "CSV import requires python3, which isn't installed.\n"
        sleep 2
        return 0
    fi
    if ! require_ram_storage_or_warn; then
        sleep 3
        return 0
    fi

    printf '=== Import CSV (Bitwarden / KeePassXC export) ===\n'
    read -r -p "Path to the encrypted CSV export (.csv.gpg): " csv_path || return 0
    csv_path="$(expand_home "$csv_path")"
    if [ ! -f "$csv_path" ]; then
        printf 'File not found.\n'
        sleep 2
        return 0
    fi

    read -r -s -p "Password to decrypt this CSV file: " csv_pwd || csv_pwd=""
    printf '\n'

    printf 'Import into:\n1) A new vault\n2) An existing vault\n'
    read -r -p "Select (1/2): " target_choice || target_choice=""

    init_csv_tmp || { sleep 2; return 0; }
    plain_csv="$CSV_TMP/import.csv"

    if ! gpg -d "${GPG_COMMON[@]}" -o "$plain_csv" "$csv_path" 3< <(printf '%s' "$csv_pwd") 2>/dev/null; then
        printf 'Failed to decrypt CSV. Wrong password or corrupted file.\n'
        wipe_csv_tmp
        sleep 2
        return 0
    fi

    if [ "$target_choice" = "2" ]; then
        read -r -p "Enter path to existing vault (.gpg or .gpg2): " vault_path || vault_path=""
        vault_path="$(expand_home "$vault_path")"
        if [ ! -f "$vault_path" ]; then
            printf 'Vault not found.\n'
            wipe_csv_tmp
            sleep 2
            return 0
        fi
        if ! acquire_vault_lock "$vault_path"; then
            print_lock_held "$vault_path"
            wipe_csv_tmp
            sleep 3
            return 0
        fi

        CURRENT_VAULT="$vault_path"
        prompt_vault_passwords "$CURRENT_VAULT"

        printf 'Decrypting...\n'
        if ! decrypt_vault "$CURRENT_VAULT" "$CURRENT_VAULT_TYPE"; then
            printf 'Decryption failed! Wrong password or corrupted file.\n'
            release_vault_lock; scrub_master_pwds; wipe_csv_tmp
            sleep 2
            return 0
        fi
        migrate_vault_schema
    else
        if ! prompt_new_vault; then
            wipe_csv_tmp
            return 0
        fi
        if ! init_secure_env; then
            scrub_master_pwds; wipe_csv_tmp
            sleep 2
            return 0
        fi
    fi

    result="$(csv_import_entries "$plain_csv" "$SECURE_TMP" || true)"
    wipe_csv_tmp

    if [[ "$result" != OK:* ]]; then
        printf 'Import failed: %s\n' "${result#ERROR:}"
        wipe_secure_tmp; release_vault_lock; scrub_master_pwds
        sleep 3
        return 0
    fi

    IFS=':' read -r _ imported skipped <<< "$result" || true
    printf 'Imported %s entries (%s rows skipped).\n' "${imported:-0}" "${skipped:-0}"
    printf 'Review the vault, then press CTRL+S to save. Nothing is written\n'
    printf 'to disk until you do.\n'
    sleep 3

    vault_tui
    release_vault_lock
    wipe_secure_tmp
    scrub_master_pwds
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------
select_vault_menu() {
    local i letter path label choice new_path new_name default_name existing_idx
    local rm_choice rm_idx rm_confirm idx

    while true; do
        load_known_vaults
        clear_screen
        printf '=== Decrypt Vault ===\n'
        if [ "${#KNOWN_VAULT_NAMES[@]}" -gt 0 ]; then
            printf 'Known vaults:\n'
            for ((i = 0; i < ${#KNOWN_VAULT_NAMES[@]} && i < ${#LETTERS}; i++)); do
                letter="$(letter_for "$i")"
                path="${KNOWN_VAULT_PATHS[$i]}"
                label="$(sanitize_display "${KNOWN_VAULT_NAMES[$i]}")"
                if [ -f "$path" ]; then
                    printf '  %s) %-20s %s\n' "$letter" "$label" "$path"
                else
                    printf '  %s) %-20s %s [NOT FOUND]\n' "$letter" "$label" "$path"
                fi
            done
            if [ "${#KNOWN_VAULT_NAMES[@]}" -gt "${#LETTERS}" ]; then
                printf '  (only the first %d are shown)\n' "${#LETTERS}"
            fi
            printf '\n'
        else
            printf 'No known vaults yet.\n\n'
        fi
        printf '1) Add a new vault\n'
        if [ "${#KNOWN_VAULT_NAMES[@]}" -gt 0 ]; then
            printf '2) Remove a known vault\n'
        fi
        printf '[Enter/Esc] Back to main menu\n'
        read -r -p "Select: " choice || return 1

        if [ -z "$choice" ] || [ "$choice" = "$ESC" ]; then
            return 1

        elif [ "$choice" = "1" ]; then
            existing_idx=-1
            read -r -p "Path to vault (.gpg or .gpg2): " new_path || continue
            new_path="$(expand_home "$new_path")"
            if [ ! -f "$new_path" ]; then
                printf 'File not found.\n'
                sleep 2
                continue
            fi
            case "$new_path" in
                *.gpg|*.gpg2) ;;
                *) printf 'Expected a .gpg or .gpg2 file.\n'; sleep 2; continue ;;
            esac

            for ((i = 0; i < ${#KNOWN_VAULT_PATHS[@]}; i++)); do
                if [ "${KNOWN_VAULT_PATHS[$i]}" = "$new_path" ]; then
                    existing_idx=$i
                fi
            done
            if [ "$existing_idx" -ge 0 ]; then
                printf "Already known as '%s', opening it.\n" "${KNOWN_VAULT_NAMES[$existing_idx]}"
                sleep 1
                open_vault "$new_path"
                return 0
            fi

            default_name="${new_path##*/}"
            default_name="${default_name%.gpg2}"
            default_name="${default_name%.gpg}"
            read -r -p "Name for this vault [$default_name]: " new_name || new_name=""
            new_name="$(sanitize_display "${new_name:-$default_name}")"
            new_name="${new_name//$'\t'/ }"
            if [ -z "$new_name" ]; then
                new_name="$default_name"
            fi

            KNOWN_VAULT_NAMES+=("$new_name")
            KNOWN_VAULT_PATHS+=("$new_path")
            save_known_vaults
            open_vault "$new_path"
            return 0

        elif [ "$choice" = "2" ] && [ "${#KNOWN_VAULT_NAMES[@]}" -gt 0 ]; then
            read -r -p "Remove which one (letter)? " rm_choice || continue
            if [[ "$rm_choice" =~ ^[a-zA-Z]$ ]]; then
                rm_idx="$(index_for "$rm_choice")"
                if [ "$rm_idx" -ge 0 ] && [ "$rm_idx" -lt "${#KNOWN_VAULT_NAMES[@]}" ]; then
                    printf "Remove '%s' from the known-vaults list?\n" "${KNOWN_VAULT_NAMES[$rm_idx]}"
                    printf '(This only forgets it here. The vault file itself is untouched.)\n'
                    read -r -p "Confirm? (y/N): " rm_confirm || rm_confirm=""
                    case "$rm_confirm" in
                        [yY]|[yY][eE][sS]) forget_known_vault "$rm_idx" ;;
                    esac
                fi
            fi

        elif [[ "$choice" =~ ^[a-zA-Z]$ ]]; then
            idx="$(index_for "$choice")"
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#KNOWN_VAULT_NAMES[@]}" ]; then
                path="${KNOWN_VAULT_PATHS[$idx]}"
                if [ ! -f "$path" ]; then
                    printf "That vault's file wasn't found at: %s\n" "$path"
                    read -r -p "Remove it from the known-vaults list? (y/N): " rm_confirm || rm_confirm=""
                    case "$rm_confirm" in
                        [yY]|[yY][eE][sS]) forget_known_vault "$idx" ;;
                    esac
                    sleep 1
                    continue
                fi
                open_vault "$path"
                return 0
            fi
        fi
    done
}

open_vault() {
    CURRENT_VAULT="$1"

    if ! acquire_vault_lock "$CURRENT_VAULT"; then
        print_lock_held "$CURRENT_VAULT"
        sleep 3
        return 0
    fi

    if ! require_ram_storage_or_warn; then
        release_vault_lock
        sleep 3
        return 0
    fi

    if [[ "$CURRENT_VAULT" == *.gpg2 ]]; then
        printf 'Two-layer encrypted vault detected.\n'
    fi
    prompt_vault_passwords "$CURRENT_VAULT"

    printf 'Decrypting...\n'
    if decrypt_vault "$CURRENT_VAULT" "$CURRENT_VAULT_TYPE"; then
        migrate_vault_schema
        SEARCH_QUERY=""
        SELECTED_INDEX=0
        SCROLL_OFFSET=0
        vault_tui
        release_vault_lock
        wipe_secure_tmp
        scrub_master_pwds
    else
        printf 'Decryption failed! Wrong password or corrupted file.\n'
        release_vault_lock
        scrub_master_pwds
        sleep 2
    fi
}

make_vault() {
    if ! require_ram_storage_or_warn; then
        sleep 3
        return 0
    fi

    prompt_new_vault || return 0

    if ! init_secure_env; then
        scrub_master_pwds
        sleep 2
        return 0
    fi
    if encrypt_vault "$CURRENT_VAULT" "$CURRENT_VAULT_TYPE"; then
        printf 'Vault created at %s\n' "$CURRENT_VAULT"
    else
        printf 'Vault creation FAILED. Nothing was written to %s.\n' "$CURRENT_VAULT"
    fi
    wipe_secure_tmp
    scrub_master_pwds
    sleep 2
}

show_main_menu() {
    local choice new_path new_days idx f letter
    local -a default_vaults=()

    while true; do
        clear_screen
        printf '=================================\n'
        printf '       PW MANAGER SHELL          \n'
        printf '=================================\n'
        printf '1) Decrypt Vault\n'
        printf '2) Make Vault\n'
        printf '3) Import CSV (Bitwarden/KeePassXC)\n'
        printf '4) Export Vault to CSV (Bitwarden/KeePassXC)\n'
        printf '5) Set Default Path for Vaults\n'
        printf '6) Set Backup Retention (currently %s days)\n' "$BACKUP_RETENTION_DAYS"
        if [ "$RAM_ONLY_STRICT" = "1" ]; then
            printf "7) RAM-only mode: ON  (refuses to decrypt if no tmpfs is available)\n"
        else
            printf '7) RAM-only mode: OFF (falls back to a disk-backed temp dir, with a warning)\n'
        fi
        printf -- '---------------------------------\n'

        default_vaults=()
        if [ -n "$DEFAULT_VAULT_PATH" ] && [ -d "$DEFAULT_VAULT_PATH" ]; then
            printf 'Vaults in %s:\n' "$DEFAULT_VAULT_PATH"
            # Globs come back sorted, no sort -z needed
            for f in "$DEFAULT_VAULT_PATH"/*.gpg*; do
                [ -f "$f" ] || continue
                case "$f" in
                    *.gpg|*.gpg2) ;;
                    *) continue ;;
                esac
                [ "${#default_vaults[@]}" -lt "${#LETTERS}" ] || break
                letter="$(letter_for "${#default_vaults[@]}")"
                default_vaults+=("$f")
                printf '%s) %s\n' "$letter" "${f##*/}"
            done
            if [ "${#default_vaults[@]}" -eq 0 ]; then
                printf '  (No vaults found)\n'
            fi
            printf -- '---------------------------------\n'
        fi
        printf 'Q) Quit\n'

        read -r -p "Select an option: " choice || exit 0

        case "$choice" in
            1)
                if select_vault_menu; then
                    break
                fi
                ;;
            2) make_vault ;;
            3) import_csv_menu ;;
            4) export_csv_menu ;;
            5)
                read -r -p "Enter directory path: " new_path || new_path=""
                new_path="$(expand_home "$new_path")"
                if [ -n "$new_path" ] && [ -d "$new_path" ]; then
                    DEFAULT_VAULT_PATH="$new_path"
                    save_config
                    printf 'Default path updated.\n'
                else
                    printf 'Directory does not exist.\n'
                fi
                sleep 2
                ;;
            6)
                read -r -p "Enter backup retention in days: " new_days || new_days=""
                if [[ "$new_days" =~ ^[0-9]+$ ]]; then
                    BACKUP_RETENTION_DAYS="$new_days"
                    save_config
                    printf 'Retention updated to %s days.\n' "$BACKUP_RETENTION_DAYS"
                else
                    printf 'Enter a whole number of days.\n'
                fi
                sleep 2
                ;;
            7)
                if [ "$RAM_ONLY_STRICT" = "1" ]; then
                    RAM_ONLY_STRICT="0"
                    printf 'RAM-only mode turned OFF.\n'
                else
                    RAM_ONLY_STRICT="1"
                    printf 'RAM-only mode turned ON. Decrypting will now refuse to\n'
                    printf 'fall back to disk if no tmpfs is available.\n'
                fi
                save_config
                sleep 2
                ;;
            q|Q) exit 0 ;;
            [a-zA-Z])
                idx="$(index_for "$choice")"
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#default_vaults[@]}" ]; then
                    open_vault "${default_vaults[$idx]}"
                    break
                fi
                ;;
        esac
    done
}

main() {
    check_dependencies
    load_config
    # CTRL+S is the save key, so flow control has to be off for it to arrive
    if [ -t 0 ]; then
        stty -ixon 2>/dev/null && STTY_CHANGED=1
    fi
    UI_STARTED=1
    show_main_menu
}

main "$@"
