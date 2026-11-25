#!/usr/bin/env bash
#
# media_transcode - batch-shrink large video files to HEVC (H.265) MKV
#
# Scans a directory tree for large video files and re-encodes them to HEVC,
# optionally downscaling. HDR10, HLG, HDR10+ and Dolby Vision sources are
# tone mapped to SDR BT.709 (libplacebo on the GPU through Vulkan, or zscale +
# tonemap on the CPU), and BT.2020 SDR sources are gamut mapped to BT.709.
# Set HDR_MODE=skip to leave them alone and log them instead. HDR metadata is
# never passed through: every output is SDR BT.709 or keeps its SDR tags.
#
# Run with no arguments for the interactive settings screen. For unattended
# runs (cron, systemd) pass flags or a saved profile plus --yes. See --help.

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'media_transcode: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

readonly VERSION="11"
readonly PROG=${0##*/}

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    printf '%s\n' "$PROG: bash 4.4 or newer is required." >&2
    exit 1
fi

# ===========================================================================
# Settings. Every key can come from a profile file, a CLI flag or the menu.
# ===========================================================================
SETTING_KEYS=(
    SCAN_DIR MIN_SIZE_GB ENCODER QUALITY MAX_HEIGHT BIT_DEPTH
    AUDIO AUDIO_CODEC ORIGINALS ARCHIVE_DIR OUTPUT_DIR OUTPUT_SUFFIX
    SCRATCH_DIR WIP_DIR SKIP_CODECS MAX_OUTPUT_PCT ORDER
    X265_PRESET X265_PARAMS NVENC_PRESET VAAPI_DEVICE HW_DECODE NICE EXTENSIONS
    HDR_MODE TONEMAP_BACKEND TONEMAP_CURVE
)
SCAN_DIR=""
MIN_SIZE_GB="20"
ENCODER="cpu"
QUALITY="15"
MAX_HEIGHT="720"
BIT_DEPTH="8"
AUDIO="copy"
AUDIO_CODEC="eac3"
ORIGINALS="move"
ARCHIVE_DIR=""
OUTPUT_DIR=""
OUTPUT_SUFFIX="_shrunk"
SCRATCH_DIR=""
WIP_DIR=""
SKIP_CODECS=""
MAX_OUTPUT_PCT="90"
ORDER="path"
X265_PRESET="slow"
X265_PARAMS="strong-intra-smoothing=0:rect=0:aq-mode=1:rd=4:psy-rd=0.75:psy-rdoq=4.0:rdoq-level=1:rskip=2"
NVENC_PRESET="p5"
VAAPI_DEVICE="/dev/dri/renderD128"
HW_DECODE="auto"
NICE="10"
EXTENSIONS="mkv mp4 m4v avi mov ts m2ts mts webm wmv mpg mpeg"
HDR_MODE="tonemap"
TONEMAP_BACKEND="auto"
TONEMAP_CURVE="auto"
readonly TONEMAP_CURVES="auto hable mobius reinhard bt.2390 spline"

# --- Runtime options (not saved in profiles) ---
DRY_RUN=0
ASSUME_YES=0
LIMIT=0
PROFILE_NAME="default"
EXPLICIT_PROFILE=0
CONFIG_FILE=""
SAVE_PROFILE=""
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/media_transcode"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/media_transcode"
RUN_LOG="$LOG_DIR/transcode.log"
FFLOG_DIR="$LOG_DIR/ffmpeg-logs"
readonly STATE_DIR_NAME=".media_transcode"
# Names from before the switch to underscores. Found ones are moved over.
OLD_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/media-transcode"
OLD_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/media-transcode"
readonly OLD_STATE_DIR_NAME=".media-transcode"
readonly HDR_LOG_NAME="_HDR_files_to_check.log"
readonly MARKER_TAG="MEDIA_TRANSCODE"

# --- Derived at run time ---
STATE_DIR=""; LOCK_DIR=""; NOGAIN_LIST=""; HDR_LOG=""
MIN_BYTES=0
HAVE_FLOCK=0
NICE_PREFIX=()
VIDEO_ENC=(); ATTEMPTS=(); SW_FMT=""; HW_FMT=""
FF_ENCODERS=""; FF_FILTERS=""
# Tone mapping, resolved once per run
TM_BACKEND=""; TM_REASON=""; TM_CURVE=""; TM_STRIP=""
ENC_HDR_ARGS=()
declare -A CLI_SET=()
declare -A P=()
FILES=(); SIZES=()
TOTAL=0

# --- Per-file state (used by the interrupt handler) ---
CUR_REL=""
CUR_PARTS=()
CLAIM_SRC=""; CLAIM_WIP=""
LOCK_FD=""; LOCK_FILE=""

# --- Probe results / messages ---
PR_SI=""; PR_VIDX=""; PR_VCODEC=""; PR_W=""; PR_H=""; PR_PIXFMT=""
PR_TRC=""; PR_PRIM=""; PR_SPACE=""; PR_RANGE=""; PR_HDR=""; PR_MARKER=""; PR_DUR_US=0
# PR_KIND: pq | hlg | dv-rpu (Dolby Vision with no HDR10/HLG base layer) |
# gamut (BT.2020 SDR) | unsure (BT.2020 with no transfer tag) | empty for SDR
PR_KIND=""
ORIG_MSG=""; VERIFY_MSG=""
# Per-file HDR decision
HDR_CONVERT=0; HDR_SKIP_WHY=""; TM_VF=""

# --- Counters ---
CNT_DONE=0; CNT_HDR=0; CNT_SKIP=0; CNT_NOGAIN=0; CNT_FAIL=0; CNT_DRY=0; CNT_TM=0
BYTES_IN=0; BYTES_OUT=0
FAILED_FILES=()
STARTED=0; STOP_REQUESTED=0; RUN_T0=0

# ===========================================================================
# Output helpers
# ===========================================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_CYN=$'\e[36m'
    C_DIM=$'\e[2m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_DIM=""; C_BLD=""; C_RST=""
fi

info() { printf '%s\n' "$*"; }
warn() { printf '%sWarning:%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%sError:%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }

log() {
    [ "$DRY_RUN" -ne 0 ] && return 0
    printf '%s [%s] %s\n' "$(date '+%F %T')" "$$" "$*" >> "$RUN_LOG" 2>/dev/null || true
}

rule() { printf '%s\n' "------------------------------------------------------------------------"; }

fmt_size() {
    local b=${1:-0} whole rem=0 u=0
    local units=(B KiB MiB GiB TiB)
    if [ "$b" -lt 0 ]; then printf -- '-'; b=$(( -b )); fi
    whole=$b
    while [ "$whole" -ge 1024 ] && [ "$u" -lt 4 ]; do
        rem=$(( whole % 1024 )); whole=$(( whole / 1024 )); u=$(( u + 1 ))
    done
    if [ "$u" -eq 0 ]; then printf '%d B' "$b"
    else printf '%d.%d %s' "$whole" $(( rem * 10 / 1024 )) "${units[u]}"; fi
}

fmt_hms() {
    local s=${1:-0}
    [ "$s" -lt 0 ] && s=0
    printf '%02d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
}

# "123.456789" seconds -> integer microseconds (0 if unparseable)
secs_to_us() {
    local v=${1:-} int frac
    if [[ $v =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
        int=${BASH_REMATCH[1]}
        frac="${BASH_REMATCH[3]}000000"; frac=${frac:0:6}
        printf '%s\n' "$(( 10#$int * 1000000 + 10#$frac ))"
    else
        printf '%s\n' 0
    fi
}

gib_to_bytes() { awk -v g="$1" 'BEGIN { printf "%.0f", g * 1073741824 }'; }

# ~ and ~/x expansion (no eval), strip trailing slash
expand_path() {
    local p=$1
    # shellcheck disable=SC2088  # comparing against a literal tilde on purpose
    if [[ $p == "~" || $p == "~/"* ]]; then p=$HOME${p:1}; fi
    [ "$p" != "/" ] && p=${p%/}
    printf '%s' "$p"
}

# Escape glob characters so a literal path can be used with find -path
glob_escape() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\*/\\*}; s=${s//\?/\\?}; s=${s//\[/\\[}
    printf '%s' "$s"
}

path_key() { printf '%s' "$1" | md5sum | cut -c1-16; }

# Free bytes on the filesystem holding $1. df -P is the POSIX one-line-per-
# filesystem format; %.0f keeps awk from switching to exponent notation.
free_bytes() {
    LC_ALL=C df -Pk -- "$1" 2>/dev/null | awk 'NR == 2 { printf "%.0f", $4 * 1024 }' || true
}

# Mount point holding $1, from df -P (fields 6 onward, so spaces survive)
mount_of() {
    LC_ALL=C df -P -- "$1" 2>/dev/null \
        | awk 'NR == 2 { m = $6; for (i = 7; i <= NF; i++) m = m " " $i; print m }' || true
}

# True when a rename between the two paths works without copying, which needs
# the same mount, not just the same filesystem
same_fs() {
    local a b
    a=$(mount_of "$1"); b=$(mount_of "$2")
    [ -n "$a" ] && [ "$a" = "$b" ]
}

# Size in bytes. GNU wc answers -c on a regular file from its metadata
# instead of reading it.
file_size() {
    local n
    n=$(wc -c < "$1" 2>/dev/null) || return 1
    printf '%s' "${n//[[:space:]]/}"
}

# Absolute path with symlinks resolved when it exists, else just made
# absolute. Stands in for GNU realpath -m.
canon_path() {
    local p=$1
    [[ $p == /* ]] || p="$PWD/$p"
    if [ -d "$p" ]; then
        (cd -P -- "$p" && pwd -P)
    else
        printf '%s' "$p"
    fi
}

enc_name() {
    case ${1:-$ENCODER} in
        cpu) printf '%s\n' libx265 ;; nvidia) printf '%s\n' hevc_nvenc ;; vaapi) printf '%s\n' hevc_vaapi ;; *) printf '%s\n' unknown ;;
    esac
}

quality_label() {
    case $ENCODER in cpu) printf '%s\n' CRF ;; nvidia) printf '%s\n' CQ ;; vaapi) printf '%s\n' QP ;; *) printf '%s\n' Q ;; esac
}

# ===========================================================================
# Usage
# ===========================================================================
usage() {
    cat <<EOF
Usage: $PROG [options]

Shrinks large video files to HEVC in MKV. HDR10, HLG, HDR10+ and Dolby Vision
files are tone mapped to SDR BT.709, BT.2020 SDR files are gamut mapped to
BT.709. Files that can't be converted safely are skipped and listed in
<scan dir>/$HDR_LOG_NAME.
With no options an interactive settings screen opens; settings can be saved
as named profiles.

Scan and selection
  -d, --dir DIR            Directory to scan (recursively)
  -m, --min-size GIB       Only files larger than this many GiB (decimals ok, 0 = all)
      --skip-codecs LIST   Skip sources already in these codecs, e.g. hevc,av1
      --order ORDER        path | largest | smallest
  -l, --limit N            Stop after N successful transcodes

Encoding
  -e, --encoder ENC        cpu (libx265) | nvidia (hevc_nvenc) | vaapi (hevc_vaapi, AMD/Intel)
  -q, --quality N          CRF for cpu, CQ for nvidia, QP for vaapi. 0-51, lower = better and bigger.
                           The scales are not equivalent between encoders.
  -H, --height N           Max output height (e.g. 720, 1080). 0 keeps the source resolution.
      --10bit | --8bit     Output bit depth (default 8)
      --audio MODE         copy | compress   (compress re-encodes lossless tracks only:
                           TrueHD, DTS-HD MA, FLAC, ALAC, PCM; lossy tracks are copied)
      --audio-codec C      eac3 | aac | opus (for --audio compress)
      --max-ratio PCT      Stop the encode and keep the original once the output reaches
                           PCT% of the source size. 0 disables. Default 90.
      --hw-decode MODE     auto | off   (auto: GPU decode, retry with CPU decode on failure)
      --vaapi-device DEV   VAAPI render node (default /dev/dri/renderD128)
      --nice N             CPU niceness for ffmpeg, 0-19 (0 = normal priority)
      --set KEY=VALUE      Set any profile key (see list below)

HDR
      --hdr MODE           tonemap | skip   (default tonemap)
                           tonemap: HDR and BT.2020 sources become SDR BT.709
                           skip:    HDR and BT.2020 sources are logged and left alone
      --tonemap-backend B  auto | libplacebo | zscale
                           libplacebo: GPU through Vulkan, best quality, the only one
                                       that handles Dolby Vision profile 5
                           zscale:     CPU (zimg + tonemap filter), no GPU needed
                           auto:       libplacebo if it can start, else zscale
      --tonemap-curve C    auto | hable | mobius | reinhard | bt.2390 | spline
                           (bt.2390 and spline are libplacebo only; auto = libplacebo's
                           own default, or hable on zscale)

Where files go
      --archive DIR        After success, move originals here (folder layout mirrored)
      --delete             After success, delete originals
      --keep               After success, leave originals in place
  -o, --output DIR         Write outputs here (folder layout mirrored). Default: next to source.
      --suffix STR         Output name suffix (default "_shrunk"; may be empty)
      --scratch DIR        Encode in this directory first, then move into place
      --wip DIR            Move each source here while it is processed

Profiles and running
  -p, --profile NAME       Load $CONFIG_DIR/NAME.conf
                           (default.conf is loaded automatically if it exists)
  -c, --config FILE        Load settings from FILE
      --save-profile NAME  Save the resulting settings as profile NAME
  -n, --dry-run            Show what would happen; change nothing
  -y, --yes                Skip the settings screen and start (cron, systemd)
  -h, --help               Show this help
  -V, --version            Show the version

Long options also accept --option=value. Short options can be grouped (-ny).
Precedence: built-in defaults < profile < command-line flags < settings screen.

During a run
  Ctrl+C                   Abort now. Partial output is removed, WIP files are returned.
  kill -USR1 <pid>         Finish the current file, then stop.

Files created
  <scan dir>/$HDR_LOG_NAME   HDR / BT.2020 files that were skipped
  <scan dir>/$STATE_DIR_NAME/locks/      Per-file locks, so several instances can share a library
  <scan dir>/$STATE_DIR_NAME/no-gain.list  Files that did not shrink enough (delete a line to retry)
  $LOG_DIR/  Run log and ffmpeg logs of failed files

Profile keys
  ${SETTING_KEYS[*]}
EOF
}

# ===========================================================================
# Profiles
# ===========================================================================
is_setting_key() {
    local k
    for k in "${SETTING_KEYS[@]}"; do [ "$k" = "$1" ] && return 0; done
    return 1
}

load_config() {
    local file=$1 line key val n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$(( n + 1 ))
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ $line != *=* ]]; then warn "$file:$n: ignoring malformed line"; continue; fi
        key=${line%%=*}; key=${key//[[:space:]]/}
        val=${line#*=}
        val=${val#"${val%%[![:space:]]*}"}
        val=${val%"${val##*[![:space:]]}"}
        if [[ ${#val} -ge 2 && $val == \"*\" ]]; then val=${val:1:${#val}-2}; fi
        if is_setting_key "$key"; then
            printf -v "$key" '%s' "$val"
        else
            warn "$file:$n: unknown setting '$key' ignored"
        fi
    done < "$file"
}

save_config() {
    local file=$1 k
    mkdir -p -- "$(dirname -- "$file")" || return 1
    {
        printf '# %s profile, saved %s\n' "$PROG" "$(date '+%F %T')"
        printf '# One KEY="value" per line. See %s --help.\n' "$PROG"
        for k in "${SETTING_KEYS[@]}"; do printf '%s="%s"\n' "$k" "${!k}"; done
    } > "$file"
}

profile_path() { printf '%s/%s.conf' "$CONFIG_DIR" "$1"; }

valid_profile_name() { [[ $1 =~ ^[A-Za-z0-9._-]+$ && $1 != .* ]]; }

# ===========================================================================
# Command line
# ===========================================================================
# Option letters and long names, and which of them take a value. Long
# options go through getopts too, as "-" with the name in OPTARG.
LONG_WITH_VALUE=" dir min-size skip-codecs order limit encoder quality height audio audio-codec max-ratio hw-decode vaapi-device nice hdr tonemap-backend tonemap-curve set archive output suffix scratch wip profile config save-profile "
LONG_EMPTY_OK=" skip-codecs suffix "
LONG_FLAGS=" 10bit 8bit delete keep dry-run yes help version "

parse_args() {
    local opt name val has_val
    OPTIND=1
    while getopts ':d:m:l:e:q:H:o:p:c:nyhV-:' opt; do
        if [ "$opt" = "-" ]; then
            name=${OPTARG%%=*}
            case "$OPTARG" in
                *=*) val=${OPTARG#*=}; has_val=1 ;;
                *) val=""; has_val=0 ;;
            esac
            case "$LONG_WITH_VALUE" in
                *" $name "*)
                    if [ "$has_val" -eq 0 ]; then
                        [ "$OPTIND" -le "$#" ] || die "Option --$name needs a value (see --help)."
                        val=${!OPTIND}
                        OPTIND=$(( OPTIND + 1 ))
                    fi
                    case "$LONG_EMPTY_OK" in
                        *" $name "*) ;;
                        *) [ -n "$val" ] || die "Option --$name needs a value (see --help)." ;;
                    esac
                    ;;
                *)
                    case "$LONG_FLAGS" in
                        *" $name "*) [ "$has_val" -eq 0 ] || die "Option --$name takes no value." ;;
                        *) die "Unknown option: --$name (see --help)" ;;
                    esac
                    ;;
            esac
            opt=$name
            OPTARG=$val
        fi
        case "$opt" in
            d|dir)          CLI_SET[SCAN_DIR]=$OPTARG ;;
            m|min-size)     CLI_SET[MIN_SIZE_GB]=$OPTARG ;;
            skip-codecs)    CLI_SET[SKIP_CODECS]=$OPTARG ;;
            order)          CLI_SET[ORDER]=$OPTARG ;;
            l|limit)        LIMIT=$OPTARG
                            [[ $LIMIT =~ ^[0-9]+$ ]] || die "--limit needs a whole number." ;;
            e|encoder)      CLI_SET[ENCODER]=$OPTARG ;;
            q|quality)      CLI_SET[QUALITY]=$OPTARG ;;
            H|height)       CLI_SET[MAX_HEIGHT]=$OPTARG ;;
            10bit)          CLI_SET[BIT_DEPTH]=10 ;;
            8bit)           CLI_SET[BIT_DEPTH]=8 ;;
            audio)          CLI_SET[AUDIO]=$OPTARG ;;
            audio-codec)    CLI_SET[AUDIO_CODEC]=$OPTARG ;;
            max-ratio)      CLI_SET[MAX_OUTPUT_PCT]=$OPTARG ;;
            hw-decode)      CLI_SET[HW_DECODE]=$OPTARG ;;
            vaapi-device)   CLI_SET[VAAPI_DEVICE]=$OPTARG ;;
            nice)           CLI_SET[NICE]=$OPTARG ;;
            hdr)            CLI_SET[HDR_MODE]=$OPTARG ;;
            tonemap-backend) CLI_SET[TONEMAP_BACKEND]=$OPTARG ;;
            tonemap-curve)  CLI_SET[TONEMAP_CURVE]=$OPTARG ;;
            set)           [[ $OPTARG == *=* ]] || die "--set expects KEY=VALUE."
                            is_setting_key "${OPTARG%%=*}" || die "--set: unknown key '${OPTARG%%=*}'."
                            CLI_SET[${OPTARG%%=*}]=${OPTARG#*=} ;;
            archive)        CLI_SET[ORIGINALS]=move; CLI_SET[ARCHIVE_DIR]=$OPTARG ;;
            delete)         CLI_SET[ORIGINALS]=delete ;;
            keep)           CLI_SET[ORIGINALS]=keep ;;
            o|output)       CLI_SET[OUTPUT_DIR]=$OPTARG ;;
            suffix)         CLI_SET[OUTPUT_SUFFIX]=$OPTARG ;;
            scratch)        CLI_SET[SCRATCH_DIR]=$OPTARG ;;
            wip)            CLI_SET[WIP_DIR]=$OPTARG ;;
            p|profile)      PROFILE_NAME=$OPTARG; EXPLICIT_PROFILE=1
                            valid_profile_name "$PROFILE_NAME" || die "Invalid profile name: $PROFILE_NAME" ;;
            c|config)       CONFIG_FILE=$(expand_path "$OPTARG") ;;
            save-profile)   SAVE_PROFILE=$OPTARG
                            valid_profile_name "$SAVE_PROFILE" || die "Invalid profile name: $SAVE_PROFILE" ;;
            n|dry-run)      DRY_RUN=1 ;;
            y|yes)          ASSUME_YES=1 ;;
            h|help)         usage; exit 0 ;;
            V|version)      printf '%s\n' "$PROG version $VERSION"; exit 0 ;;
            :)              die "Option -$OPTARG needs a value (see --help)." ;;
            *)              die "Unknown option: -$OPTARG (see --help)" ;;
        esac
    done
    shift $(( OPTIND - 1 ))
    [ "$#" -eq 0 ] || die "Unexpected argument: $1 (see --help)"
}

# Carry a config or log dir over from its old hyphenated name
migrate_dir() {
    local old=$1 new=$2
    if [ -d "$old" ] && [ ! -e "$new" ]; then
        mkdir -p -- "$(dirname -- "$new")" 2>/dev/null || true
        mv -- "$old" "$new" 2>/dev/null && info "Moved $old to $new"
    fi
    return 0
}

resolve_config() {
    local k
    if [ -n "$CONFIG_FILE" ]; then
        [ -f "$CONFIG_FILE" ] || die "Config file not found: $CONFIG_FILE"
        load_config "$CONFIG_FILE"
    else
        CONFIG_FILE=$(profile_path "$PROFILE_NAME")
        if [ -f "$CONFIG_FILE" ]; then
            load_config "$CONFIG_FILE"
        elif [ "$EXPLICIT_PROFILE" -ne 0 ]; then
            die "Profile '$PROFILE_NAME' not found ($CONFIG_FILE)."
        fi
    fi
    for k in "${!CLI_SET[@]}"; do printf -v "$k" '%s' "${CLI_SET[$k]}"; done
}

# ===========================================================================
# Capability detection
# ===========================================================================
detect_ffmpeg() {
    command -v ffmpeg  >/dev/null 2>&1 || die "ffmpeg not found in PATH."
    command -v ffprobe >/dev/null 2>&1 || die "ffprobe not found in PATH."
    FF_ENCODERS=$(LC_ALL=C ffmpeg -hide_banner -encoders 2>/dev/null)
    FF_FILTERS=$(LC_ALL=C ffmpeg -hide_banner -filters 2>/dev/null)
    if command -v flock >/dev/null 2>&1; then HAVE_FLOCK=1; fi
}

have_encoder() { awk -v n="$1" '$2 == n { f = 1 } END { exit !f }' <<< "$FF_ENCODERS"; }
have_filter()  { awk -v n="$1" '$2 == n { f = 1 } END { exit !f }' <<< "$FF_FILTERS"; }

render_nodes() {
    local n
    for n in /dev/dri/renderD*; do
        if [ -e "$n" ]; then printf '%s\n' "$n"; fi
    done
    return 0
}

render_vendor() {
    local v
    v=$(cat "/sys/class/drm/${1##*/}/device/vendor" 2>/dev/null || true)
    case $v in
        0x8086) printf '%s\n' Intel ;; 0x1002) printf '%s\n' AMD ;; 0x10de) printf '%s\n' NVIDIA ;; *) printf '%s\n' "${v:-unknown vendor}" ;;
    esac
}

