#!/usr/bin/env bash
#
# ripcd - interactive audio CD ripper. Pulls metadata and cover art from
# MusicBrainz, handles multi-disc releases, retries bad reads, resumes an
# interrupted rip, writes ReplayGain tags on FLAC, and leaves a log, a CUE
# sheet and a stats file next to the tracks.
#
# Usage: ripcd [-v]
#   -v   verbose: print debug output

# The jq filters in single quotes use jq's own $variables, not the shell's
# shellcheck disable=SC2016

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'ripcd: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail
shopt -s nullglob

# --- Configuration ---
VERBOSE=0
SCRIPT_REVISION="6.1"
USER_AGENT="shell_functions-ripcd/$SCRIPT_REVISION (https://github.com/NullAngst/shell_functions)"
MAX_RETRIES=3
RETRY_DELAY=5
CHECKPOINT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ripcd"
# Checkpoints from before the rename are moved over on first run
OLD_CHECKPOINT_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/simplecd-ripper"
TEMP_DIR=""

# --- Output helpers ---
verbose_echo() {
    if [ "$VERBOSE" -eq 1 ]; then
        printf '[DEBUG] %s\n' "$1" >&2
    fi
}

cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

error_exit() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

warn() { printf 'Warning: %s\n' "$1" >&2; }
success() { printf 'Success: %s\n' "$1"; }
info() { printf 'Info: %s\n' "$1"; }

log_entry() {
    local level="$1"
    shift
    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

need() {
    command_exists "$1" || error_exit "'$1' is not installed. Please install it for $2."
}

# Size in bytes. GNU wc answers -c on a regular file from its metadata
# instead of reading it.
file_size() {
    local s
    s="$(wc -c < "$1" 2>/dev/null)" || s=0
    printf '%s' "${s//[[:space:]]/}"
}

human_size() {
    local bytes="${1:-0}"
    if [ "$bytes" -lt 1024 ]; then
        printf '%sB' "$bytes"
    elif [ "$bytes" -lt 1048576 ]; then
        printf '%sKB' "$((bytes / 1024))"
    elif [ "$bytes" -lt 1073741824 ]; then
        printf '%sMB' "$((bytes / 1048576))"
    else
        printf '%sGB' "$((bytes / 1073741824))"
    fi
}

# Safe for a file name: no path separators or characters other systems reject
safe_filename() {
    printf '%s' "$1" | sed 's/[\/:]/_/g; s/[*?"<>|]//g; s/^[[:space:]]*//; s/[[:space:]]*$//'
}

# CUE sheets quote fields with ", so a " inside a title would end the field early
cue_text() {
    printf '%s' "${1//\"/\'}"
}

# Pull rip metrics out of cdparanoia's verbose output: pre-gap|peak|status
parse_rip_quality() {
    local rip_log="$1" pregap peak quality
    pregap="$(printf '%s\n' "$rip_log" | sed -n 's/.*pre-gap \([0-9.][0-9.]*\).*/\1/p' | sed -n '1p')"
    peak="$(printf '%s\n' "$rip_log" | sed -n 's/.*peak \([0-9.][0-9.]*\).*/\1/p' | sed -n '1p')"
    # The last verdict wins. Two plain patterns, since \| in sed is GNU-only.
    quality="$(printf '%s\n' "$rip_log" | sed -n -e 's/.*\(Done\).*/\1/p' -e 's/.*\(FAILED\).*/\1/p' | sed -n '$p')"
    printf '%s|%s|%s' "$pregap" "$peak" "${quality:-UNKNOWN}"
}

check_file_integrity() {
    local file="$1" enc="$2" size head4
    [ -f "$file" ] || return 1

    case "$enc" in
        flac)
            flac -s -t "$file" >/dev/null 2>&1
            ;;
        mp3|ogg)
            # A size heuristic, not a decode check: it only catches empty or
            # truncated output. Kept low so short interludes and hidden bonus
            # tracks don't get flagged and deleted.
            size="$(file_size "$file")"
            [ "${size:-0}" -gt 51200 ]
            ;;
        wav)
            head4="$(dd if="$file" bs=4 count=1 2>/dev/null || true)"
            [ "$head4" = "RIFF" ]
            ;;
        *)
            return 1
            ;;
    esac
}

checkpoint_file() {
    local enc_key disc_key=""
    enc_key="$(IFS=_; printf '%s' "${ENCODERS[*]}")"
    if [ "$TOTAL_DISCS" -gt 1 ]; then
        disc_key="-disc$DISC_NUMBER"
    fi
    printf '%s/checkpoint-%s-%s%s-%s.json' "$CHECKPOINT_DIR" "$SAFE_ALBUM_ARTIST" "$SAFE_ALBUM_TITLE" "$disc_key" "$enc_key"
}

create_checkpoint() {
    local track_num="$1" status="$2" cp_file
    cp_file="$(checkpoint_file)"
    # jq builds the JSON so a quote in an album title can't break the file
    jq -n \
        --arg album_artist "$ALBUM_ARTIST" \
        --arg album_title "$ALBUM_TITLE" \
        --arg mbid "$MBID" \
        --arg encoders "${ENCODERS[*]}" \
        --argjson last "$track_num" \
        --arg status "$status" \
        --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
        '{album_artist: $album_artist, album_title: $album_title, mbid: $mbid,
          encoders: $encoders, last_completed_track: $last, status: $status,
          timestamp: $ts}' > "$cp_file"
    chmod 600 -- "$cp_file"
}

load_checkpoint() {
    local cp_file last
    cp_file="$(checkpoint_file)"
    if [ -f "$cp_file" ]; then
        last="$(jq -r '.last_completed_track // 0' "$cp_file" 2>/dev/null || printf '0')"
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        printf '%s' "$last"
    else
        printf '0'
    fi
}

clear_checkpoint() {
    local cp_file
    cp_file="$(checkpoint_file)"
    rm -f -- "$cp_file"
}

# A numbered choice between lo and hi, or the default when input is bad
read_number() {
    local prompt="$1" lo="$2" hi="$3" default="$4" reply
    read -r -p "$prompt" reply || reply=""
    if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge "$lo" ] && [ "$reply" -le "$hi" ]; then
        printf '%s' "$reply"
    else
        printf '%s' "$default"
    fi
}

# jq against the selected release; extra args go to jq first
mbq() {
    jq -r --argjson idx "$SELECTED_INDEX" --argjson midx "${MEDIA_INDEX:-0}" "$@" "$MUSICBRAINZ_JSON"
}

