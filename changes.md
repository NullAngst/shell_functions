# Changes

2026.11.04 - Backend overhaul / Security patches / New script

* Every script now runs in strict mode (`set -euo pipefail`), checks its required commands up front and lists the missing ones, uses printf instead of echo, and passes shellcheck with no warnings
* Removed the source-or-run dual mode. Sourcing a script would have pushed strict mode into your interactive shell, so every script now refuses to be sourced and leaves the shell alone
* Removed GNU-only flags: `stat -c`, `find -printf`, `sort -z`, `df -B1 --output`, `realpath -m`, `grep -m`, `grep -P`, `mktemp -p/-t`, `date -Iseconds`, `date +%N`, `od -t x1z`
* Renamed `pw-manager.sh` to `pw_manager.sh`. Its config and vault list paths are unchanged, so existing settings carry over
* New `use_my_zsh.sh`: installs zsh if missing (asks first), adds it to /etc/shells, installs the bundled zshrc for you and root with backups, sets zsh as the login shell, optional `-n` for new accounts and `-k` for the matching kitty theme
* zshrc and bashrc: prompt colors now come from the kitty themes, Kawaii Dark by default, any of the seven selectable with `ZSH_PROMPT_THEME` / `BASH_PROMPT_THEME`
* zshrc and bashrc: the prompt arrow turns red after a failed command (the old zshrc described this but never did it)
* zshrc: uses add-zsh-hook so other precmd hooks keep working
* zshrc and bashrc: the ls, grep and cp aliases are only set when the tool supports them, so a machine without rsync keeps a working cp
* bashrc: security fix. The git branch name was pasted into PS1, and git allows `$(` in branch names, so cloning a repo with a crafted branch and cd'ing into it ran a command. The branch now goes in by reference
* bashrc: only runs in interactive shells, so scp/rsync sessions don't hit bind warnings
* funcupdate: also deploys zshrc and bashrc, leaves the current install alone if the clone fails or is empty, no longer depends on `find -lname`
* file_encrypt: data loss fix. If the output file already existed and gpg failed or you declined its overwrite prompt, the script deleted that existing file. It now refuses to start when the output exists
* folder_encrypt: bulk mode fix. The delete prompt read from the same stream as the folder list, which swallowed the rest of the list, so -R only ever handled the first folder
* folder_encrypt: encryption streams tar into gpg, so no plaintext archive is written to disk anymore
* folder_encrypt: decryption finishes into a temp file before extracting, and refuses to extract over an existing folder
* folder_encrypt: a second -R run no longer sweeps earlier .gpg archives into loose_files and encrypts them again
* pw_manager: passphrases reach gpg through a pipe instead of a here-string, which older bash writes to a temp file
* pw_manager: RAM storage detection reads /proc/mounts and also accepts $XDG_RUNTIME_DIR
* pw_manager: clipboard tool picked by session type (wl-copy on Wayland, xclip/xsel on X11)
* pw_manager: only .txt files count as entries, so editor backup or swap files don't show up as entries
* pw_manager: a wrong password goes back to the menu instead of re-executing the script
* pw_manager: Q is no longer used as a vault letter, since it clashed with Quit
* pw_manager: empty passwords are refused when creating a vault or an export
* ripcd: success rate counted each format as a track, so two formats could show 200%. It now counts tracks that finished in every format
* ripcd: a failed track no longer gets skipped on resume; the checkpoint stops at the first failure, and is removed after a clean rip so the next disc doesn't offer a bogus resume
* ripcd: the CUE sheet is written for the whole disc after ripping (a resumed rip used to get a partial one), and quotes in titles no longer break it
* ripcd: checkpoint and stats JSON are built with jq, so quotes in titles can't produce broken JSON. Stats now include real per-session results
* ripcd: a resumed rip appends to the log instead of wiping it
* ripcd: fixed the cover art selection filter, which returned nothing when no image was marked as front
* ripcd: missing MusicBrainz titles fall back to "Track N" instead of empty file names
* ripcd: flac overwrites a half-written file left by an interrupted run instead of failing on it
* ripcd: the output file listing no longer parses ls, so names with spaces show in full
* media_transcode: strict mode with an EXIT handler that removes partial output and returns WIP sources if anything fails unexpectedly
* media_transcode: lock inode check uses bash's -ef on the open descriptor instead of stat
* media_transcode: sorting works on index numbers, so paths with tabs or newlines can't break the order
* unpack: collects each directory listing before unpacking, so files created or deleted mid-run can't be processed twice or reported missing
* system_update: zypper uses `up` on Leap and SLES and `dup` only on Tumbleweed, Slowroll and MicroOS, and runs non-interactively so `zypper remove` can't hang
* system_update: uses apt-get, and only when dpkg is present too (old Java installs ship an unrelated tool called apt), xbps updates itself first, apk only cleans a cache that exists, revdep-rebuild only runs if installed
* system_update: every log line gets its own timestamp, and logged runs show output on screen as well as in the log
* system_update: AUR and per-user Flatpak run through runuser when available, with the right HOME
* 2ogg: the default 500k Vorbis target failed on mono files. It now scales to the channel count
* 2mp3 and 2flac keep embedded cover art as-is; 2ogg drops it instead of trying to encode it as video
* shredfile and shredfolder refuse symlinks, since shred would wipe the target and only remove the link. shredfolder stops before deleting the folder if any file failed to shred, and refuses /, . and ..
* moveav: never overwrites a file in the destination folder, adds a few more extensions (heic, avif, jxl, opus, aiff, ts, m2ts)
* ffile: raw head/tail output limited to the first and last 4 KiB with non-printable bytes shown as dots, so binaries can't spew escape codes or gigabytes into the terminal. The python entropy fallback reads in chunks instead of loading the whole file
* decode: an input like `-n` or `-e` was eaten by echo as an option and decoded to nothing; very long numeric HTML entities no longer overflow
* scrmgr list and wipe exit 0 when there are no sessions, instead of screen's non-zero status
* ufw_tui: validates ports, IPs and rule numbers before calling ufw, and a failing ufw command no longer drops you out of the menu

Reasons for changes: bring every script in line with the shell script rules (strict mode, portable flags, printf, upfront dependency checks, underscore names), and fix the bugs the audit turned up along the way, a few of which could lose data or run commands.
