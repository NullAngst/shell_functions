#!/usr/bin/env bash
#
# unpack - recursively extract archives into a directory of their own, then
# delete the source archive (and its sibling volumes) on success.
#
# Formats: tar, tar.gz/tgz, tar.bz2/tbz2/tbz, tar.xz/txz, tar.zst/tzst, zip,
# rar, 7z, bare gz/bz2/xz/zst, and multi-volume sets (.partN.rar, .rNN/.sNN,
# .zNN, .zip.NNN, .7z.NNN, and generic .NNN splits such as name.tar.001).
#
# Usage: unpack [-k] [-n] [-v] [-d N] <file|directory> [more...]
#   -k   keep source archives instead of deleting them
#   -n   dry run: report what would happen, change nothing
#   -v   verbose: show extractor output
#   -d N maximum nesting depth for archives inside archives (default 8)
#   -h   this help
#
# Exit status: 0 if every target succeeded, 1 otherwise, 2 on usage errors.
#
# External tools are only required for the formats actually encountered:
# tar, gzip, bzip2, xz, zstd, unrar (or 7z), and 7z/7zz/7za.
#
# Tested under bash 5.2 and zsh 5.9.

_unpack_usage() {
    cat <<'EOF'
Usage: unpack [-k] [-n] [-v] [-d N] <file|directory> [more...]
  -k   keep source archives instead of deleting them
  -n   dry run: report what would happen, change nothing
  -v   verbose: show extractor output
  -d N maximum nesting depth for archives inside archives (default 8)
  -h   show this help
EOF
}

_unpack_warn() { printf 'unpack: %s\n' "$*" >&2; }
_unpack_info() { printf '%s\n' "$*"; }
_unpack_have() { command -v "$1" >/dev/null 2>&1; }
_unpack_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Run an extractor with stdin closed (so it can never block on a password
# prompt) and stdout suppressed unless -v was given. stderr always passes
# through so real failures stay visible.
_unpack_run() {
    if [ "${_unpack_verbose:-0}" -eq 1 ]; then
        "$@" < /dev/null
    else
        "$@" < /dev/null > /dev/null
    fi
}

# First available 7-Zip binary. 7za cannot read rar, which is handled below.
_unpack_7zbin() {
    local b=""
    for b in 7zz 7z 7za; do
        if _unpack_have "$b"; then
            printf '%s' "$b"
            return 0
        fi
    done
    return 1
}

# Classify a lowercased basename. Order matters: longer suffixes first.
_unpack_kind() {
    case "$1" in
        *.tar.gz|*.tgz)          printf 'tar_gz' ;;
        *.tar.bz2|*.tbz2|*.tbz)  printf 'tar_bz2' ;;
        *.tar.xz|*.txz)          printf 'tar_xz' ;;
        *.tar.zst|*.tzst)        printf 'tar_zst' ;;
        *.tar)                   printf 'tar' ;;
        *.rar)                   printf 'rar' ;;
        *.zip|*.zip.001)         printf 'zip' ;;
        *.7z|*.7z.001)           printf '7z' ;;
        *.gz)                    printf 'gz' ;;
        *.bz2)                   printf 'bz2' ;;
        *.xz)                    printf 'xz' ;;
        *.zst)                   printf 'zst' ;;
        *.[0-9][0-9][0-9])       printf 'split' ;;
        *) return 1 ;;
    esac
}

# True for a non-first volume of a multi-volume set. Those are pulled in by
# the extractor when the first volume is opened, so they are never a target.
_unpack_is_continuation() {
    local lb="$1"
    case "$lb" in
        *.part[0-9]*.rar)
            case "$lb" in
                *.part1.rar|*.part01.rar|*.part001.rar|*.part0001.rar) return 1 ;;
                *) return 0 ;;
            esac
            ;;
    esac
    if [[ $lb =~ \.[rs][0-9][0-9]$ ]] || [[ $lb =~ \.z[0-9][0-9]+$ ]]; then
        return 0
    fi
    if [[ $lb =~ \.[0-9][0-9][0-9]$ ]] && [[ ! $lb =~ \.001$ ]]; then
        return 0
    fi
    return 1
}

