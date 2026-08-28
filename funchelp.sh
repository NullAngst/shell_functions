#!/usr/bin/env bash
funchelp() {
    cat << 'EOF'

========================================
             CUSTOM ALIASES
========================================
ls      : Colorized, verbose list (ls --color=auto -Flartchs)
cp      : Robust copy via rsync (--ignore-existing)
grep    : Colorized, case-insensitive, line numbers, ignore binary

========================================
            CUSTOM FUNCTIONS
========================================
vmv        : Verbose file move using rsync (cleans empty source dirs after transfer)
vcp        : Verbose file copy using rsync
unpack     : Intelligently extract common compression types, including split archives
scrmgr     : Manage screen sessions: start/resume/kill/list/wipe (replaces sss/srs/sks/sls/swp)
moveav     : Move and sort folders of media into images/, videos/, and audio/
shredfile  : Runs shred against a file with proper arguments
shredfolder: Runs shred against a folder with proper arguments
ffile      : Forensic file analysis -- stat, hashes, hex, strings, entropy, metadata
cleandir   : Removes empty folders in the current dir (Usage: cleandir [-r] for recursive)
2mp3       : Convert a file or folder of audio to MP3 (Usage: 2mp3 [-v] <file_or_dir>)
2flac      : Convert a file or folder of audio to FLAC (Usage: 2flac <file_or_dir>)
2ogg       : Convert a file or folder of audio to OGG (Usage: 2ogg [-v] <file_or_dir>)
system-update  : Checks for package manager and secondary managers (pacman, flatpak, snap) and runs their full update commands.
ripcd   : Interactive terminal CD ripper. Fetches metadata, coverart, writes replaygain tags on FLAC.
funchelp   : Displays this help menu

========================================
           STANDALONE SCRIPTS
========================================
file_encrypt   : Encrypt/decrypt a file with GPG symmetric AES-256 (Usage: file_encrypt [-D] <file>)
folder_encrypt : Tar + GPG-encrypt a folder, or reverse with -D; -R for bulk mode (Usage: folder_encrypt [-D] [-R] <target>)
pw-manager     : Menu-driven terminal password manager (GPG-encrypted vaults, CSV import/export)
ufw_tui        : Menu-driven front end for ufw (rules, policy, enable/disable/reset); requires root
funcupdate     : Re-pulls this repo and redeploys all scripts system-wide; requires root

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
