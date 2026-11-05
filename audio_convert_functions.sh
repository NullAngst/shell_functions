#!/usr/bin/env bash
#
# audio_convert_functions.sh - convert audio files to mp3, flac, or ogg
# using ffmpeg. Exposes three commands: 2mp3, 2flac, 2ogg. All three share
# the same conversion logic, which is why this stays as one file. The
# command is picked from the name the script was run as.
#
# COMMANDS: 2mp3 2flac 2ogg
#
# Usage:
#   2mp3  [-v] <file_or_dir>   Convert to MP3  (default: 320k CBR, -v: LAME V0 VBR)
#   2flac [-v] <file_or_dir>   Convert to FLAC (lossless; -v is ignored)
#   2ogg  [-v] <file_or_dir>   Convert to OGG  (default: 500k for stereo, 240k per channel otherwise; -v: highest Vorbis VBR)
#
# Given a single file, the output is written next to it. Given a directory,
# every recognized audio file directly inside it (not recursive) is
# converted into a "converted" subfolder, skipping files already in the
# target format so 2mp3 on a folder of mp3s doesn't re-encode them.
# Existing output files are never overwritten.

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'audio_convert_functions.sh: run this as 2mp3, 2flac or 2ogg, do not source it\n' >&2; return 1; }

set -euo pipefail

prog="${0##*/}"

# Vorbis bitrate for a file: 500k for stereo, 240k per channel otherwise.
vorbis_bitrate() {
    local ch=""
    if command -v ffprobe >/dev/null 2>&1; then
        ch="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 -i "$1" 2>/dev/null || true)"
    fi
    case "$ch" in
        2|"") printf '500k' ;;
        *[!0-9]*) printf '500k' ;;
        *) printf '%dk' "$(( ch * 240 ))" ;;
    esac
}

# Convert a single file. Args: format vbr file outdir
# outdir empty means "write next to the input file".
# Returns 0 = converted, 2 = skipped (output exists), 1 = error.
convert_file() {
    local format="$1" vbr="$2" file="$3" outdir="$4"
    local dir base_name base out
    local -a codec_args=()

    if [ -n "$outdir" ]; then
        dir="$outdir"
    else
        dir="$(dirname -- "$file")"
    fi
    base_name="${file##*/}"
    base="${base_name%.*}"
    out="$dir/$base.$format"

    if [ -e "$out" ]; then
        printf 'Skipping "%s": "%s" already exists.\n' "$file" "$out" >&2
        return 2
    fi

    case "$format" in
        mp3)
            if [ "$vbr" -eq 1 ]; then
                # -q:a 0 is LAME V0, the highest VBR quality
                codec_args=(-c:a libmp3lame -q:a 0)
            else
                codec_args=(-c:a libmp3lame -b:a 320k)
            fi
            ;;
        flac)
            # FLAC is lossless; -v is ignored. Level 8 is the highest compression.
            codec_args=(-c:a flac -compression_level 8)
            ;;
        ogg)
            if [ "$vbr" -eq 1 ]; then
                # -q:a 10 is the highest Vorbis VBR quality
                codec_args=(-c:a libvorbis -q:a 10)
            else
                # libvorbis refuses a target above roughly 250k per channel,
                # so a flat 500k only works for stereo. Scale it to the source.
                codec_args=(-c:a libvorbis -b:a "$(vorbis_bitrate "$file")")
            fi
            ;;
        *)
            printf '%s: unsupported format "%s"\n' "$prog" "$format" >&2
            return 1
            ;;
    esac

    # Embedded cover art shows up as a video stream. MP3 and FLAC can hold it,
    # so it's copied as-is instead of being re-encoded to PNG. Ogg Vorbis
    # can't, and ffmpeg would try to turn the picture into a Theora video
    # stream, so it's dropped there.
    # -nostdin keeps ffmpeg from eating the terminal input of a batch run.
    local -a extra=(-c:v copy)
    if [ "$format" = ogg ]; then
        extra=(-vn)
    fi
    if ! ffmpeg -nostdin -hide_banner -loglevel error -n -i "$file" "${extra[@]}" "${codec_args[@]}" "$out"; then
        printf '%s: ffmpeg failed converting "%s"\n' "$prog" "$file" >&2
        rm -f -- "$out"
        return 1
    fi

    printf 'Converted "%s" to "%s".\n' "$file" "$out"
    return 0
}

