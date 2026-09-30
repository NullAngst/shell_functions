#!/usr/bin/env bash
funchelp() {
    cat << 'EOF'

========================================
             CUSTOM ALIASES
========================================
ls     : Colorized, verbose list (ls --color=auto -Flartchs)
cp     : Copy via rsync that SKIPS files already at the destination (--ignore-existing)
grep   : Colorized, case-insensitive, line numbers, ignore binary
(aliases come from the bundled bashrc/zshrc, not from these scripts)

========================================
            CUSTOM FUNCTIONS
========================================
vmv          : Verbose move via rsync, removes empty source dirs afterward
vcp          : Verbose copy via rsync, skips files that already exist
unpack       : Recursively extract archives, including split sets (Usage: unpack [-k] [-n] [-v] [-d N] <target>)
scrmgr       : Manage screen sessions (Usage: scrmgr start|resume|kill <name>, scrmgr list|wipe)
moveav       : Sort media into images/, videos/, audio/ (Usage: moveav [-R] [dir])
shredfile    : shred -vzu a file after confirmation (not reliable on SSDs)
shredfolder  : shred -vzu every file in a folder, then remove it (not reliable on SSDs)
ffile        : Forensic file analysis: stat, hashes, hex, strings, entropy, metadata
cleandir     : Remove empty folders in the current dir (Usage: cleandir [-r])
2mp3         : Convert a file or folder of audio to MP3 (Usage: 2mp3 [-v] <file_or_dir>)
2flac        : Convert a file or folder of audio to FLAC (Usage: 2flac <file_or_dir>)
2ogg         : Convert a file or folder of audio to OGG (Usage: 2ogg [-v] <file_or_dir>)
funchelp     : Displays this help menu

========================================
           STANDALONE SCRIPTS
========================================
decode          : Try every common decoding of a string (Usage: decode '<string>')
file_encrypt    : GPG AES-256 encrypt/decrypt a file (Usage: file_encrypt [-D] <file>)
folder_encrypt  : Tar + GPG-encrypt a folder; -D reverses, -R bulk mode (Usage: folder_encrypt [-D] [-R] <target>)
pw-manager      : Menu-driven terminal password manager (GPG-encrypted vaults, CSV import/export)
ripcd           : Interactive CD ripper with MusicBrainz metadata, cover art, FLAC replaygain
media_transcode : Batch-shrink large SDR video to HEVC MKV; skips HDR/DV (Usage: media_transcode [--help])
system_update   : Update via the native package manager plus Flatpak/Snap; requires root (Usage: system_update [-l])
ufw_tui         : Menu-driven front end for ufw; requires root
funcupdate      : Re-pull this repo and redeploy system-wide; requires root (Usage: funcupdate [-l])

EOF
}

_funchelp_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
    case ${ZSH_EVAL_CONTEXT} in
        *:file) _funchelp_sourced=1 ;;
    esac
elif [ -n "${BASH_VERSION:-}" ]; then
    if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
        _funchelp_sourced=1
    fi
fi

if [ "$_funchelp_sourced" -eq 0 ]; then
    funchelp "$@"
fi
unset _funchelp_sourced
