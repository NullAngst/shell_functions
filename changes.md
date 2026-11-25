# Changes

2026.11.25 - media_transcode HDR support

* media_transcode 11: HDR10, HLG, HDR10+ and Dolby Vision files are tone mapped to SDR BT.709 instead of skipped. BT.2020 SDR files are gamut mapped to BT.709
* Two backends: libplacebo (GPU through Vulkan, reads HDR10+ and the Dolby Vision RPU) and zscale + tonemap (CPU). `auto` tests libplacebo at start and falls back to zscale with the reason printed
* Dolby Vision without an HDR10/HLG base layer (profile 5) is only converted with libplacebo, always with CPU decode, and skipped and logged otherwise
* BT.2020 files with no transfer tag are still skipped and logged, since they could be HDR or SDR
* New settings `HDR_MODE` (tonemap/skip), `TONEMAP_BACKEND` (auto/libplacebo/zscale), `TONEMAP_CURVE` (auto/hable/mobius/reinhard/bt.2390/spline), as flags `--hdr`, `--tonemap-backend`, `--tonemap-curve` and menu item 15. Advanced moved to 16
* Converted files are encoded through `-filter_complex`, have HDR and Dolby Vision frame metadata stripped, and get `-dolbyvision 0` on encoders that know it. ffmpeg 6.1 otherwise copies the source's mastering display and light level metadata onto the SDR output
* The verify step now fails a converted file whose output isn't tagged bt709 or still carries HDR / Dolby Vision metadata, so the original is kept
* With GPU encoders, HDR files decode on the GPU and download to system memory for tone mapping, then retry with CPU decode on failure as before
* Skip messages and the HDR log say why a file was skipped. The summary counts how many outputs were converted to SDR, and the marker tag records the backend
* fmt_size printed negative byte counts raw, e.g. "saved -841278 B" when outputs grew

Reasons for changes: HDR sources had to be converted by hand. Tone mapping in the script makes them part of the normal batch, and the metadata stripping plus the verify check keep an SDR file from going out tagged as HDR.

2026.11.25 - Backend overhaul / Security patches

* Every script now parses its flags with getopts (long options like `--help` go through getopts too) and takes `-h` / `--help`
* Plain tests use `[ ]` instead of `[[ ]]` and `(( ))`. `[[ ]]` is left only where it does pattern matching, `(( ))` only for `for` loops
* Root checks use `id -u` instead of bash's `$EUID`
* `LC_ALL=C` on every command whose output gets parsed (df, ffmpeg -encoders/-filters, cdparanoia, pacman, getent)
* Trap handlers carry both shellcheck codes (SC2317 and SC2329), so the scripts pass clean on shellcheck 0.9 through 0.11
* Install directory renamed from `lib/shell-functions` to `lib/shell_functions`, matching the repo. funcupdate removes the old directory and its symlinks
* funcupdate: new `-u` / `--user` mode deploys to `~/.local` for Option A installs, which had no updater before
* funcupdate: no longer replaces a file in the bin directory that it didn't create, it skips that command with a warning
* system_update and funcupdate: log file renamed to `/var/log/system_update.log`
* system_update: package cleanup (autoremove, depclean, orphan removal) only runs when the upgrade before it succeeded. A depclean after a half-finished Gentoo world update can remove things the system still needs
* system_update: `emerge --ask=n`, so an `--ask` in EMERGE_DEFAULT_OPTS can't stall an unattended run
* system_update: openSUSE MicroOS, Aeon and Kalpa (read-only root) now update through `transactional-update dup`
* system_update: added Solus (eopkg), unused Flatpak runtimes get removed, NixOS uses `nixos-rebuild switch --upgrade`
* pw_manager: bug fix. Closing a vault, or typing a wrong password, quit the whole program instead of going back to the menu
* pw_manager: settings and the known-vaults list moved to `~/.config/pw_manager/`, old files are moved over on first run
* pw_manager: new vaults (made directly or by CSV import) are locked while being created and added to the known-vaults list
* pw_manager: vault paths are stored absolute, so the list works from any directory
* pw_manager: arrow keys work in terminals that send application cursor codes (ESC O A)
* pw_manager: editor picked from `$VISUAL`, then `$EDITOR` (arguments allowed, like `code -w`), then nano, then vi
* pw_manager: a vault in a folder you can't write to now says so, instead of claiming it's open elsewhere
* pw_manager: settings that can't be saved show a message instead of crashing the program
* ripcd 6.1: composers were never found. The lookup read a composer relation off the recording, but MusicBrainz keeps it on the work. Now follows recording to work to composer or writer
* ripcd: hidden track detection never fired, since cdparanoia doesn't list a track 0. It now checks whether track 1 starts late, and asks before ripping since some drives stall reading that area. It also works for WAV, MP3 and OGG-only rips now
* ripcd: removed a GNU-only `\|` from a sed pattern, which broke the rip quality line on non-GNU sed
* ripcd: checkpoint folder renamed to `~/.cache/ripcd/`, the old one is moved over
* ripcd: the save directory is made absolute, so the encoders can never read a path as an option
* media_transcode 10: config, logs and the in-library state folder renamed from `media-transcode` to `media_transcode`, old ones moved over on first run
* media_transcode: required commands checked before anything else, SIGHUP handled like Ctrl+C
* unpack: archives inside subfolders of an extracted archive are now found. Before, only the top level of what came out was checked
* unpack: new `-r` to search the subfolders of a directory you point it at
* unpack: deleting a finished set compared names without case, so unpacking `Foo.zip` also deleted an unrelated `foo.zip` next to it
* unpack: tar.zst goes through zstd instead of relying on tar to detect it, which BusyBox and older GNU tar can't
* unpack: passworded rar archives fail right away instead of waiting on a prompt
* 2mp3/2flac/2ogg: a file name with a colon, like `Intro: Live.flac`, made ffmpeg look for a network protocol and fail
* decode and ffile: on a terminal, control bytes in the output show as dots, so decoded or file-supplied escape sequences can't act on your terminal
* folder_encrypt: `.` and `..` work as targets, and `/` is refused
* file_encrypt: sets GPG_TTY so the terminal passphrase prompt works without a desktop pinentry
* shredfolder and cleandir: a folder name starting with `-` is passed to find as a path, not read as an expression
* cleandir: takes a directory argument
* use_my_zsh: every step of installing a zshrc checks its own result, so a failed copy no longer reports success
* bashrc: the prompt hook goes in front of an existing PROMPT_COMMAND instead of replacing it, so terminal integrations keep working
* README, maintenance.md and funchelp updated to match

Reasons for changes: the scripts now follow the shell script rules in full, and a line-by-line review turned up the bugs above, several of which (pw_manager quitting, ripcd composers and hidden tracks, unpack's case-blind delete) were silent.

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
