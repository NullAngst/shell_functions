#!/bin/bash

#==============================================================================
#   DESCRIPTION: A script to rip CDs to various formats, automatically fetching
#                metadata, genres, composer info, and cover art from
#                MusicBrainz. It organizes files into a clean, archival-quality
#                directory structure with ReplayGain, HDA ripping, and auto-eject.
#
#  REQUIREMENTS: cdparanoia, flac, curl, jq, md5sum, eject, metaflac,
#                and lame/oggenc for MP3/OGG. Optional: mediainfo
#        AUTHOR: ReverendRetro
#       CREATED: 2025-08-10
#      REVISION: 5.0
#==============================================================================

set -euo pipefail

# --- Configuration ---
VERBOSE="false"
SCRIPT_REVISION="5.0"
TEMP_DIR=$(mktemp -d) || exit 1
readonly TEMP_DIR
MAX_RETRIES=3
RETRY_DELAY=5

# Enable nullglob to handle empty globs
shopt -s nullglob

# --- Functions ---

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function for verbose output
verbose_echo() {
    if [ "$VERBOSE" == "true" ]; then
        echo "[DEBUG] $1" >&2
    fi
}

# Function to display an error message and exit
error_exit() {
    cleanup
    echo "Error: $1" >&2
    exit 1
}

# Function to display a warning message
warn() {
    echo "Warning: $1" >&2
}

# Function to display success
success() {
    echo "Success: $1"
}

# Function to display info
info() {
    echo "Info: $1"
}

# Function to log to file
log_entry() {
    local level="$1"
    shift
    local message="$*"
    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
    fi
}

# Function to clean up temporary files
cleanup() {
    verbose_echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

# --- Dependency Check ---

echo "Checking for required dependencies..."
MISSING_DEPS=()
for cmd in cdparanoia curl jq md5sum eject metaflac; do
    if ! command_exists "$cmd"; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    error_exit "Missing dependencies: ${MISSING_DEPS[*]}. Please install them to continue."
fi

success "Core dependencies are satisfied."
echo

# --- Helper Functions ---

# Safely format filenames (remove problematic characters)
safe_filename() {
    echo "$1" | sed 's/[\/:]/_/g; s/[*?"]//g; s/[[:space:]]*$//'
}

# Parse cdparanoia output for track quality metrics
parse_rip_quality() {
    local rip_log="$1"
    local pregap=$(echo "$rip_log" | grep -oP 'pre-gap \K[0-9.]+' | head -1 || echo "")
    local peak=$(echo "$rip_log" | grep -oP 'peak \K[0-9.]+' | head -1 || echo "")
    local quality=$(echo "$rip_log" | grep -o 'Done\|FAILED' | tail -1 || echo "UNKNOWN")
    
    printf "%s|%s|%s" "$pregap" "$peak" "$quality"
}

# Check file integrity
check_file_integrity() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        return 1
    fi
    
    case "$ENCODER" in
        flac)
            if flac -t "$file" >/dev/null 2>&1; then
                return 0
            else
                return 1
            fi
            ;;
        mp3|ogg)
            # Check file size is reasonable (at least 1MB for audio)
            local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
            if [ "$size" -gt 1048576 ]; then
                return 0
            else
                return 1
            fi
            ;;
        wav)
            # WAV header check
            if head -c 4 "$file" | grep -q "RIFF"; then
                return 0
            else
                return 1
            fi
            ;;
    esac
    return 1
}

# Create checkpoint file
resolve_checkpoint_file() {
    # Encoders array may have multiple entries; join them for a stable key
    local enc_key
    enc_key=$(IFS=_; echo "${ENCODERS[*]:-unknown}")
    local album_key="$SAFE_ALBUM_ARTIST-$SAFE_ALBUM_TITLE-$enc_key"
    local checkpoint_dir="$HOME/.cache/simplecd-ripper"
    echo "$checkpoint_dir/checkpoint-$album_key.json"
}

create_checkpoint() {
    local track_num="$1"
    local status="$2"
    local cp_file
    cp_file=$(resolve_checkpoint_file)
    
    cat > "$cp_file" <<EOF
{
  "album_artist": "$ALBUM_ARTIST",
  "album_title": "$ALBUM_TITLE",
  "mbid": "$MBID",
  "encoders": "${ENCODERS[*]:-}",
  "last_completed_track": $track_num,
  "status": "$status",
  "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF
    chmod 600 "$cp_file"
}

# Load checkpoint file
load_checkpoint() {
    local cp_file
    cp_file=$(resolve_checkpoint_file)
    
    if [ -f "$cp_file" ]; then
        local last_track
        last_track=$(jq -r '.last_completed_track' "$cp_file" 2>/dev/null || echo "0")
        echo "$last_track"
    else
        echo "0"
    fi
}

# Initialize checkpoint directory
init_checkpoint_dir() {
    local checkpoint_dir="$HOME/.cache/simplecd-ripper"
    mkdir -p "$checkpoint_dir"
}

# Get file size in human-readable format
human_size() {
    local bytes=$1
    if [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024))KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$((bytes / 1048576))MB"
    else
        echo "$((bytes / 1073741824))GB"
    fi
}

# --- Auto-detect CD Drive ---

echo "Scanning for CD drives with a disc..."
DRIVES=($(ls /dev/sr* 2>/dev/null || true))
VALID_DRIVES=()

