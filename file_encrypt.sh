#!/usr/bin/env bash
#
# file_encrypt - encrypt or decrypt a file with GPG symmetric AES-256.
#
# Usage:
#   file_encrypt FILE          encrypt to FILE.gpg
#   file_encrypt -D FILE.gpg   decrypt to FILE (or FILE.gpg.decrypted)
#
# Never writes over an existing file. Asks before deleting the source.

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'file_encrypt: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=file_encrypt
OUT_FILE=""
OUT_DONE=0

show_help() {
    cat <<EOF
Usage: $prog [OPTIONS] FILE

Encrypt or decrypt a file using GPG symmetric AES-256 encryption.

Options:
  -h, -H    Show this help message and exit
  -D        Decrypt the specified file

Examples:
  Encrypt a file:
    $prog /path/to/file.txt

  Decrypt a file:
    $prog -D /path/to/file.txt.gpg
EOF
}

# A failed or interrupted run removes only the output it created itself.
cleanup() {
    if [ "$OUT_DONE" -eq 0 ] && [ -n "$OUT_FILE" ] && [ -e "$OUT_FILE" ]; then
        rm -f -- "$OUT_FILE"
    fi
}

ask_delete() {
    local what="$1" path="$2" choice
    printf 'Delete the %s "%s"? [y/N]: ' "$what" "$path"
    read -r choice || choice=""
    case "$choice" in
        [yY]|[yY][eE][sS])
            rm -f -- "$path"
            printf 'Deleted %s.\n' "$path"
            ;;
    esac
}

main() {
    local mode=encrypt file="" opt

    if ! command -v gpg >/dev/null 2>&1; then
        printf '%s: missing required commands: gpg\n' "$prog" >&2
        exit 1
    fi

    while getopts ':DhH' opt; do
        case "$opt" in
            D) mode=decrypt ;;
            h|H) show_help; exit 0 ;;
            *) printf '%s: invalid option -%s\n' "$prog" "$OPTARG" >&2; show_help >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))

    if [ "$#" -ne 1 ]; then
        if [ "$#" -gt 1 ]; then
            printf '%s: give exactly one file\n' "$prog" >&2
        else
            printf '%s: no file specified\n' "$prog" >&2
        fi
        show_help >&2
        exit 1
    fi
    file="$1"

    if [ ! -f "$file" ]; then
        printf '%s: file "%s" does not exist\n' "$prog" "$file" >&2
        exit 1
    fi

    trap cleanup EXIT
    trap 'exit 130' INT TERM

    if [ "$mode" = encrypt ]; then
        OUT_FILE="$file.gpg"
        if [ -e "$OUT_FILE" ]; then
            printf '%s: "%s" already exists, move it out of the way first\n' "$prog" "$OUT_FILE" >&2
            OUT_FILE=""
            exit 1
        fi
        printf 'Encrypting %s using AES-256...\n' "$file"
        if ! gpg --symmetric --cipher-algo AES256 -o "$OUT_FILE" -- "$file"; then
            printf '%s: encryption failed\n' "$prog" >&2
            exit 1
        fi
        OUT_DONE=1
        printf 'Encryption successful: %s\n' "$OUT_FILE"
        ask_delete "original file" "$file"
    else
        case "$file" in
            *.gpg) OUT_FILE="${file%.gpg}" ;;
            *) OUT_FILE="$file.decrypted" ;;
        esac
        if [ -e "$OUT_FILE" ]; then
            printf '%s: "%s" already exists, move it out of the way first\n' "$prog" "$OUT_FILE" >&2
            OUT_FILE=""
            exit 1
        fi
        printf 'Decrypting %s...\n' "$file"
        if ! gpg --decrypt -o "$OUT_FILE" -- "$file"; then
            printf '%s: decryption failed\n' "$prog" >&2
            exit 1
        fi
        OUT_DONE=1
        printf 'Decryption successful: %s\n' "$OUT_FILE"
        ask_delete "encrypted file" "$file"
    fi
}

main "$@"