nvidia_present() { [ -e /dev/nvidia0 ] || command -v nvidia-smi >/dev/null 2>&1; }

encoder_status() {
    case $1 in
        cpu)    have_encoder libx265 && printf '%s\n' "available" || printf '%s\n' "not in this ffmpeg build" ;;
        nvidia) if ! have_encoder hevc_nvenc; then printf '%s\n' "not in this ffmpeg build"
                elif nvidia_present; then printf '%s\n' "available"
                else printf '%s\n' "in ffmpeg, but no NVIDIA device found"; fi ;;
        vaapi)  if ! have_encoder hevc_vaapi; then printf '%s\n' "not in this ffmpeg build"
                elif [ -n "$(render_nodes)" ]; then printf '%s\n' "available"
                else printf '%s\n' "in ffmpeg, but no /dev/dri render node found"; fi ;;
    esac
}

# ===========================================================================
# Normalisation and validation
# ===========================================================================
canon_dir_var() {
    local var=$1 v=${!1}
    [ -z "$v" ] && return 0
    v=$(expand_path "$v")
    v=$(canon_path "$v")
    printf -v "$var" '%s' "$v"
}

normalize_settings() {
    ENCODER=${ENCODER,,}
    case $ENCODER in amd|intel) ENCODER=vaapi ;; nvenc) ENCODER=nvidia ;; x265|libx265) ENCODER=cpu ;; esac
    ORIGINALS=${ORIGINALS,,}; [ "$ORIGINALS" = archive ] && ORIGINALS=move
    AUDIO=${AUDIO,,}; AUDIO_CODEC=${AUDIO_CODEC,,}; ORDER=${ORDER,,}; HW_DECODE=${HW_DECODE,,}
    HDR_MODE=${HDR_MODE,,}; TONEMAP_BACKEND=${TONEMAP_BACKEND,,}; TONEMAP_CURVE=${TONEMAP_CURVE,,}
    case $HDR_MODE in tonemapping|tonemapped|convert) HDR_MODE=tonemap ;; esac
    case $TONEMAP_BACKEND in placebo|vulkan|gpu) TONEMAP_BACKEND=libplacebo ;; zimg|cpu) TONEMAP_BACKEND=zscale ;; esac
    case $TONEMAP_CURVE in bt2390) TONEMAP_CURVE=bt.2390 ;; esac
    SKIP_CODECS=${SKIP_CODECS,,}; SKIP_CODECS=${SKIP_CODECS// /}
    MAX_HEIGHT=${MAX_HEIGHT%[pP]}
    MAX_OUTPUT_PCT=${MAX_OUTPUT_PCT%\%}
    local d
    for d in SCAN_DIR ARCHIVE_DIR OUTPUT_DIR SCRATCH_DIR WIP_DIR; do canon_dir_var "$d"; done
    # An output dir equal to the scan dir is the same as "next to the source"
    if [ -n "$OUTPUT_DIR" ] && [ "$OUTPUT_DIR" = "$SCAN_DIR" ]; then OUTPUT_DIR=""; fi
}

VALIDATION_ERRORS=()
verr() { VALIDATION_ERRORS+=("$*"); }

check_dir() {
    local label=$1 p=$2
    if [ ! -d "$p" ]; then verr "$label does not exist: $p"; return 1; fi
    if [ ! -r "$p" ] || [ ! -x "$p" ]; then verr "$label is not readable: $p"; return 1; fi
    if [ "$DRY_RUN" -eq 0 ] && [ ! -w "$p" ]; then verr "$label is not writable: $p"; return 1; fi
    return 0
}

is_int_range() { [[ $1 =~ ^[0-9]+$ ]] && [ "$(( 10#$1 ))" -ge "$2" ] && [ "$(( 10#$1 ))" -le "$3" ]; }