# Remove one known archive suffix from a basename, preserving its case.
_unpack_strip_suffix() {
    local b="$1"
    local lb=""
    lb=$(_unpack_lower "$b")

    case "$lb" in
        *.part[0-9]*.rar)
            local t="${b%.*}"
            printf '%s' "${t%.*}"
            return ;;
    esac

    local suf=""
    for suf in .tar.gz .tar.bz2 .tar.xz .tar.zst .tgz .tbz2 .tbz .txz .tzst \
               .tar .zip.001 .zip .7z.001 .7z .rar .gz .bz2 .xz .zst; do
        case "$lb" in
            *"$suf")
                printf '%s' "${b:0:$(( ${#b} - ${#suf} ))}"
                return ;;
        esac
    done

    case "$lb" in
        *.[0-9][0-9][0-9])
            printf '%s' "${b:0:$(( ${#b} - 4 ))}"
            return ;;
    esac

    printf '%s' "$b"
}

# A path that does not exist yet, so extraction never merges into or
# overwrites something that was already there.
_unpack_unique_path() {
    local p="$1"
    local i=1
    if [ ! -e "$p" ]; then
        printf '%s' "$p"
        return
    fi
    while [ -e "${p}_$i" ]; do
        i=$((i + 1))
    done
    printf '%s' "${p}_$i"
}

# Delete the volumes belonging to one archive set. The prefix is compared
# literally (case-insensitively) rather than being spliced into a glob, so a
# name containing *, ? or [ ] cannot reach unrelated files.
_unpack_delete_set() {
    local dir="$1" prefix="$2" mode="$3"
    local plower=""
    plower=$(_unpack_lower "$prefix")
    local plen="${#plower}"
    local f="" b="" bl="" suf=""

    while IFS= read -r -d '' f; do
        b="${f##*/}"
        bl=$(_unpack_lower "$b")
        [ "${bl:0:$plen}" = "$plower" ] || continue
        suf="${bl:$plen}"
        case "$mode" in
            rar_old)  [[ $suf =~ ^\.(rar|r[0-9][0-9]|s[0-9][0-9])$ ]] || continue ;;
            rar_part) [[ $suf =~ ^\.part[0-9]+\.rar$ ]] || continue ;;
            zip)      [[ $suf =~ ^(\.zip|\.z[0-9][0-9]+|\.zip\.[0-9][0-9][0-9])$ ]] || continue ;;
            sevenz)   [[ $suf =~ ^(\.7z|\.7z\.[0-9][0-9][0-9])$ ]] || continue ;;
            split)    [[ $suf =~ ^\.[0-9][0-9][0-9]$ ]] || continue ;;
            *) continue ;;
        esac
        rm -f -- "$f"
    done < <(find "$dir" -maxdepth 1 -type f -print0)
}

_unpack_missing() {
    _unpack_warn "cannot extract '$2': $1 is not installed"
    return 1
}