# Bulk-convert every recognized audio file directly inside a directory
# (not recursive) into a "converted" subfolder. Args: format vbr dir
convert_dir() {
    local format="$1" vbr="$2" dir="$3"
    local -a exts=(flac wav aiff aif ape wv m4a mp3 ogg oga opus aac wma)
    local outdir="${dir%/}/converted"

    # Build a find expression like: -iname "*.flac" -o -iname "*.wav" ...
    # leaving out the target format itself.
    local -a find_expr=()
    local ext
    for ext in "${exts[@]}"; do
        [ "$ext" != "$format" ] || continue
        if [ "${#find_expr[@]}" -gt 0 ]; then
            find_expr+=(-o)
        fi
        find_expr+=(-iname "*.$ext")
    done

    local -a files=()
    local f
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f \( "${find_expr[@]}" \) -print0)

    if [ "${#files[@]}" -eq 0 ]; then
        printf 'No convertible audio files found in "%s".\n' "$dir" >&2
        return 1
    fi

    if ! mkdir -p -- "$outdir"; then
        printf '%s: could not create output directory "%s"\n' "$prog" "$outdir" >&2
        return 1
    fi

    local converted=0 skipped=0 failed=0 rc
    for f in "${files[@]}"; do
        rc=0
        convert_file "$format" "$vbr" "$f" "$outdir" || rc=$?
        case "$rc" in
            0) converted=$((converted + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
            *) failed=$((failed + 1)) ;;
        esac
    done

    printf 'Done: %d converted, %d skipped, %d failed. Output in "%s".\n' "$converted" "$skipped" "$failed" "$outdir"
    [ "$failed" -eq 0 ]
}

convert() {
    local format="$1"
    shift
    local vbr=0 target=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -v) vbr=1 ;;
            -h|--help)
                printf 'Usage: %s [-v] <file_or_dir>\n' "$prog"
                return 0
                ;;
            --) shift; break ;;
            -*)
                printf '%s: unknown option "%s"\n' "$prog" "$1" >&2
                return 1
                ;;
            *)
                if [ -n "$target" ]; then
                    printf '%s: multiple targets given ("%s" and "%s")\n' "$prog" "$target" "$1" >&2
                    return 1
                fi
                target="$1"
                ;;
        esac
        shift
    done
    if [ "$#" -gt 0 ] && [ -z "$target" ]; then
        target="$1"
    fi

    if [ -z "$target" ]; then
        printf 'Usage: %s [-v] <file_or_dir>\n' "$prog" >&2
        return 1
    fi

    if [ -d "$target" ]; then
        convert_dir "$format" "$vbr" "$target"
        return
    fi

    if [ ! -f "$target" ]; then
        printf '%s: "%s" not found\n' "$prog" "$target" >&2
        return 1
    fi

    local rc=0
    convert_file "$format" "$vbr" "$target" "" || rc=$?
    # A single file that was skipped because the output exists is not a failure
    [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]
}

main() {
    local format
    case "$prog" in
        2mp3)  format=mp3 ;;
        2flac) format=flac ;;
        2ogg)  format=ogg ;;
        *)
            printf 'Run this as 2mp3, 2flac, or 2ogg (the symlinks the install step creates).\n' >&2
            exit 1
            ;;
    esac

    if ! command -v ffmpeg >/dev/null 2>&1; then
        printf '%s: missing required commands: ffmpeg\n' "$prog" >&2
        exit 1
    fi

    convert "$format" "$@"
}

main "$@"