validate_settings() {
    VALIDATION_ERRORS=()
    if [ -z "$SCAN_DIR" ]; then verr "Scan directory is not set."
    else check_dir "Scan directory" "$SCAN_DIR"; fi

    [[ $MIN_SIZE_GB =~ ^[0-9]+(\.[0-9]+)?$ ]] || verr "Minimum size must be a number of GiB, e.g. 20 or 1.5."

    case $ENCODER in
        cpu|nvidia|vaapi) have_encoder "$(enc_name)" || verr "Encoder $(enc_name) is not available in this ffmpeg build." ;;
        *) verr "Encoder must be cpu, nvidia or vaapi (got '$ENCODER')." ;;
    esac
    if [ "$ENCODER" = vaapi ] && [ ! -e "$VAAPI_DEVICE" ]; then verr "VAAPI device not found: $VAAPI_DEVICE"; fi

    is_int_range "$QUALITY" 0 51 || verr "Quality must be a whole number from 0 to 51."
    if ! [[ $MAX_HEIGHT =~ ^[0-9]+$ ]] || { [ "$(( 10#$MAX_HEIGHT ))" -ne 0 ] && [ "$(( 10#$MAX_HEIGHT ))" -lt 120 ]; }; then
        verr "Max height must be 0 (keep source) or a height in pixels such as 720 or 1080."
    fi
    [ "$BIT_DEPTH" = 8 ] || [ "$BIT_DEPTH" = 10 ] || verr "Bit depth must be 8 or 10."
    [ "$AUDIO" = copy ] || [ "$AUDIO" = compress ] || verr "Audio mode must be copy or compress."
    case $AUDIO_CODEC in
        eac3|aac) ;;
        opus) [ "$AUDIO" != compress ] || have_encoder libopus || verr "Audio codec opus needs libopus, which this ffmpeg lacks." ;;
        *) verr "Audio codec must be eac3, aac or opus." ;;
    esac

    case $ORIGINALS in
        move)
            if [ -z "$ARCHIVE_DIR" ]; then verr "Originals are set to 'move' but no archive directory is set."
            elif check_dir "Archive directory" "$ARCHIVE_DIR" && [ "$ARCHIVE_DIR" = "$SCAN_DIR" ]; then
                verr "Archive directory cannot be the scan directory."
            fi ;;
        delete) ;;
        keep)
            if [ -z "$OUTPUT_SUFFIX" ] && [ -z "$OUTPUT_DIR" ]; then
                verr "Keeping originals needs an output suffix or a separate output directory, or the output would overwrite the source."
            fi ;;
        *) verr "Originals must be move, delete or keep." ;;
    esac

    [ -n "$OUTPUT_DIR" ] && check_dir "Output directory" "$OUTPUT_DIR"
    [[ $OUTPUT_SUFFIX =~ ^[A-Za-z0-9._\ -]*$ ]] || verr "Output suffix may only contain letters, digits, space, '.', '_' and '-'."
    [ -n "$SCRATCH_DIR" ] && check_dir "Scratch directory" "$SCRATCH_DIR"
    if [ -n "$WIP_DIR" ]; then
        check_dir "WIP directory" "$WIP_DIR" && [ "$WIP_DIR" = "$SCAN_DIR" ] && verr "WIP directory cannot be the scan directory."
    fi
    [[ $SKIP_CODECS =~ ^[a-z0-9_,]*$ ]] || verr "Skip codecs must be a comma-separated list like hevc,av1."
    is_int_range "$MAX_OUTPUT_PCT" 0 100 || verr "Max output ratio must be 0-100 (percent)."
    case $ORDER in path|largest|smallest) ;; *) verr "Order must be path, largest or smallest." ;; esac
    case $HW_DECODE in auto|off) ;; *) verr "Hardware decode must be auto or off." ;; esac
    is_int_range "$NICE" 0 19 || verr "Nice level must be 0-19."
    case $HDR_MODE in tonemap|skip) ;; *) verr "HDR mode must be tonemap or skip." ;; esac
    case $TONEMAP_BACKEND in
        auto) ;;
        libplacebo) have_filter libplacebo || verr "Tone map backend libplacebo: this ffmpeg has no libplacebo filter." ;;
        zscale) { have_filter zscale && have_filter tonemap; } || verr "Tone map backend zscale: this ffmpeg lacks the zscale or tonemap filter (needs libzimg)." ;;
        *) verr "Tone map backend must be auto, libplacebo or zscale." ;;
    esac
    case " $TONEMAP_CURVES " in
        *" $TONEMAP_CURVE "*)
            if [ "$TONEMAP_BACKEND" = zscale ]; then
                case $TONEMAP_CURVE in bt.2390|spline) verr "Tone map curve $TONEMAP_CURVE needs libplacebo; zscale offers hable, mobius or reinhard." ;; esac
            fi ;;
        *) verr "Tone map curve must be one of: $TONEMAP_CURVES." ;;
    esac
    case $X265_PRESET in
        ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow|placebo) ;;
        *) verr "x265 preset '$X265_PRESET' is not valid." ;;
    esac
    [[ $NVENC_PRESET =~ ^[a-z0-9]+$ ]] || verr "NVENC preset '$NVENC_PRESET' is not valid."
    [[ $X265_PARAMS =~ ^[A-Za-z0-9=:._,+-]*$ ]] || verr "x265 params contain unexpected characters."
    [[ $EXTENSIONS =~ ^[A-Za-z0-9\ ]+$ && $EXTENSIONS =~ [A-Za-z0-9] ]] || verr "Extensions must be a space-separated list like 'mkv mp4'."
    [ "${#VALIDATION_ERRORS[@]}" -eq 0 ]
}

# ===========================================================================
# Interactive settings screen
# ===========================================================================
REPLY_VAL=""
MENU_MSG=""

ask_yes_no() {
    local prompt=$1 default=$2 response
    if [ "$default" = Y ]; then read -r -p "$prompt (Y/n): " response || return 1
    else read -r -p "$prompt (y/N): " response || return 1; fi
    response=${response:-$default}
    [[ $response =~ ^[Yy] ]]
}

prompt_text() {
    local label=$1 cur=${2-}
    read -e -r -p "  $label: " -i "$cur" REPLY_VAL || return 1
}

prompt_choice() {
    local label=$1 cur=$2 v o
    shift 2
    while true; do
        read -e -r -p "  $label [$(IFS=/; printf '%s' "$*")]: " -i "$cur" v || return 1
        v=${v,,}
        for o in "$@"; do [ "$v" = "$o" ] && { REPLY_VAL=$v; return 0; }; done
        printf '%s\n' "  Please enter one of: $*"
    done
}

prompt_int() {
    local label=$1 cur=$2 lo=$3 hi=$4 v
    while true; do
        read -e -r -p "  $label: " -i "$cur" v || return 1
        v=${v%[pP%]}
        if is_int_range "$v" "$lo" "$hi"; then REPLY_VAL=$((10#$v)); return 0; fi
        printf '%s\n' "  Please enter a whole number from $lo to $hi."
    done
}

prompt_dir() {
    local label=$1 cur=$2 allow_empty=${3:-0} v
    while true; do
        read -e -r -p "  $label: " -i "$cur" v || return 1
        v=$(expand_path "$v")
        if [ -z "$v" ]; then
            if [ "$allow_empty" -ne 0 ]; then REPLY_VAL=""; return 0; fi
            printf '%s\n' "  A directory is required."; continue
        fi
        if [ ! -d "$v" ]; then
            if ask_yes_no "  '$v' does not exist. Create it?" N; then
                mkdir -p -- "$v" || { printf '%s\n' "  Could not create it."; continue; }
            else
                continue
            fi
        fi
        REPLY_VAL=$(cd -P -- "$v" && pwd -P)
        return 0
    done
}

opt_or_none() { if [ -n "$1" ]; then printf '%s' "$1"; else printf '%s(none)%s' "$C_DIM" "$C_RST"; fi; }

desc_encoder() {
    case $ENCODER in
        cpu)    printf 'cpu     libx265, preset %s' "$X265_PRESET" ;;
        nvidia) printf 'nvidia  hevc_nvenc, preset %s' "$NVENC_PRESET" ;;
        vaapi)  printf 'vaapi   hevc_vaapi on %s (%s)' "$VAAPI_DEVICE" "$(render_vendor "$VAAPI_DEVICE")" ;;
        *)      printf '%s%s (invalid)%s' "$C_RED" "$ENCODER" "$C_RST" ;;
    esac
    local st; st=$(encoder_status "$ENCODER" 2>/dev/null)
    [ -n "$st" ] && [ "$st" != available ] && printf '  %s[%s]%s' "$C_YEL" "$st" "$C_RST"
    [ "$ENCODER" != cpu ] && [ "$HW_DECODE" = off ] && printf ', CPU decode'
    return 0
}

desc_audio() {
    if [ "$AUDIO" = compress ]; then
        printf 'copy lossy tracks, re-encode lossless tracks to %s' "${AUDIO_CODEC^^}"
    else
        printf 'copy all tracks'
    fi
}

desc_hdr() {
    if [ "$HDR_MODE" = skip ]; then
        printf 'skip HDR and BT.2020 sources, list them in %s' "$HDR_LOG_NAME"
        return 0
    fi
    printf 'tone map to SDR BT.709, backend %s, curve %s' "$TONEMAP_BACKEND" "$TONEMAP_CURVE"
    if [ -n "$TM_BACKEND" ]; then
        printf '  %s(using %s)%s' "$C_DIM" "$TM_BACKEND" "$C_RST"
    fi
    return 0
}

desc_originals() {
    case $ORIGINALS in
        move)   if [ -n "$ARCHIVE_DIR" ]; then printf 'move to %s' "$ARCHIVE_DIR"
                else printf 'move to %s(archive dir not set)%s' "$C_RED" "$C_RST"; fi ;;
        delete) printf '%sDELETE%s after a verified transcode' "$C_RED" "$C_RST" ;;
        keep)   printf 'leave in place' ;;
    esac
}

desc_output() {
    local where=${OUTPUT_DIR:-next to the source}
    printf '%s, named <name>%s.mkv' "$where" "$OUTPUT_SUFFIX"
}

draw_menu() {
    local dry="off"
    [ "$DRY_RUN" -ne 0 ] && dry="${C_YEL}ON${C_RST}"
    [ -t 1 ] && printf '\e[H\e[2J'
    printf '%sMedia Transcode v%s%s   profile: %s\n' "$C_BLD" "$VERSION" "$C_RST" "$PROFILE_NAME"
    rule
    menu_item 1  "Scan directory"  "$( [ -n "$SCAN_DIR" ] && printf '%s' "$SCAN_DIR" || printf '%s(not set)%s' "$C_RED" "$C_RST")"
    menu_item 2  "Minimum size"    "$MIN_SIZE_GB GiB"
    menu_item 3  "Encoder"         "$(desc_encoder)"
    menu_item 4  "Quality"         "$(quality_label) $QUALITY  ${C_DIM}(lower = better quality, bigger file)${C_RST}"
    menu_item 5  "Max height"      "$( is_int_range "$MAX_HEIGHT" 0 0 && printf '%s\n' 'keep source resolution' || printf '%s\n' "${MAX_HEIGHT}p (smaller sources are not upscaled)")"
    menu_item 6  "Bit depth"       "${BIT_DEPTH}-bit"
    menu_item 7  "Audio"           "$(desc_audio)"
    menu_item 8  "Originals"       "$(desc_originals)"
    menu_item 9  "Output"          "$(desc_output)"
    menu_item 10 "Scratch dir"     "$(opt_or_none "$SCRATCH_DIR")"
    menu_item 11 "WIP dir"         "$(opt_or_none "$WIP_DIR")"
    menu_item 12 "Skip codecs"     "$(opt_or_none "$SKIP_CODECS")"
    menu_item 13 "Size guard"      "$( is_int_range "$MAX_OUTPUT_PCT" 1 999999 && printf '%s\n' "abort if output reaches ${MAX_OUTPUT_PCT}% of source" || printf '%s\n' off)"
    menu_item 14 "Order"           "$ORDER"
    menu_item 15 "HDR"             "$(desc_hdr)"
    menu_item 16 "Advanced"        "x265 params, presets, hw decode ($HW_DECODE), nice ($NICE), extensions"
    rule
    printf '  %sEnter%s start   %s1-16%s edit  %ss%s save profile   %sn%s dry run: %s   %sq%s quit\n' \
        "$C_BLD" "$C_RST" "$C_BLD" "$C_RST" "$C_BLD" "$C_RST" "$C_BLD" "$C_RST" "$dry" "$C_BLD" "$C_RST"
    if [ -n "$MENU_MSG" ]; then printf '\n%s\n' "$MENU_MSG"; MENU_MSG=""; fi
}

menu_item() { printf '  %s%2d%s  %-15s %s\n' "$C_CYN" "$1" "$C_RST" "$2" "$3"; }

edit_encoder() {
    local e nodes=() n i
    printf '\n'
    for e in cpu nvidia vaapi; do printf '    %-7s %-11s %s\n' "$e" "$(enc_name "$e")" "$(encoder_status "$e")"; done
    prompt_choice "Encoder" "$ENCODER" cpu nvidia vaapi || return 0
    ENCODER=$REPLY_VAL
    if [ "$ENCODER" = vaapi ]; then
        mapfile -t nodes < <(render_nodes)
        if [ "${#nodes[@]}" -gt 1 ]; then
            for i in "${!nodes[@]}"; do n=${nodes[i]}; printf '    %s  %s\n' "$n" "$(render_vendor "$n")"; done
            prompt_text "VAAPI device" "$VAAPI_DEVICE" && VAAPI_DEVICE=$REPLY_VAL
        elif [ "${#nodes[@]}" -eq 1 ]; then
            VAAPI_DEVICE=${nodes[0]}
        fi
    fi
    MENU_MSG="Note: quality numbers mean different things per encoder; re-check item 4."
}