# $1 archive, $2 destination directory, $3 kind, $4 stem (for bare
# compressors, the name to write inside the destination).
_unpack_extract() {
    local file="$1" dest="$2" kind="$3" stem="$4"
    local tv=""
    if [ "$_unpack_verbose" -eq 1 ]; then tv="v"; fi
    local z=""

    case "$kind" in
        tar|tar_gz|tar_bz2|tar_xz|tar_zst)
            _unpack_have tar || { _unpack_missing tar "$file"; return 1; }
            case "$kind" in
                tar)     _unpack_run tar "-x${tv}f" "$file" -C "$dest" ;;
                tar_gz)  _unpack_have gzip  || { _unpack_missing gzip "$file"; return 1; }
                         _unpack_run tar "-x${tv}zf" "$file" -C "$dest" ;;
                tar_bz2) _unpack_have bzip2 || { _unpack_missing bzip2 "$file"; return 1; }
                         _unpack_run tar "-x${tv}jf" "$file" -C "$dest" ;;
                tar_xz)  _unpack_have xz    || { _unpack_missing xz "$file"; return 1; }
                         _unpack_run tar "-x${tv}Jf" "$file" -C "$dest" ;;
                tar_zst) _unpack_have zstd  || { _unpack_missing zstd "$file"; return 1; }
                         # Relies on tar's compression auto-detection
                         # (GNU tar 1.31+ or bsdtar).
                         _unpack_run tar "-x${tv}f" "$file" -C "$dest" ;;
            esac
            ;;
        gz)  _unpack_have gzip  || { _unpack_missing gzip "$file"; return 1; }
             gzip -dc "$file" > "$dest/$stem" ;;
        bz2) _unpack_have bzip2 || { _unpack_missing bzip2 "$file"; return 1; }
             bzip2 -dc "$file" > "$dest/$stem" ;;
        xz)  _unpack_have xz    || { _unpack_missing xz "$file"; return 1; }
             xz -dc "$file" > "$dest/$stem" ;;
        zst) _unpack_have zstd  || { _unpack_missing zstd "$file"; return 1; }
             zstd -dcq "$file" > "$dest/$stem" ;;
        rar)
            if _unpack_have unrar; then
                _unpack_run unrar x -or -y "$file" "$dest/"
            elif _unpack_have rar; then
                _unpack_run rar x -or -y "$file" "$dest/"
            else
                z=$(_unpack_7zbin) || { _unpack_missing "unrar or 7z" "$file"; return 1; }
                [ "$z" = "7za" ] && { _unpack_missing unrar "$file"; return 1; }
                _unpack_run "$z" x -aou -y -bd "-o$dest" "$file"
            fi
            ;;
        zip|7z|split)
            z=$(_unpack_7zbin) || { _unpack_missing 7z "$file"; return 1; }
            _unpack_run "$z" x -aou -y -bd "-o$dest" "$file"
            ;;
        *)
            _unpack_warn "internal error: unhandled kind '$kind'"
            return 1
            ;;
    esac
}

# Scan one directory level for archives worth unpacking.
_unpack_dir() {
    local dir="$1" depth="$2"
    local rc=0 f="" b="" bl=""

    while IFS= read -r -d '' f; do
        b="${f##*/}"
        bl=$(_unpack_lower "$b")
        _unpack_kind "$bl" >/dev/null 2>&1 || continue
        _unpack_is_continuation "$bl" && continue
        _unpack_one "$f" "$depth" || rc=1
    done < <(find "$dir" -maxdepth 1 -type f -print0)

    return "$rc"
}

