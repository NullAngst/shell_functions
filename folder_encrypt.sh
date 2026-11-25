#!/usr/bin/env bash
#
# folder_encrypt - archive a folder with tar and encrypt it with GPG
# symmetric AES-256, or reverse that.
#
# Usage:
#   folder_encrypt FOLDER              -> FOLDER.tar.gz.gpg
#   folder_encrypt -D FOLDER.tar.gz.gpg
#   folder_encrypt -R TARGET           every subfolder of TARGET on its own,
#                                      loose files gathered into loose_files/ first
#   folder_encrypt -R -D TARGET        every .gpg file inside TARGET
#
# Encryption streams tar straight into gpg, so no unencrypted archive ever
# lands on disk. Nothing existing is overwritten. Asks before deleting sources.

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'folder_encrypt: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=folder_encrypt
# Paths created by the step in progress, removed if it fails or is interrupted
PARTIAL=()

show_help() {
    cat <<EOF
Usage: $prog [OPTIONS] TARGET

Archive and encrypt/decrypt folders using GPG symmetric AES-256 encryption.

Options:
  -h, --help       Show this help message and exit
  -D, --decrypt    Decrypt the target
  -R, --bulk       Bulk mode: operate on the contents of the target folder rather than the folder itself

Nothing existing is overwritten. Asks before deleting sources.

Examples:
  Encrypt a single folder:
    $prog /path/to/folder

  Bulk encrypt folders and group loose files inside a target directory:
    $prog -R /path/to/folder

  Decrypt a single archive:
    $prog -D /path/to/folder.tar.gz.gpg

  Bulk decrypt all .gpg archives inside a directory:
    $prog -R -D /path/to/folder
EOF
}

cleanup() {
    local p
    for p in "${PARTIAL[@]}"; do
        [ -e "$p" ] && rm -f -- "$p"
    done
    PARTIAL=()
}

err() {
    printf '%s: %s\n' "$prog" "$*" >&2
}

ask_yes() {
    local choice
    printf '%s [y/N]: ' "$1"
    read -r choice || choice=""
    case "$choice" in
        [yY]|[yY][eE][sS]) return 0 ;;
    esac
    return 1
}

encrypt_folder() {
    local folder_path="$1"
    local parent_dir base_name gpg_file
    parent_dir="$(dirname -- "$folder_path")"
    base_name="$(basename -- "$folder_path")"
    gpg_file="$folder_path.tar.gz.gpg"

    if [ -e "$gpg_file" ]; then
        err "\"$gpg_file\" already exists, skipping \"$folder_path\""
        return 1
    fi

    printf 'Archiving and encrypting "%s"...\n' "$folder_path"
    PARTIAL=("$gpg_file")
    if ! tar -czf - -C "$parent_dir" -- "$base_name" \
        | gpg --symmetric --cipher-algo AES256 -o "$gpg_file"; then
        cleanup
        err "encryption failed for \"$folder_path\""
        return 1
    fi
    PARTIAL=()

    printf 'Encryption successful: %s\n' "$gpg_file"
    if ask_yes "Delete the original folder \"$folder_path\"?"; then
        rm -rf -- "$folder_path"
        printf 'Original folder deleted.\n'
    fi
}

decrypt_file() {
    local gpg_file="$1"
    local parent_dir tmp_tar name clash=""
    parent_dir="$(dirname -- "$gpg_file")"

    # Decrypt fully before extracting: gpg only reports a bad passphrase or a
    # tampered file at the very end, and a half-extracted tree is worse than none.
    # The temp file goes next to the archive rather than in $TMPDIR, since a
    # big folder may not fit in a RAM-backed /tmp.
    if ! tmp_tar="$(mktemp "$parent_dir/.folder_encrypt.XXXXXX")"; then
        err "cannot create a temporary file in \"$parent_dir\""
        return 1
    fi
    PARTIAL=("$tmp_tar")

    printf 'Decrypting "%s"...\n' "$gpg_file"
    if ! gpg --yes --decrypt -o "$tmp_tar" -- "$gpg_file"; then
        cleanup
        err "decryption failed for \"$gpg_file\""
        return 1
    fi

    # Refuse to extract on top of something that already exists
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ -e "$parent_dir/$name" ] || [ -L "$parent_dir/$name" ]; then
            clash="$name"
            break
        fi
    done < <(tar -tzf "$tmp_tar" | sed -e 's,^\./,,' -e 's,/.*,,' | sort -u)

    if [ -n "$clash" ]; then
        cleanup
        err "\"$parent_dir/$clash\" already exists, move it out of the way and run this again"
        return 1
    fi

    printf 'Extracting...\n'
    if ! tar -xzf "$tmp_tar" -C "$parent_dir"; then
        cleanup
        err "failed to extract \"$gpg_file\", anything partly extracted is still in $parent_dir"
        return 1
    fi
    cleanup

    printf 'Decryption and extraction successful for "%s".\n' "$gpg_file"
    if ask_yes "Delete the encrypted file \"$gpg_file\"?"; then
        rm -f -- "$gpg_file"
        printf 'Encrypted file deleted.\n'
    fi
}

