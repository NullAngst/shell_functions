#!/usr/bin/env bash

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] TARGET

Archive and encrypt/decrypt folders using GPG symmetric AES-256 encryption.

Options:
  -H, -h    Show this help message and exit
  -D        Decrypt the target
  -R        Bulk mode: operate on the contents of the target folder rather than the folder itself

Examples:
  Encrypt a single folder:
    $0 /path/to/folder

  Bulk encrypt folders and group loose files inside a target directory:
    $0 /path/to/folder -R

  Decrypt a single archive:
    $0 -D /path/to/folder.tar.gz.gpg

  Bulk decrypt all .gpg archives inside a directory:
    $0 /path/to/folder -R -D
EOF
}

MODE="encrypt"
BULK=0
TARGET=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h|-H)
            show_help
            exit 0
            ;;
        -D)
            MODE="decrypt"
            ;;
        -R)
            BULK=1
            ;;
        -*)
            echo "Invalid option: $1" >&2
            show_help
            exit 1
            ;;
        *)
            if [ -n "$TARGET" ]; then
                echo "Error: Multiple targets specified ($TARGET and $1)." >&2
                exit 1
            fi
            TARGET="$1"
            ;;
    esac
    shift
done

if [ -z "$TARGET" ]; then
    echo "Error: No target specified." >&2
    show_help
    exit 1
fi

if [ ! -e "$TARGET" ]; then
    echo "Error: Target '$TARGET' does not exist." >&2
    exit 1
fi

if ! command -v gpg >/dev/null 2>&1; then
    echo "Error: gpg is not installed or not in PATH." >&2
    exit 1
fi

# Strip trailing slash from TARGET if present
TARGET="${TARGET%/}"

encrypt_folder() {
    local folder_path="$1"
    local parent_dir="$(dirname "$folder_path")"
    local base_name="$(basename "$folder_path")"
    local tar_file="${folder_path}.tar.gz"
    local gpg_file="${tar_file}.gpg"

    echo "Archiving '$folder_path'..."
    if ! tar -czf "$tar_file" -C "$parent_dir" "$base_name"; then
        echo "Failed to archive '$folder_path'." >&2
        rm -f "$tar_file"
        return 1
    fi

    echo "Encrypting '$tar_file'..."
    if gpg --symmetric --cipher-algo AES256 -o "$gpg_file" "$tar_file"; then
        echo "Encryption successful: $gpg_file"
        rm -f "$tar_file"
        read -r -p "Delete the original folder '$folder_path'? [y/N]: " del_choice
        if [[ "$del_choice" =~ ^[Yy]$ ]]; then
            rm -rf "$folder_path"
            echo "Original folder deleted."
        fi
    else
        echo "Encryption failed for '$folder_path'." >&2
        rm -f "$tar_file"
        return 1
    fi
}

decrypt_file() {
    local gpg_file="$1"
    local tar_file="${gpg_file%.gpg}"
    local parent_dir="$(dirname "$gpg_file")"

    echo "Decrypting '$gpg_file'..."
    if gpg --decrypt -o "$tar_file" "$gpg_file"; then
        echo "Extracting '$tar_file'..."
        if tar -xzf "$tar_file" -C "$parent_dir"; then
            echo "Decryption and extraction successful for '$gpg_file'."
            rm -f "$tar_file"
            read -r -p "Delete the encrypted file '$gpg_file'? [y/N]: " del_choice
            if [[ "$del_choice" =~ ^[Yy]$ ]]; then
                rm -f "$gpg_file"
                echo "Encrypted file deleted."
            fi
        else
            echo "Failed to extract '$tar_file'." >&2
            rm -f "$tar_file"
            return 1
        fi
    else
        echo "Decryption failed for '$gpg_file'." >&2
        rm -f "$tar_file"
        return 1
    fi
}

if [ "$MODE" = "encrypt" ]; then
    if [ ! -d "$TARGET" ]; then
        echo "Error: Target must be a directory for encryption." >&2
        exit 1
    fi

    if [ "$BULK" -eq 1 ]; then
        loose_dir="$TARGET/loose_files"
        moved_loose=0

        mkdir -p "$loose_dir"

        while IFS= read -r -d '' file; do
            base="$(basename "$file")"
            dest="$loose_dir/$base"
            if [ -e "$dest" ]; then
                dest="$loose_dir/${base}.$(date +%s%N)"
            fi
            mv "$file" "$dest"
            moved_loose=1
        done < <(find "$TARGET" -maxdepth 1 -mindepth 1 -type f -print0)

        if [ "$moved_loose" -eq 0 ]; then
            rmdir "$loose_dir" 2>/dev/null
        else
            echo "Moved loose files into '$loose_dir'."
        fi

        while IFS= read -r -d '' dir; do
            encrypt_folder "$dir"
            echo "----------------------------------------"
        done < <(find "$TARGET" -maxdepth 1 -mindepth 1 -type d -print0)

    else
        encrypt_folder "$TARGET"
    fi

elif [ "$MODE" = "decrypt" ]; then
    if [ "$BULK" -eq 1 ]; then
        if [ ! -d "$TARGET" ]; then
            echo "Error: Target must be a directory for bulk decryption." >&2
            exit 1
        fi

        while IFS= read -r -d '' file; do
            decrypt_file "$file"
            echo "----------------------------------------"
        done < <(find "$TARGET" -maxdepth 1 -mindepth 1 -type f -name "*.gpg" -print0)
    else
        if [[ "$TARGET" != *.gpg ]]; then
            echo "Error: Target must be a .gpg file for single decryption." >&2
            exit 1
        fi
        decrypt_file "$TARGET"
    fi
fi