_unpack_one() {
    local target="$1" depth="$2"
    case "$target" in
        -*) target="./$target" ;;
    esac

    if [ "$depth" -gt "$_unpack_maxdepth" ]; then
        _unpack_warn "depth limit ($_unpack_maxdepth) reached, leaving '$target' packed"
        return 1
    fi

    if [ -d "$target" ]; then
        _unpack_dir "$target" "$depth"
        return
    fi
    if [ ! -f "$target" ]; then
        _unpack_warn "'$target' is not a regular file or directory"
        return 1
    fi

    local dir="" base="" lb=""
    dir=$(dirname -- "$target")
    base=$(basename -- "$target")
    lb=$(_unpack_lower "$base")

    if _unpack_is_continuation "$lb"; then
        _unpack_info "skipping '$base': part of a multi-volume set, unpack the first volume instead"
        return 0
    fi

    local kind=""
    kind=$(_unpack_kind "$lb") || {
        _unpack_warn "unsupported archive format: '$target'"
        return 1
    }

    local stem=""
    stem=$(_unpack_strip_suffix "$base")
    [ -n "$stem" ] || stem="${base}.out"

    # Bare single-file compressors produce one file, not a tree, so they are
    # decompressed alongside the archive instead of into a new directory.
    local out=""
    if [ "$kind" = gz ] || [ "$kind" = bz2 ] || [ "$kind" = xz ] || [ "$kind" = zst ]; then
        out=$(_unpack_unique_path "$dir/$stem")
        if [ "$_unpack_dry" -eq 1 ]; then
            _unpack_info "would decompress '$target' -> '$out'"
            return 0
        fi
        if _unpack_extract "$target" "$dir" "$kind" "${out##*/}"; then
            _unpack_info "decompressed '$base' -> '${out##*/}'"
            if [ "$_unpack_keep" -eq 0 ]; then
                rm -f -- "$target"
            fi
            local outlb=""
            outlb=$(_unpack_lower "${out##*/}")
            if _unpack_kind "$outlb" >/dev/null 2>&1; then
                _unpack_one "$out" $((depth + 1)) || return 1
            fi
            return 0
        fi
        _unpack_warn "decompression failed for '$target', source kept"
        rm -f -- "$out" 2>/dev/null
        return 1
    fi

    # Volume set bookkeeping. vol_prefix is matched literally, not as a glob.
    local vol_prefix="" vol_mode=""
    case "$kind" in
        split)
            vol_prefix="$stem"
            vol_mode="split"
            local inner="$stem"
            stem=$(_unpack_strip_suffix "$inner")
            [ -n "$stem" ] || stem="$inner"
            ;;
        zip) vol_prefix="$stem"; vol_mode="zip" ;;
        7z)  vol_prefix="$stem"; vol_mode="sevenz" ;;
        rar)
            vol_prefix="$stem"
            case "$lb" in
                *.part[0-9]*.rar) vol_mode="rar_part" ;;
                *) vol_mode="rar_old" ;;
            esac
            ;;
    esac

    local dest=""
    dest=$(_unpack_unique_path "$dir/$stem")

    if [ "$_unpack_dry" -eq 1 ]; then
        _unpack_info "would unpack '$target' -> '$dest/'"
        return 0
    fi

    if ! mkdir -p -- "$dest"; then
        _unpack_warn "could not create '$dest'"
        return 1
    fi

    if _unpack_extract "$target" "$dest" "$kind" "$stem"; then
        _unpack_info "unpacked '$base' -> '$dest/'"
        if [ "$_unpack_keep" -eq 0 ]; then
            if [ -n "$vol_mode" ]; then
                _unpack_delete_set "$dir" "$vol_prefix" "$vol_mode"
            else
                rm -f -- "$target"
            fi
        fi
        if rmdir -- "$dest" 2>/dev/null; then
            _unpack_warn "'$base' contained nothing"
            return 0
        fi
        _unpack_dir "$dest" $((depth + 1)) || return 1
        return 0
    fi

    _unpack_warn "extraction failed for '$target', sources kept"
    # $dest did not exist before this call, so removing it is safe. It only
    # survives if the extractor left partial output behind.
    if ! rmdir -- "$dest" 2>/dev/null; then
        _unpack_warn "partial output left in '$dest/'"
    fi
    return 1
}

unpack() {
    local _unpack_keep=0 _unpack_dry=0 _unpack_verbose=0 _unpack_maxdepth=8
    local OPTIND=1 OPTARG="" opt="" rc=0 t=""

    while getopts ':knvd:h' opt; do
        case "$opt" in
            k) _unpack_keep=1 ;;
            n) _unpack_dry=1 ;;
            v) _unpack_verbose=1 ;;
            d) _unpack_maxdepth="$OPTARG" ;;
            h) _unpack_usage; return 0 ;;
            :) _unpack_warn "option -$OPTARG requires an argument"; return 2 ;;
            *) _unpack_warn "unknown option -$OPTARG"; return 2 ;;
        esac
    done
    shift $((OPTIND - 1))

    if ! [[ $_unpack_maxdepth =~ ^[0-9]+$ ]]; then
        _unpack_warn "-d needs a non-negative integer"
        return 2
    fi
    if [ "$#" -eq 0 ]; then
        _unpack_usage >&2
        return 2
    fi

    for t in "$@"; do
        _unpack_one "$t" 0 || rc=1
    done
    return "$rc"
}

_unpack_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT:-} in
        *:file) _unpack_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _unpack_sourced=1
    fi
fi

if [ "$_unpack_sourced" -eq 0 ]; then
    unset _unpack_sourced
    unpack "$@"
    exit $?
fi
unset _unpack_sourced