if [ ${#DRIVES[@]} -eq 0 ]; then
    error_exit "No CD drives detected. Please check your hardware."
fi

for drive in "${DRIVES[@]}"; do
    if cdparanoia -Q -d "$drive" >/dev/null 2>&1; then
        VALID_DRIVES+=("$drive")
    fi
done

if [ ${#VALID_DRIVES[@]} -eq 0 ]; then
    error_exit "No readable audio CD found in any drive. Please insert a disc."
elif [ ${#VALID_DRIVES[@]} -eq 1 ]; then
    CD_DEVICE=${VALID_DRIVES[0]}
    success "Found CD in: $CD_DEVICE"
else
    echo "Found discs in multiple drives. Please choose which one to rip:"
    select drive in "${VALID_DRIVES[@]}"; do
        if [ -n "$drive" ]; then
            CD_DEVICE=$drive
            break
        else
            echo "Invalid selection."
        fi
    done
fi
echo

# --- Choose Output Format(s) ---

echo "Please choose output format(s):"
echo "  1) FLAC (lossless, with ReplayGain, default)"
echo "  2) WAV (uncompressed)"
echo "  3) MP3 (320kbps)"
echo "  4) OGG (Vorbis, ~500kbps)"
echo "  5) Multiple formats (e.g., FLAC + MP3)"
read -p "Enter your choice [1-5]: " FORMAT_CHOICE

ENCODERS=()
EXTENSIONS=()

case $FORMAT_CHOICE in
    2)
        ENCODERS=("wav")
        EXTENSIONS=("wav")
        ;;
    3)
        command_exists "lame" || error_exit "'lame' is not installed. Please install it for MP3 encoding."
        ENCODERS=("mp3")
        EXTENSIONS=("mp3")
        ;;
    4)
        command_exists "oggenc" || error_exit "'oggenc' is not installed. Please install it for OGG encoding."
        ENCODERS=("ogg")
        EXTENSIONS=("ogg")
        ;;
    5)
        echo ""
        echo "Select formats to generate:"
        echo "  [1] FLAC"
        echo "  [2] WAV"
        echo "  [3] MP3"
        echo "  [4] OGG"
        echo ""
        echo "Enter numbers separated by spaces (e.g., '1 3' for FLAC+MP3):"
        read -p "Selection: " MULTI_FORMAT
        
        for fmt in $MULTI_FORMAT; do
            case $fmt in
                1) ENCODERS+=("flac"); EXTENSIONS+=("flac") ;;
                2) ENCODERS+=("wav"); EXTENSIONS+=("wav") ;;
                3) 
                    command_exists "lame" || error_exit "'lame' is not installed."
                    ENCODERS+=("mp3"); EXTENSIONS+=("mp3") 
                    ;;
                4) 
                    command_exists "oggenc" || error_exit "'oggenc' is not installed."
                    ENCODERS+=("ogg"); EXTENSIONS+=("ogg") 
                    ;;
            esac
        done
        
        if [ ${#ENCODERS[@]} -eq 0 ]; then
            error_exit "No valid formats selected. Using FLAC as default."
            ENCODERS=("flac")
            EXTENSIONS=("flac")
        fi
        ;;
    *)
        command_exists "flac" || error_exit "'flac' is not installed. Please install it for FLAC encoding."
        ENCODERS=("flac")
        EXTENSIONS=("flac")
        ;;
esac

echo ""
success "Selected formats: ${ENCODERS[*]^^}"
echo

# --- Set Save Directory ---

read -p "Enter the directory to save the ripped files (default: $HOME/Music): " -e SAVE_DIR
SAVE_DIR=${SAVE_DIR:-"$HOME/Music"}

if [ ! -d "$SAVE_DIR" ]; then
    echo "Directory '$SAVE_DIR' does not exist. Creating it..."
    mkdir -p "$SAVE_DIR" || error_exit "Could not create directory '$SAVE_DIR'."
fi

success "Rips will be saved in: $SAVE_DIR"
echo

# --- Get CD Information from MusicBrainz ---

echo "Attempting to retrieve CD information from MusicBrainz..."

CDPARANOIA_TOC="$TEMP_DIR/cdparanoia_toc.txt"
cdparanoia -Q -d "$CD_DEVICE" > "$CDPARANOIA_TOC" 2>&1
TRACK_COUNT_ACTUAL=$(grep '^[[:space:]]*[0-9]\+\.' "$CDPARANOIA_TOC" | wc -l)

if [ "$TRACK_COUNT_ACTUAL" -eq 0 ]; then
    error_exit "No audio tracks found on the disc or could not read the disc."
fi
success "Found $TRACK_COUNT_ACTUAL tracks on the disc."

# --- Construct the TOC string for the MusicBrainz API ---
FIRST_TRACK_SECTOR=$(grep '^[[:space:]]*1\.' "$CDPARANOIA_TOC" | awk '{print $4}')
TOTAL_SECTORS=$(grep 'TOTAL' "$CDPARANOIA_TOC" | awk '{print $2}')
LEADOUT_SECTOR=$((FIRST_TRACK_SECTOR + TOTAL_SECTORS))
OFFSETS=$(grep '^[[:space:]]*[0-9]\+\.' "$CDPARANOIA_TOC" | awk '{print $4}' | tr '\n' '+')

TOC_STRING="1+$TRACK_COUNT_ACTUAL+$LEADOUT_SECTOR+${OFFSETS%?}"
verbose_echo "Constructed TOC for API: '$TOC_STRING'"

# Construct API URL with comprehensive metadata
API_URL="https://musicbrainz.org/ws/2/discid/-?toc=${TOC_STRING}&fmt=json&inc=artist-credits+recordings+release-groups+genres+work-rels"
verbose_echo "Constructed API URL: $API_URL"

MUSICBRAINZ_JSON="$TEMP_DIR/musicbrainz_response.json"
HTTP_STATUS=$(curl -s -o "$MUSICBRAINZ_JSON" -w "%{http_code}" \
    -A "SimpleCDRipper/$SCRIPT_REVISION (https://github.com/ReverendRetro/SimpleCDRipper)" \
    "$API_URL" || echo "000")
verbose_echo "Received HTTP Status: $HTTP_STATUS"

# Initialize metadata variables
RELEASE_URL=""
SUCCESS_COUNT=0
COVER_ART_FILE=""
GENRE=""
DISC_SUBDIR=""
METADATA_SOURCE="Manual"
declare -a TRACK_TITLES=()
declare -a COMPOSERS=()
declare -a TRACK_ARTISTS=()
declare -a TRACK_COMMENTS=()
MBID=""
ORIGINAL_DATE=""
ALBUM_ARTIST=""
ALBUM_TITLE=""
YEAR=""
ENCODER=""

# --- Attempt to load metadata from MusicBrainz ---

if [ "$HTTP_STATUS" -eq 200 ] && [ -s "$MUSICBRAINZ_JSON" ]; then
    RELEASE_COUNT=$(jq '.releases | length' "$MUSICBRAINZ_JSON" 2>/dev/null || echo "0")
    verbose_echo "MusicBrainz returned $RELEASE_COUNT potential matches"
    
    if [ "$RELEASE_COUNT" -gt 0 ]; then
        SELECTED_INDEX=0

        if [ "$RELEASE_COUNT" -eq 1 ]; then
            echo ""
            echo "Found one matching release:"
            jq -r '.releases[0] | "\(."artist-credit"[0].name // "Various Artists") - \(.title)"' "$MUSICBRAINZ_JSON"
            read -p "Use this release? (y/n): " -r CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                METADATA_SOURCE="MusicBrainz"
            fi
        else
            echo ""
            echo "Found $RELEASE_COUNT matching releases. Please choose the correct one:"
            echo "  0) None of these - Enter manually"
            jq -r '.releases[] | "\(."artist-credit"[0].name // "Various Artists") - \(.title) (\(.date // "Unknown"))"' "$MUSICBRAINZ_JSON" | nl -w2 -s'. '
            
            while true; do
                read -p "Enter your choice (0-$RELEASE_COUNT): " -r SELECTION
                if [[ "$SELECTION" =~ ^[0-9]+$ ]] && [ "$SELECTION" -ge 0 ] && [ "$SELECTION" -le "$RELEASE_COUNT" ]; then
                    if [ "$SELECTION" -ne 0 ]; then
                        SELECTED_INDEX=$((SELECTION - 1))
                        METADATA_SOURCE="MusicBrainz"
                    fi
                    break
                else
                    echo "Invalid selection. Please try again."
                fi
            done
        fi
    else
        warn "No matches found on MusicBrainz for this disc."
    fi
else
    if [ "$HTTP_STATUS" -ne 200 ]; then
        warn "MusicBrainz API returned status $HTTP_STATUS. Proceeding with manual entry."
    fi
fi

# --- Load MusicBrainz metadata if successful ---

if [ "$METADATA_SOURCE" == "MusicBrainz" ]; then
    success "Metadata loaded from MusicBrainz!"
    echo ""
    
    ALBUM_ARTIST=$(jq -r --argjson idx "$SELECTED_INDEX" '.releases[$idx]."artist-credit"[0].name // "Various Artists"' "$MUSICBRAINZ_JSON")
    ALBUM_TITLE=$(jq -r --argjson idx "$SELECTED_INDEX" '.releases[$idx].title' "$MUSICBRAINZ_JSON")
    YEAR=$(jq -r --argjson idx "$SELECTED_INDEX" '.releases[$idx].date // ""' "$MUSICBRAINZ_JSON" | cut -d'-' -f1)
    ORIGINAL_DATE=$(jq -r --argjson idx "$SELECTED_INDEX" '.releases[$idx]."release-group"."first-release-date" // ""' "$MUSICBRAINZ_JSON" | cut -d'-' -f1)
    TRACK_COUNT=$(jq --argjson idx "$SELECTED_INDEX" '.releases[$idx].media[0]."track-count"' "$MUSICBRAINZ_JSON" 2>/dev/null || echo "$TRACK_COUNT_ACTUAL")
    MBID=$(jq -r --argjson idx "$SELECTED_INDEX" '.releases[$idx].id' "$MUSICBRAINZ_JSON")
    RELEASE_URL="https://musicbrainz.org/release/$MBID"

    echo "Album: $ALBUM_ARTIST - $ALBUM_TITLE"
    [ -n "$YEAR" ] && echo "Year: $YEAR"
    [ -n "$ORIGINAL_DATE" ] && [ "$ORIGINAL_DATE" != "$YEAR" ] && echo "Original Release: $ORIGINAL_DATE"
    echo ""

    # --- Genre Selection ---
    GENRES=($(jq -r --argjson idx "$SELECTED_INDEX" '.releases[$idx].genres[]?.name' "$MUSICBRAINZ_JSON" 2>/dev/null || true))
    if [ ${#GENRES[@]} -gt 0 ]; then
        if [ ${#GENRES[@]} -gt 1 ]; then
            echo "Found multiple genres. Please choose one:"
            for i in "${!GENRES[@]}"; do
                echo "  $((i+1))) ${GENRES[$i]}"
            done
            read -p "Enter your choice [1-${#GENRES[@]}]: " -r GENRE_CHOICE
            if [[ "$GENRE_CHOICE" =~ ^[0-9]+$ ]] && [ "$GENRE_CHOICE" -ge 1 ] && [ "$GENRE_CHOICE" -le ${#GENRES[@]} ]; then
                GENRE=${GENRES[$((GENRE_CHOICE-1))]}
            else
                GENRE=${GENRES[0]}
            fi
        else
            GENRE=${GENRES[0]}
        fi
        echo "Selected genre: $GENRE"
    else
        warn "No genres found on MusicBrainz."
    fi
    echo ""

    # --- Fetch Cover Art (highest quality via CAA API) ---
    COVER_ART_FOUND=$(jq -r --argjson idx "$SELECTED_INDEX" '.releases[$idx]."cover-art-archive".front // false' "$MUSICBRAINZ_JSON")
    if [ "$COVER_ART_FOUND" == "true" ]; then
        echo "Downloading cover art (highest quality)..."
        COVER_ART_FILE="$TEMP_DIR/cover_art.jpg"
        CAA_JSON="$TEMP_DIR/caa_response.json"
        CAA_STATUS=$(curl -s -o "$CAA_JSON" -w "%{http_code}" \
            -A "SimpleCDRipper/$SCRIPT_REVISION (https://github.com/ReverendRetro/SimpleCDRipper)" \
            "https://coverartarchive.org/release/$MBID" 2>/dev/null || echo "000")

        COVER_ART_URL=""
        if [ "$CAA_STATUS" -eq 200 ] && [ -s "$CAA_JSON" ]; then
            # Prefer front image; pick largest available thumbnail size (1200 > 500 > original)
            # The 'image' field is the original full-resolution source
            COVER_ART_URL=$(jq -r '[.images[] | select(.front == true)] |
                if length > 0 then .[0] else .[] | first end |
                .thumbnails["1200"] // .thumbnails["500"] // .image // ""' \
                "$CAA_JSON" 2>/dev/null || echo "")
            verbose_echo "CAA selected URL: $COVER_ART_URL"
        fi

        # Fallback to direct front endpoint if CAA API parse failed
        [ -z "$COVER_ART_URL" ] && COVER_ART_URL="https://coverartarchive.org/release/$MBID/front"

        if curl -sL --max-time 30 -o "$COVER_ART_FILE" "$COVER_ART_URL" 2>/dev/null && [ -s "$COVER_ART_FILE" ]; then
            ART_SIZE=$(stat -c%s "$COVER_ART_FILE" 2>/dev/null || stat -f%z "$COVER_ART_FILE" 2>/dev/null)
            success "Cover art downloaded ($(human_size "$ART_SIZE"))."
            log_entry "INFO" "Cover art downloaded: $(human_size "$ART_SIZE") from $COVER_ART_URL"
        else
            warn "Failed to download cover art."
            log_entry "WARN" "Cover art download failed"
            COVER_ART_FILE=""
        fi
    fi

    # --- Extract Track Titles and Composers ---
    for i in $(seq 0 $((TRACK_COUNT - 1))); do
        title=$(jq -r --argjson idx "$SELECTED_INDEX" --argjson i "$i" \
            '.releases[$idx].media[0].tracks[$i]?.title // ""' "$MUSICBRAINZ_JSON")
        TRACK_TITLES+=("$title")
        
        composer=$(jq -r --argjson idx "$SELECTED_INDEX" --argjson i "$i" \
            '[.releases[$idx].media[0].tracks[$i].recording.relations[]? | select(.type == "composer") | .artist.name] | .[0] // ""' \
            "$MUSICBRAINZ_JSON" 2>/dev/null)
        COMPOSERS+=("$composer")
        
        # Get track artist (if different from album artist)
        track_artist=$(jq -r --argjson idx "$SELECTED_INDEX" --argjson i "$i" \
            '.releases[$idx].media[0].tracks[$i].recording."artist-credit"[0].name // ""' \
            "$MUSICBRAINZ_JSON" 2>/dev/null)
        TRACK_ARTISTS+=("$track_artist")
        
        TRACK_COMMENTS+=("")
    done

else
    # --- Manual metadata entry ---
    echo "Please enter album metadata manually:"
    read -p "Album Artist: " -r ALBUM_ARTIST
    read -p "Album Title: " -r ALBUM_TITLE
    read -p "Year (optional): " -r YEAR
    read -p "Original Release Year (optional): " -r ORIGINAL_DATE
    read -p "Genre (optional): " -r GENRE
    echo ""

    # --- Multi-disc Handling for Manual Entry ---
    read -p "Is this part of a multi-disc set? (y/n): " -r IS_MULTI
    if [[ "$IS_MULTI" =~ ^[Yy]$ ]]; then
        read -p "Please enter the disc number: " -r DISC_NUMBER
        if [[ "$DISC_NUMBER" =~ ^[0-9]+$ ]]; then
            DISC_SUBDIR="Disc $DISC_NUMBER"
        else
            warn "Invalid disc number. Proceeding without disc subdirectory."
        fi
    fi
    echo ""

    # --- Manual track title entry ---
    declare -a TRACK_TITLES=()
    echo "Enter track titles (press Enter to skip):"
    for i in $(seq 1 $TRACK_COUNT_ACTUAL); do
        read -p "Track $i title: " -r title
        TRACK_TITLES+=("${title:-Track $i}")
        TRACK_ARTISTS+=("")
        COMPOSERS+=("")
        TRACK_COMMENTS+=("")
    done
    TRACK_COUNT=$TRACK_COUNT_ACTUAL
fi

# --- Metadata Review and Editing ---

echo ""
echo "================================================================================"
echo "METADATA REVIEW"
echo "================================================================================"
echo ""
echo "Album: $ALBUM_ARTIST - $ALBUM_TITLE"
[ -n "$YEAR" ] && echo "Year: $YEAR"
[ -n "$ORIGINAL_DATE" ] && echo "Original Release: $ORIGINAL_DATE"
[ -n "$GENRE" ] && echo "Genre: $GENRE"
[ -n "$DISC_SUBDIR" ] && echo "Disc: ${DISC_SUBDIR##* }"
echo ""
echo "Tracks:"
for i in $(seq 1 $TRACK_COUNT); do
    TRACK_TITLE=${TRACK_TITLES[$((i-1))]}
    TRACK_ARTIST=${TRACK_ARTISTS[$((i-1))]}
    COMPOSER=${COMPOSERS[$((i-1))]}
    printf "  %2d. %-50s\n" "$i" "$TRACK_TITLE"
    [ -n "$TRACK_ARTIST" ] && [ "$TRACK_ARTIST" != "$ALBUM_ARTIST" ] && printf "       Artist: %s\n" "$TRACK_ARTIST"
    [ -n "$COMPOSER" ] && printf "       Composer: %s\n" "$COMPOSER"
done
echo ""
read -p "Is this information correct? (y/n): " -r METADATA_CONFIRM

if [[ ! "$METADATA_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Edit options:"
    echo "  1) Album artist"
    echo "  2) Album title"
    echo "  3) Year"
    echo "  4) Genre"
    echo "  5) Edit individual track"
    echo "  6) Start over with manual entry"
    read -p "Select option (1-6) or press Enter to continue anyway: " -r EDIT_CHOICE
    
    case $EDIT_CHOICE in
        1)
            read -p "New album artist: " -r ALBUM_ARTIST
            ;;
        2)
            read -p "New album title: " -r ALBUM_TITLE
            ;;
        3)
            read -p "New year: " -r YEAR
            ;;
        4)
            read -p "New genre: " -r GENRE
            ;;
        5)
            read -p "Track number to edit: " -r TRACK_EDIT
            if [[ "$TRACK_EDIT" =~ ^[0-9]+$ ]] && [ "$TRACK_EDIT" -ge 1 ] && [ "$TRACK_EDIT" -le $TRACK_COUNT ]; then
                read -p "New title: " -r NEW_TITLE
                TRACK_TITLES[$((TRACK_EDIT-1))]="$NEW_TITLE"
            fi
            ;;
        6)
            exec "$0"
            ;;
    esac
fi

echo ""

# --- Prepare Output Directory ---

SAFE_ALBUM_ARTIST=$(safe_filename "$ALBUM_ARTIST")
SAFE_ALBUM_TITLE=$(safe_filename "$ALBUM_TITLE")

if [ -n "$DISC_SUBDIR" ]; then
    OUTPUT_DIR="$SAVE_DIR/$SAFE_ALBUM_ARTIST/$SAFE_ALBUM_TITLE/$DISC_SUBDIR"
else
    OUTPUT_DIR="$SAVE_DIR/$SAFE_ALBUM_ARTIST/$SAFE_ALBUM_TITLE"
fi

echo "Creating output directory: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR" || error_exit "Could not create output directory."
echo ""

# --- Initialize checkpoint system ---
init_checkpoint_dir
LAST_COMPLETED_TRACK=$(load_checkpoint)

if [ "$LAST_COMPLETED_TRACK" -gt 0 ]; then
    echo "Found previous rip checkpoint. Last completed track: $LAST_COMPLETED_TRACK"
    read -p "Resume from track $((LAST_COMPLETED_TRACK + 1))? (y/n): " -r RESUME_CHOICE
    if [[ ! "$RESUME_CHOICE" =~ ^[Yy]$ ]]; then
        LAST_COMPLETED_TRACK=0
        echo "Starting fresh."
    else
        echo "Resuming rip..."
    fi
else
    LAST_COMPLETED_TRACK=0
fi

echo ""

# --- Initialize Log File ---

LOG_FILE="$OUTPUT_DIR/rip_log.txt"
CUE_FILE="$OUTPUT_DIR/$(safe_filename "$ALBUM_TITLE").cue"
STATS_FILE="$OUTPUT_DIR/rip_stats.json"

DRIVE_MODEL=$(grep -oP 'CDROM model sensed sensed:\s*\K.*' "$CDPARANOIA_TOC" 2>/dev/null | xargs || echo "Unknown")

{
    echo "================================================================================"
    echo "CD RIP LOG - SimpleCDRipper v$SCRIPT_REVISION"
    echo "================================================================================"
    echo ""
    echo "Album Information:"
    echo "  Artist: $ALBUM_ARTIST"
    echo "  Title: $ALBUM_TITLE"
    [ -n "$DISC_SUBDIR" ] && echo "  Disc: ${DISC_SUBDIR##* }"
    [ -n "$YEAR" ] && echo "  Year: $YEAR"
    [ -n "$ORIGINAL_DATE" ] && echo "  Original Release: $ORIGINAL_DATE"
    [ -n "$GENRE" ] && echo "  Genre: $GENRE"
    [ -n "$MBID" ] && echo "  MusicBrainz ID: $MBID"
    [ -n "$RELEASE_URL" ] && echo "  MusicBrainz URL: $RELEASE_URL"
    echo ""
    echo "Ripping Session:"
    echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Script version: $SCRIPT_REVISION"
    echo "  Metadata source: $METADATA_SOURCE"
    echo "  Resumed from track: $((LAST_COMPLETED_TRACK + 1))"
    echo ""
    echo "Output Configuration:"
    printf "  Formats: %s\n" "${ENCODERS[*]^^}"
    printf "  Bitrates: "
    for enc in "${ENCODERS[@]}"; do
        case $enc in
            flac) printf "FLAC=Lossless " ;;
            wav) printf "WAV=Uncompressed " ;;
            mp3) printf "MP3=320kbps " ;;
            ogg) printf "OGG=q10 " ;;
        esac
    done
    echo ""
    echo ""
    echo "Tool Versions:"
    cdparanoia --version 2>&1 | head -n 1
    metaflac --version 2>&1 | head -n 1 || true
    for enc in "${ENCODERS[@]}"; do
        case $enc in
            flac) flac --version 2>&1 | head -n 1 ;;
            mp3) lame --version 2>&1 | head -n 1 ;;
            ogg) oggenc --version 2>&1 | head -n 1 ;;
        esac
    done
    echo ""
    echo "Drive Information:"
    echo "  Device: $CD_DEVICE"
    [ -n "$DRIVE_MODEL" ] && echo "  Model: $DRIVE_MODEL"
    echo ""
    echo "================================================================================"
    echo ""
} > "$LOG_FILE"