edit_hdr() {
    local curves
    printf '\n'
    printf '%s\n' "    tonemap: HDR10, HLG, HDR10+ and Dolby Vision become SDR BT.709; BT.2020 SDR is gamut mapped"
    printf '%s\n' "    skip:    those files are left alone and listed in $HDR_LOG_NAME"
    prompt_choice "HDR sources" "$HDR_MODE" tonemap skip && HDR_MODE=$REPLY_VAL
    [ "$HDR_MODE" = tonemap ] || return 0
    printf '    libplacebo: %s\n' "$(have_filter libplacebo && printf 'in this ffmpeg (GPU via Vulkan, handles Dolby Vision profile 5)' || printf 'not in this ffmpeg')"
    printf '    zscale:     %s\n' "$( { have_filter zscale && have_filter tonemap; } && printf 'in this ffmpeg (CPU)' || printf 'not in this ffmpeg (needs libzimg)')"
    prompt_choice "Tone map backend" "$TONEMAP_BACKEND" auto libplacebo zscale && TONEMAP_BACKEND=$REPLY_VAL
    curves=$TONEMAP_CURVES
    if [ "$TONEMAP_BACKEND" = zscale ]; then
        curves="auto hable mobius reinhard"
        case $TONEMAP_CURVE in bt.2390|spline) TONEMAP_CURVE=auto ;; esac
    fi
    printf '%s\n' "    auto: libplacebo's own default, or hable on zscale. hable: filmic, darker. mobius: keeps more brightness."
    # Unquoted on purpose: one choice per word
    # shellcheck disable=SC2086
    prompt_choice "Tone map curve" "$TONEMAP_CURVE" $curves && TONEMAP_CURVE=$REPLY_VAL
    return 0
}

edit_advanced() {
    printf '\n'
    prompt_choice "x265 preset" "$X265_PRESET" ultrafast superfast veryfast faster fast medium slow slower veryslow placebo && X265_PRESET=$REPLY_VAL
    prompt_text "x265 params (empty = x265 defaults)" "$X265_PARAMS" && X265_PARAMS=$REPLY_VAL
    prompt_choice "NVENC preset" "$NVENC_PRESET" p1 p2 p3 p4 p5 p6 p7 && NVENC_PRESET=$REPLY_VAL
    prompt_choice "GPU decode for hw encoders" "$HW_DECODE" auto off && HW_DECODE=$REPLY_VAL
    prompt_int "Nice level for ffmpeg (0 = normal priority)" "$NICE" 0 19 && NICE=$REPLY_VAL
    prompt_text "File extensions to scan" "$EXTENSIONS" && EXTENSIONS=$REPLY_VAL
    return 0
}

edit_item() {
    printf '\n'
    case $1 in
        1)  prompt_dir "Directory to scan" "$SCAN_DIR" && SCAN_DIR=$REPLY_VAL ;;
        2)  while prompt_text "Only process files larger than (GiB, decimals ok, 0 = all)" "$MIN_SIZE_GB"; do
                [[ $REPLY_VAL =~ ^[0-9]+(\.[0-9]+)?$ ]] && { MIN_SIZE_GB=$REPLY_VAL; break; }
                printf '%s\n' "  Please enter a number like 20 or 1.5."
            done ;;
        3)  edit_encoder ;;
        4)  prompt_int "$(quality_label) value, 0-51 (lower = better quality, bigger file)" "$QUALITY" 0 51 && QUALITY=$REPLY_VAL ;;
        5)  prompt_int "Max output height in pixels, e.g. 720 or 1080 (0 = keep source)" "$MAX_HEIGHT" 0 8640 && MAX_HEIGHT=$REPLY_VAL ;;
        6)  prompt_choice "Output bit depth" "$BIT_DEPTH" 8 10 && BIT_DEPTH=$REPLY_VAL ;;
        7)  prompt_choice "Audio: copy all, or compress lossless tracks" "$AUDIO" copy compress && AUDIO=$REPLY_VAL
            if [ "$AUDIO" = compress ]; then
                printf '%s\n' "    eac3: widest device support (max 5.1, 7.1 is downmixed)   aac: universal   opus: smallest"
                prompt_choice "Codec for lossless tracks" "$AUDIO_CODEC" eac3 aac opus && AUDIO_CODEC=$REPLY_VAL
            fi ;;
        8)  prompt_choice "After success, originals are" "$ORIGINALS" move delete keep && ORIGINALS=$REPLY_VAL
            [ "$ORIGINALS" = move ] && prompt_dir "Archive directory (folder layout is mirrored)" "$ARCHIVE_DIR" && ARCHIVE_DIR=$REPLY_VAL ;;
        9)  prompt_dir "Output directory (empty = next to the source)" "$OUTPUT_DIR" 1 && OUTPUT_DIR=$REPLY_VAL
            [ "$OUTPUT_DIR" = "$SCAN_DIR" ] && OUTPUT_DIR=""
            while prompt_text "Output name suffix (may be empty)" "$OUTPUT_SUFFIX"; do
                [[ $REPLY_VAL =~ ^[A-Za-z0-9._\ -]*$ ]] && { OUTPUT_SUFFIX=$REPLY_VAL; break; }
                printf '%s\n' "  Letters, digits, space, '.', '_' and '-' only."
            done ;;
        10) prompt_dir "Scratch directory (empty = encode in place)" "$SCRATCH_DIR" 1 && SCRATCH_DIR=$REPLY_VAL ;;
        11) prompt_dir "WIP directory (empty = none; locks already stop instances colliding)" "$WIP_DIR" 1 && WIP_DIR=$REPLY_VAL ;;
        12) while prompt_text "Skip sources already in these codecs, comma separated (e.g. hevc,av1)" "$SKIP_CODECS"; do
                REPLY_VAL=${REPLY_VAL,,}; REPLY_VAL=${REPLY_VAL// /}
                [[ $REPLY_VAL =~ ^[a-z0-9_,]*$ ]] && { SKIP_CODECS=$REPLY_VAL; break; }
                printf '%s\n' "  Use a comma-separated list like hevc,av1."
            done ;;
        13) prompt_int "Abort and keep the original if output reaches this % of source (0 = off)" "$MAX_OUTPUT_PCT" 0 100 && MAX_OUTPUT_PCT=$REPLY_VAL ;;
        14) prompt_choice "Processing order" "$ORDER" path largest smallest && ORDER=$REPLY_VAL ;;
        15) edit_hdr ;;
        16) edit_advanced ;;
        *)  MENU_MSG="No item $1." ;;
    esac
    # A prompt cut short by Ctrl+D just leaves the setting as it was
    return 0
}

run_menu() {
    local choice name file e
    while true; do
        draw_menu
        read -r -p "> " choice || { printf '\n'; exit 0; }
        case ${choice,,} in
            "")
                if validate_settings; then
                    if [ "$ORIGINALS" = delete ] && [ "$DRY_RUN" -eq 0 ]; then
                        ask_yes_no "Originals will be permanently deleted after each verified transcode. Continue?" N || continue
                    fi
                    return 0
                fi
                MENU_MSG="${C_RED}Cannot start yet:${C_RST}"
                for e in "${VALIDATION_ERRORS[@]}"; do MENU_MSG+=$'\n'"  - $e"; done ;;
            s)
                read -e -r -p "  Save as profile name: " -i "$PROFILE_NAME" name || continue
                if ! valid_profile_name "$name"; then MENU_MSG="Invalid profile name '$name'."; continue; fi
                file=$(profile_path "$name")
                if save_config "$file"; then
                    PROFILE_NAME=$name
                    MENU_MSG="${C_GRN}Saved${C_RST} $file"
                    [ "$name" != default ] && MENU_MSG+=$'\n'"Load it with: $PROG --profile $name"
                else
                    MENU_MSG="${C_RED}Could not write${C_RST} $file"
                fi ;;
            n)  DRY_RUN=$(( 1 - DRY_RUN )) ;;
            q)  exit 0 ;;
            *)  if [[ $choice =~ ^[0-9]+$ ]]; then edit_item "$((10#$choice))"; else MENU_MSG="Unknown choice '$choice'."; fi ;;
        esac
    done
}

# ===========================================================================
# Encoder setup
# ===========================================================================
build_encoder_settings() {
    case $ENCODER in
        cpu)
            VIDEO_ENC=(-c:v libx265 -preset:v "$X265_PRESET" -crf:v "$QUALITY")
            [ -n "$X265_PARAMS" ] && VIDEO_ENC+=(-x265-params:v "$X265_PARAMS")
            if [ "$BIT_DEPTH" -eq 10 ]; then SW_FMT=yuv420p10le; else SW_FMT=yuv420p; fi
            ATTEMPTS=(cpu)
            ;;
        nvidia)
            # -b:v 0 matters: without it NVENC's default 2M target bitrate caps -cq
            VIDEO_ENC=(-c:v hevc_nvenc -preset:v "$NVENC_PRESET" -tune:v hq -rc:v vbr -cq:v "$QUALITY" -b:v 0 -rc-lookahead:v 32)
            if [ "$BIT_DEPTH" -eq 10 ]; then VIDEO_ENC+=(-profile:v main10); HW_FMT=p010le; SW_FMT=p010le
            else HW_FMT=nv12; SW_FMT=nv12; fi
            if [ "$HW_DECODE" = auto ] && have_filter scale_cuda; then ATTEMPTS=(gpu sw); else ATTEMPTS=(sw); fi
            ;;
        vaapi)
            VIDEO_ENC=(-c:v hevc_vaapi -qp:v "$QUALITY")
            if [ "$BIT_DEPTH" -eq 10 ]; then VIDEO_ENC+=(-profile:v main10); HW_FMT=p010; SW_FMT=p010le
            else HW_FMT=nv12; SW_FMT=nv12; fi
            if [ "$HW_DECODE" = auto ] && have_filter scale_vaapi; then ATTEMPTS=(gpu sw); else ATTEMPTS=(sw); fi
            ;;
    esac
}

# ===========================================================================
# Tone mapping
# ===========================================================================
# Runs a one-frame PQ test clip through a filter. Catches a libplacebo that
# is compiled in but can't get a Vulkan device, which only shows at run time.
# Sets TM_REASON to ffmpeg's last error line on failure.
tonemap_selftest() {
    local vf=$1 out tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=(timeout 30)
    if out=$(LC_ALL=C "${tmo[@]}" ffmpeg -hide_banner -nostdin -v error \
            -f lavfi -i "color=c=gray:s=64x64:d=0.1,format=yuv420p10le,setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc:range=tv" \
            -vf "$vf" -frames:v 1 -f null - 2>&1); then
        return 0
    fi
    # The first line naming the filter or Vulkan says the most; ffmpeg's
    # last line is usually a generic "nothing was written"
    TM_REASON=$(printf '%s\n' "$out" | awk '
        { sub(/^\[[^]]* @ [^]]*\] */, "") }
        NF && !first && /libplacebo|[Vv]ulkan|zscale|zimg|tonemap/ { first = $0 }
        NF { last = $0 }
        END { print (first != "" ? first : last) }')
    [ -n "$TM_REASON" ] || TM_REASON="test run failed"
    return 1
}

test_libplacebo() {
    have_filter libplacebo || { TM_REASON="this ffmpeg has no libplacebo filter"; return 1; }
    tonemap_selftest "libplacebo=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=yuv420p"
}

test_zscale() {
    { have_filter zscale && have_filter tonemap; } || { TM_REASON="this ffmpeg has no zscale/tonemap filter (needs libzimg)"; return 1; }
    tonemap_selftest "zscale=tin=smpte2084:min=bt2020nc:pin=bt2020:rin=tv:t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"
}

# Picks the backend for this run and builds the pieces every converted file
# shares. Leaves TM_BACKEND empty (with TM_REASON) when nothing works.
resolve_tonemap() {
    local why_pl="" t names=()
    TM_BACKEND=""; TM_REASON=""; TM_CURVE=""; TM_STRIP=""; ENC_HDR_ARGS=()
    [ "$HDR_MODE" = tonemap ] || return 0

    case $TONEMAP_BACKEND in
        libplacebo)
            test_libplacebo || die "Tone map backend libplacebo cannot start: $TM_REASON"
            TM_BACKEND=libplacebo ;;
        zscale)
            test_zscale || die "Tone map backend zscale cannot run: $TM_REASON"
            TM_BACKEND=zscale ;;
        auto)
            if test_libplacebo; then
                TM_BACKEND=libplacebo
            else
                why_pl=$TM_REASON
                if test_zscale; then
                    TM_BACKEND=zscale
                    warn "libplacebo is not usable ($why_pl). Tone mapping on the CPU with zscale instead; Dolby Vision profile 5 files will be skipped."
                else
                    TM_REASON="libplacebo: $why_pl; zscale: $TM_REASON"
                    warn "No tone mapping filter works in this ffmpeg ($TM_REASON). HDR files will be skipped and logged."
                    return 0
                fi
            fi ;;
    esac

    TM_CURVE=$TONEMAP_CURVE
    if [ "$TM_BACKEND" = zscale ]; then
        case $TM_CURVE in
            auto) TM_CURVE=hable ;;
            bt.2390|spline) warn "Curve $TM_CURVE needs libplacebo; using hable with zscale."; TM_CURVE=hable ;;
        esac
    fi

    # Drop HDR frame metadata after conversion so no encoder writes HDR SEI
    # into an SDR stream. Only names this ffmpeg's sidedata filter knows are
    # used, since an unknown name stops the whole filter graph.
    if have_filter sidedata; then
        mapfile -t names < <(LC_ALL=C ffmpeg -hide_banner -h filter=sidedata 2>/dev/null \
            | awk '$1 ~ /^(MASTERING_DISPLAY_METADATA|CONTENT_LIGHT_LEVEL|DYNAMIC_HDR_PLUS|DYNAMIC_HDR_VIVID|DOVI_RPU_BUFFER|DOVI_METADATA)$/ { print $1 }' \
            | sort -u)
        for t in "${names[@]}"; do TM_STRIP+=",sidedata=mode=delete:type=$t"; done
    fi
    # Newer ffmpeg can write a Dolby Vision RPU from libx265; never for SDR output
    if LC_ALL=C ffmpeg -hide_banner -h "encoder=$(enc_name)" 2>/dev/null | awk '$1 == "-dolbyvision" { f = 1 } END { exit !f }'; then
        ENC_HDR_ARGS=(-dolbyvision:v 0)
    fi
    return 0
}