encode_track() {
    # Encodes TEMP_WAV_FILE to one format. Args: encoder extension track_index
    local enc="$1" ext="$2" i="$3"
    local out="$OUTPUT_DIR/$TRACK_NUM. $SAFE_TRACK_TITLE.$ext"
    local start end size
    local -a args=()

    printf '  Encoding to %s...\n' "${enc^^}"
    start="$(date +%s)"

    case "$enc" in
        flac)
            args=(-f -s --best --verify)
            if [ -n "$COVER_ART_FILE" ]; then
                args+=("--picture=$COVER_ART_FILE")
            fi
            args+=(-T "ARTIST=${TRACK_ARTIST:-$ALBUM_ARTIST}" -T "TITLE=$TRACK_TITLE"
                   -T "ALBUM=$ALBUM_TITLE" -T "TRACKNUMBER=$i"
                   -T "PERFORMER=$ALBUM_ARTIST" -T "ALBUMARTIST=$ALBUM_ARTIST"
                   -T "DISCNUMBER=$DISC_NUMBER" -T "TOTALDISCS=$TOTAL_DISCS"
                   -T "TOTALTRACKS=$TRACK_COUNT")
            [ -z "$YEAR" ] || args+=(-T "DATE=$YEAR")
            [ -z "$GENRE" ] || args+=(-T "GENRE=$GENRE")
            [ -z "$COMPOSER" ] || args+=(-T "COMPOSER=$COMPOSER")
            [ -z "$COMMENT" ] || args+=(-T "COMMENT=$COMMENT")
            if [ -n "$ORIGINAL_DATE" ] && [ "$ORIGINAL_DATE" != "$YEAR" ]; then
                args+=(-T "ORIGINALDATE=$ORIGINAL_DATE")
            fi
            [ -z "$MBID" ] || args+=(-T "MUSICBRAINZ_ALBUMID=$MBID")
            flac "${args[@]}" "$TEMP_WAV_FILE" -o "$out" 2>/dev/null || { rm -f -- "$out"; false; }
            ;;
        wav)
            cp -- "$TEMP_WAV_FILE" "$out" || { rm -f -- "$out"; false; }
            ;;
        mp3)
            args=(-S -b 320 --add-id3v2
                  --tt "$TRACK_TITLE" --ta "${TRACK_ARTIST:-$ALBUM_ARTIST}"
                  --tl "$ALBUM_TITLE" --tn "$i/$TRACK_COUNT"
                  --tv "TPE2=$ALBUM_ARTIST" --tv "TPOS=$DISC_NUMBER/$TOTAL_DISCS")
            [ -z "$YEAR" ] || args+=(--ty "$YEAR")
            [ -z "$GENRE" ] || args+=(--tg "$GENRE")
            [ -z "$COMPOSER" ] || args+=(--tv "TCOM=$COMPOSER")
            [ -z "$COMMENT" ] || args+=(--tc "$COMMENT")
            lame "${args[@]}" "$TEMP_WAV_FILE" "$out" 2>/dev/null || { rm -f -- "$out"; false; }
            ;;
        ogg)
            args=(-Q -q 10 -a "${TRACK_ARTIST:-$ALBUM_ARTIST}" -l "$ALBUM_TITLE"
                  -t "$TRACK_TITLE" -N "$i"
                  -c "PERFORMER=$ALBUM_ARTIST" -c "ALBUMARTIST=$ALBUM_ARTIST"
                  -c "DISCNUMBER=$DISC_NUMBER" -c "TOTALDISCS=$TOTAL_DISCS"
                  -c "TOTALTRACKS=$TRACK_COUNT")
            [ -z "$YEAR" ] || args+=(-d "$YEAR")
            [ -z "$GENRE" ] || args+=(-G "$GENRE")
            [ -z "$COMPOSER" ] || args+=(-c "COMPOSER=$COMPOSER")
            [ -z "$COMMENT" ] || args+=(-c "COMMENT=$COMMENT")
            oggenc "${args[@]}" "$TEMP_WAV_FILE" -o "$out" 2>/dev/null || { rm -f -- "$out"; false; }
            ;;
    esac || {
        printf '    Encode FAILED\n'
        log_entry "ERROR" "Track $i ($enc): Encoding failed"
        return 1
    }

    if ! check_file_integrity "$out" "$enc"; then
        printf '    Encode FAILED (integrity check)\n'
        log_entry "ERROR" "Track $i ($enc): Integrity check failed"
        rm -f -- "$out"
        return 1
    fi

    end="$(date +%s)"
    size="$(file_size "$out")"
    printf '    Encode OK [%s] in %ss\n' "$(human_size "$size")" "$((end - start))"
    log_entry "INFO" "Track $i ($enc): OK ($(human_size "$size"))"
    return 0
}

write_cue() {
    local i num title artist composer
    {
        printf 'PERFORMER "%s"\n' "$(cue_text "$ALBUM_ARTIST")"
        printf 'TITLE "%s"\n' "$(cue_text "$ALBUM_TITLE")"
        [ -z "$GENRE" ] || printf 'REM GENRE "%s"\n' "$(cue_text "$GENRE")"
        [ -z "$YEAR" ] || printf 'REM DATE %s\n' "$YEAR"
        printf '\n'
        for (( i = 1; i <= TRACK_COUNT; i++ )); do
            if [ "$TOTAL_DISCS" -gt 1 ]; then
                num="$DISC_NUMBER-$(printf '%02d' "$i")"
            else
                num="$(printf '%02d' "$i")"
            fi
            title="${TRACK_TITLES[$((i - 1))]}"
            artist="${TRACK_ARTISTS[$((i - 1))]:-$ALBUM_ARTIST}"
            composer="${COMPOSERS[$((i - 1))]}"
            printf '  FILE "%s" WAVE\n' "$(cue_text "$num. $(safe_filename "$title").${EXTENSIONS[0]}")"
            printf '    TRACK %02d AUDIO\n' "$i"
            printf '      TITLE "%s"\n' "$(cue_text "$title")"
            printf '      PERFORMER "%s"\n' "$(cue_text "$artist")"
            [ -z "$composer" ] || printf '      SONGWRITER "%s"\n' "$(cue_text "$composer")"
            printf '      INDEX 01 00:00:00\n'
        done
    } > "$CUE_FILE"
}

usage() {
    printf 'Usage: ripcd [-v] [-h]\n'
    printf '  Interactive CD ripper: cdparanoia, MusicBrainz tags and cover art,\n'
    printf '  FLAC, MP3, OGG or WAV output, a rip log, a CUE sheet and checksums.\n'
    printf '  -v, --verbose   show the API calls and other detail\n'
}

