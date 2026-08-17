_convert_audio() {
    local format="$1"
    shift
    local vbr=0
    local file=""

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
                if [[ -n "$file" ]]; then
                    echo "Error: multiple filenames given ('$file' and '$1')" >&2
                    return 1
                fi
                file="$1"
                ;;
        esac
        shift
    done

    if [[ -z "$file" ]]; then
        echo "Error: no input file specified." >&2
        return 1
    fi

    if [[ ! -f "$file" ]]; then
        echo "Error: File '$file' not found." >&2
        return 1
    fi

    # Split into directory and basename before stripping the extension,
    # so a dot in a parent directory name can't get mistaken for
    # the file's extension.
    local dir base_name base out
    dir="$(dirname -- "$file")"
    base_name="$(basename -- "$file")"
    base="${base_name%.*}"
    out="${dir}/${base}.${format}"

    if [[ -e "$out" ]]; then
        echo "Error: output file '$out' already exists." >&2
        return 1
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
        return "$status"
    fi

    echo "Converted '$file' to '$out'."
}

2mp3() { _convert_audio mp3 "$@"; }
2flac() { _convert_audio flac "$@"; }
2ogg() { _convert_audio ogg "$@"; }