# Picks a value off a whitelist of names zscale understands, else a default
pick_name() {
    local v=$1 def=$2 ok
    shift 2
    for ok in "$@"; do [ "$v" = "$ok" ] && { printf '%s' "$v"; return 0; }; done
    printf '%s' "$def"
}

# Decides what happens to an HDR / BT.2020 file. Sets HDR_CONVERT=1, or
# HDR_SKIP_WHY with the reason it can't be converted.
hdr_decide() {
    HDR_CONVERT=0; HDR_SKIP_WHY=""
    [ -n "$PR_KIND" ] || return 0
    if [ "$HDR_MODE" = skip ]; then
        HDR_SKIP_WHY="HDR mode is skip"
    elif [ "$PR_KIND" = unsure ]; then
        HDR_SKIP_WHY="BT.2020 with no transfer tag, could be HDR or SDR, check it by hand"
    elif [ -z "$TM_BACKEND" ]; then
        HDR_SKIP_WHY="no working tone mapping filter ($TM_REASON)"
    elif [ "$PR_KIND" = dv-rpu ] && [ "$TM_BACKEND" != libplacebo ]; then
        HDR_SKIP_WHY="needs the libplacebo backend, zscale would get the colours wrong"
    else
        HDR_CONVERT=1
    fi
    return 0
}

# Builds TM_VF: scaling + conversion to SDR BT.709, ending in software
# frames of format $SW_FMT. $1 = output height (number, quoted expression,
# or empty for no scaling).
build_tonemap_vf() {
    local h=$1 planar=yuv420p vf="" opts tin min pin rin
    [ "$BIT_DEPTH" -eq 10 ] && planar=yuv420p10le

    if [ "$TM_BACKEND" = libplacebo ]; then
        # libplacebo reads the colour tags, HDR10/HDR10+ metadata and the
        # Dolby Vision RPU from the frames itself, and scales on the GPU too
        opts=""
        [ -n "$h" ] && opts="w=-2:h=$h:"
        opts+="colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=$planar"
        [ "$TM_CURVE" != auto ] && opts+=":tonemapping=$TM_CURVE"
        vf="libplacebo=$opts"
    else
        # zscale needs the input described exactly, or it refuses to convert.
        # Scaling first keeps the float RGB stage at the small output size.
        tin=$(pick_name "$PR_TRC" bt709 smpte2084 arib-std-b67 bt709 bt2020-10 bt2020-12 smpte170m bt470bg bt470m smpte240m iec61966-2-1)
        min=$(pick_name "$PR_SPACE" bt2020nc bt2020nc bt2020c bt709 bt470bg smpte170m smpte240m fcc ycgco)
        pin=$(pick_name "$PR_PRIM" bt2020 bt2020 bt709 bt470m bt470bg smpte170m smpte240m film smpte431 smpte432)
        rin=$(pick_name "$PR_RANGE" tv tv pc)
        [ -n "$h" ] && vf="scale=w=-2:h=$h,"
        vf+="zscale=tin=$tin:min=$min:pin=$pin:rin=$rin:"
        if [ "$PR_KIND" = gamut ]; then
            # SDR already: only the primaries and matrix change
            vf+="t=bt709:m=bt709:p=bt709:r=tv:d=error_diffusion,format=$planar"
        else
            vf+="t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=$TM_CURVE:desat=0,"
            vf+="zscale=t=bt709:m=bt709:r=tv:d=error_diffusion,format=$planar"
        fi
    fi
    [ "$planar" != "$SW_FMT" ] && vf+=",format=$SW_FMT"
    TM_VF="$vf$TM_STRIP"
}

tonemap_desc() {
    case $PR_KIND in
        gamut) printf 'gamut mapped to BT.709 with %s' "$TM_BACKEND" ;;
        *)     printf 'tone mapped to SDR BT.709 with %s, curve %s' "$TM_BACKEND" "$TM_CURVE" ;;
    esac
}

# Sets PRE_INPUT (options before -i) and VF for one attempt.
# $1 = cpu | gpu | sw     $2 = output height, or empty for no scaling
# With HDR_CONVERT set, the frames go through TM_VF in system memory: the
# GPU attempt decodes on the GPU and lets ffmpeg download the frames, since
# the GPU scalers can't tone map (libplacebo still runs on the GPU).
PRE_INPUT=(); VF=""
video_pipeline() {
    local mode=$1 h=$2 sc=""
    PRE_INPUT=()
    if [ "$HDR_CONVERT" -ne 0 ]; then
        build_tonemap_vf "$h"
        case $mode in
            cpu) VF=$TM_VF ;;
            gpu)
                if [ "$ENCODER" = nvidia ]; then
                    PRE_INPUT=(-hwaccel cuda)
                    VF=$TM_VF
                else
                    PRE_INPUT=(-init_hw_device "vaapi=va:$VAAPI_DEVICE" -hwaccel vaapi -hwaccel_device va -filter_hw_device va)
                    VF="$TM_VF,hwupload"
                fi ;;
            sw)
                if [ "$ENCODER" = nvidia ]; then
                    VF=$TM_VF
                else
                    PRE_INPUT=(-vaapi_device "$VAAPI_DEVICE")
                    VF="$TM_VF,hwupload"
                fi ;;
        esac
        return 0
    fi
    case $mode in
        cpu)
            [ -n "$h" ] && sc="scale=w=-2:h=$h,"
            VF="${sc}format=$SW_FMT" ;;
        gpu)
            [ -n "$h" ] && sc="w=-2:h=$h:"
            if [ "$ENCODER" = nvidia ]; then
                PRE_INPUT=(-hwaccel cuda -hwaccel_output_format cuda)
                VF="scale_cuda=${sc}format=$HW_FMT"
            else
                PRE_INPUT=(-hwaccel vaapi -hwaccel_device "$VAAPI_DEVICE" -hwaccel_output_format vaapi)
                VF="scale_vaapi=${sc}format=$HW_FMT"
            fi ;;
        sw)
            [ -n "$h" ] && sc="scale=w=-2:h=$h,"
            if [ "$ENCODER" = nvidia ]; then
                VF="${sc}format=$SW_FMT"
            else
                PRE_INPUT=(-vaapi_device "$VAAPI_DEVICE")
                VF="${sc}format=$SW_FMT,hwupload"
            fi ;;
    esac
}

attempt_label() {
    case $1 in
        cpu) printf '%s\n' "libx265 on CPU" ;;
        gpu) printf '%s\n' "$(enc_name), GPU decode" ;;
        sw)  printf '%s\n' "$(enc_name), CPU decode" ;;
    esac
}

# ===========================================================================
# Probing
# ===========================================================================
# Fills P (flat ffprobe output) and the PR_* summary variables.
probe_file() {
    local f=$1 out line key val i k s
    P=()
    PR_SI=""; PR_VIDX=""; PR_VCODEC=""; PR_W=""; PR_H=""; PR_PIXFMT=""
    PR_TRC=""; PR_PRIM=""; PR_SPACE=""; PR_RANGE=""; PR_HDR=""; PR_MARKER=""; PR_DUR_US=0
    PR_KIND=""
    out=$(ffprobe -v error -analyzeduration 100M -probesize 100M \
          -show_streams -show_format -of flat -i "$f" 2>/dev/null) || return 1
    [ -n "$out" ] || return 1
    while IFS= read -r line; do
        key=${line%%=*}; val=${line#*=}
        if [[ ${#val} -ge 2 && $val == \"*\" ]]; then val=${val:1:${#val}-2}; val=${val//\\\"/\"}; fi
        P[$key]=$val
    done <<< "$out"

    # Main video = first video stream that is not cover art / a thumbnail
    for (( i = 0; ; i++ )); do
        [ -n "${P[streams.stream.$i.index]:-}" ] || break
        if [ "${P[streams.stream.$i.codec_type]:-}" = video ] && [ "${P[streams.stream.$i.disposition.attached_pic]:-0}" != 1 ]; then
            PR_SI=$i; break
        fi
    done

    for k in "${!P[@]}"; do
        if [ "${k,,}" = "format.tags.${MARKER_TAG,,}" ]; then PR_MARKER=${P[$k]}; fi
    done

    PR_DUR_US=$(secs_to_us "${P[format.duration]:-}")
    [ -n "$PR_SI" ] || return 0

    s="streams.stream.$PR_SI"
    PR_VIDX=${P[$s.index]}
    PR_VCODEC=${P[$s.codec_name]:-unknown}
    PR_W=${P[$s.width]:-}
    PR_H=${P[$s.height]:-}
    PR_PIXFMT=${P[$s.pix_fmt]:-}
    PR_TRC=${P[$s.color_transfer]:-}
    PR_PRIM=${P[$s.color_primaries]:-}
    PR_SPACE=${P[$s.color_space]:-}
    PR_RANGE=${P[$s.color_range]:-}
    [ "$PR_DUR_US" -gt 0 ] || PR_DUR_US=$(secs_to_us "${P[$s.duration]:-}")

    # HDR / Dolby Vision detection. DV profile 5 often has no PQ transfer tag,
    # so the DOVI configuration record and dvh1/dvhe tags are checked too.
    # A DV stream whose base layer is HDR10 or HLG (profiles 7, 8.1, 8.4) can
    # be tone mapped from that base layer by any backend. Profile 5 has no
    # such base layer (compatibility id 0): only the RPU gives correct
    # colours, and only libplacebo applies it.
    local dv=0 compat="" hdr10p=0
    for k in "${!P[@]}"; do
        case $k in
            streams.stream.*.side_data_type)
                [[ ${P[$k]} == *DOVI* || ${P[$k]} == *"Dolby Vision"* ]] && dv=1
                [[ ${P[$k]} == *"HDR10+"* || ${P[$k]} == *"SMPTE2094-40"* ]] && hdr10p=1 ;;
            streams.stream.*.codec_tag_string) [[ ${P[$k]} =~ ^(dvh1|dvhe|dva1|dvav)$ ]] && dv=1 ;;
            "$s".side_data_list.*.dv_bl_signal_compatibility_id) compat=${P[$k]} ;;
        esac
    done
    local base_ok=0
    case $PR_TRC in smpte2084|arib-std-b67) base_ok=1 ;; esac
    if [ "$dv" -ne 0 ]; then
        if [ "$base_ok" -eq 0 ] || [ "$compat" = 0 ]; then
            PR_HDR="Dolby Vision, no HDR10/HLG base layer (e.g. profile 5)"; PR_KIND="dv-rpu"
        elif [ "$PR_TRC" = arib-std-b67 ]; then
            PR_HDR="Dolby Vision with HLG base layer"; PR_KIND=hlg
        else
            PR_HDR="Dolby Vision with HDR10 base layer"; PR_KIND=pq
        fi
    elif [ "$PR_TRC" = smpte2084 ]; then
        if [ "$hdr10p" -ne 0 ]; then PR_HDR="HDR10+ / PQ (smpte2084)"; else PR_HDR="HDR10 / PQ (smpte2084)"; fi
        PR_KIND=pq
    elif [ "$PR_TRC" = arib-std-b67 ]; then
        PR_HDR="HLG (arib-std-b67)"; PR_KIND=hlg
    elif [ "$PR_PRIM" = bt2020 ]; then
        if known "$PR_TRC"; then
            PR_HDR="BT.2020 SDR, transfer $PR_TRC"; PR_KIND=gamut
        else
            PR_HDR="BT.2020 colour with no transfer tag"; PR_KIND=unsure
        fi
    fi
    return 0
}

join_parts() {
    local out="" p
    for p in "$@"; do out+="${out:+, }$p"; done
    printf '%s' "${out:-none}"
}

is_lossless_audio() {
    case $1 in
        truehd|mlp|flac|alac|ape|wavpack|tta|pcm_*) return 0 ;;
        dts) [[ $2 == *"HD MA"* ]] && return 0 ;;
    esac
    return 1
}