main() {
    local opt
    while getopts ':vh-:' opt; do
        case "$opt" in
            v) VERBOSE=1 ;;
            h) usage; exit 0 ;;
            -)
                case "$OPTARG" in
                    verbose) VERBOSE=1 ;;
                    help) usage; exit 0 ;;
                    *) printf 'ripcd: unknown option --%s\n' "$OPTARG" >&2; usage >&2; exit 1 ;;
                esac
                ;;
            *) printf 'ripcd: unknown option -%s\n' "$OPTARG" >&2; usage >&2; exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))
    if [ "$#" -gt 0 ]; then
        usage >&2
        exit 1
    fi

    printf 'Checking for required dependencies...\n'
    local -a missing=()
    local cmd
    for cmd in cdparanoia curl jq md5sum eject wc sed date mktemp; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        error_exit "Missing dependencies: ${missing[*]}. Please install them to continue."
    fi
    success "Core dependencies are satisfied."
    printf '\n'

    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ripcd.XXXXXX")"
    trap cleanup EXIT
    trap 'exit 130' INT TERM HUP

    # --- Auto-detect CD drive ---
    printf 'Scanning for CD drives with a disc...\n'
    local -a drives=(/dev/sr*) valid=()
    local drive
    if [ "${#drives[@]}" -eq 0 ]; then
        error_exit "No CD drives detected. Please check your hardware."
    fi
    for drive in "${drives[@]}"; do
        if LC_ALL=C cdparanoia -Q -d "$drive" >/dev/null 2>&1; then
            valid+=("$drive")
        fi
    done

    if [ "${#valid[@]}" -eq 0 ]; then
        error_exit "No readable audio CD found in any drive. Please insert a disc."
    elif [ "${#valid[@]}" -eq 1 ]; then
        CD_DEVICE="${valid[0]}"
        success "Found CD in: $CD_DEVICE"
    else
        printf 'Found discs in multiple drives. Please choose which one to rip:\n'
        select drive in "${valid[@]}"; do
            if [ -n "$drive" ]; then
                CD_DEVICE="$drive"
                break
            fi
            printf 'Invalid selection.\n'
        done
        [ -n "${CD_DEVICE:-}" ] || error_exit "No drive selected."
    fi
    printf '\n'

    # --- Output format(s) ---
    printf 'Please choose output format(s):\n'
    printf '  1) FLAC (lossless, with ReplayGain, default)\n'
    printf '  2) WAV (uncompressed)\n'
    printf '  3) MP3 (320kbps)\n'
    printf '  4) OGG (Vorbis, quality 10)\n'
    printf '  5) Multiple formats (e.g., FLAC + MP3)\n'
    local format_choice multi fmt
    read -r -p "Enter your choice [1-5]: " format_choice || format_choice=""

    ENCODERS=()
    EXTENSIONS=()
    case "$format_choice" in
        2) ENCODERS=(wav); EXTENSIONS=(wav) ;;
        3) need lame "MP3 encoding"; ENCODERS=(mp3); EXTENSIONS=(mp3) ;;
        4) need oggenc "OGG encoding"; ENCODERS=(ogg); EXTENSIONS=(ogg) ;;
        5)
            printf '\nSelect formats to generate:\n  [1] FLAC\n  [2] WAV\n  [3] MP3\n  [4] OGG\n\n'
            printf "Enter numbers separated by spaces (e.g., '1 3' for FLAC+MP3):\n"
            read -r -p "Selection: " multi || multi=""
            # Unquoted on purpose: split the space-separated selection
            for fmt in $multi; do
                case "$fmt" in
                    1) need flac "FLAC encoding"; ENCODERS+=(flac); EXTENSIONS+=(flac) ;;
                    2) ENCODERS+=(wav); EXTENSIONS+=(wav) ;;
                    3) need lame "MP3 encoding"; ENCODERS+=(mp3); EXTENSIONS+=(mp3) ;;
                    4) need oggenc "OGG encoding"; ENCODERS+=(ogg); EXTENSIONS+=(ogg) ;;
                esac
            done
            if [ "${#ENCODERS[@]}" -eq 0 ]; then
                warn "No valid formats selected. Using FLAC as default."
                need flac "FLAC encoding"
                ENCODERS=(flac); EXTENSIONS=(flac)
            fi
            ;;
        *) need flac "FLAC encoding"; ENCODERS=(flac); EXTENSIONS=(flac) ;;
    esac

    local flac_selected=0 enc
    for enc in "${ENCODERS[@]}"; do
        if [ "$enc" = flac ]; then
            flac_selected=1
        fi
    done
    if [ "$flac_selected" -eq 1 ]; then
        need metaflac "ReplayGain tagging"
    fi
    printf '\n'
    success "Selected formats: ${ENCODERS[*]^^}"
    printf '\n'

    # --- Save directory ---
    local save_dir
    read -r -e -p "Enter the directory to save the ripped files (default: $HOME/Music): " save_dir || save_dir=""
    save_dir="${save_dir:-$HOME/Music}"
    # shellcheck disable=SC2088  # matching a literal tilde the user typed
    case "$save_dir" in
        "~") save_dir="$HOME" ;;
        "~/"*) save_dir="$HOME/${save_dir#"~/"}" ;;
    esac
    if [ ! -d "$save_dir" ]; then
        printf "Directory '%s' does not exist. Creating it...\n" "$save_dir"
        mkdir -p -- "$save_dir" || error_exit "Could not create directory '$save_dir'."
    fi
    # Absolute, so the encoders can never read a path as an option
    save_dir="$(cd -P -- "$save_dir" && pwd -P)" || error_exit "Could not open directory '$save_dir'."
    success "Rips will be saved in: $save_dir"
    printf '\n'

    # --- Read the TOC ---
    printf 'Attempting to retrieve CD information from MusicBrainz...\n'
    local toc="$TEMP_DIR/cdparanoia_toc.txt"
    LC_ALL=C cdparanoia -Q -d "$CD_DEVICE" > "$toc" 2>&1 || true
    local track_count_actual
    track_count_actual="$(grep -cE '^[[:space:]]*[1-9][0-9]*\.' "$toc" || true)"
    if [ "${track_count_actual:-0}" -eq 0 ]; then
        error_exit "No audio tracks found on the disc or could not read the disc."
    fi
    success "Found $track_count_actual tracks on the disc."

    # cdparanoia's "begin" column is a 0-based sector count. MusicBrainz disc
    # IDs expect offsets that include the 150-frame (2s) lead-in, so 150 is
    # added to every offset and to the leadout.
    local first_sector total_sectors leadout offsets toc_string api_url
    first_sector="$(awk '$1 == "1." { print $4; exit }' "$toc")"
    total_sectors="$(awk '$1 == "TOTAL" { print $2; exit }' "$toc")"
    [[ "$first_sector" =~ ^[0-9]+$ ]] || error_exit "Could not read the first track offset from the TOC."
    [[ "$total_sectors" =~ ^[0-9]+$ ]] || error_exit "Could not read the total sector count from the TOC."
    leadout=$((first_sector + total_sectors + 150))
    offsets="$(awk '$1 ~ /^[1-9][0-9]*\.$/ { printf "+%d", $4 + 150 }' "$toc")"
    toc_string="1+$track_count_actual+$leadout$offsets"
    verbose_echo "Constructed TOC for API: '$toc_string'"

    api_url="https://musicbrainz.org/ws/2/discid/-?toc=$toc_string&fmt=json&inc=artist-credits+recordings+release-groups+genres+work-rels+recording-level-rels+work-level-rels+artist-rels"
    verbose_echo "Constructed API URL: $api_url"

    MUSICBRAINZ_JSON="$TEMP_DIR/musicbrainz_response.json"
    local http_status
    # curl prints 000 itself when the request never completes
    http_status="$(curl -s --max-time 30 -o "$MUSICBRAINZ_JSON" -w '%{http_code}' -A "$USER_AGENT" "$api_url" || true)"
    [[ "$http_status" =~ ^[0-9]{3}$ ]] || http_status=000
    verbose_echo "Received HTTP Status: $http_status"

    # --- Metadata state (globals read by the helpers above) ---
    RELEASE_URL=""
    COVER_ART_FILE=""
    GENRE=""
    COMMENT=""
    DISC_NUMBER=1
    TOTAL_DISCS=1
    METADATA_SOURCE="Manual"
    TRACK_TITLES=()
    COMPOSERS=()
    TRACK_ARTISTS=()
    MBID=""
    ORIGINAL_DATE=""
    ALBUM_ARTIST=""
    ALBUM_TITLE=""
    YEAR=""
    SELECTED_INDEX=0
    MEDIA_INDEX=0
    TRACK_COUNT="$track_count_actual"

    local release_count confirm selection
    if [ "$http_status" = 200 ] && [ -s "$MUSICBRAINZ_JSON" ]; then
        release_count="$(jq '.releases | length' "$MUSICBRAINZ_JSON" 2>/dev/null || printf '0')"
        [[ "$release_count" =~ ^[0-9]+$ ]] || release_count=0
        verbose_echo "MusicBrainz returned $release_count potential matches"

        if [ "$release_count" -eq 1 ]; then
            printf '\nFound one matching release:\n'
            jq -r '.releases[0] | "\(."artist-credit"[0].name // "Various Artists") - \(.title)"' "$MUSICBRAINZ_JSON"
            read -r -p "Use this release? (y/n): " confirm || confirm=""
            case "$confirm" in
                [yY]*) METADATA_SOURCE="MusicBrainz" ;;
            esac
        elif [ "$release_count" -gt 1 ]; then
            printf '\nFound %s matching releases. Please choose the correct one:\n' "$release_count"
            printf '   0. None of these, enter manually\n'
            jq -r '.releases | to_entries[] | "\(.key + 1 | tostring | if length < 2 then " " + . else . end). \(.value."artist-credit"[0].name // "Various Artists") - \(.value.title) (\(.value.date // "Unknown"))"' "$MUSICBRAINZ_JSON" \
                | sed 's/^/ /'
            while true; do
                read -r -p "Enter your choice (0-$release_count): " selection || selection=0
                if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -le "$release_count" ]; then
                    if [ "$selection" -ne 0 ]; then
                        SELECTED_INDEX=$((selection - 1))
                        METADATA_SOURCE="MusicBrainz"
                    fi
                    break
                fi
                printf 'Invalid selection. Please try again.\n'
            done
        else
            warn "No matches found on MusicBrainz for this disc."
        fi
    elif [ "$http_status" != 200 ]; then
        warn "MusicBrainz API returned status $http_status. Proceeding with manual entry."
    fi

    local i title composer track_artist media_count mb_tracks
    if [ "$METADATA_SOURCE" = "MusicBrainz" ]; then
        success "Metadata loaded from MusicBrainz!"
        printf '\n'

        ALBUM_ARTIST="$(mbq '.releases[$idx]."artist-credit"[0].name // "Various Artists"')"
        ALBUM_TITLE="$(mbq '.releases[$idx].title // ""')"
        YEAR="$(mbq '.releases[$idx].date // ""' | cut -d- -f1)"
        ORIGINAL_DATE="$(mbq '.releases[$idx]."release-group"."first-release-date" // ""' | cut -d- -f1)"
        MBID="$(mbq '.releases[$idx].id // ""')"
        [ -z "$MBID" ] || RELEASE_URL="https://musicbrainz.org/release/$MBID"

        printf 'Album: %s - %s\n' "$ALBUM_ARTIST" "$ALBUM_TITLE"
        [ -z "$YEAR" ] || printf 'Year: %s\n' "$YEAR"
        if [ -n "$ORIGINAL_DATE" ] && [ "$ORIGINAL_DATE" != "$YEAR" ]; then
            printf 'Original Release: %s\n' "$ORIGINAL_DATE"
        fi
        printf '\n'

        # A release can span several discs (media). Ask which one is in the drive.
        media_count="$(mbq '.releases[$idx].media | length' 2>/dev/null || printf '1')"
        [[ "$media_count" =~ ^[0-9]+$ ]] || media_count=1
        if [ "$media_count" -gt 1 ]; then
            printf 'This release has %s discs. Which one is in the drive?\n' "$media_count"
            mbq '.releases[$idx].media | to_entries[] | "  \(.key + 1). \(.value."track-count") tracks\(if (.value.title // "") != "" then " - " + .value.title else "" end)"'
            MEDIA_INDEX=$(( $(read_number "Enter disc number [1-$media_count]: " 1 "$media_count" 1) - 1 ))
            TOTAL_DISCS="$media_count"
            DISC_NUMBER=$((MEDIA_INDEX + 1))
            printf '\n'
        fi

        # Trust the disc over the release match: cdparanoia counted what's there
        mb_tracks="$(mbq '.releases[$idx].media[$midx]."track-count" // empty' 2>/dev/null || true)"
        if [[ "$mb_tracks" =~ ^[0-9]+$ ]] && [ "$mb_tracks" -ne "$track_count_actual" ]; then
            warn "MusicBrainz reports $mb_tracks tracks but the disc has $track_count_actual. Using the disc's count."
        fi

        # --- Genre ---
        local -a genres=()
        local g
        while IFS= read -r g; do
            [ -n "$g" ] && genres+=("$g")
        done < <(mbq '.releases[$idx].genres[]?.name' 2>/dev/null || true)
        if [ "${#genres[@]}" -gt 1 ]; then
            printf 'Found multiple genres. Please choose one:\n'
            for i in "${!genres[@]}"; do
                printf '  %d) %s\n' "$((i + 1))" "${genres[$i]}"
            done
            GENRE="${genres[$(( $(read_number "Enter your choice [1-${#genres[@]}]: " 1 "${#genres[@]}" 1) - 1 ))]}"
            printf 'Selected genre: %s\n' "$GENRE"
        elif [ "${#genres[@]}" -eq 1 ]; then
            GENRE="${genres[0]}"
            printf 'Selected genre: %s\n' "$GENRE"
        else
            warn "No genres found on MusicBrainz."
        fi
        printf '\n'

        read -r -p "Comment (optional): " COMMENT || COMMENT=""
        printf '\n'

        # --- Cover art ---
        # The 1200px thumbnail is plenty for embedding in every track; the
        # original upload can be a 10+ MB scan.
        local front art_url caa_json caa_status art_size
        front="$(mbq '.releases[$idx]."cover-art-archive".front // false')"
        if [ "$front" = "true" ] && [ -n "$MBID" ]; then
            printf 'Downloading cover art...\n'
            COVER_ART_FILE="$TEMP_DIR/cover_art.jpg"
            caa_json="$TEMP_DIR/caa_response.json"
            caa_status="$(curl -sL --max-time 30 -o "$caa_json" -w '%{http_code}' -A "$USER_AGENT" \
                "https://coverartarchive.org/release/$MBID" || true)"
            art_url=""
            if [ "$caa_status" = 200 ] && [ -s "$caa_json" ]; then
                art_url="$(jq -r '([.images[] | select(.front == true)] + .images) | .[0] // empty
                    | .thumbnails["1200"] // .thumbnails.large // .image // empty' "$caa_json" 2>/dev/null || true)"
                verbose_echo "CAA selected URL: $art_url"
            fi
            [ -n "$art_url" ] || art_url="https://coverartarchive.org/release/$MBID/front"

            if curl -sL --max-time 30 -A "$USER_AGENT" -o "$COVER_ART_FILE" "$art_url" && [ -s "$COVER_ART_FILE" ]; then
                art_size="$(file_size "$COVER_ART_FILE")"
                success "Cover art downloaded ($(human_size "$art_size"))."
            else
                warn "Failed to download cover art."
                COVER_ART_FILE=""
            fi
        fi

        # --- Tracks ---
        for (( i = 0; i < TRACK_COUNT; i++ )); do
            title="$(mbq --argjson i "$i" '.releases[$idx].media[$midx].tracks[$i]?.title // ""' 2>/dev/null || true)"
            TRACK_TITLES+=("${title:-Track $((i + 1))}")
            # Composers are credited on the work a recording performs, so
            # the path is recording -> work relation -> composer or writer
            composer="$(mbq --argjson i "$i" '[.releases[$idx].media[$midx].tracks[$i]?.recording.relations[]? | select(."target-type" == "work") | .work.relations[]? | select(.type == "composer" or .type == "writer") | .artist.name] | unique | join("; ")' 2>/dev/null || true)"
            COMPOSERS+=("$composer")
            track_artist="$(mbq --argjson i "$i" '.releases[$idx].media[$midx].tracks[$i]?.recording."artist-credit"[0].name // ""' 2>/dev/null || true)"
            TRACK_ARTISTS+=("$track_artist")
        done
    else
        printf 'Please enter album metadata manually:\n'
        read -r -p "Album Artist: " ALBUM_ARTIST || ALBUM_ARTIST=""
        read -r -p "Album Title: " ALBUM_TITLE || ALBUM_TITLE=""
        read -r -p "Year (optional): " YEAR || YEAR=""
        read -r -p "Original Release Year (optional): " ORIGINAL_DATE || ORIGINAL_DATE=""
        read -r -p "Genre (optional): " GENRE || GENRE=""
        read -r -p "Comment (optional): " COMMENT || COMMENT=""
        printf '\n'

        local is_multi disc_in total_in
        read -r -p "Is this part of a multi-disc set? (y/n): " is_multi || is_multi=""
        case "$is_multi" in
            [yY]*)
                read -r -p "Disc number: " disc_in || disc_in=""
                read -r -p "Total number of discs: " total_in || total_in=""
                if [[ "$disc_in" =~ ^[1-9][0-9]*$ ]]; then
                    DISC_NUMBER="$disc_in"
                else
                    warn "Invalid disc number. Defaulting to disc 1."
                fi
                if [[ "$total_in" =~ ^[0-9]+$ ]] && [ "$total_in" -ge "$DISC_NUMBER" ]; then
                    TOTAL_DISCS="$total_in"
                else
                    warn "Invalid disc total. Defaulting to $DISC_NUMBER."
                    TOTAL_DISCS="$DISC_NUMBER"
                fi
                ;;
        esac
        printf '\n'

        printf 'Enter track titles (press Enter to skip):\n'
        for (( i = 1; i <= TRACK_COUNT; i++ )); do
            read -r -p "Track $i title: " title || title=""
            TRACK_TITLES+=("${title:-Track $i}")
            TRACK_ARTISTS+=("")
            COMPOSERS+=("")
        done
    fi

    [ -n "$ALBUM_ARTIST" ] || ALBUM_ARTIST="Unknown Artist"
    [ -n "$ALBUM_TITLE" ] || ALBUM_TITLE="Unknown Album"

    # --- Review and edit ---
    local metadata_confirm edit_choice track_edit new_title
    while true; do
        printf '\n================================================================================\n'
        printf 'METADATA REVIEW\n'
        printf '================================================================================\n\n'
        printf 'Album: %s - %s\n' "$ALBUM_ARTIST" "$ALBUM_TITLE"
        [ -z "$YEAR" ] || printf 'Year: %s\n' "$YEAR"
        [ -z "$ORIGINAL_DATE" ] || printf 'Original Release: %s\n' "$ORIGINAL_DATE"
        [ -z "$GENRE" ] || printf 'Genre: %s\n' "$GENRE"
        [ -z "$COMMENT" ] || printf 'Comment: %s\n' "$COMMENT"
        if [ "$TOTAL_DISCS" -gt 1 ]; then
            printf 'Disc: %s of %s\n' "$DISC_NUMBER" "$TOTAL_DISCS"
        fi
        printf '\nTracks:\n'
        for (( i = 1; i <= TRACK_COUNT; i++ )); do
            printf '  %2d. %-50s\n' "$i" "${TRACK_TITLES[$((i - 1))]}"
            track_artist="${TRACK_ARTISTS[$((i - 1))]}"
            composer="${COMPOSERS[$((i - 1))]}"
            if [ -n "$track_artist" ] && [ "$track_artist" != "$ALBUM_ARTIST" ]; then
                printf '       Artist: %s\n' "$track_artist"
            fi
            [ -z "$composer" ] || printf '       Composer: %s\n' "$composer"
        done
        printf '\n'
        read -r -p "Is this information correct? (y/n): " metadata_confirm || metadata_confirm=y
        case "$metadata_confirm" in
            [yY]*) break ;;
        esac

        printf 'Edit options:\n  1) Album artist\n  2) Album title\n  3) Year\n  4) Genre\n'
        printf '  5) Comment\n  6) Edit individual track\n  7) Start over from the disc lookup\n'
        read -r -p "Select option (1-7) or press Enter to continue anyway: " edit_choice || edit_choice=""
        case "$edit_choice" in
            1) read -r -p "New album artist: " ALBUM_ARTIST || true ;;
            2) read -r -p "New album title: " ALBUM_TITLE || true ;;
            3) read -r -p "New year: " YEAR || true ;;
            4) read -r -p "New genre: " GENRE || true ;;
            5) read -r -p "New comment: " COMMENT || true ;;
            6)
                read -r -p "Track number to edit: " track_edit || track_edit=""
                if [[ "$track_edit" =~ ^[0-9]+$ ]] && [ "$track_edit" -ge 1 ] && [ "$track_edit" -le "$TRACK_COUNT" ]; then
                    read -r -p "New title: " new_title || new_title=""
                    [ -z "$new_title" ] || TRACK_TITLES[track_edit - 1]="$new_title"
                fi
                ;;
            7)
                # Starts over from the top, MusicBrainz lookup included.
                # exec replaces this process without running the EXIT trap
                cleanup
                exec "$0" "$@"
                ;;
            "") break ;;
        esac
    done
    printf '\n'

    # --- Output directory ---
    SAFE_ALBUM_ARTIST="$(safe_filename "$ALBUM_ARTIST")"
    SAFE_ALBUM_TITLE="$(safe_filename "$ALBUM_TITLE")"
    OUTPUT_DIR="$save_dir/$SAFE_ALBUM_ARTIST/$SAFE_ALBUM_ARTIST - $SAFE_ALBUM_TITLE"
    printf 'Creating output directory: %s\n' "$OUTPUT_DIR"
    mkdir -p -- "$OUTPUT_DIR" || error_exit "Could not create output directory."
    printf '\n'

    # --- Checkpoint ---
    if [ -d "$OLD_CHECKPOINT_DIR" ] && [ ! -e "$CHECKPOINT_DIR" ]; then
        mv -- "$OLD_CHECKPOINT_DIR" "$CHECKPOINT_DIR" || true
    fi
    mkdir -p -- "$CHECKPOINT_DIR"
    local last_completed resume_choice
    last_completed="$(load_checkpoint)"
    if [ "$last_completed" -ge "$TRACK_COUNT" ]; then
        last_completed=0
    fi
    if [ "$last_completed" -gt 0 ]; then
        printf 'Found previous rip checkpoint. Last completed track: %s\n' "$last_completed"
        read -r -p "Resume from track $((last_completed + 1))? (y/n): " resume_choice || resume_choice=n
        case "$resume_choice" in
            [yY]*) printf 'Resuming rip...\n' ;;
            *) last_completed=0; printf 'Starting fresh.\n' ;;
        esac
    fi
    printf '\n'

    # --- Log, CUE and stats paths ---
    if [ "$TOTAL_DISCS" -gt 1 ]; then
        LOG_FILE="$OUTPUT_DIR/rip_log_disc$DISC_NUMBER.txt"
        CUE_FILE="$OUTPUT_DIR/$SAFE_ALBUM_TITLE (Disc $DISC_NUMBER).cue"
        STATS_FILE="$OUTPUT_DIR/rip_stats_disc$DISC_NUMBER.json"
    else
        LOG_FILE="$OUTPUT_DIR/rip_log.txt"
        CUE_FILE="$OUTPUT_DIR/$SAFE_ALBUM_TITLE.cue"
        STATS_FILE="$OUTPUT_DIR/rip_stats.json"
    fi

    local drive_model session_start
    drive_model="$(sed -n 's/.*CDROM model sensed sensed:[[:space:]]*//p' "$toc" | sed -n '1p')"
    session_start="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    # A resumed rip appends, so the log of the earlier session survives
    if [ "$last_completed" -eq 0 ]; then
        : > "$LOG_FILE"
    fi
    {
        printf '================================================================================\n'
        printf 'CD RIP LOG - ripcd v%s\n' "$SCRIPT_REVISION"
        printf '================================================================================\n\n'
        printf 'Album Information:\n'
        printf '  Artist: %s\n  Title: %s\n' "$ALBUM_ARTIST" "$ALBUM_TITLE"
        if [ "$TOTAL_DISCS" -gt 1 ]; then printf '  Disc: %s of %s\n' "$DISC_NUMBER" "$TOTAL_DISCS"; fi
        [ -z "$YEAR" ] || printf '  Year: %s\n' "$YEAR"
        [ -z "$ORIGINAL_DATE" ] || printf '  Original Release: %s\n' "$ORIGINAL_DATE"
        [ -z "$GENRE" ] || printf '  Genre: %s\n' "$GENRE"
        [ -z "$MBID" ] || printf '  MusicBrainz ID: %s\n' "$MBID"
        [ -z "$RELEASE_URL" ] || printf '  MusicBrainz URL: %s\n' "$RELEASE_URL"
        printf '\nRipping Session:\n'
        printf '  Started: %s\n  Script version: %s\n  Metadata source: %s\n  Resumed from track: %s\n\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$SCRIPT_REVISION" "$METADATA_SOURCE" "$((last_completed + 1))"
        printf 'Output Configuration:\n  Formats: %s\n  Bitrates:' "${ENCODERS[*]^^}"
        for enc in "${ENCODERS[@]}"; do
            case "$enc" in
                flac) printf ' FLAC=Lossless' ;;
                wav) printf ' WAV=Uncompressed' ;;
                mp3) printf ' MP3=320kbps' ;;
                ogg) printf ' OGG=q10' ;;
            esac
        done
        printf '\n\nTool Versions:\n'
        { cdparanoia --version 2>&1 || true; } | sed -n '1p'
        for enc in "${ENCODERS[@]}"; do
            case "$enc" in
                flac) { flac --version 2>&1 || true; } | sed -n '1p'
                      { metaflac --version 2>&1 || true; } | sed -n '1p' ;;
                mp3) { lame --version 2>&1 || true; } | sed -n '1p' ;;
                ogg) { oggenc --version 2>&1 || true; } | sed -n '1p' ;;
            esac
        done
        printf '\nDrive Information:\n  Device: %s\n' "$CD_DEVICE"
        [ -z "$drive_model" ] || printf '  Model: %s\n' "$drive_model"
        printf '\n================================================================================\n\n'
    } >> "$LOG_FILE"

    # --- Hidden track (pre-gap audio before track 1) ---
    # cdparanoia never lists a track 0. Hidden audio shows up as track 1
    # starting after sector 0, and "cdparanoia 0" rips that span. A gap of
    # 2 seconds or less is just silence. Some drives can't read the pre-gap
    # and hang trying, so it's opt-in.
    local hda_file hda_out ext idx hda_rc hda_choice=n
    if [ "$first_sector" -gt 150 ] && [ "$last_completed" -eq 0 ]; then
        printf 'Track 1 starts %d seconds in, so there may be a hidden track before it.\n' "$((first_sector / 75))"
        read -r -p "Rip it as track 00? Some drives can't read this area and stall. (y/N): " hda_choice || hda_choice=n
    fi
    if [[ "$hda_choice" =~ ^[yY] ]]; then
        printf 'Ripping the hidden track...\n'
        if [ "$TOTAL_DISCS" -gt 1 ]; then
            hda_file="$OUTPUT_DIR/$DISC_NUMBER-00. Hidden Track"
        else
            hda_file="$OUTPUT_DIR/00. Hidden Track"
        fi
        if cdparanoia -d "$CD_DEVICE" 0 "$TEMP_DIR/hda.wav" >/dev/null 2>&1 && [ -s "$TEMP_DIR/hda.wav" ]; then
            for idx in "${!ENCODERS[@]}"; do
                enc="${ENCODERS[$idx]}"
                ext="${EXTENSIONS[$idx]}"
                hda_out="$hda_file.$ext"
                hda_rc=0
                case "$enc" in
                    flac) flac -f -s --best -o "$hda_out" "$TEMP_DIR/hda.wav" 2>/dev/null || hda_rc=1 ;;
                    wav) cp -- "$TEMP_DIR/hda.wav" "$hda_out" || hda_rc=1 ;;
                    mp3) lame -S -b 320 "$TEMP_DIR/hda.wav" "$hda_out" 2>/dev/null || hda_rc=1 ;;
                    ogg) oggenc -Q -q 10 "$TEMP_DIR/hda.wav" -o "$hda_out" 2>/dev/null || hda_rc=1 ;;
                esac
                if [ "$hda_rc" -eq 0 ] && [ -s "$hda_out" ]; then
                    success "Hidden track ripped to: $hda_out"
                    log_entry "INFO" "Hidden Track (Track 0, $enc): Successfully ripped"
                else
                    warn "Failed to encode hidden track to $enc."
                    log_entry "WARN" "Hidden Track (Track 0, $enc): Encode FAILED"
                    rm -f -- "$hda_out"
                fi
            done
        else
            warn "Failed to rip hidden track."
            log_entry "WARN" "Hidden Track (Track 0): Rip FAILED"
        fi
        rm -f -- "$TEMP_DIR/hda.wav"
    fi

    printf '\n================================================================================\nTRACK RIPS\n================================================================================\n' >> "$LOG_FILE"

    # --- Main ripping loop ---
    printf '\nBeginning rip...\n'
    printf '================================================================================\n'

    local rip_start track_start retry rip_ok rip_log rip_exit pregap peak quality
    local wav_size track_ok tracks_ok=0 encodes_ok=0 encodes_failed=0 first_failed=0
    local -a failed_tracks=()
    rip_start="$(date +%s)"

    for (( i = 1; i <= TRACK_COUNT; i++ )); do
        if [ "$i" -le "$last_completed" ]; then
            tracks_ok=$((tracks_ok + 1))
            continue
        fi

        if [ "$TOTAL_DISCS" -gt 1 ]; then
            TRACK_NUM="$DISC_NUMBER-$(printf '%02d' "$i")"
        else
            TRACK_NUM="$(printf '%02d' "$i")"
        fi
        TRACK_TITLE="${TRACK_TITLES[$((i - 1))]}"
        COMPOSER="${COMPOSERS[$((i - 1))]}"
        TRACK_ARTIST="${TRACK_ARTISTS[$((i - 1))]}"
        SAFE_TRACK_TITLE="$(safe_filename "$TRACK_TITLE")"
        TEMP_WAV_FILE="$TEMP_DIR/$TRACK_NUM.wav"

        track_start="$(date +%s)"
        retry=0
        rip_ok=0
        while [ "$retry" -lt "$MAX_RETRIES" ] && [ "$rip_ok" -eq 0 ]; do
            printf '[%s/%s] Ripping: %s (attempt %d/%d)\n' "$TRACK_NUM" "$TRACK_COUNT" "$TRACK_TITLE" "$((retry + 1))" "$MAX_RETRIES"
            rip_exit=0
            rip_log="$(cdparanoia -v -d "$CD_DEVICE" "$i" "$TEMP_WAV_FILE" 2>&1)" || rip_exit=$?
            IFS='|' read -r pregap peak quality <<< "$(parse_rip_quality "$rip_log")" || true

            if [ "$rip_exit" -eq 0 ] && [ -s "$TEMP_WAV_FILE" ]; then
                rip_ok=1
            else
                retry=$((retry + 1))
                rm -f -- "$TEMP_WAV_FILE"
                if [ "$retry" -lt "$MAX_RETRIES" ]; then
                    warn "Rip failed for track $i. Retrying in ${RETRY_DELAY}s..."
                    log_entry "WARN" "Track $i: Rip attempt $retry failed, retrying..."
                    sleep "$RETRY_DELAY"
                fi
            fi
        done

        if [ "$rip_ok" -eq 0 ]; then
            printf 'Track %s: FAILED after %s attempts\n' "$i" "$MAX_RETRIES"
            log_entry "ERROR" "Track $i: Failed after $MAX_RETRIES attempts"
            failed_tracks+=("$i")
            [ "$first_failed" -ne 0 ] || first_failed="$i"
            create_checkpoint "$((first_failed - 1))" "failed_at_track_$first_failed"
            continue
        fi

        wav_size="$(file_size "$TEMP_WAV_FILE")"
        {
            printf '\nTrack %s: %s\n' "$i" "$TRACK_TITLE"
            printf '  Artist: %s\n' "${TRACK_ARTIST:-$ALBUM_ARTIST}"
            [ -z "$COMPOSER" ] || printf '  Composer: %s\n' "$COMPOSER"
            printf '  Rip Quality: %s\n' "$quality"
            [ -z "$pregap" ] || printf '  Pre-gap: %ss\n' "$pregap"
            [ -z "$peak" ] || printf '  Peak Level: %s%%\n' "$peak"
            printf '  Rip Duration: %ss\n' "$(( $(date +%s) - track_start ))"
            printf '  WAV Size: %s\n' "$(human_size "$wav_size")"
        } >> "$LOG_FILE"

        track_ok=1
        for idx in "${!ENCODERS[@]}"; do
            if encode_track "${ENCODERS[$idx]}" "${EXTENSIONS[$idx]}" "$i"; then
                encodes_ok=$((encodes_ok + 1))
            else
                encodes_failed=$((encodes_failed + 1))
                track_ok=0
            fi
        done
        rm -f -- "$TEMP_WAV_FILE"

        if [ "$track_ok" -eq 1 ]; then
            tracks_ok=$((tracks_ok + 1))
        else
            failed_tracks+=("$i")
            [ "$first_failed" -ne 0 ] || first_failed="$i"
        fi

        # The checkpoint only moves forward while every track so far is
        # complete, so a resume always starts at the first gap.
        if [ "$first_failed" -eq 0 ]; then
            create_checkpoint "$i" "completed"
        else
            create_checkpoint "$((first_failed - 1))" "failed_at_track_$first_failed"
        fi
    done

    printf '================================================================================\n\n'
    local rip_time=$(( $(date +%s) - rip_start ))

    write_cue

    # --- ReplayGain ---
    if [ "$flac_selected" -eq 1 ]; then
        local -a flac_files=()
        if [ "$TOTAL_DISCS" -gt 1 ]; then
            flac_files=("$OUTPUT_DIR/$DISC_NUMBER"-*.flac)
        else
            flac_files=("$OUTPUT_DIR"/*.flac)
        fi
        if [ "${#flac_files[@]}" -eq 0 ]; then
            warn "No FLAC files found to apply ReplayGain to."
        else
            printf 'Applying ReplayGain tags to FLAC files...\n'
            if metaflac --add-replay-gain "${flac_files[@]}" 2>/dev/null; then
                success "ReplayGain scanning complete."
                log_entry "INFO" "ReplayGain scanning applied to FLAC files"
            else
                warn "ReplayGain application failed."
                log_entry "WARN" "ReplayGain application failed"
            fi
            printf '\n'
        fi
    fi

    if [ -n "$COVER_ART_FILE" ] && [ -f "$COVER_ART_FILE" ]; then
        if cp -- "$COVER_ART_FILE" "$OUTPUT_DIR/folder.jpg" 2>/dev/null; then
            success "Cover art saved to output directory as folder.jpg."
        else
            warn "Could not save cover art to output directory."
        fi
    fi

    # --- Checksums ---
    printf 'Calculating file checksums...\n'
    printf '\n================================================================================\nFILE CHECKSUMS (MD5)\n================================================================================\n\n' >> "$LOG_FILE"
    local -a matches=() names=()
    local m
    for ext in "${EXTENSIONS[@]}"; do
        if [ "$TOTAL_DISCS" -gt 1 ]; then
            matches=("$OUTPUT_DIR/$DISC_NUMBER"-*."$ext")
        else
            matches=("$OUTPUT_DIR"/*."$ext")
        fi
        [ "${#matches[@]}" -gt 0 ] || continue
        names=()
        for m in "${matches[@]}"; do
            names+=("${m##*/}")
        done
        ( cd -- "$OUTPUT_DIR" && md5sum -- "${names[@]}" ) >> "$LOG_FILE" 2>/dev/null || warn "md5sum failed for .$ext files"
    done

    # --- Summary ---
    {
        printf '\n================================================================================\nRIP SUMMARY\n================================================================================\n\n'
        printf 'Results:\n'
        printf '  Tracks complete: %s of %s\n' "$tracks_ok" "$TRACK_COUNT"
        printf '  Encodes OK: %s, failed: %s\n' "$encodes_ok" "$encodes_failed"
        if [ "${#failed_tracks[@]}" -gt 0 ]; then
            printf '  Failed tracks: %s\n' "${failed_tracks[*]}"
        fi
        printf '  Success rate: %s%%\n\n' "$(( tracks_ok * 100 / TRACK_COUNT ))"
        printf 'Timing:\n  Total duration: %sm %ss\n  Completed: %s\n\n' \
            "$((rip_time / 60))" "$((rip_time % 60))" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'Output Files:\n'
        for m in "$OUTPUT_DIR"/*; do
            [ -f "$m" ] || continue
            case "$m" in
                *.cue|*.txt|*.json) continue ;;
            esac
            printf '  %s (%s)\n' "${m##*/}" "$(human_size "$(file_size "$m")")"
        done
        printf '\n================================================================================\n'
    } >> "$LOG_FILE"

    jq -n \
        --arg start "$session_start" \
        --arg end "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        --arg artist "$ALBUM_ARTIST" \
        --arg album "$ALBUM_TITLE" \
        --arg mbid "$MBID" \
        --argjson disc "$DISC_NUMBER" \
        --argjson discs "$TOTAL_DISCS" \
        --argjson total "$TRACK_COUNT" \
        --argjson ok "$tracks_ok" \
        --argjson enc_ok "$encodes_ok" \
        --argjson enc_failed "$encodes_failed" \
        --argjson seconds "$rip_time" \
        --arg formats "${ENCODERS[*]}" \
        --arg failed "${failed_tracks[*]}" \
        '{session_start: $start, session_end: $end, album_artist: $artist,
          album_title: $album, mbid: $mbid, disc: $disc, total_discs: $discs,
          formats: ($formats | split(" ")), total_tracks: $total,
          tracks_complete: $ok, encodes_ok: $enc_ok, encodes_failed: $enc_failed,
          failed_tracks: ($failed | split(" ") | map(select(. != "") | tonumber)),
          rip_seconds: $seconds}' > "$STATS_FILE"

    if [ "${#failed_tracks[@]}" -eq 0 ]; then
        clear_checkpoint
        success "CD ripping complete!"
    else
        warn "Finished with failed tracks: ${failed_tracks[*]}. Run ripcd again and choose resume to retry from track $first_failed."
    fi
    printf 'Log file: %s\nCUE sheet: %s\nStatistics: %s\n\n' "$LOG_FILE" "$CUE_FILE" "$STATS_FILE"

    printf 'Ejecting disc...\n'
    if eject "$CD_DEVICE" 2>/dev/null; then
        success "Disc ejected."
        log_entry "INFO" "Disc ejected successfully"
    else
        warn "Could not eject disc automatically."
        log_entry "WARN" "Could not eject disc"
    fi

    [ "${#failed_tracks[@]}" -eq 0 ]
}

main "$@"