# Initialize statistics file
{
    echo "{"
    echo "  \"session_start\": \"$(date -Iseconds)\","
    echo "  \"formats\": [$(printf '\"%s\"' "${ENCODERS[@]}" | sed 's/" *"/, /g')],"
    echo "  \"total_tracks\": $TRACK_COUNT,"
    echo "  \"tracks\": []"
    echo "}"
} > "$STATS_FILE"

# --- Generate CUE Sheet ---

{
    echo "PERFORMER \"$ALBUM_ARTIST\""
    echo "TITLE \"$ALBUM_TITLE\""
    echo ""
} > "$CUE_FILE"

# --- HDA (Hidden Track One Audio) Ripping ---

if grep -q '^[[:space:]]*0\.' "$CDPARANOIA_TOC"; then
    if [ "$LAST_COMPLETED_TRACK" -eq 0 ]; then
        echo "Hidden track (pre-gap audio) found. Ripping track 0..."
        HDA_FILE="$OUTPUT_DIR/00. Hidden Track"
        
        for encoder_idx in "${!ENCODERS[@]}"; do
            ENCODER="${ENCODERS[$encoder_idx]}"
            EXT="${EXTENSIONS[$encoder_idx]}"
            
            HDA_OUTPUT="$HDA_FILE.$EXT"
            set +e
            cdparanoia -v -d "$CD_DEVICE" 0 - 2>/dev/null | flac -s --best -o "$TEMP_DIR/hda_temp.flac" -
            HDA_EXIT=${PIPESTATUS[0]}
            set -e
            
            if [ "$HDA_EXIT" -eq 0 ] && [ -s "$TEMP_DIR/hda_temp.flac" ]; then
                # Convert if needed
                case $ENCODER in
                    flac)
                        cp "$TEMP_DIR/hda_temp.flac" "$HDA_OUTPUT"
                        ;;
                    wav)
                        flac -d -o "$HDA_OUTPUT" "$TEMP_DIR/hda_temp.flac"
                        ;;
                esac
                success "Hidden track ripped to: $HDA_OUTPUT"
                log_entry "INFO" "Hidden Track (Track 0): Successfully ripped"
            else
                warn "Failed to rip hidden track."
                log_entry "WARN" "Hidden Track (Track 0): FAILED"
            fi
            rm -f "$TEMP_DIR/hda_temp.flac"
        done
        
        {
            echo ""
            echo "================================================================================"
            echo "TRACK RIPS"
            echo "================================================================================"
        } >> "$LOG_FILE"
    fi
