#!/usr/bin/env bash
#
# pw-manager.sh
#
# Vault entry format on disk (inside the encrypted tar), one file per entry,
# 5 newline-separated fields:
#   line 1: Title / Domain
#   line 2: URL
#   line 3: Username
#   line 4: Password
#   line 5+: Notes (may be multi-line)
#

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

ENTRIES=()
DISPLAY_ENTRIES=()
SELECTED_INDEX=0
SCROLL_OFFSET=0
SEARCH_QUERY=""

KNOWN_VAULT_NAMES=()
KNOWN_VAULT_PATHS=()

CTRL_A=$'\x01'
CTRL_F=$'\x06'
CTRL_S=$'\x13'
ESC=$'\x1b'

set -o pipefail
shopt -s nullglob

umask 077

if [ -t 0 ]; then
    stty -ixon
fi

release_vault_lock() {
    if [[ -n "$LOCK_DIR" && -d "$LOCK_DIR" ]]; then
        rm -rf "$LOCK_DIR"
    fi
    LOCK_DIR=""
}

wipe_secure_tmp() {
    if [[ -n "$SECURE_TMP" && -d "$SECURE_TMP" ]]; then
        if command -v shred >/dev/null 2>&1; then
            find "$SECURE_TMP" -type f -exec shred -u {} \; 2>/dev/null
        fi
        rm -rf "$SECURE_TMP"
    fi
    SECURE_TMP=""
}

wipe_csv_tmp() {
    if [[ -n "$CSV_TMP" && -d "$CSV_TMP" ]]; then
        if command -v shred >/dev/null 2>&1; then
            find "$CSV_TMP" -type f -exec shred -u {} \; 2>/dev/null
        fi
        rm -rf "$CSV_TMP"
    fi
    CSV_TMP=""
}
scrub_master_pwds() {
    MASTER_PWD_1=""
    MASTER_PWD_2=""
    unset MASTER_PWD_1 MASTER_PWD_2
    MASTER_PWD_1=""
    MASTER_PWD_2=""
}

cleanup() {
    if [ -t 0 ]; then
        stty ixon
        tput cnorm
    fi
    scrub_master_pwds
    wipe_secure_tmp
    wipe_csv_tmp
    release_vault_lock
    clear
    exit 0
}
trap cleanup EXIT INT TERM
sanitize_display() {
    printf '%s' "$1" | tr -d '\000-\010\013-\037\177'
}

check_dependencies() {
    local deps=(gpg tar sed grep find)
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Error: required dependency '$dep' is not installed."
            exit 1
        fi
    done
}
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then return; fi
    local line1 line2 line3
    IFS= read -r line1 < "$CONFIG_FILE"
    line2=$(sed -n '2p' "$CONFIG_FILE" 2>/dev/null)
    line3=$(sed -n '3p' "$CONFIG_FILE" 2>/dev/null)
    if [[ -n "$line1" ]]; then
        DEFAULT_VAULT_PATH="$line1"
    fi
    if [[ "$line2" =~ ^[0-9]+$ ]]; then
        BACKUP_RETENTION_DAYS="$line2"
    fi
    if [[ "$line3" == "1" ]]; then
        RAM_ONLY_STRICT="1"
    else
        RAM_ONLY_STRICT="0"
    fi
}

