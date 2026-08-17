#!/usr/bin/env bash
#
# unpack - recursively extract archives (tar.gz/tgz, tar.bz2/tbz2, tar.xz, tar,
# zip, rar, 7z), including multi-volume/split archives, then remove the
# source file(s) on a successful extraction.
#
# Setup:
# create file at /usr/local/bin/unpack.sh
# sudo chmod +x /usr/local/bin/unpack.sh
#
# Add:
# source /usr/local/bin/unpack.sh
# to bashrc or zshrc
#
# Usage: unpack <archive_file_or_directory> [additional_files...]

unpack() {
    if [ "$#" -eq 0 ]; then
        echo "Usage: unpack <archive_file_or_directory> [additional_files...]"
        return 1
    fi

    for target in "$@"; do
        if [ -d "$target" ]; then
            find "$target" -maxdepth 1 -type f -print0 | while IFS= read -r -d '' file; do
                local lower_file
                lower_file=$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')
                case "$lower_file" in
                    *.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.tar|*.zip|*.rar|*.7z|*.001)
                        unpack "$file"
                        ;;
                esac
            done
            continue
        fi

        if [ ! -f "$target" ]; then
            echo "Error: '$target' is not a valid file or directory."
            continue
        fi

        local file="$target"
        local dir
        dir=$(dirname "$file")
        local base
        base=$(basename "$file")

        local folder_name
        folder_name=$(printf '%s' "$base" | sed -E 's/\.(tar\.gz|tar\.bz2|tar\.xz|tgz|tbz2|zip\.001|zip|rar|7z\.001|7z|tar|part[0-9]+\.rar|[0-9]{3})$//I')
        local folder="$dir/$folder_name"
        local lower_base
        lower_base=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')

        if [[ "$lower_base" =~ \.(r[0-9]{2,}|z[0-9]{2,}|[0-9]{3})$ && ! "$lower_base" =~ \.(001)$ ]]; then
             continue
        fi
        if [[ "$lower_base" =~ \.part[0-9]+\.rar$ && ! "$lower_base" =~ \.part0*1\.rar$ ]]; then
             continue
        fi

        case "$lower_base" in
            *.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.tar|*.rar|*.zip|*.zip.001|*.7z|*.7z.001) ;;
            *)
                echo "Error: Unsupported archive format for '$file'."
                continue
                ;;
        esac

        mkdir -p "$folder"
        local extracted=0

        case "$lower_base" in
            *.tar.bz2|*.tbz2) tar -xvjf "$file" -C "$folder" && extracted=1 ;;
            *.tar.gz|*.tgz)   tar -xvzf "$file" -C "$folder" && extracted=1 ;;
            *.tar.xz)         tar -xvJf "$file" -C "$folder" && extracted=1 ;;
            *.tar)            tar -xvf "$file" -C "$folder" && extracted=1 ;;
            *.rar) unrar x "$file" "$folder/" && extracted=1 ;;
            *.zip|*.zip.001|*.7z|*.7z.001) 7z x "$file" -o"$folder" -y && extracted=1 ;;
        esac

        if [ "$extracted" -eq 1 ]; then
            echo "Successfully unpacked into '$folder/'."

            local clean_base
            if [[ "$lower_base" =~ \.part[0-9]+\.rar$ ]]; then
                clean_base=$(printf '%s' "$base" | sed -E 's/\.part[0-9]+\.rar$//I')
                find "$dir" -maxdepth 1 -type f -iname "${clean_base}.part*.rar" -delete
            elif [[ "$lower_base" =~ \.rar$ ]]; then
                clean_base=$(printf '%s' "$base" | sed -E 's/\.rar$//I')
                rm -f "$file"
                find "$dir" -maxdepth 1 -type f \( -iname "${clean_base}.r[0-9][0-9]" -o -iname "${clean_base}.s[0-9][0-9]" \) -delete
            elif [[ "$lower_base" =~ \.zip$ || "$lower_base" =~ \.zip\.001$ ]]; then
                clean_base=$(printf '%s' "$base" | sed -E 's/\.zip(\.001)?$//I')
                find "$dir" -maxdepth 1 -type f \( -iname "${clean_base}.zip" -o -iname "${clean_base}.z[0-9][0-9]" -o -iname "${clean_base}.zip.[0-9][0-9][0-9]" \) -delete
            elif [[ "$lower_base" =~ \.7z\.001$ ]]; then
                clean_base=$(printf '%s' "$base" | sed -E 's/\.001$//I')
                find "$dir" -maxdepth 1 -type f -iname "${clean_base}.[0-9][0-9][0-9]" -delete
            else
                rm -f "$file"
            fi
            unpack "$folder"
        else
            echo "Extraction failed for '$file'. Original files were not deleted."
            rmdir "$folder" 2>/dev/null
        fi
    done
}
_unpack_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT} in
        *:file) _unpack_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _unpack_sourced=1
    fi
fi

if [ "$_unpack_sourced" -eq 0 ]; then
    unpack "$@"
fi
unset _unpack_sourced