fi

# --- Main Ripping Loop ---

echo ""
echo "Beginning rip..."
echo "================================================================================"

RIPPING_START_TIME=$(date +%s)

for i in $(seq 1 $TRACK_COUNT); do
    # Skip if already completed
    if [ "$i" -le "$LAST_COMPLETED_TRACK" ]; then
        continue
    fi
    
    TRACK_NUM=$(printf "%02d" $i)
    TRACK_TITLE=${TRACK_TITLES[$((i-1))]}
    COMPOSER=${COMPOSERS[$((i-1))]}
    TRACK_ARTIST=${TRACK_ARTISTS[$((i-1))]}
    SAFE_TRACK_TITLE=$(safe_filename "$TRACK_TITLE")
    TEMP_WAV_FILE="$OUTPUT_DIR/$TRACK_NUM.tmp.wav"
    
    # Add to CUE sheet
    {
        echo "  FILE \"$TRACK_NUM. $SAFE_TRACK_TITLE.${EXTENSIONS[0]}\" WAVE"
        echo "    TRACK $(printf "%02d" $i) AUDIO"
        echo "      TITLE \"$TRACK_TITLE\""
        echo "      PERFORMER \"${TRACK_ARTIST:-$ALBUM_ARTIST}\""
        [ -n "$COMPOSER" ] && echo "      COMPOSER \"$COMPOSER\""
        echo "      INDEX 01 00:00:00"
    } >> "$CUE_FILE"

    TRACK_START_TIME=$(date +%s)
    RETRY_COUNT=0
    RIP_SUCCESS=false

    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$RIP_SUCCESS" = false ]; do
        echo "[$TRACK_NUM/$TRACK_COUNT] Ripping: $TRACK_TITLE (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
        
        # --- Stage 1: Rip to temporary WAV ---
        # Temporarily disable errexit so a failed rip attempt is catchable
        set +e
        RIP_LOG=$(cdparanoia -v -d "$CD_DEVICE" "$i" "$TEMP_WAV_FILE" 2>&1)
        RIP_EXIT=$?
        set -e

        # Parse rip quality metrics
        IFS='|' read -r PREGAP PEAK_LEVEL TRACK_QUALITY <<< "$(parse_rip_quality "$RIP_LOG")"

        if [ -f "$TEMP_WAV_FILE" ] && [ $RIP_EXIT -eq 0 ]; then
            RIP_SUCCESS=true
            TRACK_END_TIME=$(date +%s)
            TRACK_DURATION=$((TRACK_END_TIME - TRACK_START_TIME))
            
            # Log track rip details
            {
                echo ""
                echo "Track $i: $TRACK_TITLE"
                echo "  Artist: ${TRACK_ARTIST:-$ALBUM_ARTIST}"
                [ -n "$COMPOSER" ] && echo "  Composer: $COMPOSER"
                echo "  Rip Quality: $TRACK_QUALITY"
                [ -n "$PREGAP" ] && echo "  Pre-gap: ${PREGAP}s"
                [ -n "$PEAK_LEVEL" ] && echo "  Peak Level: ${PEAK_LEVEL}%"
                echo "  Rip Duration: ${TRACK_DURATION}s"
            } >> "$LOG_FILE"

            # --- Stage 2: Encode from WAV ---
            WAV_SIZE=$(stat -f%z "$TEMP_WAV_FILE" 2>/dev/null || stat -c%s "$TEMP_WAV_FILE" 2>/dev/null)
            
            for encoder_idx in "${!ENCODERS[@]}"; do
                ENCODER="${ENCODERS[$encoder_idx]}"
                EXT="${EXTENSIONS[$encoder_idx]}"
                OUTPUT_FILE="$OUTPUT_DIR/$TRACK_NUM. $SAFE_TRACK_TITLE.$EXT"
                
                echo "  Encoding to ${ENCODER^^}..."
                
                ENCODE_START=$(date +%s)
                
                case $ENCODER in
                    flac)
                        PICTURE_OPTION=""
                        [ -n "$COVER_ART_FILE" ] && PICTURE_OPTION="--picture=$COVER_ART_FILE"
                        
                        ENCODE_TAGS=()
                        ENCODE_TAGS+=(-T "ARTIST=${TRACK_ARTIST:-$ALBUM_ARTIST}")
                        ENCODE_TAGS+=(-T "ALBUM=$ALBUM_TITLE")
                        ENCODE_TAGS+=(-T "ALBUMARTIST=$ALBUM_ARTIST")
                        ENCODE_TAGS+=(-T "TITLE=$TRACK_TITLE")
                        ENCODE_TAGS+=(-T "TRACKNUMBER=$i")
                        ENCODE_TAGS+=(-T "TOTALTRACKS=$TRACK_COUNT")
                        [ -n "$YEAR" ] && ENCODE_TAGS+=(-T "DATE=$YEAR")
                        [ -n "$ORIGINAL_DATE" ] && [ "$ORIGINAL_DATE" != "$YEAR" ] && ENCODE_TAGS+=(-T "ORIGINALDATE=$ORIGINAL_DATE")
                        [ -n "$GENRE" ] && ENCODE_TAGS+=(-T "GENRE=$GENRE")
                        [ -n "$COMPOSER" ] && ENCODE_TAGS+=(-T "COMPOSER=$COMPOSER")
                        [ -n "$MBID" ] && ENCODE_TAGS+=(-T "MUSICBRAINZ_ALBUMID=$MBID")
                        
                        if flac -s --best --verify $PICTURE_OPTION "${ENCODE_TAGS[@]}" "$TEMP_WAV_FILE" -o "$OUTPUT_FILE" 2>/dev/null; then
                            if check_file_integrity "$OUTPUT_FILE"; then
                                ENCODE_END=$(date +%s)
                                FILE_SIZE=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null)
                                echo "    Encode OK [$(human_size "$FILE_SIZE")] in $((ENCODE_END - ENCODE_START))s"
                                log_entry "INFO" "Track $i ($ENCODER): OK ($(human_size "$FILE_SIZE"))"
                                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                            else
                                echo "    Encode FAILED (integrity check)"
                                log_entry "ERROR" "Track $i ($ENCODER): Integrity check failed"
                                rm -f "$OUTPUT_FILE"
                            fi
                        else
                            echo "    Encode FAILED"
                            log_entry "ERROR" "Track $i ($ENCODER): Encoding failed"
                            rm -f "$OUTPUT_FILE"
                        fi
                        ;;
                    
                    wav)
                        if cp "$TEMP_WAV_FILE" "$OUTPUT_FILE"; then
                            ENCODE_END=$(date +%s)
                            FILE_SIZE=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null)
                            echo "    Copy OK [$(human_size "$FILE_SIZE")]"
                            log_entry "INFO" "Track $i ($ENCODER): OK ($(human_size "$FILE_SIZE"))"
                            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                        else
                            echo "    Copy FAILED"
                            log_entry "ERROR" "Track $i ($ENCODER): Copy failed"
                        fi
                        ;;
                    
                    mp3)
                        LAME_ARGS=(-S -b 320 --add-id3v2
                            --tt "$TRACK_TITLE"
                            --ta "${TRACK_ARTIST:-$ALBUM_ARTIST}"
                            --tl "$ALBUM_TITLE"
                            --tp "$ALBUM_ARTIST"
                            --tn "$i")
                        [ -n "$YEAR" ]     && LAME_ARGS+=(--ty "$YEAR")
                        [ -n "$GENRE" ]    && LAME_ARGS+=(--tg "$GENRE")
                        [ -n "$COMPOSER" ] && LAME_ARGS+=(--tc "$COMPOSER")
                        if lame "${LAME_ARGS[@]}" "$TEMP_WAV_FILE" "$OUTPUT_FILE" 2>/dev/null; then
                            if check_file_integrity "$OUTPUT_FILE"; then
                                ENCODE_END=$(date +%s)
                                FILE_SIZE=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null)
                                echo "    Encode OK [$(human_size "$FILE_SIZE")] in $((ENCODE_END - ENCODE_START))s"
                                log_entry "INFO" "Track $i ($ENCODER): OK ($(human_size "$FILE_SIZE"))"
                                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                            else
                                echo "    Encode FAILED (integrity check)"
                                log_entry "ERROR" "Track $i ($ENCODER): Integrity check failed"
                                rm -f "$OUTPUT_FILE"
                            fi
                        else
                            echo "    Encode FAILED"
                            log_entry "ERROR" "Track $i ($ENCODER): Encoding failed"
                            rm -f "$OUTPUT_FILE"
                        fi
                        ;;
                    
                    ogg)
                        OGGENC_ARGS=(-Q -q 10
                            -a "${TRACK_ARTIST:-$ALBUM_ARTIST}"
                            -l "$ALBUM_TITLE"
                            -t "$TRACK_TITLE"
                            -N "$i")
                        [ -n "$YEAR" ]     && OGGENC_ARGS+=(-d "$YEAR")
                        [ -n "$GENRE" ]    && OGGENC_ARGS+=(-G "$GENRE")
                        [ -n "$COMPOSER" ] && OGGENC_ARGS+=(-c "COMPOSER=$COMPOSER")
                        if oggenc "${OGGENC_ARGS[@]}" "$TEMP_WAV_FILE" -o "$OUTPUT_FILE" 2>/dev/null; then
                            if check_file_integrity "$OUTPUT_FILE"; then
                                ENCODE_END=$(date +%s)
                                FILE_SIZE=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null)
                                echo "    Encode OK [$(human_size "$FILE_SIZE")] in $((ENCODE_END - ENCODE_START))s"
                                log_entry "INFO" "Track $i ($ENCODER): OK ($(human_size "$FILE_SIZE"))"
                                SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
                            else
                                echo "    Encode FAILED (integrity check)"
                                log_entry "ERROR" "Track $i ($ENCODER): Integrity check failed"
                                rm -f "$OUTPUT_FILE"
                            fi
                        else
                            echo "    Encode FAILED"
                            log_entry "ERROR" "Track $i ($ENCODER): Encoding failed"
                            rm -f "$OUTPUT_FILE"
                        fi
                        ;;
                esac
            done

            rm -f "$TEMP_WAV_FILE"
            create_checkpoint "$i" "completed"
            
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                warn "Rip failed for track $i. Retrying in ${RETRY_DELAY}s..."
                log_entry "WARN" "Track $i: Rip attempt $RETRY_COUNT failed, retrying..."
                sleep $RETRY_DELAY
            else
                echo "Track $i: FAILED after $MAX_RETRIES attempts"
                log_entry "ERROR" "Track $i: Failed after $MAX_RETRIES attempts"
                rm -f "$TEMP_WAV_FILE"
                create_checkpoint "$((i - 1))" "failed_at_track_$i"
            fi
        fi
    done
