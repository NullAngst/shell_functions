#!/usr/bin/env bash

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] FILE

Encrypt or decrypt a file using GPG symmetric AES-256 encryption.

Options:
  -H, -h    Show this help message and exit
  -D        Decrypt the specified file

Examples:
  Encrypt a file:
    $0 /path/to/file.txt

  Decrypt a file:
    $0 -D /path/to/file.txt.gpg
EOF
}

MODE="encrypt"
FILE=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h|-H)
            show_help
            exit 0
            ;;
        -D)
            MODE="decrypt"
            ;;
        -*)
            echo "Invalid option: $1" >&2
            show_help
            exit 1
            ;;
        *)
            if [ -n "$FILE" ]; then
                echo "Error: Multiple files specified ($FILE and $1)." >&2
                exit 1
            fi
            FILE="$1"
            ;;
    esac
    shift
done

if [ -z "$FILE" ]; then
    echo "Error: No file specified." >&2
    show_help
    exit 1
fi

if [ ! -f "$FILE" ]; then
    echo "Error: File '$FILE' does not exist." >&2
    exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
    echo "Error: gpg is not installed or not in PATH." >&2
    exit 1
fi

if [ "$MODE" = "encrypt" ]; then
    OUT_FILE="${FILE}.gpg"
    echo "Encrypting $FILE using AES-256..."

    if gpg --symmetric --cipher-algo AES256 -o "$OUT_FILE" "$FILE"; then
        echo "Encryption successful: $OUT_FILE"
        read -r -p "Delete the original file '$FILE'? [y/N]: " del_choice
        if [[ "$del_choice" =~ ^[Yy]$ ]]; then
            rm "$FILE"
            echo "Original file deleted."
        fi
    else
        echo "Encryption failed." >&2
        rm -f "$OUT_FILE"
        exit 1
    fi

elif [ "$MODE" = "decrypt" ]; then
    if [[ "$FILE" == *.gpg ]]; then
        OUT_FILE="${FILE%.gpg}"
    else
        OUT_FILE="${FILE}.decrypted"
    fi

    echo "Decrypting $FILE..."

    if gpg --decrypt -o "$OUT_FILE" "$FILE"; then
        echo "Decryption successful: $OUT_FILE"
        read -r -p "Delete the encrypted file '$FILE'? [y/N]: " del_choice
        if [[ "$del_choice" =~ ^[Yy]$ ]]; then
            rm "$FILE"
            echo "Encrypted file deleted."
        fi
    else
        echo "Decryption failed." >&2
        rm -f "$OUT_FILE"
        exit 1
    fi
fi