# Builds MAP_ARGS for all non-video streams and plan summaries. The video
# map comes from the encode loop, since a converted file maps a filter
# output instead of the input stream. Output stream 0 is always the video.
MAP_ARGS=(); PLAN_AUDIO=""; PLAN_SUBS=""
build_stream_args() {
    local i=0 oi=1 idx type codec ch br a_copy=0 a_enc=0 s_copy=0 s_conv=0 att=0
    local enc_from=() dropped=()
    MAP_ARGS=()
    while [ -n "${P[streams.stream.$i.index]:-}" ]; do
        idx=${P[streams.stream.$i.index]}
        type=${P[streams.stream.$i.codec_type]:-}
        codec=${P[streams.stream.$i.codec_name]:-unknown}
        case $type in
            audio)
                MAP_ARGS+=(-map "0:$idx")
                if [ "$AUDIO" = compress ] && is_lossless_audio "$codec" "${P[streams.stream.$i.profile]:-}"; then
                    ch=${P[streams.stream.$i.channels]:-2}
                    [[ $ch =~ ^[0-9]+$ ]] || ch=2
                    case $AUDIO_CODEC in
                        eac3)
                            if [ "$ch" -le 2 ]; then br=224k; else br=640k; fi
                            MAP_ARGS+=("-c:$oi" eac3 "-b:$oi" "$br")
                            [ "$ch" -gt 6 ] && MAP_ARGS+=("-ac:$oi" 6) ;;
                        aac)
                            if [ "$ch" -le 2 ]; then br=192k; elif [ "$ch" -le 6 ]; then br=384k; else br=512k; fi
                            MAP_ARGS+=("-c:$oi" aac "-b:$oi" "$br") ;;
                        opus)
                            if [ "$ch" -le 2 ]; then br=128k; elif [ "$ch" -le 6 ]; then br=256k; else br=384k; fi
                            # libopus rejects layouts like 5.1(side) unless remapped
                            MAP_ARGS+=("-c:$oi" libopus "-b:$oi" "$br" "-filter:$oi" "aformat=channel_layouts=7.1|6.1|5.1|5.0|quad|stereo|mono") ;;
                    esac
                    a_enc=$(( a_enc + 1 )); enc_from+=("$codec ${ch}ch")
                else
                    MAP_ARGS+=("-c:$oi" copy); a_copy=$(( a_copy + 1 ))
                fi
                oi=$(( oi + 1 )) ;;
            subtitle)
                case $codec in
                    subrip|srt|ass|ssa|webvtt|hdmv_pgs_subtitle|dvd_subtitle|dvb_subtitle)
                        MAP_ARGS+=(-map "0:$idx" "-c:$oi" copy); oi=$(( oi + 1 )); s_copy=$(( s_copy + 1 )) ;;
                    mov_text|text|sami|microdvd|subviewer|subviewer1|jacosub|realtext|stl|pjs|mpl2|vplayer)
                        MAP_ARGS+=(-map "0:$idx" "-c:$oi" srt); oi=$(( oi + 1 )); s_conv=$(( s_conv + 1 )) ;;
                    *)
                        dropped+=("$codec") ;;
                esac ;;
            attachment)
                MAP_ARGS+=(-map "0:$idx" "-c:$oi" copy); oi=$(( oi + 1 )); att=$(( att + 1 )) ;;
        esac
        i=$(( i + 1 ))
    done

    local parts=()
    [ "$a_copy" -ne 0 ] && parts+=("$a_copy copied")
    [ "$a_enc" -ne 0 ]  && parts+=("$a_enc re-encoded to ${AUDIO_CODEC^^} ($(IFS=,; printf '%s' "${enc_from[*]}"))")
    PLAN_AUDIO=$(join_parts "${parts[@]}")
    parts=()
    [ "$s_copy" -ne 0 ] && parts+=("$s_copy copied")
    [ "$s_conv" -ne 0 ] && parts+=("$s_conv converted to SRT")
    [ "${#dropped[@]}" -ne 0 ] && parts+=("${#dropped[@]} dropped ($(IFS=,; printf '%s' "${dropped[*]}"): not supported in MKV)")
    [ "$att" -ne 0 ]    && parts+=("$att attachment(s)/fonts kept")
    PLAN_SUBS=$(join_parts "${parts[@]}")
    return 0
}

# Colour tags for the output. Carried over when known; an untagged HD source
# is tagged BT.709, because once downscaled to SD most players would assume
# BT.601 and shift the colours.
COLOR_ARGS=()
known() { [ -n "$1" ] && [ "$1" != unknown ] && [ "$1" != reserved ]; }
build_color_args() {
    COLOR_ARGS=()
    if [ "$HDR_CONVERT" -ne 0 ]; then
        COLOR_ARGS=(-color_primaries bt709 -color_trc bt709 -colorspace bt709 -color_range tv)
        return 0
    fi
    if known "$PR_PRIM" || known "$PR_TRC" || known "$PR_SPACE"; then
        known "$PR_PRIM"  && COLOR_ARGS+=(-color_primaries "$PR_PRIM")
        known "$PR_TRC"   && COLOR_ARGS+=(-color_trc "$PR_TRC")
        known "$PR_SPACE" && COLOR_ARGS+=(-colorspace "$PR_SPACE")
    elif [[ $PR_H =~ ^[0-9]+$ && $PR_W =~ ^[0-9]+$ ]] && { [ "$PR_H" -ge 720 ] || [ "$PR_W" -ge 1280 ]; }; then
        COLOR_ARGS+=(-color_primaries bt709 -color_trc bt709 -colorspace bt709)
    fi
    known "$PR_RANGE" && COLOR_ARGS+=(-color_range "$PR_RANGE")
    return 0
}

# ===========================================================================
# Progress display (reads ffmpeg -progress output on stdin)
# ===========================================================================
progress_meter() {
    local dur_us=${1:-0} key val out_us=0 speed="" size=0 sp=0 pm=0 bucket=-1
    local tty=0 eta est line
    [ -t 1 ] && tty=1
    while IFS='=' read -r key val; do
        case $key in
            out_time_us) [[ $val =~ ^[0-9]+$ ]] && out_us=$val ;;
            total_size)  [[ $val =~ ^[0-9]+$ ]] && size=$val ;;
            speed)       speed=${val//[[:space:]x]/} ;;
            progress)
                sp=0
                if [[ $speed =~ ^([0-9]+)(\.([0-9]+))?$ ]]; then
                    local fr="${BASH_REMATCH[3]}00"
                    sp=$(( 10#${BASH_REMATCH[1]} * 100 + 10#${fr:0:2} ))
                fi
                line="  $(fmt_hms $(( out_us / 1000000 )))"
                if [ "$dur_us" -gt 0 ]; then
                    pm=$(( out_us * 1000 / dur_us )); [ "$pm" -gt 1000 ] && pm=1000
                    line=$(printf '  %3d.%d%%  %s / %s' $(( pm / 10 )) $(( pm % 10 )) \
                           "$(fmt_hms $(( out_us / 1000000 )))" "$(fmt_hms $(( dur_us / 1000000 )))")
                fi
                [ "$sp" -gt 0 ] && line+=$(printf '  %d.%02dx' $(( sp / 100 )) $(( sp % 100 )))
                if [ "$sp" -gt 0 ] && [ "$dur_us" -gt "$out_us" ]; then
                    eta=$(( (dur_us - out_us) / (sp * 10000) ))
                    line+="  ETA $(fmt_hms "$eta")"
                fi
                # Encoder lookahead and muxer buffering make early numbers meaningless
                if [ "$pm" -ge 50 ] && [ "$out_us" -ge 120000000 ] && [ "$size" -gt 0 ]; then
                    est=$(( size * 1000 / pm ))
                    line+="  ~$(fmt_size "$est") final"
                fi
                if [ "$tty" -ne 0 ]; then
                    printf '\r\e[K%s' "$line"
                elif [ "$dur_us" -gt 0 ] && [ "$(( pm / 100 ))" -gt "$bucket" ]; then
                    bucket=$(( pm / 100 )); printf '%s\n' "$line"
                fi
                [ "$val" = end ] && break ;;
        esac
    done
    [ "$tty" -ne 0 ] && printf '\n'
    cat > /dev/null   # drain anything left so ffmpeg never blocks on the pipe
}

# ===========================================================================
# File handling
# ===========================================================================
# Lock files are deleted on release. A process that opened the file just
# before it was deleted would then lock a dead inode, so after locking we
# check that the path still points at the inode we hold, and retry if not.
acquire_lock() {
    [ "$HAVE_FLOCK" -ne 0 ] || return 0
    local f="$LOCK_DIR/$1.lock" _
    for _ in 1 2 3; do
        if ! exec {LOCK_FD}>>"$f"; then LOCK_FD=""; return 2; fi
        if ! flock -n "$LOCK_FD"; then
            exec {LOCK_FD}>&-; LOCK_FD=""; return 1
        fi
        # bash's -ef compares device and inode, and for /dev/fd/N it looks
        # at the open descriptor itself
        if [ "/dev/fd/$LOCK_FD" -ef "$f" ]; then
            LOCK_FILE=$f; return 0
        fi
        exec {LOCK_FD}>&-; LOCK_FD=""
    done
    return 1
}

release_lock() {
    if [ -n "$LOCK_FD" ]; then
        rm -f -- "$LOCK_FILE"
        exec {LOCK_FD}>&-
        LOCK_FD=""; LOCK_FILE=""
    fi
    return 0
}

# Put a WIP-claimed source back where it came from.
return_claim() {
    [ -n "$CLAIM_WIP" ] || return 0
    if [ ! -e "$CLAIM_WIP" ]; then :
    elif [ -e "$CLAIM_SRC" ]; then
        warn "Could not return $CLAIM_WIP: $CLAIM_SRC exists. Left in the WIP dir."
    else
        mv -n -- "$CLAIM_WIP" "$CLAIM_SRC" 2>/dev/null || true
        if [ -e "$CLAIM_WIP" ]; then warn "Could not return $CLAIM_WIP to $CLAIM_SRC."
        else info "  Returned source from WIP dir."; fi
    fi
    CLAIM_WIP=""; CLAIM_SRC=""
}

# Move without ever overwriting. Succeeds only if the source is gone afterwards.
safe_move() {
    local from=$1 to=$2
    [ -e "$to" ] && return 1
    mv -n -- "$from" "$to" 2>/dev/null
    [ ! -e "$from" ] && [ -e "$to" ]
}

unique_path() {
    local p=$1 base ext
    [ -e "$p" ] || { printf '%s' "$p"; return; }
    base=${p%.*}; ext=${p##*.}
    [ "$base" = "$p" ] && ext="" || ext=".$ext"
    printf '%s.%s%s' "$base" "$(date +%Y%m%d-%H%M%S)" "$ext"
}

# Delete / archive / keep the original after a verified transcode.
handle_original() {
    local input=$1 src=$2 rel=$3 dest
    case $ORIGINALS in
        delete)
            rm -f -- "$input" || { ORIG_MSG="could not delete $input"; return 1; }
            ORIG_MSG="original deleted" ;;
        move)
            dest=$(unique_path "$ARCHIVE_DIR/$rel")
            mkdir -p -- "${dest%/*}" || { ORIG_MSG="could not create ${dest%/*}"; return 1; }
            same_fs "$input" "${dest%/*}" || info "  Copying original to archive (different filesystem)..."
            safe_move "$input" "$dest" || { ORIG_MSG="could not move original to $dest"; return 1; }
            ORIG_MSG="original archived to $dest" ;;
        keep)
            if [ "$input" != "$src" ]; then
                safe_move "$input" "$src" || { ORIG_MSG="could not return original from WIP dir ($input)"; return 1; }
            fi
            ORIG_MSG="original kept" ;;
    esac
    CLAIM_WIP=""; CLAIM_SRC=""
    return 0
}

log_hdr() {
    if [ ! -f "$HDR_LOG" ]; then
        {
            printf '# HDR videos log, created %s\n' "$(date)"
            printf '# These HDR / Dolby Vision / BT.2020 files were skipped. The run log says why for each.\n'
            printf '# Convert them by hand (e.g. HandBrake), or fix the cause and run again.\n\n'
        } > "$HDR_LOG" 2>/dev/null || return 0
    fi
    if ! grep -qxF -- "$1" "$HDR_LOG" 2>/dev/null; then
        printf '%s\n' "$1" >> "$HDR_LOG" 2>/dev/null || true
    fi
    return 0
}

verify_output() {
    local f=$1 want=$2 out got diff tol
    out=$(ffprobe -v error -show_entries format=duration:stream=codec_type -of flat -i "$f" 2>/dev/null) \
        || { VERIFY_MSG="output cannot be read by ffprobe"; return 1; }
    grep -q 'codec_type="video"' <<< "$out" || { VERIFY_MSG="output has no video stream"; return 1; }
    if [ "$want" -gt 0 ]; then
        got=$(sed -n 's/^format\.duration="\(.*\)"$/\1/p' <<< "$out")
        got=$(secs_to_us "$got")
        diff=$(( got > want ? got - want : want - got ))
        tol=$(( want / 200 )); [ "$tol" -lt 5000000 ] && tol=5000000
        if [ "$diff" -gt "$tol" ]; then
            VERIFY_MSG="duration mismatch: source $(fmt_hms $(( want / 1000000 ))), output $(fmt_hms $(( got / 1000000 )))"
            return 1
        fi
    fi
    [ "$HDR_CONVERT" -ne 0 ] && { verify_sdr "$f" || return 1; }
    return 0
}

# A converted file must come out tagged BT.709 with no HDR or Dolby Vision
# metadata left in the container or the first frame, or players would treat
# SDR pixels as HDR. Checked here so a bad output never replaces a source.
verify_sdr() {
    local f=$1 out trc
    out=$(ffprobe -v error -select_streams v:0 -show_streams -of flat -i "$f" 2>/dev/null) \
        || { VERIFY_MSG="output cannot be read by ffprobe"; return 1; }
    out+=$'\n'$(ffprobe -v error -select_streams v:0 -read_intervals '%+#1' -show_frames -of flat -i "$f" 2>/dev/null || true)
    trc=$(sed -n 's/^streams\.stream\.0\.color_transfer="\(.*\)"$/\1/p' <<< "$out")
    if [ "$trc" != bt709 ]; then
        VERIFY_MSG="converted output is tagged transfer '${trc:-none}', not bt709"; return 1
    fi
    if grep -qiE 'side_data_type="[^"]*(Mastering display|Content light level|DOVI|Dolby Vision|HDR Dynamic|HDR10)' <<< "$out"; then
        VERIFY_MSG="converted output still carries HDR / Dolby Vision metadata"; return 1
    fi
    return 0
}