save_config() {
    {
        printf '%s\n' "$DEFAULT_VAULT_PATH"
        printf '%s\n' "$BACKUP_RETENTION_DAYS"
        printf '%s\n' "$RAM_ONLY_STRICT"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}
load_known_vaults() {
    KNOWN_VAULT_NAMES=()
    KNOWN_VAULT_PATHS=()
    if [[ ! -f "$VAULTS_FILE" ]]; then return; fi
    local name path
    while IFS=$'\t' read -r name path; do
        [[ -z "$name" && -z "$path" ]] && continue
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
    chmod 600 "$VAULTS_FILE"
}

backup_vault() {
    local vault="$1"
    if [[ ! -f "$vault" ]]; then return; fi

    local v_dir v_name b_dir date_str backup_file
    v_dir=$(dirname "$vault")
    v_name=$(basename "$vault")
    b_dir="$v_dir/backups"

    mkdir -p "$b_dir"
    chmod 700 "$b_dir" 2>/dev/null
    date_str=$(date +%Y-%m-%d)
    backup_file="$b_dir/${v_name}.${date_str}.bak"

    if [[ ! -f "$backup_file" ]]; then
        cp "$vault" "$backup_file"
        chmod 600 "$backup_file"
    fi

    find "$b_dir" -name "${v_name}.*.bak" -type f -mtime "+${BACKUP_RETENTION_DAYS}" -exec rm -f {} \; 2>/dev/null
}
is_shm_tmpfs() {
    [[ -d /dev/shm ]] || return 1
    local fstype
    fstype=$(stat -f -c '%T' /dev/shm 2>/dev/null)
    [[ "$fstype" == "tmpfs" || "$fstype" == "ramfs" ]]
}
print_ram_only_failure() {
    echo "RAM-only mode is on, but no RAM-backed (tmpfs) storage was found"
    echo "at /dev/shm. Refusing to decrypt to disk. Troubleshooting:"
    echo "  - Check it's mounted:    mount | grep /dev/shm"
    echo "  - Check fstab has it:    grep shm /etc/fstab"
    echo "  - Try remounting it:     sudo mount -t tmpfs -o size=64m tmpfs /dev/shm"
    echo "  - In a container/chroot, /dev/shm may not exist unless whoever"
    echo "    built the image added it."
    echo "  - Or turn RAM-only mode off in Settings to allow the disk-backed"
    echo "    fallback again (with the shred/SSD caveat that comes with it)."
}
require_ram_storage_or_warn() {
    if is_shm_tmpfs || [[ "$RAM_ONLY_STRICT" != "1" ]]; then
        return 0
    fi
    print_ram_only_failure
    return 1
}
init_secure_env() {
    unset TMPDIR
    if is_shm_tmpfs; then
        SECURE_TMP=$(mktemp -d -p /dev/shm pwman.XXXXXX)
    elif [[ "$RAM_ONLY_STRICT" == "1" ]]; then
        print_ram_only_failure
        return 1
    else
        echo "WARNING: /dev/shm not found or not tmpfs. Falling back to a" >&2
        echo "disk-backed temp directory - decrypted vault contents will" >&2
        echo "touch a real disk, and 'shred' cannot reliably erase them" >&2
        echo "afterward on SSDs or copy-on-write filesystems (btrfs, ZFS)." >&2
        sleep 2
        SECURE_TMP=$(mktemp -d -t pwman.XXXXXX)
    fi
    chmod 700 "$SECURE_TMP"
    export TMPDIR="$SECURE_TMP"
    return 0
}

init_csv_tmp() {
    unset TMPDIR
    if is_shm_tmpfs; then
        CSV_TMP=$(mktemp -d -p /dev/shm pwmancsv.XXXXXX)
    elif [[ "$RAM_ONLY_STRICT" == "1" ]]; then
        print_ram_only_failure
        return 1
    else
        echo "WARNING: /dev/shm not found or not tmpfs. Falling back to a" >&2
        echo "disk-backed temp directory for CSV handling (see" >&2
        echo "init_secure_env)." >&2
        sleep 2
        CSV_TMP=$(mktemp -d -t pwmancsv.XXXXXX)
    fi
    chmod 700 "$CSV_TMP"
    export TMPDIR="$CSV_TMP"
    return 0
}
acquire_vault_lock() {
    local vault="$1"
    local lock="${vault}.lock"

    if mkdir "$lock" 2>/dev/null; then
        echo "$$" > "$lock/pid"
        LOCK_DIR="$lock"
        return 0
    fi

    if [[ -f "$lock/pid" ]]; then
        local other_pid
        other_pid=$(cat "$lock/pid" 2>/dev/null)
        if [[ -n "$other_pid" ]] && ! kill -0 "$other_pid" 2>/dev/null; then
            rm -rf "$lock"
            if mkdir "$lock" 2>/dev/null; then
                echo "$$" > "$lock/pid"
                LOCK_DIR="$lock"
                return 0
            fi
        fi
    fi
    return 1
}

decrypt_vault() {
    local vault="$1"
    local type="$2"
    if ! init_secure_env; then
        return 1
    fi

    if [[ "$type" == "2" ]]; then
        if ! gpg -d --batch --yes --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 "$vault" 3<<<"$MASTER_PWD_2" 2>/dev/null | \
             gpg -d --batch --yes --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 3<<<"$MASTER_PWD_1" 2>/dev/null | \
             tar -xz -C "$SECURE_TMP" 2>/dev/null; then
            wipe_secure_tmp
            return 1
        fi
    else
        if ! gpg -d --batch --yes --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 "$vault" 3<<<"$MASTER_PWD_1" 2>/dev/null | \
             tar -xz -C "$SECURE_TMP" 2>/dev/null; then
            wipe_secure_tmp
            return 1
        fi
    fi

    if [[ ! -f "$SECURE_TMP/.pwman_metadata" ]]; then
        wipe_secure_tmp
        return 1
    fi
    return 0
}
encrypt_vault() {
    local vault="$1"
    local type="$2"
    local tmp_out
    tmp_out=$(mktemp "${vault}.XXXXXX" 2>/dev/null) || return 1

    backup_vault "$vault"

    printf 'PWMAN_SCHEMA=2\n' > "$SECURE_TMP/.pwman_metadata"
    chmod 600 "$SECURE_TMP/.pwman_metadata"

    local s2k_opts=(--s2k-digest-algo SHA512 --s2k-count 65011712)
    local saved=1
    if [[ "$type" == "2" ]]; then
        if tar -cz -C "$SECURE_TMP" . | \
           gpg --symmetric --cipher-algo AES256 "${s2k_opts[@]}" --batch --yes --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 3<<<"$MASTER_PWD_1" 2>/dev/null | \
           gpg --symmetric --cipher-algo AES256 "${s2k_opts[@]}" --batch --yes --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 3<<<"$MASTER_PWD_2" > "$tmp_out" 2>/dev/null; then
            saved=0
        fi
    else
        if tar -cz -C "$SECURE_TMP" . | \
           gpg --symmetric --cipher-algo AES256 "${s2k_opts[@]}" --batch --yes --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 3<<<"$MASTER_PWD_1" > "$tmp_out" 2>/dev/null; then
            saved=0
        fi
    fi

    if [[ "$saved" -ne 0 || ! -s "$tmp_out" ]]; then
        shred -u "$tmp_out" 2>/dev/null || rm -f "$tmp_out"
        return 1
    fi

    chmod 600 "$tmp_out"
    if ! mv -f "$tmp_out" "$vault"; then
        shred -u "$tmp_out" 2>/dev/null || rm -f "$tmp_out"
        return 1
    fi
    return 0
}
migrate_vault_schema() {
    local meta="$SECURE_TMP/.pwman_metadata"
    local version="0"

    if [[ -f "$meta" ]]; then
        local k v
        while IFS='=' read -r k v; do
            if [[ "$k" == "PWMAN_SCHEMA" ]]; then
                version="$v"
            fi
        done < "$meta"
    fi

    if [[ "$version" =~ ^[0-9]+$ ]] && (( version >= 2 )); then
        return
    fi

    local f domain user pass note
    for f in "$SECURE_TMP"/*.txt; do
        [[ -f "$f" ]] || continue
        domain=$(sed -n '1p' "$f")
        user=$(sed -n '2p' "$f")
        pass=$(sed -n '3p' "$f")
        note=$(tail -n +4 "$f")
        {
            printf '%s\n' "$domain"
            printf '%s\n' ""
            printf '%s\n' "$user"
            printf '%s\n' "$pass"
            printf '%s\n' "$note"
        } > "$f"
        chmod 600 "$f"
    done
    printf 'PWMAN_SCHEMA=2\n' > "$meta"
    chmod 600 "$meta"
}

copy_to_clipboard() {
    local data="$1"
    local label="$2"
    local clip_cmd=""

    if command -v pbcopy >/dev/null; then clip_cmd="pbcopy"
    elif command -v wl-copy >/dev/null; then clip_cmd="wl-copy"
    elif command -v xclip >/dev/null; then clip_cmd="xclip -selection clipboard"
    elif command -v xsel >/dev/null; then clip_cmd="xsel --clipboard --input"
    fi

    if [[ -n "$clip_cmd" ]]; then
        if [[ -n "$CLIP_CLEAR_PID" ]] && kill -0 "$CLIP_CLEAR_PID" 2>/dev/null; then
            kill "$CLIP_CLEAR_PID" 2>/dev/null
        fi
        echo -n "$data" | $clip_cmd
        echo "$label copied to clipboard. Will clear in 45 seconds..."
        ( sleep 45; echo -n "" | $clip_cmd ) &
        CLIP_CLEAR_PID=$!
        disown
    else
        echo "Clipboard utility not found. Please install xclip, xsel, pbcopy, or wl-copy."
    fi
    sleep 2
}

generate_pwd() {
    tr -dc 'a-zA-Z0-9!@#$%^&*()_+?><~' < /dev/urandom | fold -w 16 | head -n 1
}

load_entries() {
    ENTRIES=()
    for f in "$SECURE_TMP"/*; do
        if [[ -f "$f" && "$(basename "$f")" != ".pwman_metadata" ]]; then
            ENTRIES+=("$f")
        fi
    done
}

filter_entries() {
    local sort_keys=()
    for entry in "${ENTRIES[@]}"; do
        local domain user
        domain=$(sed -n '1p' "$entry")
        if [[ -n "$SEARCH_QUERY" ]]; then
            user=$(sed -n '3p' "$entry")
            if ! echo "$domain $user" | grep -qiF "$SEARCH_QUERY"; then
                continue
            fi
        fi
        sort_keys+=("$domain"$'\t'"$entry")
    done

    DISPLAY_ENTRIES=()
    if [ ${#sort_keys[@]} -gt 0 ]; then
        while IFS=$'\t' read -r _ path; do
            DISPLAY_ENTRIES+=("$path")
        done < <(printf '%s\n' "${sort_keys[@]}" | sort -f)
    fi

    if [ ${#DISPLAY_ENTRIES[@]} -eq 0 ]; then
        SELECTED_INDEX=0
    elif [ "$SELECTED_INDEX" -ge "${#DISPLAY_ENTRIES[@]}" ]; then
        SELECTED_INDEX=$((${#DISPLAY_ENTRIES[@]} - 1))
    fi
}

add_entry() {
    tput cnorm
    clear
    echo "=== Add New Entry ==="
    read -r -p "Domain / Title: " domain
    read -r -p "URL (optional): " url
    read -r -p "Username: " user
    read -r -s -p "Password (leave blank to auto-generate): " pass
    echo
    read -r -p "Note: " note

    domain=$(sanitize_display "$domain")
    url=$(sanitize_display "$url")
    user=$(sanitize_display "$user")
    note=$(sanitize_display "$note")

    if [[ -z "$domain" ]]; then
        echo "Domain / Title cannot be empty. Entry not added."
        sleep 1.5
        tput civis
        return
    fi

    if [[ -z "$pass" ]]; then
        pass=$(generate_pwd)
        echo "Generated Password: $pass"
        sleep 2
    fi

    local id file
    id=$(date +%s%N)
    file="$SECURE_TMP/$id.txt"
    {
        printf '%s\n' "$domain"
        printf '%s\n' "$url"
        printf '%s\n' "$user"
        printf '%s\n' "$pass"
        printf '%s\n' "$note"
    } > "$file"
    chmod 600 "$file"

    load_entries
    tput civis
}

view_entry() {
    local file="$1"
    if [[ ! -f "$file" ]]; then return; fi

    while true; do
        clear
        local domain url user pass note
        domain=$(sed -n '1p' "$file")
        url=$(sed -n '2p' "$file")
        user=$(sed -n '3p' "$file")
        pass=$(sed -n '4p' "$file")
        note=$(tail -n +5 "$file")

        echo "=== Entry: $(sanitize_display "$domain") ==="
        echo "1) URL      : $(sanitize_display "${url:-<none>}")"
        echo "2) Username : $(sanitize_display "$user")"
        echo "3) Password : [ HIDDEN - Press 'C' to copy, 'V' to view ]"
        echo "4) Note     : $(sanitize_display "$note")"
        echo "---------------------------------------------------------"
        echo "[C] Copy Pass | [U] Copy User | [L] Copy URL | [E] Edit File | [D] Delete | [ESC] Back"

        read -rsn1 key
        case "$key" in
            c|C) copy_to_clipboard "$pass" "Password" ;;
            u|U) copy_to_clipboard "$user" "Username" ;;
            l|L) copy_to_clipboard "$url" "URL" ;;
            v|V)
                echo -e "\nPassword: $(sanitize_display "$pass")"
                echo "(Press any key to hide...)"
                read -rsn1
                ;;
            e|E)
                tput cnorm
                "${EDITOR:-nano}" "$file"
                tput civis
                ;;
            d|D)
                tput cnorm
                read -r -p "Are you sure you want to delete this entry? (y/N): " confirm
                tput civis
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    rm -f "$file"
                    load_entries
                    return
                fi
                ;;
            "$ESC") return ;;
        esac
    done
}

vault_tui() {
    tput civis
    load_entries

    while true; do
        filter_entries
        clear

        local term_lines max_visible
        term_lines=$(tput lines)
        max_visible=$((term_lines - 8))
        if (( max_visible < 1 )); then max_visible=1; fi

        echo "=== VAULT: $(basename "$CURRENT_VAULT") ==="
        if [[ -n "$SEARCH_QUERY" ]]; then
            echo "Search: '$SEARCH_QUERY' (Clear with CTRL+F, Enter empty)"
        else
            echo "Search: [None]"
        fi
        echo "---------------------------------------------------------"

        if [ ${#DISPLAY_ENTRIES[@]} -eq 0 ]; then
            echo "  (No entries found)"
        else
            if [ "$SELECTED_INDEX" -lt "$SCROLL_OFFSET" ]; then
                SCROLL_OFFSET=$SELECTED_INDEX
            elif [ "$SELECTED_INDEX" -ge "$((SCROLL_OFFSET + max_visible))" ]; then
                SCROLL_OFFSET=$((SELECTED_INDEX - max_visible + 1))
            fi

            local end_idx=$((SCROLL_OFFSET + max_visible - 1))
            if [ "$end_idx" -ge "${#DISPLAY_ENTRIES[@]}" ]; then
                end_idx=$((${#DISPLAY_ENTRIES[@]} - 1))
            fi

            for i in $(seq "$SCROLL_OFFSET" "$end_idx"); do
                local file="${DISPLAY_ENTRIES[$i]}"
                local domain user display_text
                domain=$(sanitize_display "$(sed -n '1p' "$file")")
                user=$(sanitize_display "$(sed -n '3p' "$file")")
                display_text=$(printf "%-25s | %s" "${domain:0:25}" "${user:0:25}")

                if [ "$i" -eq "$SELECTED_INDEX" ]; then
                    echo "> $display_text"
                else
                    echo "  $display_text"
                fi
            done
        fi

        echo "---------------------------------------------------------"
        echo "[CTRL+A] Add  [CTRL+F] Search  [CTRL+S] Save  [ENTER] View  [ESC] Exit"

        read -rsn1 key

        case "$key" in
            "$CTRL_A")
                add_entry
                ;;
            "$CTRL_S")
                clear
                if encrypt_vault "$CURRENT_VAULT" "$CURRENT_VAULT_TYPE"; then
                    echo "Vault saved successfully!"
                else
                    echo "SAVE FAILED. Your on-disk vault was left untouched;"
                    echo "today's backup, if one exists, is your most recent copy."
                fi
                sleep 2
                ;;
            "$CTRL_F")
                tput cnorm
                echo -n "Search query: "
                read -r SEARCH_QUERY
                SELECTED_INDEX=0
                SCROLL_OFFSET=0
                tput civis
                ;;
            "$ESC")
                read -rsn2 -t 0.1 seq
                if [[ "$seq" == "[A" ]]; then
                    if [ "$SELECTED_INDEX" -gt 0 ]; then
                        ((SELECTED_INDEX--))
                    fi
                elif [[ "$seq" == "[B" ]]; then
                    if [ "$SELECTED_INDEX" -lt $((${#DISPLAY_ENTRIES[@]} - 1)) ]; then
                        ((SELECTED_INDEX++))
                    fi
                elif [[ -z "$seq" ]]; then
                    tput cnorm
                    read -r -p "Save before exiting? (y/N/cancel): " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        if encrypt_vault "$CURRENT_VAULT" "$CURRENT_VAULT_TYPE"; then
                            break
                        fi
                        echo "SAVE FAILED. Staying open so nothing is lost."
                        sleep 2
                    elif [[ "$confirm" =~ ^[Nn]$ ]]; then
                        break
                    fi
                    tput civis
                fi
                ;;
            "")
                if [ ${#DISPLAY_ENTRIES[@]} -gt 0 ]; then
                    view_entry "${DISPLAY_ENTRIES[$SELECTED_INDEX]}"
                fi
                ;;
        esac
    done
}
csv_import_entries() {
    local src_csv="$1"
    local dest_dir="$2"

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
    # Entries are newline-delimited single-line fields, so embedded
    # CR/LF would corrupt the on-disk format regardless of source. Also
    # strips other control/escape bytes a terminal could act on later
    # when this field gets displayed - an imported CSV is untrusted
    # input as far as that goes.
    s = s.replace("\r", " ").replace("\n", " ").strip()
    return CONTROL_RE.sub("", s)


def clean_pw(s):
    # Password only gets the structural CR/LF fix - every other
    # character is kept exactly as imported, since stripping anything
    # else would silently change the actual password.
    return s.replace("\r", " ").replace("\n", " ").strip()


def clean_notes(s):
    # Notes may legitimately span multiple lines - keep newlines, strip
    # everything else a terminal could interpret as a control sequence.
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
    local src_dir="$1"
    local dest_csv="$2"
    local fmt="$3"

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

export_csv_menu() {
    clear
    if ! command -v python3 >/dev/null 2>&1; then
        echo "CSV export requires python3, which isn't installed."
        sleep 2
        return
    fi
    if ! require_ram_storage_or_warn; then
        sleep 3
        return
    fi

    echo "=== Export Vault to CSV (Bitwarden / KeePassXC) ==="
    local vault_path
    read -r -p "Path to vault to export (.gpg or .gpg2): " vault_path
    vault_path="${vault_path/#\~/$HOME}"
    if [[ ! -f "$vault_path" ]]; then
        echo "Vault not found."
        sleep 2
        return
    fi

    if ! acquire_vault_lock "$vault_path"; then
        echo "This vault appears to already be open elsewhere (lock present)."
        echo "If you're sure that's not the case, remove: ${vault_path}.lock"
        sleep 3
        return
    fi

    local vtype
    if [[ "$vault_path" == *.gpg2 ]]; then
        vtype="2"
        read -r -s -p "Enter Layer 1 Password: " MASTER_PWD_1; echo
        read -r -s -p "Enter Layer 2 Password: " MASTER_PWD_2; echo
    else
        vtype="1"
        read -r -s -p "Enter Vault Password: " MASTER_PWD_1; echo
    fi

    echo "Decrypting..."
    if ! decrypt_vault "$vault_path" "$vtype"; then
        echo "Decryption failed! Wrong password or corrupted file."
        release_vault_lock
        scrub_master_pwds
        sleep 2
        return
    fi
    migrate_vault_schema

    echo "Export format:"
    echo "1) Bitwarden (csv)"
    echo "2) KeePassXC (csv)"
    read -r -p "Select (1/2): " fmt_choice
    local fmt="bitwarden"
    [[ "$fmt_choice" == "2" ]] && fmt="keepassxc"

    local out_path
    read -r -p "Output path for the encrypted export (e.g. ~/export.csv.gpg): " out_path
    out_path="${out_path/#\~/$HOME}"
    if [[ -e "$out_path" ]]; then
        local ow
        read -r -p "File already exists. Overwrite? (y/N): " ow
        if [[ ! "$ow" =~ ^[Yy]$ ]]; then
            wipe_secure_tmp
            release_vault_lock
            scrub_master_pwds
            echo "Cancelled."
            sleep 1
            return
        fi
    fi

    local csv_pwd1 csv_pwd2
    read -r -s -p "Set a password to encrypt the exported CSV: " csv_pwd1; echo
    read -r -s -p "Confirm password: " csv_pwd2; echo
    if [[ "$csv_pwd1" != "$csv_pwd2" ]]; then
        echo "Passwords did not match. Aborting export."
        wipe_secure_tmp
        release_vault_lock
        scrub_master_pwds
        sleep 2
        return
    fi

    local plain_csv="$SECURE_TMP/.export.csv"
    local result
    result=$(csv_export_entries "$SECURE_TMP" "$plain_csv" "$fmt")

    if [[ "$result" == ERROR:* ]]; then
        echo "Export failed: ${result#ERROR:}"
        [[ -f "$plain_csv" ]] && shred -u "$plain_csv" 2>/dev/null
        wipe_secure_tmp
        release_vault_lock
        scrub_master_pwds
        sleep 3
        return
    fi

    if ! gpg --symmetric --cipher-algo AES256 --s2k-digest-algo SHA512 --s2k-count 65011712 --batch --yes --pinentry-mode loopback --no-symkey-cache \
         --passphrase-fd 3 -o "$out_path" "$plain_csv" 3<<<"$csv_pwd1" 2>/dev/null; then
        echo "Failed to encrypt the export file."
        shred -u "$plain_csv" 2>/dev/null
        wipe_secure_tmp
        release_vault_lock
        scrub_master_pwds
        sleep 3
        return
    fi
    chmod 600 "$out_path"
    shred -u "$plain_csv" 2>/dev/null
    wipe_secure_tmp
    release_vault_lock
    scrub_master_pwds

    echo "Exported ${result#OK:} entries to: $out_path"
    echo "To use it: gpg -d \"$out_path\" > entries.csv"
    if [[ "$fmt" == "bitwarden" ]]; then
        echo "In Bitwarden, import it choosing file format 'Bitwarden (csv)'."
    else
        echo "In KeePassXC, use Database > Import > CSV File, then map the"
        echo "Title/Username/Password/URL/Notes columns (one-time, guided step)."
    fi
    echo "Delete the decrypted entries.csv afterwards - it's plaintext."
    sleep 4
}

import_csv_menu() {
    clear
    if ! command -v python3 >/dev/null 2>&1; then
        echo "CSV import requires python3, which isn't installed."
        sleep 2
        return
    fi
    if ! require_ram_storage_or_warn; then
        sleep 3
        return
    fi

    echo "=== Import CSV (Bitwarden / KeePassXC export) ==="
    local csv_path
    read -r -p "Path to the encrypted CSV export (.csv.gpg): " csv_path
    csv_path="${csv_path/#\~/$HOME}"
    if [[ ! -f "$csv_path" ]]; then
        echo "File not found."
        sleep 2
        return
    fi

    local csv_pwd
    read -r -s -p "Password to decrypt this CSV file: " csv_pwd; echo

    echo "Import into:"
    echo "1) A new vault"
    echo "2) An existing vault"
    local target_choice
    read -r -p "Select (1/2): " target_choice

    if ! init_csv_tmp; then
        return
    fi
    local plain_csv="$CSV_TMP/import.csv"

    if ! gpg -d --batch --yes --pinentry-mode loopback --no-symkey-cache --passphrase-fd 3 \
         -o "$plain_csv" "$csv_path" 3<<<"$csv_pwd" 2>/dev/null; then
        echo "Failed to decrypt CSV. Wrong password or corrupted file."
        wipe_csv_tmp
        sleep 2
        return
    fi

    if [[ "$target_choice" == "2" ]]; then
        local vault_path
        read -r -p "Enter path to existing vault (.gpg or .gpg2): " vault_path
        vault_path="${vault_path/#\~/$HOME}"
        if [[ ! -f "$vault_path" ]]; then
            echo "Vault not found."
            wipe_csv_tmp
            sleep 2
            return
        fi

        if ! acquire_vault_lock "$vault_path"; then
            echo "This vault appears to already be open elsewhere (lock present)."
            echo "If you're sure that's not the case, remove: ${vault_path}.lock"
            wipe_csv_tmp
            sleep 3
            return
        fi

        CURRENT_VAULT="$vault_path"
        if [[ "$CURRENT_VAULT" == *.gpg2 ]]; then
            CURRENT_VAULT_TYPE="2"
            read -r -s -p "Enter Layer 1 Password: " MASTER_PWD_1; echo
            read -r -s -p "Enter Layer 2 Password: " MASTER_PWD_2; echo
        else
            CURRENT_VAULT_TYPE="1"
            read -r -s -p "Enter Vault Password: " MASTER_PWD_1; echo
        fi

        echo "Decrypting..."
        if ! decrypt_vault "$CURRENT_VAULT" "$CURRENT_VAULT_TYPE"; then
            echo "Decryption failed! Wrong password or corrupted file."
            release_vault_lock
            scrub_master_pwds
            wipe_csv_tmp
            sleep 2
            return
        fi
        migrate_vault_schema
    else
        local target_dir v_name v_type confirm_pwd
        target_dir="${DEFAULT_VAULT_PATH:-$PWD}"
        read -r -p "Enter new vault name (e.g. personal): " v_name
        if [[ -z "$v_name" ]]; then
            wipe_csv_tmp
            return
        fi
        if [[ ! "$v_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo "Vault name can only contain letters, numbers, dots, dashes and underscores."
            wipe_csv_tmp
            sleep 2
            return
        fi
        echo "Encryption Options:"
        echo "1) Standard (1 Password, .gpg)"
        echo "2) Two-Layer (2 Passwords, .gpg2)"
        read -r -p "Select type (1/2): " v_type

        if [[ "$v_type" == "2" ]]; then
            CURRENT_VAULT_TYPE="2"
            CURRENT_VAULT="$target_dir/$v_name.gpg2"
            read -r -s -p "Set Layer 1 Password: " MASTER_PWD_1; echo
            read -r -s -p "Confirm Layer 1 Password: " confirm_pwd; echo
            if [[ "$MASTER_PWD_1" != "$confirm_pwd" ]]; then
                echo "Passwords did not match. Aborting."
                scrub_master_pwds
                wipe_csv_tmp
                sleep 2
                return
            fi
            read -r -s -p "Set Layer 2 Password: " MASTER_PWD_2; echo
            read -r -s -p "Confirm Layer 2 Password: " confirm_pwd; echo
            if [[ "$MASTER_PWD_2" != "$confirm_pwd" ]]; then
                echo "Passwords did not match. Aborting."
                scrub_master_pwds
                wipe_csv_tmp
                sleep 2
                return
            fi
        else
            CURRENT_VAULT_TYPE="1"
            CURRENT_VAULT="$target_dir/$v_name.gpg"
            read -r -s -p "Set Vault Password: " MASTER_PWD_1; echo
            read -r -s -p "Confirm Vault Password: " confirm_pwd; echo
            if [[ "$MASTER_PWD_1" != "$confirm_pwd" ]]; then
                echo "Passwords did not match. Aborting."
                scrub_master_pwds
                wipe_csv_tmp
                sleep 2
                return
            fi
        fi

        if [[ -e "$CURRENT_VAULT" ]]; then
            echo "A vault already exists at $CURRENT_VAULT. Aborting to avoid overwriting it."
            scrub_master_pwds
            wipe_csv_tmp
            sleep 2
            return
        fi

        if ! init_secure_env; then
            scrub_master_pwds
            wipe_csv_tmp
            sleep 2
            return
        fi
    fi

    local result
    result=$(csv_import_entries "$plain_csv" "$SECURE_TMP")
    wipe_csv_tmp

    if [[ "$result" == ERROR:* ]]; then
        echo "Import failed: ${result#ERROR:}"
        wipe_secure_tmp
        release_vault_lock
        scrub_master_pwds
        sleep 3
        return
    fi

    local imported skipped
    IFS=':' read -r _ imported skipped <<< "$result"
    echo "Imported ${imported:-0} entries (${skipped:-0} rows skipped)."
    echo "Review the vault, then press CTRL+S to save - nothing is written"
    echo "to disk until you do."
    sleep 3

    vault_tui
    release_vault_lock
    wipe_secure_tmp
    scrub_master_pwds
}
select_vault_menu() {
    while true; do
        load_known_vaults
        clear
        echo "=== Decrypt Vault ==="
        if [[ ${#KNOWN_VAULT_NAMES[@]} -gt 0 ]]; then
            echo "Known vaults:"
            local i letter path label
            for ((i = 0; i < ${#KNOWN_VAULT_NAMES[@]}; i++)); do
                printf -v letter '%b' "\\$(printf '%03o' $((65 + i)))"
                path="${KNOWN_VAULT_PATHS[$i]}"
                label=$(sanitize_display "${KNOWN_VAULT_NAMES[$i]}")
                if [[ -f "$path" ]]; then
                    printf "  %s) %-20s %s\n" "$letter" "$label" "$path"
                else
                    printf "  %s) %-20s %s [NOT FOUND]\n" "$letter" "$label" "$path"
                fi
            done
            echo
        else
            echo "No known vaults yet."
            echo
        fi
        echo "1) Add a new vault"
        [[ ${#KNOWN_VAULT_NAMES[@]} -gt 0 ]] && echo "2) Remove a known vault"
        echo "[Enter/Esc] Back to main menu"
        read -r -p "Select: " choice

        if [[ -z "$choice" || "$choice" == "$ESC" ]]; then
            return 1

        elif [[ "$choice" == "1" ]]; then
            local new_path new_name default_name existing_idx=-1
            read -r -p "Path to vault (.gpg or .gpg2): " new_path
            new_path="${new_path/#\~/$HOME}"
            if [[ ! -f "$new_path" ]]; then
                echo "File not found."
                sleep 2
                continue
            fi
            if [[ "$new_path" != *.gpg && "$new_path" != *.gpg2 ]]; then
                echo "Expected a .gpg or .gpg2 file."
                sleep 2
                continue
            fi

            for ((i = 0; i < ${#KNOWN_VAULT_PATHS[@]}; i++)); do
                [[ "${KNOWN_VAULT_PATHS[$i]}" == "$new_path" ]] && existing_idx=$i
            done
            if [[ $existing_idx -ge 0 ]]; then
                echo "Already known as '${KNOWN_VAULT_NAMES[$existing_idx]}' - opening it."
                sleep 1
                open_vault "$new_path"
                return 0
            fi

            default_name=$(basename "$new_path")
            default_name="${default_name%.gpg2}"
            default_name="${default_name%.gpg}"
            read -r -p "Name for this vault [$default_name]: " new_name
            new_name="${new_name:-$default_name}"
            new_name=$(sanitize_display "$new_name")
            new_name="${new_name//$'\t'/ }"
            [[ -z "$new_name" ]] && new_name="$default_name"

            KNOWN_VAULT_NAMES+=("$new_name")
            KNOWN_VAULT_PATHS+=("$new_path")
            save_known_vaults
            open_vault "$new_path"
            return 0

        elif [[ "$choice" == "2" && ${#KNOWN_VAULT_NAMES[@]} -gt 0 ]]; then
            local rm_choice rm_idx rm_ascii rm_confirm
            read -r -p "Remove which one (letter)? " rm_choice
            if [[ "$rm_choice" =~ ^[a-zA-Z]$ ]]; then
                rm_ascii=$(printf "%d" "'${rm_choice^^}")
                rm_idx=$((rm_ascii - 65))
                if [[ $rm_idx -ge 0 && $rm_idx -lt ${#KNOWN_VAULT_NAMES[@]} ]]; then
                    echo "Remove '${KNOWN_VAULT_NAMES[$rm_idx]}' from the known-vaults list?"
                    echo "(This only forgets it here - the vault file itself is untouched.)"
                    read -r -p "Confirm? (y/N): " rm_confirm
                    if [[ "$rm_confirm" =~ ^[Yy]$ ]]; then
                        unset 'KNOWN_VAULT_NAMES[rm_idx]'
                        unset 'KNOWN_VAULT_PATHS[rm_idx]'
                        KNOWN_VAULT_NAMES=("${KNOWN_VAULT_NAMES[@]}")
                        KNOWN_VAULT_PATHS=("${KNOWN_VAULT_PATHS[@]}")
                        save_known_vaults
                    fi
                fi
            fi

        elif [[ "$choice" =~ ^[a-zA-Z]$ ]]; then
            local ascii idx path rm_confirm
            ascii=$(printf "%d" "'${choice^^}")
            idx=$((ascii - 65))
            if [[ $idx -ge 0 && $idx -lt ${#KNOWN_VAULT_NAMES[@]} ]]; then
                path="${KNOWN_VAULT_PATHS[$idx]}"
                if [[ ! -f "$path" ]]; then
                    echo "That vault's file wasn't found at: $path"
                    read -r -p "Remove it from the known-vaults list? (y/N): " rm_confirm
                    if [[ "$rm_confirm" =~ ^[Yy]$ ]]; then
                        unset 'KNOWN_VAULT_NAMES[idx]'
                        unset 'KNOWN_VAULT_PATHS[idx]'
                        KNOWN_VAULT_NAMES=("${KNOWN_VAULT_NAMES[@]}")
                        KNOWN_VAULT_PATHS=("${KNOWN_VAULT_PATHS[@]}")
                        save_known_vaults
                    fi
                    sleep 1
                    continue
                fi
                open_vault "$path"
                return 0
            fi
        fi
    done
}

show_main_menu() {
    check_dependencies
    load_config

    while true; do
        clear
        echo "================================="
        echo "       PW MANAGER SHELL          "
        echo "================================="
        echo "1) Decrypt Vault"
        echo "2) Make Vault"
        echo "3) Import CSV (Bitwarden/KeePassXC)"
        echo "4) Export Vault to CSV (Bitwarden/KeePassXC)"
        echo "5) Set Default Path for Vaults"
        echo "6) Set Backup Retention (currently ${BACKUP_RETENTION_DAYS} days)"
        if [[ "$RAM_ONLY_STRICT" == "1" ]]; then
            echo "7) RAM-only mode: ON  (refuses to decrypt if /dev/shm isn't available)"
        else
            echo "7) RAM-only mode: OFF (falls back to a disk-backed temp dir, with a warning)"
        fi
        echo "---------------------------------"

        local default_vaults=()
        if [[ -n "$DEFAULT_VAULT_PATH" && -d "$DEFAULT_VAULT_PATH" ]]; then
            echo "Vaults in $DEFAULT_VAULT_PATH:"
            local idx=0
            while IFS= read -r -d '' file; do
                default_vaults+=("$file")
                local letter
                printf -v letter '%b' "\\$(printf '%03o' $((65 + idx)))"
                echo "$letter) $(basename "$file")"
                ((idx++))
            done < <(find "$DEFAULT_VAULT_PATH" -maxdepth 1 -type f \( -name "*.gpg" -o -name "*.gpg2" \) -print0 | sort -z)
            if [ ${#default_vaults[@]} -eq 0 ]; then
                echo "  (No vaults found)"
            fi
            echo "---------------------------------"
        fi
        echo "Q) Quit"

        echo -n "Select an option: "
        read -r choice

        if [[ "$choice" == "1" ]]; then
            if select_vault_menu; then
                break
            fi
        elif [[ "$choice" == "2" ]]; then
            make_vault
        elif [[ "$choice" == "3" ]]; then
            import_csv_menu
        elif [[ "$choice" == "4" ]]; then
            export_csv_menu
        elif [[ "$choice" == "5" ]]; then
            read -r -p "Enter directory path: " new_path
            new_path="${new_path/#\~/$HOME}"
            if [[ -d "$new_path" ]]; then
                DEFAULT_VAULT_PATH="$new_path"
                save_config
                echo "Default path updated."
            else
                echo "Directory does not exist."
            fi
            sleep 2
        elif [[ "$choice" == "6" ]]; then
            read -r -p "Enter backup retention in days: " new_days
            if [[ "$new_days" =~ ^[0-9]+$ ]]; then
                BACKUP_RETENTION_DAYS="$new_days"
                save_config
                echo "Retention updated to ${BACKUP_RETENTION_DAYS} days."
            else
                echo "Enter a whole number of days."
            fi
            sleep 2
        elif [[ "$choice" == "7" ]]; then
            if [[ "$RAM_ONLY_STRICT" == "1" ]]; then
                RAM_ONLY_STRICT="0"
                echo "RAM-only mode turned OFF."
            else
                RAM_ONLY_STRICT="1"
                echo "RAM-only mode turned ON. Decrypting will now refuse to"
                echo "fall back to disk if /dev/shm isn't available as tmpfs."
            fi
            save_config
            sleep 2
        elif [[ "$choice" =~ ^[Qq]$ ]]; then
            cleanup
        elif [[ "$choice" =~ ^[a-zA-Z]$ ]]; then
            local ascii idx
            ascii=$(printf "%d" "'${choice^^}")
            idx=$((ascii - 65))
            if [[ $idx -ge 0 && $idx -lt ${#default_vaults[@]} ]]; then
                open_vault "${default_vaults[$idx]}"
                break
            fi
        fi
    done
}

open_vault() {
    CURRENT_VAULT="$1"

    if ! acquire_vault_lock "$CURRENT_VAULT"; then
        echo "This vault appears to already be open elsewhere (lock present)."
        echo "If you're sure that's not the case, remove: ${CURRENT_VAULT}.lock"
        sleep 3
        return
    fi

    if ! require_ram_storage_or_warn; then
        release_vault_lock
        sleep 3
        return
    fi

    if [[ "$CURRENT_VAULT" == *.gpg2 ]]; then
        CURRENT_VAULT_TYPE="2"
        echo "Two-layer encrypted vault detected."
        read -r -s -p "Enter Layer 1 Password: " MASTER_PWD_1
        echo
        read -r -s -p "Enter Layer 2 Password: " MASTER_PWD_2
        echo
    else
        CURRENT_VAULT_TYPE="1"
        read -r -s -p "Enter Vault Password: " MASTER_PWD_1
        echo
    fi

    echo "Decrypting..."
    if decrypt_vault "$CURRENT_VAULT" "$CURRENT_VAULT_TYPE"; then
        migrate_vault_schema
        vault_tui
        release_vault_lock
        wipe_secure_tmp
        scrub_master_pwds
    else
        echo "Decryption failed! Wrong password or corrupted file."
        release_vault_lock
        scrub_master_pwds
        sleep 2
        exec "$0"
    fi
}

make_vault() {
    if ! require_ram_storage_or_warn; then
        sleep 3
        return
    fi

    local target_dir="${DEFAULT_VAULT_PATH:-$PWD}"
    read -r -p "Enter new vault name (e.g. personal): " v_name
    if [[ -z "$v_name" ]]; then return; fi
    if [[ ! "$v_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Vault name can only contain letters, numbers, dots, dashes and underscores."
        sleep 2
        return
    fi

    echo "Encryption Options:"
    echo "1) Standard (1 Password, .gpg)"
    echo "2) Two-Layer (2 Passwords, .gpg2)"
    read -r -p "Select type (1/2): " v_type

    local target_path confirm_pwd
    if [[ "$v_type" == "2" ]]; then
        target_path="$target_dir/$v_name.gpg2"
        read -r -s -p "Set Layer 1 Password: " MASTER_PWD_1; echo
        read -r -s -p "Confirm Layer 1 Password: " confirm_pwd; echo
        if [[ "$MASTER_PWD_1" != "$confirm_pwd" ]]; then
            echo "Passwords did not match. Aborting."
            scrub_master_pwds
            sleep 2
            return
        fi
        read -r -s -p "Set Layer 2 Password: " MASTER_PWD_2; echo
        read -r -s -p "Confirm Layer 2 Password: " confirm_pwd; echo
        if [[ "$MASTER_PWD_2" != "$confirm_pwd" ]]; then
            echo "Passwords did not match. Aborting."
            scrub_master_pwds
            sleep 2
            return
        fi
    else
        v_type="1"
        target_path="$target_dir/$v_name.gpg"
        read -r -s -p "Set Vault Password: " MASTER_PWD_1; echo
        read -r -s -p "Confirm Vault Password: " confirm_pwd; echo
        if [[ "$MASTER_PWD_1" != "$confirm_pwd" ]]; then
            echo "Passwords did not match. Aborting."
            scrub_master_pwds
            sleep 2
            return
        fi
    fi

    if [[ -e "$target_path" ]]; then
        echo "A vault already exists at $target_path. Aborting to avoid overwriting it."
        scrub_master_pwds
        sleep 2
        return
    fi

    if ! init_secure_env; then
        scrub_master_pwds
        sleep 2
        return
    fi
    if encrypt_vault "$target_path" "$v_type"; then
        echo "Vault created at $target_path"
    else
        echo "Vault creation FAILED - nothing was written to $target_path."
    fi
    wipe_secure_tmp
    scrub_master_pwds
    sleep 2
}

show_main_menu