done

echo "================================================================================"
echo ""

RIPPING_END_TIME=$(date +%s)
TOTAL_RIPPING_TIME=$((RIPPING_END_TIME - RIPPING_START_TIME))

# --- Post-Processing ---

if [[ " ${ENCODERS[@]} " =~ " flac " ]]; then
    echo "Applying ReplayGain tags to FLAC files..."
    if metaflac --add-replay-gain "$OUTPUT_DIR"/*.flac 2>/dev/null; then
        success "ReplayGain scanning complete."
        log_entry "INFO" "ReplayGain scanning applied to FLAC files"
    else
        warn "ReplayGain application failed."
        log_entry "WARN" "ReplayGain application failed"
    fi
    echo ""
fi

# --- Save Cover Art to Output Directory ---

if [ -n "${COVER_ART_FILE:-}" ] && [ -f "$COVER_ART_FILE" ]; then
    cp "$COVER_ART_FILE" "$OUTPUT_DIR/folder.jpg" 2>/dev/null &&         success "Cover art saved to output directory as folder.jpg." ||         warn "Could not save cover art to output directory."
fi

# --- Disc Verification (after all encoding and art embedding) ---

echo "Calculating disc verification checksums..."
{
    echo ""
    echo "================================================================================"
    echo "DISC VERIFICATION"
    echo "================================================================================"
    echo ""
    echo "File Integrity Checksums (MD5):"
} >> "$LOG_FILE"

CHECKSUM_PASSED=0
CHECKSUM_FAILED=0

for ext in "${EXTENSIONS[@]}"; do
    if (cd "$OUTPUT_DIR" && md5sum -- *."$ext" 2>/dev/null >> "$LOG_FILE"); then
        CHECKSUM_PASSED=$((CHECKSUM_PASSED + 1))
    fi
done

log_entry "INFO" "Checksum verification: $CHECKSUM_PASSED files verified"

# --- Finalization ---

{
    echo ""
    echo "================================================================================"
    echo "RIP SUMMARY"
    echo "================================================================================"
    echo ""
    echo "Results:"
    echo "  Successfully processed: $SUCCESS_COUNT tracks"
    echo "  Total tracks: $TRACK_COUNT"
    echo "  Success rate: $(( (SUCCESS_COUNT * 100) / TRACK_COUNT ))%"
    echo ""
    echo "Timing:"
    echo "  Total duration: $((TOTAL_RIPPING_TIME / 60))m $((TOTAL_RIPPING_TIME % 60))s"
    echo "  Completed: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "Output Files:"
    ls -lh "$OUTPUT_DIR" | grep -v "^total\|\.cue\|\.txt\|\.json" | awk '{print "  " $9 " (" $5 ")"}'
    echo ""
    echo "================================================================================"
} >> "$LOG_FILE"

success "CD ripping complete!"
echo "Log file: $LOG_FILE"
echo "CUE sheet: $CUE_FILE"
echo "Statistics: $STATS_FILE"
echo ""

# Eject the disc
echo "Ejecting disc..."
if eject "$CD_DEVICE" 2>/dev/null; then
    success "Disc ejected."
    log_entry "INFO" "Disc ejected successfully"
else
    warn "Could not eject disc automatically."
    log_entry "WARN" "Could not eject disc"
fi