mark() {
    local cat=$1; shift
    case $cat in
        done)   CNT_DONE=$(( CNT_DONE + 1 ));     printf '  %sDone:%s %s\n' "$C_GRN" "$C_RST" "$*" ;;
        dry)    CNT_DRY=$(( CNT_DRY + 1 ));       printf '  %s[dry run]%s %s\n' "$C_CYN" "$C_RST" "$*" ;;
        hdr)    CNT_HDR=$(( CNT_HDR + 1 ));       printf '  %sSkipped, HDR:%s %s\n' "$C_YEL" "$C_RST" "$*" ;;        skip)   CNT_SKIP=$(( CNT_SKIP + 1 ));     printf '  %sSkipped:%s %s\n' "$C_YEL" "$C_RST" "$*" ;;
        nogain) CNT_NOGAIN=$(( CNT_NOGAIN + 1 )); printf '  %sNot worth it:%s %s\n' "$C_YEL" "$C_RST" "$*" ;;
        fail)   CNT_FAIL=$(( CNT_FAIL + 1 ));     printf '  %sFAILED:%s %s\n' "$C_RED" "$C_RST" "$*" >&2
                FAILED_FILES+=("$CUR_REL: $*") ;;
    esac
    log "$cat: $CUR_REL: $*"
}

# ===========================================================================
# Per-file processing
# ===========================================================================
process_file() {
    local n=$1 src=$2 size=$3
    local rel=${src#"$SCAN_DIR"/}
    CUR_REL=$rel
    printf '\n%s[%d/%d]%s %s  %s%s%s\n' "$C_BLD" "$n" "$TOTAL" "$C_RST" "$rel" "$C_DIM" "$(fmt_size "$size")" "$C_RST"
    if [ "$DRY_RUN" -eq 0 ]; then
        local lock_rc=0
        acquire_lock "$(path_key "$rel")" || lock_rc=$?
        case $lock_rc in
            1) mark skip "being processed by another instance"; return ;;
            2) warn "Could not create a lock file in $LOCK_DIR; continuing without a lock." ;;
        esac
    fi
    process_one "$src" "$size" "$rel"
    CUR_PARTS=()
    release_lock
}

