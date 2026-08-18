#!/usr/bin/env bash
#
# moveav - moves and sorts files in a directory into images/, videos/, and
# audio/ subfolders based on extension.
#
#
# Usage: moveav [-R] [target_dir]
#   -R : recurse into subdirectories, sorting each one independently

moveav() {
    local recursive=0
    local target_dir="."

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -R) recursive=1 ;;
            -*) echo "Error: Invalid option '$1'" >&2; return 1 ;;
            *) target_dir="$1" ;;
        esac
        shift
    done

    if [[ ! -d "$target_dir" ]]; then
        echo "Error: Directory '$target_dir' does not exist." >&2
        return 1
    fi

    target_dir=$(cd "$target_dir" && pwd)

    _process_category() {
        local dir="$1"
        local category="$2"
        shift 2

        # $@ passes the remaining arguments (the -iname flags) to the find command
        find "$dir" -maxdepth 1 -type f \( "$@" \) -print0 | while IFS= read -r -d $'\0' file; do
            local dest_dir="$dir/$category"
            local filename=$(basename "$file")

            if [[ ! -d "$dest_dir" ]]; then
                mkdir -p "$dest_dir"
            fi

            mv "$file" "$dest_dir/"

            # Verbose output
            echo "Moved: $filename"
            echo "From:  $file"
            echo "To:    $dest_dir/$filename"
            echo ""
        done
    }

    _sort_media() {
        local dir="$1"

        _process_category "$dir" "images" -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.webp" -o -iname "*.bmp" -o -iname "*.tiff" -o -iname "*.svg"

        _process_category "$dir" "videos" -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.m4v"

        _process_category "$dir" "audio" -iname "*.mp3" -o -iname "*.wav" -o -iname "*.flac" -o -iname "*.m4a" -o -iname "*.ogg" -o -iname "*.aac" -o -iname "*.wma"
    }

    if (( recursive )); then
        find "$target_dir" -type d \( -name "images" -o -name "videos" -o -name "audio" \) -prune -o -type d -print0 | while IFS= read -r -d $'\0' d; do
            _sort_media "$d"
        done
    else
        _sort_media "$target_dir"
    fi

    unset -f _process_category
    unset -f _sort_media
}

_moveav_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT} in
        *:file) _moveav_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _moveav_sourced=1
    fi
fi

if [ "$_moveav_sourced" -eq 0 ]; then
    moveav "$@"
fi
unset _moveav_sourced
