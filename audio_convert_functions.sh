#!/usr/bin/env bash
#
# audio_convert_functions.sh - convert audio files to mp3, flac, or ogg
# using ffmpeg. Exposes three commands: 2mp3, 2flac, 2ogg. All three share
# the same underlying conversion logic, which is why this stays as one file
# instead of being split like the other functions in this set.
#
# Usage:
#   2mp3  [-v] <file_or_dir>   Convert to MP3  (default: 320k CBR, -v: LAME V0 VBR)
#   2flac [-v] <file_or_dir>   Convert to FLAC (lossless; -v is ignored)
#   2ogg  [-v] <file_or_dir>   Convert to OGG  (default: ~500kbps CBR, -v: highest Vorbis VBR)
#
# Given a single file, the output is written next to it. Given a directory,
# every recognized audio file directly inside it (not recursive) is
# converted into a "converted" subfolder, skipping files already in the
# target format so e.g. 2mp3 on a folder of mp3s doesn't re-encode them.
# Existing output files are never overwritten.

# Convert a single file. Args: format vbr file outdir
# outdir empty means "write next to the input file".
# Returns 0 = converted, 2 = skipped (output exists), 1 = error.
_convert_audio_file() {
    local format="$1" vbr="$2" file="$3" outdir="$4"
    local dir base_name base out

    if [[ -n "$outdir" ]]; then
        dir="$outdir"
    else
        dir="$(dirname -- "$file")"
    fi
    base_name="$(basename -- "$file")"
    base="${base_name%.*}"
    out="${dir}/${base}.${format}"

    if [[ -e "$out" ]]; then
        echo "Skipping '$file': '$out' already exists." >&2
        return 2
    fi

    case "$format" in
        mp3)
            if [[ "$vbr" -eq 1 ]]; then
                # -q:a 0 is LAME V0 (highest VBR quality)
                ffmpeg -hide_banner -loglevel error -n -i "$file" -c:a libmp3lame -q:a 0 "$out"
            else
                ffmpeg -hide_banner -loglevel error -n -i "$file" -c:a libmp3lame -b:a 320k "$out"
            fi
            ;;
        flac)
            # FLAC is lossless; -v is ignored. Level 8 is the highest compression.
            ffmpeg -hide_banner -loglevel error -n -i "$file" -c:a flac -compression_level 8 "$out"
            ;;
        ogg)
            if [[ "$vbr" -eq 1 ]]; then
                # -q:a 10 is the highest Vorbis VBR quality (~500kbps)
                ffmpeg -hide_banner -loglevel error -n -i "$file" -c:a libvorbis -q:a 10 "$out"
            else
                ffmpeg -hide_banner -loglevel error -n -i "$file" -c:a libvorbis -b:a 500k "$out"
            fi
            ;;
        *)
            echo "Error: unsupported format '$format'." >&2
            return 1
            ;;
    esac

    local status=$?
    if [[ "$status" -ne 0 ]]; then
        echo "Error: ffmpeg failed converting '$file' (exit $status)." >&2
        return 1
    fi

    echo "Converted '$file' to '$out'."
    return 0
}

# Bulk-convert every recognized audio file directly inside a directory
# (not recursive) into a "converted" subfolder. Args: format vbr dir
_convert_audio_dir() {
    local format="$1" vbr="$2" dir="$3"
    local -a exts=(flac wav aiff aif ape wv m4a mp3 ogg oga opus aac wma)
    local outdir="${dir%/}/converted"

    # Build a find expression like: -iname "*.flac" -o -iname "*.wav" ...
    # skipping the target format itself, so 2mp3 on a folder of mp3s
    # doesn't try to re-encode mp3 to mp3.
    local -a find_expr=()
    local ext
    for ext in "${exts[@]}"; do
        [[ "$ext" == "$format" ]] && continue
        [[ "${#find_expr[@]}" -gt 0 ]] && find_expr+=(-o)
        find_expr+=(-iname "*.${ext}")
    done

    local -a files=()
    local f
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f \( "${find_expr[@]}" \) -print0)

    if [[ "${#files[@]}" -eq 0 ]]; then
        echo "No convertible audio files found in '$dir'." >&2
        return 1
    fi

    mkdir -p -- "$outdir" || {
        echo "Error: could not create output directory '$outdir'." >&2
        return 1
    }

    local converted=0 skipped=0 failed=0
    for f in "${files[@]}"; do
        _convert_audio_file "$format" "$vbr" "$f" "$outdir"
        case $? in
            0) converted=$((converted + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done

    echo "Done: $converted converted, $skipped skipped, $failed failed. Output in '$outdir'."
    [[ "$failed" -eq 0 ]]
}

_convert_audio() {
    local format="$1"
    shift
    local vbr=0
    local target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v)
                vbr=1
                ;;
            -*)
                echo "Error: unknown option '$1'" >&2
                return 1
                ;;
            *)
                if [[ -n "$target" ]]; then
                    echo "Error: multiple targets given ('$target' and '$1')" >&2
                    return 1
                fi
                target="$1"
                ;;
        esac
        shift
    done

    if [[ -z "$target" ]]; then
        echo "Error: no input file or directory specified." >&2
        return 1
    fi

    if [[ -d "$target" ]]; then
        _convert_audio_dir "$format" "$vbr" "$target"
        return $?
    fi

    if [[ ! -f "$target" ]]; then
        echo "Error: '$target' not found." >&2
        return 1
    fi

    _convert_audio_file "$format" "$vbr" "$target" ""
}

2mp3() { _convert_audio mp3 "$@"; }
2flac() { _convert_audio flac "$@"; }
2ogg() { _convert_audio ogg "$@"; }