process_one() {
    local src=$1 size=$2 rel=$3

    [ -f "$src" ] || { mark skip "no longer exists (moved by another instance?)"; return; }
    size=$(file_size "$src" || printf '%s' "$size")

    if [ -f "$NOGAIN_LIST" ] && grep -qxF -- "$size"$'\t'"$rel" "$NOGAIN_LIST"; then
        mark skip "did not shrink enough on an earlier run (see $NOGAIN_LIST)"; return
    fi

    probe_file "$src" || { mark fail "ffprobe could not read the file"; return; }
    [ -n "$PR_MARKER" ] && { mark skip "already transcoded by this script ($PR_MARKER)"; return; }
    [ -n "$PR_VIDX" ]   || { mark skip "no video stream"; return; }

    hdr_decide
    if [ -n "$HDR_SKIP_WHY" ]; then
        [ "$DRY_RUN" -ne 0 ] || log_hdr "$src"
        mark hdr "$PR_HDR: $HDR_SKIP_WHY"; return
    fi
    if [[ -n $SKIP_CODECS && ",$SKIP_CODECS," == *",$PR_VCODEC,"* ]]; then
        mark skip "video is already $PR_VCODEC"; return
    fi

    # --- Geometry ---
    local out_h="" res_desc
    if [ "$(( 10#$MAX_HEIGHT ))" -gt 0 ]; then
        if [[ $PR_H =~ ^[0-9]+$ ]]; then
            [ "$PR_H" -gt "$(( 10#$MAX_HEIGHT ))" ] && out_h=$(( 10#$MAX_HEIGHT / 2 * 2 ))
        else
            out_h="'trunc(min(ih,$MAX_HEIGHT)/2)*2'"
        fi
    fi
    if [[ $out_h =~ ^[0-9]+$ ]]; then res_desc="${out_h}p"
    elif [ -n "$out_h" ]; then res_desc="max ${MAX_HEIGHT}p"
    else res_desc="same size"; fi

    build_stream_args
    build_color_args

    # --- Paths ---
    local src_dir=${src%/*} name=${src##*/} key
    local stem=${name%.*} rel_dir=""
    [[ $rel == */* ]] && rel_dir=${rel%/*}
    key=$(path_key "$rel"); key=${key:0:8}
    local out_name="${stem}${OUTPUT_SUFFIX}.mkv"
    local final_dir=$src_dir
    [ -n "$OUTPUT_DIR" ] && final_dir="$OUTPUT_DIR${rel_dir:+/$rel_dir}"
    local final_path="$final_dir/$out_name"
    local stage_path="$final_dir/.${out_name}.${key}.part"
    local encode_path=$stage_path
    [ -n "$SCRATCH_DIR" ] && encode_path="$SCRATCH_DIR/.${key}_${out_name}.part"
    local replaces_src=0
    [ "$final_path" = "$src" ] && replaces_src=1

    if [ "$replaces_src" -eq 0 ] && [ -e "$final_path" ]; then
        mark skip "output already exists: $final_path"; return
    fi

    printf '  Video : %s %sx%s %s -> HEVC %s, %s-bit, %s %s\n' "$PR_VCODEC" "${PR_W:-?}" "${PR_H:-?}" \
        "${PR_PIXFMT:-}" "$res_desc" "$BIT_DEPTH" "$(quality_label)" "$QUALITY"
    [ "$HDR_CONVERT" -ne 0 ] && printf '  HDR   : %s, %s\n' "$PR_HDR" "$(tonemap_desc)"
    printf '  Audio : %s\n' "$PLAN_AUDIO"
    printf '  Subs  : %s\n' "$PLAN_SUBS"

    # The RPU of a Dolby Vision file with no usable base layer is read from
    # the bitstream; CPU decode is the path where that is certain to work
    local attempts=("${ATTEMPTS[@]}") a
    if [ "$PR_KIND" = dv-rpu ]; then
        attempts=()
        for a in "${ATTEMPTS[@]}"; do [ "$a" = gpu ] || attempts+=("$a"); done
    fi

    if [ "$DRY_RUN" -ne 0 ]; then
        printf '  Output: %s\n' "$final_path"
        [ -n "$WIP_DIR" ] && printf '  WIP   : %s\n' "$WIP_DIR/${key}_$name"
        case $ORIGINALS in
            move)   printf '  Then  : archive original to %s\n' "$ARCHIVE_DIR/$rel" ;;
            delete) printf '  Then  : delete original\n' ;;
            keep)   printf '  Then  : keep original\n' ;;
        esac
        [ "$HDR_CONVERT" -ne 0 ] && CNT_TM=$(( CNT_TM + 1 ))
        mark dry "would transcode"
        return
    fi

    # --- Space checks ---
    local limit=0 need have
    [ "$(( 10#$MAX_OUTPUT_PCT ))" -gt 0 ] && limit=$(( size * 10#$MAX_OUTPUT_PCT / 100 ))
    need=$(( (limit > 0 ? limit : size) + 536870912 ))
    mkdir -p -- "$final_dir" || { mark fail "could not create $final_dir"; return; }
    have=$(free_bytes "${encode_path%/*}")
    if [[ $have =~ ^[0-9]+$ ]] && [ "$have" -lt "$need" ]; then
        mark skip "not enough free space in ${encode_path%/*} (need ~$(fmt_size "$need"), have $(fmt_size "$have"))"; return
    fi
    if [ -n "$SCRATCH_DIR" ] && ! same_fs "$SCRATCH_DIR" "$final_dir"; then
        have=$(free_bytes "$final_dir")
        if [[ $have =~ ^[0-9]+$ ]] && [ "$have" -lt "$need" ]; then
            mark skip "not enough free space in $final_dir (need ~$(fmt_size "$need"), have $(fmt_size "$have"))"; return
        fi
    fi

    # --- Claim (WIP move) ---
    local input=$src
    if [ -n "$WIP_DIR" ]; then
        local wip_path="$WIP_DIR/${key}_$name"
        if [ -e "$wip_path" ]; then mark skip "already in the WIP dir: $wip_path"; return; fi
        if ! same_fs "$src" "$WIP_DIR"; then
            have=$(free_bytes "$WIP_DIR")
            if [[ $have =~ ^[0-9]+$ ]] && [ "$have" -lt "$size" ]; then
                mark skip "not enough free space in WIP dir"; return
            fi
            info "  Copying source to WIP dir (different filesystem)..."
        fi
        if ! safe_move "$src" "$wip_path"; then
            [ -e "$src" ] && rm -f -- "$wip_path"
            mark fail "could not move source to WIP dir"; return
        fi
        CLAIM_SRC=$src; CLAIM_WIP=$wip_path
        input=$wip_path
    fi

    # --- Encode ---
    mkdir -p -- "$FFLOG_DIR" 2>/dev/null || true
    local ff_log
    ff_log="$FFLOG_DIR/$(date +%Y%m%d-%H%M%S)_${key}_${stem:0:60}.log"
    local fs_args=()
    [ "$limit" -gt 0 ] && fs_args=(-fs "$limit")
    local marker
    marker="v$VERSION $(enc_name) $(quality_label)=$QUALITY height=${out_h:-source}"
    [ "$HDR_CONVERT" -ne 0 ] && marker+=" sdr=$TM_BACKEND"
    marker+=" $(date +%F)"

    CUR_PARTS=("$encode_path")
    [ "$encode_path" != "$stage_path" ] && CUR_PARTS+=("$stage_path")

    local attempt rc=1 t0=$SECONDS cmd=() n_att=0 vid_args=() enc_extra=()
    for attempt in "${attempts[@]}"; do
        n_att=$(( n_att + 1 ))
        video_pipeline "$attempt" "$out_h"
        if [ "$HDR_CONVERT" -ne 0 ]; then
            # A filter_complex output has no input stream behind it, so ffmpeg
            # can't copy the source's HDR / Dolby Vision stream metadata onto
            # the SDR output (which it does with -vf, at least up to 6.1)
            vid_args=(-filter_complex "[0:$PR_VIDX]${VF}[vout]" -map "[vout]")
            enc_extra=("${ENC_HDR_ARGS[@]}")
        else
            vid_args=(-map "0:$PR_VIDX" -vf "$VF")
            enc_extra=()
        fi
        cmd=( "${NICE_PREFIX[@]}" ffmpeg -hide_banner -nostdin -y
              -analyzeduration 100M -probesize 100M
              "${PRE_INPUT[@]}"
              -i "$input"
              "${vid_args[@]}"
              "${MAP_ARGS[@]}"
              "${VIDEO_ENC[@]}" "${enc_extra[@]}"
              "${COLOR_ARGS[@]}"
              -map_metadata 0 -map_chapters 0
              -metadata "$MARKER_TAG=$marker"
              -max_muxing_queue_size 4096
              "${fs_args[@]}"
              -progress pipe:1 -nostats
              -f matroska "$encode_path" )
        [ "$n_att" -gt 1 ] && info "  GPU decode failed; retrying with CPU decode."
        info "  Encoding with $(attempt_label "$attempt")"
        { printf '### attempt %d (%s)\n### ' "$n_att" "$attempt"; printf '%q ' "${cmd[@]}"; printf '\n'; } >> "$ff_log"
        # rc is ffmpeg's own exit status, not the progress reader's
        if "${cmd[@]}" 2>>"$ff_log" | progress_meter "$PR_DUR_US"; then
            rc=0
        else
            rc=${PIPESTATUS[0]}
        fi
        # ffmpeg catches Ctrl+C / SIGTERM and exits normally with 255. Bash then
        # assumes the child dealt with the signal and does not run our trap,
        # so treat that exit as an interrupt ourselves. grep reads a process
        # substitution so an early exit can't trip pipefail on tail.
        if [ "$rc" -eq 255 ] && grep -qi 'received signal' < <(tail -n 20 "$ff_log" 2>/dev/null || true); then
            on_interrupt
        fi
        [ "$rc" -eq 0 ] && break
        rm -f -- "$encode_path"
    done
    local elapsed=$(( SECONDS - t0 ))

    if [ "$rc" -ne 0 ]; then
        rm -f -- "${CUR_PARTS[@]}"; CUR_PARTS=()
        return_claim
        printf '%s' "$C_DIM"; { tail -n 4 "$ff_log" 2>/dev/null || true; } | sed 's/^/    /'; printf '%s' "$C_RST"
        mark fail "ffmpeg exited with $rc after $(fmt_hms "$elapsed"). Log: $ff_log"
        return
    fi

    local out_size
    out_size=$(file_size "$encode_path" || printf '0')
    if [ "$limit" -gt 0 ] && [ "$out_size" -ge "$limit" ]; then
        rm -f -- "${CUR_PARTS[@]}"; CUR_PARTS=()
        return_claim
        printf '%s\t%s\n' "$size" "$rel" >> "$NOGAIN_LIST"
        rm -f -- "$ff_log"
        mark nogain "output hit ${MAX_OUTPUT_PCT}% of the source size, encode stopped, original kept (will be skipped next time)"
        return
    fi
    if ! verify_output "$encode_path" "$PR_DUR_US"; then
        rm -f -- "${CUR_PARTS[@]}"; CUR_PARTS=()
        return_claim
        mark fail "verification failed: $VERIFY_MSG. Log: $ff_log"
        return
    fi

    # --- Bring the output next to its final location ---
    if [ "$encode_path" != "$stage_path" ]; then
        same_fs "$encode_path" "$final_dir" || info "  Copying output from scratch dir..."
        if ! mv -f -- "$encode_path" "$stage_path"; then
            rm -f -- "$stage_path"
            local kept="$SCRATCH_DIR/${key}_${out_name}"
            mv -f -- "$encode_path" "$kept" 2>/dev/null || kept=$encode_path
            CUR_PARTS=()
            return_claim
            mark fail "could not move output out of the scratch dir; finished file kept at $kept"
            return
        fi
    fi
    CUR_PARTS=()   # the staged file is a verified output from here on; never auto-delete it

    # --- Place output and handle the original, in the safe order ---
    ORIG_MSG=""
    if [ "$replaces_src" -ne 0 ]; then
        # Output takes the source's own name: the original has to go first.
        if ! handle_original "$input" "$src" "$rel"; then
            return_claim
            mark fail "$ORIG_MSG. Verified output left at $stage_path"
            return
        fi
        if ! safe_move "$stage_path" "$final_path"; then
            mark fail "$ORIG_MSG, but renaming the output failed. It is at $stage_path"
            return
        fi
    else
        if ! safe_move "$stage_path" "$final_path"; then
            return_claim
            mark fail "could not rename output to $final_path; original untouched, output at $stage_path"
            return
        fi
        if ! handle_original "$input" "$src" "$rel"; then
            return_claim
            mark fail "output is in place, but $ORIG_MSG"
            return
        fi
    fi

    rm -f -- "$ff_log"
    BYTES_IN=$(( BYTES_IN + size )); BYTES_OUT=$(( BYTES_OUT + out_size ))
    local pct=$(( size > 0 ? out_size * 100 / size : 0 ))
    [ "$HDR_CONVERT" -ne 0 ] && CNT_TM=$(( CNT_TM + 1 ))
    mark "done" "$(fmt_size "$size") -> $(fmt_size "$out_size") (${pct}%) in $(fmt_hms "$elapsed"); $ORIG_MSG"
}

# ===========================================================================
# Run setup, scan, summary
# ===========================================================================
prepare_run() {
    STATE_DIR="$SCAN_DIR/$STATE_DIR_NAME"
    # Keeps the no-gain list from runs before the rename. Run a library with
    # one version at a time while this happens, since locks live here too.
    if [ "$DRY_RUN" -eq 0 ]; then
        migrate_dir "$SCAN_DIR/$OLD_STATE_DIR_NAME" "$STATE_DIR"
    fi
    LOCK_DIR="$STATE_DIR/locks"
    NOGAIN_LIST="$STATE_DIR/no-gain.list"
    HDR_LOG="$SCAN_DIR/$HDR_LOG_NAME"
    MIN_BYTES=$(gib_to_bytes "$MIN_SIZE_GB")

    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p -- "$LOCK_DIR" || die "Cannot create $LOCK_DIR"
        mkdir -p -- "$LOG_DIR" "$FFLOG_DIR" 2>/dev/null || warn "Cannot create log dir $LOG_DIR"
        [ "$HAVE_FLOCK" -ne 0 ] || warn "flock not found: running several instances on the same library is not safe."
    fi

    NICE_PREFIX=()
    if [ "$(( 10#$NICE ))" -gt 0 ]; then
        NICE_PREFIX=(nice -n "$NICE")
        command -v ionice >/dev/null 2>&1 && NICE_PREFIX+=(ionice -c2 -n7)
    fi

    build_encoder_settings
    resolve_tonemap

    [ "$ENCODER" = nvidia ] && ! nvidia_present && warn "No NVIDIA device detected; hevc_nvenc will probably fail."
    if [ "$ENCODER" != cpu ] && [ "$HW_DECODE" = auto ] && [ "${ATTEMPTS[0]}" = sw ]; then
        warn "This ffmpeg lacks the GPU scaler for $ENCODER; using CPU decode + GPU encode."
    fi
    if [ -n "$WIP_DIR" ] && ! same_fs "$SCAN_DIR" "$WIP_DIR"; then
        warn "WIP dir is on a different filesystem: every source will be copied there and back."
    fi
    if [ "$ENCODER" != cpu ] && [ "$(( 10#$QUALITY ))" -lt 18 ]; then
        warn "$(quality_label) $QUALITY on $(enc_name) is very high quality and may barely shrink files; the size guard will catch those."
    fi
}

scan_files() {
    local d ext prune=() names=() path i key
    local -a order=() sorted_files=() sorted_sizes=()
    for d in "$ARCHIVE_DIR" "$WIP_DIR" "$SCRATCH_DIR" "$OUTPUT_DIR"; do
        if [[ -n $d && $d == "$SCAN_DIR"/* ]]; then prune+=(-o -path "$(glob_escape "$d")"); fi
    done
    # Unquoted on purpose: EXTENSIONS is a space-separated list
    for ext in $EXTENSIONS; do
        if [ "${#names[@]}" -ne 0 ]; then names+=(-o); fi
        names+=(-iname "*.$ext")
    done
    local not_ours=()
    if [ -n "$OUTPUT_SUFFIX" ]; then not_ours=(! -iname "*${OUTPUT_SUFFIX}.mkv"); fi

    FILES=(); SIZES=()
    while IFS= read -r -d '' path; do
        FILES+=("$path")
        SIZES+=("$(file_size "$path" || printf '0')")
    done < <(find "$SCAN_DIR" -mindepth 1 \
                \( -name '.*' "${prune[@]}" \) -prune -o \
                -type f -size +"${MIN_BYTES}c" \( "${names[@]}" \) "${not_ours[@]}" \
                -print0 2>/dev/null || true)
    TOTAL=${#FILES[@]}
    [ "$TOTAL" -gt 1 ] || return 0

    # Sort index numbers, not the paths themselves, so a path with a tab or
    # newline in it can't break the sort and no NUL-aware sort is needed.
    while IFS=$'\t' read -r _ i; do
        order+=("$i")
    done < <(
        for i in "${!FILES[@]}"; do
            case $ORDER in
                largest|smallest) key=${SIZES[i]} ;;
                *) key=${FILES[i]//[$'\t\n']/ } ;;
            esac
            printf '%s\t%s\n' "$key" "$i"
        done | case $ORDER in
            largest)  sort -t "$(printf '\t')" -k1,1nr ;;
            smallest) sort -t "$(printf '\t')" -k1,1n ;;
            *)        sort -t "$(printf '\t')" -k1,1 ;;
        esac
    )
    for i in "${order[@]}"; do
        sorted_files+=("${FILES[i]}")
        sorted_sizes+=("${SIZES[i]}")
    done
    FILES=("${sorted_files[@]}")
    SIZES=("${sorted_sizes[@]}")
}

print_header() {
    local total_bytes=0 s
    for s in "${SIZES[@]}"; do total_bytes=$(( total_bytes + s )); done
    rule
    printf '  Scan dir     : %s\n' "$SCAN_DIR"
    printf '  Candidates   : %d file(s) over %s GiB, %s total\n' "$TOTAL" "$MIN_SIZE_GB" "$(fmt_size "$total_bytes")"
    printf '  Encoder      : %s, %s %s, %s-bit, max height %s\n' "$(enc_name)" "$(quality_label)" "$QUALITY" "$BIT_DEPTH" \
        "$( [ "$(( 10#$MAX_HEIGHT ))" -gt 0 ] && printf '%s\n' "${MAX_HEIGHT}p" || printf '%s\n' source)"
    if [ "$HDR_MODE" = skip ]; then
        printf '  HDR          : skip and log\n'
    elif [ -n "$TM_BACKEND" ]; then
        printf '  HDR          : to SDR BT.709 with %s, curve %s\n' "$TM_BACKEND" "$TM_CURVE"
    else
        printf '  HDR          : %sskip and log, no working tone mapping filter%s\n' "$C_YEL" "$C_RST"
    fi
    printf '  Originals    : %s\n' "$(desc_originals)"
    printf '  Output       : %s\n' "$(desc_output)"
    [ -n "$SCRATCH_DIR" ] && printf '  Scratch      : %s\n' "$SCRATCH_DIR"
    [ -n "$WIP_DIR" ]     && printf '  WIP          : %s\n' "$WIP_DIR"
    [ "$LIMIT" -gt 0 ]       && printf '  Limit        : %d transcode(s)\n' "$LIMIT"
    if [ "$DRY_RUN" -ne 0 ]; then
        printf '  %s*** DRY RUN: nothing will be changed ***%s\n' "$C_YEL" "$C_RST"
    else
        printf '  Run log      : %s\n' "$RUN_LOG"
        printf '  Stop cleanly : kill -USR1 %d  (finishes the current file)\n' "$$"
    fi
    rule
}

print_summary() {
    local elapsed=$(( SECONDS - RUN_T0 )) f
    printf '\n'
    rule
    printf '  Run finished after %s\n' "$(fmt_hms "$elapsed")"
    rule
    if [ "$DRY_RUN" -ne 0 ]; then
        printf '  Would transcode    : %d\n' "$CNT_DRY"
    else
        printf '  Transcoded         : %d' "$CNT_DONE"
        if [ "$CNT_DONE" -gt 0 ]; then
            printf '   (%s -> %s, saved %s)' "$(fmt_size "$BYTES_IN")" "$(fmt_size "$BYTES_OUT")" "$(fmt_size $(( BYTES_IN - BYTES_OUT )))"
        fi
        printf '\n'
    fi
    [ "$CNT_TM" -gt 0 ] && printf '    of which to SDR  : %d\n' "$CNT_TM"
    printf '  Skipped, HDR       : %d\n' "$CNT_HDR"
    [ "$DRY_RUN" -ne 0 ] || printf '  Did not shrink     : %d\n' "$CNT_NOGAIN"
    printf '  Skipped, other     : %d\n' "$CNT_SKIP"
    printf '  Failed             : %d\n' "$CNT_FAIL"
    for f in "${FAILED_FILES[@]}"; do printf '    %s- %s%s\n' "$C_RED" "$f" "$C_RST"; done
    [ "$CNT_HDR" -gt 0 ] && [ "$DRY_RUN" -eq 0 ] && printf '  HDR log            : %s\n' "$HDR_LOG"
    [ "$DRY_RUN" -ne 0 ] && printf '  %s*** DRY RUN: nothing was changed ***%s\n' "$C_YEL" "$C_RST"
    rule
    log "run finished: done=$CNT_DONE tonemapped=$CNT_TM hdr_skipped=$CNT_HDR nogain=$CNT_NOGAIN skipped=$CNT_SKIP failed=$CNT_FAIL saved=$(( BYTES_IN - BYTES_OUT ))"
}

# shellcheck disable=SC2317,SC2329  # invoked via trap
on_interrupt() {
    trap '' INT TERM
    printf '\n'
    warn "Interrupted."
    local p
    for p in "${CUR_PARTS[@]}"; do
        if [ -e "$p" ]; then rm -f -- "$p"; info "Removed partial file: $p"; fi
    done
    CUR_PARTS=()
    return_claim
    release_lock
    [ -n "$CUR_REL" ] && log "interrupted during $CUR_REL"
    [ "$STARTED" -ne 0 ] && print_summary
    exit 130
}

# Strict mode stops the script on an unexpected failure. When that happens
# mid-file, clean up the same way Ctrl+C does so nothing is left half done.
# shellcheck disable=SC2317,SC2329  # invoked via trap
on_exit() {
    local rc=$? p
    [ "$rc" -ne 0 ] || return 0
    if [ "${#CUR_PARTS[@]}" -ne 0 ] || [ -n "$CLAIM_WIP" ]; then
        warn "Stopped by an unexpected error (exit $rc) while working on $CUR_REL."
        for p in "${CUR_PARTS[@]}"; do
            if [ -e "$p" ]; then rm -f -- "$p"; info "Removed partial file: $p"; fi
        done
        CUR_PARTS=()
        return_claim
    fi
    release_lock
}

# shellcheck disable=SC2317,SC2329  # invoked via trap
on_usr1() {
    STOP_REQUESTED=1
    info "  Stop requested: exiting after the current file."
}

# ===========================================================================
# Main
# ===========================================================================
main() {
    local missing=() cmd
    for cmd in ffmpeg ffprobe awk sed grep find sort cut df wc tail md5sum date mkdir mv rm; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [ "${#missing[@]}" -eq 0 ] || die "missing required commands: ${missing[*]}"

    trap on_interrupt INT TERM HUP
    trap on_usr1 USR1
    trap on_exit EXIT

    parse_args "$@"
    migrate_dir "$OLD_CONFIG_DIR" "$CONFIG_DIR"
    migrate_dir "$OLD_LOG_DIR" "$LOG_DIR"
    resolve_config
    normalize_settings
    detect_ffmpeg

    if [ -n "$SAVE_PROFILE" ]; then
        save_config "$(profile_path "$SAVE_PROFILE")" || die "Could not save profile $SAVE_PROFILE."
        info "Saved profile '$SAVE_PROFILE' to $(profile_path "$SAVE_PROFILE")"
        PROFILE_NAME=$SAVE_PROFILE
    fi

    if [ "$ASSUME_YES" -ne 0 ] || [ ! -t 0 ]; then
        if ! validate_settings; then
            local e
            for e in "${VALIDATION_ERRORS[@]}"; do err "$e"; done
            printf '%s\n' "Run '$PROG --help' for options, or run it in a terminal without --yes for the settings screen." >&2
            exit 1
        fi
    else
        run_menu
    fi

    prepare_run
    info "Scanning $SCAN_DIR ..."
    scan_files
    print_header
    if [ "$TOTAL" -eq 0 ]; then
        info "Nothing to do: no matching files over $MIN_SIZE_GB GiB."
        exit 0
    fi
    log "run started: $TOTAL candidate(s) in $SCAN_DIR, $(enc_name) $(quality_label)=$QUALITY height=$MAX_HEIGHT originals=$ORIGINALS"

    STARTED=1
    RUN_T0=$SECONDS
    local i
    for i in "${!FILES[@]}"; do
        if [ "$STOP_REQUESTED" -ne 0 ]; then info "Stopping as requested."; break; fi
        if [ "$LIMIT" -gt 0 ] && [ "$(( CNT_DONE + CNT_DRY ))" -ge "$LIMIT" ]; then info "Reached the limit of $LIMIT."; break; fi
        process_file $(( i + 1 )) "${FILES[i]}" "${SIZES[i]}"
    done
    CUR_REL=""

    print_summary
    [ "$CNT_FAIL" -gt 0 ] && exit 1
    exit 0
}

main "$@"