# A free name inside dir for a loose file, never clobbering an existing one.
free_name() {
    local dir="$1" name="$2" i=1
    if [ ! -e "$dir/$name" ]; then
        printf '%s' "$dir/$name"
        return 0
    fi
    while [ -e "$dir/$name.$i" ]; do
        i=$((i + 1))
    done
    printf '%s' "$dir/$name.$i"
}

main() {
    local mode=encrypt bulk=0 target opt f rc=0
    local -a items=()

    local missing=() cmd
    for cmd in gpg tar gzip mktemp sed sort; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        err "missing required commands: ${missing[*]}"
        exit 1
    fi

    while getopts ':DRhH-:' opt; do
        case "$opt" in
            D) mode=decrypt ;;
            R) bulk=1 ;;
            h|H) show_help; exit 0 ;;
            -)
                case "$OPTARG" in
                    help) show_help; exit 0 ;;
                    decrypt) mode=decrypt ;;
                    bulk) bulk=1 ;;
                    *) err "unknown option --$OPTARG"; show_help >&2; exit 1 ;;
                esac
                ;;
            *) err "unknown option -$OPTARG"; show_help >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))

    if [ "$#" -ne 1 ]; then
        err "give exactly one target"
        show_help >&2
        exit 1
    fi
    target="${1%/}"
    [ -n "$target" ] || target="/"

    if [ ! -e "$target" ]; then
        err "target \"$target\" does not exist"
        exit 1
    fi
    # An absolute path makes "." and ".." work: the archive is named after the
    # folder and lands next to it, not inside it
    if [ -d "$target" ]; then
        target="$(cd -P -- "$target" && pwd -P)"
    else
        target="$(cd -P -- "$(dirname -- "$target")" && pwd -P)/${target##*/}"
    fi
    if [ "$target" = "/" ]; then
        err "refusing to work on /"
        exit 1
    fi

    # gpg's terminal passphrase prompt needs to know the tty, and stdin is a
    # pipe from tar by the time gpg runs
    if [ -t 0 ]; then
        GPG_TTY="$(tty)"
        export GPG_TTY
    fi

    trap cleanup EXIT
    trap 'exit 130' INT TERM HUP

    if [ "$mode" = encrypt ]; then
        if [ ! -d "$target" ]; then
            err "target must be a directory for encryption"
            exit 1
        fi

        if [ "$bulk" -eq 0 ]; then
            encrypt_folder "$target"
            exit
        fi

        # Loose files go into loose_files/ so they get encrypted too. Archives
        # from an earlier run are left where they are, or a second run would
        # sweep them up and encrypt them again.
        local loose_dir="$target/loose_files" moved=0
        while IFS= read -r -d '' f; do
            case "$f" in
                *.gpg) continue ;;
            esac
            mkdir -p -- "$loose_dir"
            mv -- "$f" "$(free_name "$loose_dir" "${f##*/}")"
            moved=1
        done < <(find "$target" -mindepth 1 -maxdepth 1 -type f -print0)
        if [ "$moved" -eq 1 ]; then
            printf 'Moved loose files into "%s".\n' "$loose_dir"
        fi

        # Collected up front: the prompts below read stdin, which must stay
        # the terminal and not the list of folders.
        while IFS= read -r -d '' f; do
            items+=("$f")
        done < <(find "$target" -mindepth 1 -maxdepth 1 -type d -print0)

        for f in "${items[@]}"; do
            encrypt_folder "$f" || rc=1
            printf -- '----------------------------------------\n'
        done
        exit "$rc"
    fi

    if [ "$bulk" -eq 1 ]; then
        if [ ! -d "$target" ]; then
            err "target must be a directory for bulk decryption"
            exit 1
        fi
        while IFS= read -r -d '' f; do
            items+=("$f")
        done < <(find "$target" -mindepth 1 -maxdepth 1 -type f -name '*.gpg' -print0)
        if [ "${#items[@]}" -eq 0 ]; then
            printf 'No .gpg files found in "%s".\n' "$target"
            exit 0
        fi
        for f in "${items[@]}"; do
            decrypt_file "$f" || rc=1
            printf -- '----------------------------------------\n'
        done
        exit "$rc"
    fi

    case "$target" in
        *.gpg) ;;
        *) err "target must be a .gpg file for single decryption"; exit 1 ;;
    esac
    decrypt_file "$target"
}

main "$@"
