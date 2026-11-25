#!/usr/bin/env bash
#
# funchelp - print a summary of every command in NullAngst/shell_functions
# and the aliases from the bundled rc files.
#
# Usage: funchelp [-h]

# Strict mode and exit would leak into the calling shell, so refuse to be sourced.
(return 0 2>/dev/null) && { printf 'funchelp: run this as a command, do not source it\n' >&2; return 1; }

set -euo pipefail

prog=funchelp

opt=""
while getopts ':h-:' opt; do
    case "$opt" in
        h) printf 'Usage: %s\n  Lists every command and alias in shell_functions.\n' "$prog"; exit 0 ;;
        -)
            case "$OPTARG" in
                help) printf 'Usage: %s\n  Lists every command and alias in shell_functions.\n' "$prog"; exit 0 ;;
                *) printf '%s: unknown option --%s\n' "$prog" "$OPTARG" >&2; exit 1 ;;
            esac
            ;;
        *) printf '%s: unknown option -%s\n' "$prog" "$OPTARG" >&2; exit 1 ;;
    esac
done

cat <<'EOF'

========================================
             ALIASES
========================================
(from the bundled bashrc and zshrc, not from these scripts)
ls     : Colorized long list, hidden files, newest change last (ls --color=auto -Flartchs)
cp     : Copy via rsync that SKIPS files already at the destination (--ignore-existing)
grep   : Colorized, case-insensitive, line numbers, ignores binary files

========================================
             FILE COMMANDS
========================================
vmv          : Verbose move via rsync, removes emptied source dirs (vmv <src>... <dest>)
vcp          : Verbose copy via rsync, skips files that already exist (vcp <src>... <dest>)
unpack       : Extract archives into their own folders, nested and split sets too (unpack [-k] [-n] [-v] [-r] [-d N] <target>...)
moveav       : Sort media into images/, videos/, audio/ (moveav [-R] [dir])
cleandir     : Remove empty folders (cleandir [-r] [dir])
shredfile    : shred a file after confirmation, not reliable on SSDs (shredfile <file>)
shredfolder  : shred every file in a folder, then remove it (shredfolder <dir>)
ffile        : Forensic file report: stat, hashes, hex, strings, entropy, metadata (ffile <file>)
scrmgr       : Manage screen sessions (scrmgr start|resume|kill <name>, scrmgr list|wipe)
2mp3         : Convert a file or folder of audio to MP3 (2mp3 [-v] <file_or_dir>)
2flac        : Convert a file or folder of audio to FLAC (2flac <file_or_dir>)
2ogg         : Convert a file or folder of audio to OGG (2ogg [-v] <file_or_dir>)
funchelp     : This list

========================================
             BIGGER TOOLS
========================================
decode          : Try every common decoding of a string (decode [--] '<string>')
file_encrypt    : GPG AES-256 encrypt or decrypt a file (file_encrypt [-D] <file>)
folder_encrypt  : Tar + GPG-encrypt a folder, -D reverses, -R bulk mode (folder_encrypt [-D] [-R] <target>)
pw_manager      : Terminal password manager with GPG vaults and CSV import/export
ripcd           : Interactive CD ripper with MusicBrainz tags, cover art, CUE and logs (ripcd [-v])
media_transcode : Batch-shrink large SDR video to HEVC MKV, skips HDR/DV (media_transcode --help)
system_update   : Full upgrade with the native package manager plus Flatpak/Snap, needs root (system_update [-l])
ufw_tui         : Menu-driven front end for ufw, needs root
use_my_zsh      : Make zsh your and root's login shell with the bundled zshrc, needs root (use_my_zsh -h)
funcupdate      : Pull the latest scripts and redeploy (sudo funcupdate, or funcupdate -u for a user install)

Every command takes -h for its own help.

EOF
