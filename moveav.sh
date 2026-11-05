#!/usr/bin/env bash
#
# moveav - sort files in a directory into images/, videos/ and audio/
# subfolders by extension.
#
# Usage: moveav [-R] [target_dir]
#   -R   recurse: sort every subdirectory on its own as well
#
# A file never overwrites another one. If the destination already has a file
# with that name, the moved one gets a _1, _2, ... suffix.

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'moveav: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=moveav

usage() {
    printf 'Usage: %s [-R] [target_dir]\n' "$prog"
    printf '  -R   sort each subdirectory independently as well\n'
}

# Print the category for a file name, or nothing if it isn't media.
category_for() {
    local ext="${1##*.}"
    [ "$ext" != "$1" ] || return 0
    ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    case "$ext" in
        jpg|jpeg|png|gif|webp|bmp|tif|tiff|svg|heic|avif|jxl) printf 'images' ;;
        mp4|mkv|avi|mov|wmv|flv|webm|m4v|mpg|mpeg|ts|m2ts) printf 'videos' ;;
        mp3|wav|flac|m4a|ogg|oga|opus|aac|wma|aiff|aif|ape|wv) printf 'audio' ;;
    esac
}

# A path in dir that does not exist yet, based on name.
free_name() {
    local dir="$1" name="$2" stem ext i=1
    if [ ! -e "$dir/$name" ]; then
        printf '%s' "$dir/$name"
        return 0
    fi
    stem="${name%.*}"
    ext="${name##*.}"
    while [ -e "$dir/${stem}_$i.$ext" ]; do
        i=$((i + 1))
    done
    printf '%s' "$dir/${stem}_$i.$ext"
}

sort_dir() {
    local dir="$1" file name cat dest
    local -a files=()

    # Collect first, so the mkdir/mv below cannot change what find is walking.
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -print0)

    for file in "${files[@]}"; do
        name="${file##*/}"
        cat="$(category_for "$name")"
        [ -n "$cat" ] || continue
        mkdir -p -- "$dir/$cat"
        dest="$(free_name "$dir/$cat" "$name")"
        mv -- "$file" "$dest"
        printf 'Moved: %s\nFrom:  %s\nTo:    %s\n\n' "$name" "$file" "$dest"
    done
}

main() {
    local recursive=0 target_dir="." opt d
    local -a dirs=()

    while getopts ':Rrh' opt; do
        case "$opt" in
            R|r) recursive=1 ;;
            h) usage; exit 0 ;;
            *) printf '%s: invalid option -%s\n' "$prog" "$OPTARG" >&2; usage >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))

    if [ "$#" -gt 1 ]; then
        usage >&2
        exit 1
    fi
    if [ "$#" -eq 1 ]; then
        target_dir="$1"
    fi

    if [ ! -d "$target_dir" ]; then
        printf '%s: directory "%s" does not exist\n' "$prog" "$target_dir" >&2
        exit 1
    fi
    target_dir="$(cd -P -- "$target_dir" && pwd -P)"

    if [ "$recursive" -eq 1 ]; then
        # Skip the category folders themselves, or a second run would sort
        # images/ into images/images/. The target itself always gets sorted,
        # even if it happens to be called images/.
        dirs=("$target_dir")
        while IFS= read -r -d '' d; do
            dirs+=("$d")
        done < <(find "$target_dir" -mindepth 1 -type d \( -name images -o -name videos -o -name audio \) -prune -o -type d -print0)
        for d in "${dirs[@]}"; do
            sort_dir "$d"
        done
    else
        sort_dir "$target_dir"
    fi
}

main "$@"
