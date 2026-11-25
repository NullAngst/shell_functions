# shell_functions

A set of Bash scripts for everyday terminal work on Linux (moving files, extracting archives, converting audio, shrinking video, encrypting files, updating the system), installed as plain commands that work the same from Bash or Zsh, plus my zsh and bash configs and a script that sets zsh up for you.

## How it works

Every `.sh` file in this repo is a standalone script with a `#!/usr/bin/env bash` shebang. They get copied into one directory, and each one is symlinked onto your `PATH` under its command name, so `vmv.sh` becomes `vmv`. Since they always run under bash via the shebang, your interactive shell doesn't matter. Zsh users install them exactly like Bash users do.

Every script:

- runs in strict mode (`set -euo pipefail`)
- checks for the tools it needs before doing anything and names the missing ones
- takes `-h` or `--help`
- sticks to portable bash 4.4+ and POSIX tool flags, so it runs on any distro, not only GNU userlands
- refuses to be `source`d, since strict mode and `exit` would leak into your shell

One file can provide more than one command. `audio_convert_functions.sh` declares `# COMMANDS: 2mp3 2flac 2ogg` in its header, so the install step makes three symlinks to it and the script picks what to do from the name it was called by. Running `./audio_convert_functions.sh` directly isn't valid, use one of the three names.

Every command is the file name without `.sh`, unless the file has a `COMMANDS:` line. File names use underscores, never hyphens.

## File commands

| File | Command | What it does | Needs |
|---|---|---|---|
| `vmv.sh` | `vmv` | Verbose move via `rsync`. Removes source files as they transfer, then deletes source directories left empty. `vmv <src> [src...] <dest>` | `rsync` |
| `vcp.sh` | `vcp` | Verbose copy via `rsync`, skipping files that already exist at the destination. `vcp <src> [src...] <dest>` | `rsync` |
| `unpack.sh` | `unpack` | Extracts archives into a folder of their own, then deletes the source on success. Everything that comes out is searched, subfolders included, for archives inside archives. Handles tar, tar.gz/tgz, tar.bz2/tbz2/tbz, tar.xz/txz, tar.zst/tzst, zip, rar, 7z, bare gz/bz2/xz/zst, and split sets (`.partN.rar`, `.rNN`, `.zNN`, `.zip.NNN`, `.7z.NNN`, `name.tar.001`). Given a directory it unpacks the archives directly inside it, `-r` searches its subfolders too. `-k` keeps sources, `-n` is a dry run, `-v` shows extractor output, `-d N` caps nesting depth (default 8). | `tar`, plus `gzip`/`bzip2`/`xz`/`zstd`, `unrar` or `7z`, and `7z`/`7zz`/`7za`, only for the formats it actually hits |
| `scrmgr.sh` | `scrmgr` | One entry point for GNU `screen`: `scrmgr start <name>`, `resume <name>`, `kill <name>`, `list`, `wipe`. | `screen` |
| `moveav.sh` | `moveav` | Sorts files into `images/`, `videos/`, and `audio/` subfolders by extension. `moveav [-R] [dir]`, `-R` sorts each subdirectory on its own. A name that's already taken gets a `_1`, `_2`, ... suffix instead of being overwritten. | nothing extra |
| `shredfile.sh` | `shredfile` | `shred -vzu` on one file after a confirmation prompt. | `shred` (coreutils) |
| `shredfolder.sh` | `shredfolder` | `shred -vzu` on every file in a directory, then removes the directory, after a confirmation prompt. If any file fails to shred, the directory stays so you can see what's left. | `shred` (coreutils) |
| `ffile.sh` | `ffile` | Forensic file report: stat, md5/sha1/sha256/sha512/b2 checksums, lsattr, getfattr, getfacl, lsof, package ownership, hex header and tail, printable strings, exiftool metadata, binwalk signatures, byte entropy. A missing optional tool just means less output. | `file`, `stat`, `md5sum`, `du`, `od`, `dd`; optional: `exiftool`, `binwalk`, `xxd` or `hexdump`, `strings`, `getfattr`, `getfacl`, `lsof`, `ent` or `python3` |
| `cleandir.sh` | `cleandir` | Removes empty directories. `cleandir [-r] [dir]`, current directory by default, `-r` recurses. | nothing extra |
| `audio_convert_functions.sh` | `2mp3`, `2flac`, `2ogg` | Converts audio with `ffmpeg`. A file converts next to itself. A directory batch-converts every audio file directly inside it (not recursive) into a `converted/` subfolder, skipping files already in the target format and never overwriting output. `-v` uses the top VBR mode for MP3/OGG instead of a fixed bitrate; FLAC ignores it. Cover art is kept for MP3 and FLAC. | `ffmpeg` |
| `funchelp.sh` | `funchelp` | Prints a summary of every command in this set and the aliases from the bundled rc files. | nothing extra |

A heads up on `shredfile` and `shredfolder`: `shred` does not reliably wipe data on SSDs or on copy-on-write filesystems like Btrfs, since the overwrite can land on different blocks than the original data. Both prompts say so. Believe them. Both also refuse a symlink as the target, since shred would wipe what it points at and only remove the link.

## Bigger tools

| File | Command | What it does | Needs |
|---|---|---|---|
| `decode.sh` | `decode` | Prints every plausible decoding of one string: base64 (standard and URL-safe), base32, base85/Z85, hex, octal, decimal, binary, URL/percent, ROT13, ROT47, Atbash, HTML entities, and all 25 Caesar shifts. Schemes that don't fit are left blank. `decode '<string>'`, or `decode -- '<string>'` when it starts with `-`. On a terminal, control bytes in the output show as dots, so a decoded escape sequence can't mess with your terminal. | `basenc` (coreutils 8.31+) for Z85 |
| `file_encrypt.sh` | `file_encrypt` | GPG symmetric AES-256. `file_encrypt FILE` encrypts, `file_encrypt -D FILE.gpg` decrypts. Never writes over an existing file. Asks before deleting the source afterward. | `gpg` |
| `folder_encrypt.sh` | `folder_encrypt` | Tars and GPG-encrypts a folder, `-D` reverses it. Encryption streams tar straight into gpg, so no unencrypted archive touches the disk. `-R` is bulk mode: every subdirectory of the target is handled on its own (or every `.gpg` inside it, with `-D`), and loose files in the target get moved into `loose_files/` first so they aren't left out. Asks before deleting sources, and won't extract on top of a folder that already exists. | `gpg`, `tar`, `gzip` |
| `pw_manager.sh` | `pw_manager` | Menu-driven password manager. Vaults are GPG-encrypted tar archives (`.gpg` single password, `.gpg2` two-layer, two passwords), unpacked to RAM (`/dev/shm` or `$XDG_RUNTIME_DIR`) while open. Search, add, and edit entries in a TUI, import/export CSV compatible with Bitwarden and KeePassXC, per-vault locking, rolling backups with a retention period. New vaults are added to the known-vaults list on their own. | `gpg`, `tar`, `gzip`; `python3` for CSV; `wl-copy` (Wayland) or `xclip`/`xsel` (X11) for clipboard |
| `ripcd.sh` | `ripcd` | Interactive CD ripper. Pulls metadata, composers and cover art from MusicBrainz, supports multi-disc releases, offers to rip a hidden track before track 1, retries bad reads, resumes from the first failed track, writes a rip log, CUE sheet and checksums, and ReplayGain tags on FLAC. | `cdparanoia`, `curl`, `jq`, `eject`, `md5sum`; `flac` and `metaflac`, `lame`, or `oggenc` for the formats you pick |
| `media_transcode.sh` | `media_transcode` | Batch-shrinks large video to HEVC in MKV, with optional downscaling, on CPU (libx265), NVIDIA (NVENC), or AMD/Intel (VAAPI). HDR10, HLG, HDR10+ and Dolby Vision files are tone mapped to SDR BT.709 (libplacebo on the GPU through Vulkan, or zscale on the CPU), BT.2020 SDR files are gamut mapped to BT.709. `--hdr skip` leaves them alone and logs them instead. No arguments opens a settings screen; flags or a saved profile plus `--yes` run it unattended (cron, systemd). See `media_transcode --help`. | `ffmpeg`, `ffprobe`, `md5sum`; `flock` if you run more than one instance on the same library; for HDR, an ffmpeg built with libplacebo (plus a working Vulkan driver) or libzimg |
| `system_update.sh` | `system_update` | Finds the native package manager (apt, dnf, yum, zypper, pacman plus yay/paru for AUR, apk, xbps, emerge, eopkg, or nix), runs its full upgrade, then its cleanup only if the upgrade went through, then updates Flatpak and Snap if they're installed. On read-only-root openSUSE (MicroOS, Aeon, Kalpa) it uses `transactional-update` instead. `-l` / `--log` also appends to `/var/log/system_update.log`. | root |
| `ufw_tui.sh` | `ufw_tui` | Menu-driven front end for `ufw`: list, add, and remove rules, allow or deny by port (`80/tcp`) or source IP, set default policies, enable/disable/reload, or reset. | `ufw`, root |
| `use_my_zsh.sh` | `use_my_zsh` | Installs zsh if it's missing, makes it the login shell for you and root, and installs the bundled `zshrc` for both. See below. | root |
| `funcupdate.sh` | `funcupdate` | Pulls the latest scripts from this repo and redeploys them. `sudo funcupdate` updates the system-wide install (Option B), `funcupdate -u` the per-user one (Option A). `-l` / `--log` also keeps a log. | `git` |

## Prerequisites

- Linux with bash 4.4 or newer. Your login shell can be Bash or Zsh, it doesn't matter since every script runs under bash.
- `git`, to clone the repo and for `funcupdate`.
- Whatever the "Needs" column lists for the commands you actually plan to use. Nothing is required up front. A command tells you what's missing when you run it.

I'm on Kubuntu, so in my case the common ones are `sudo apt install git rsync ffmpeg gnupg screen`. Package names vary, so check yours: openSUSE calls it `gpg2` instead of `gnupg`, for example.

## Installation

Pick one option. Option A installs for just your user, Option B for everyone on the machine. Both use the same layout: scripts in a `lib/shell_functions` directory, command symlinks in a `bin` directory.

Every command below works when pasted into either Bash or Zsh.

### Option A: just your user

1. Clone the repo and step into it: `git clone https://github.com/NullAngst/shell_functions.git && cd shell_functions`
2. Make the directories: `mkdir -p ~/.local/lib/shell_functions ~/.local/bin`
3. Copy the scripts and the rc files: `cp *.sh zshrc bashrc ~/.local/lib/shell_functions/`, since `use_my_zsh` looks for `zshrc` next to itself
4. Make the scripts executable: `chmod 755 ~/.local/lib/shell_functions/*.sh`
5. Symlink each command into `~/.local/bin`:

   ```sh
   for f in ~/.local/lib/shell_functions/*.sh; do
       for name in $(sed -n -e '/^# COMMANDS:/{' -e 's/^# COMMANDS://p' -e 'q' -e '}' "$f" | grep . || basename "$f" .sh); do
           ln -sf "$f" ~/.local/bin/"$name"
       done
   done
   ```

   That uses the `COMMANDS:` names when a file has them, and the file name minus `.sh` when it doesn't.

6. Make sure `~/.local/bin` is on your `PATH`. A lot of distros already add it; check with `printf '%s\n' "$PATH"`. If it's missing, add this line to `~/.bashrc` or `~/.zshrc` (or whichever rc file your shell reads): `export PATH="$HOME/.local/bin:$PATH"`
7. Open a new terminal, or `source` the rc file you just edited.

Steps 2 through 5 are also what `bash funcupdate.sh -u` does, except it pulls the latest copy from GitHub instead of using your clone.

To update later, run `funcupdate -u`.

### Option B: every user on the machine

1. Clone the repo and step into it: `git clone https://github.com/NullAngst/shell_functions.git && cd shell_functions`
2. Make the directory: `sudo mkdir -p /usr/local/lib/shell_functions`
3. Copy the scripts and the rc files: `sudo cp *.sh zshrc bashrc /usr/local/lib/shell_functions/`
4. Make the scripts executable: `sudo chmod 755 /usr/local/lib/shell_functions/*.sh`
5. Symlink each command into `/usr/local/bin`, which is already on everyone's `PATH`:

   ```sh
   for f in /usr/local/lib/shell_functions/*.sh; do
       for name in $(sed -n -e '/^# COMMANDS:/{' -e 's/^# COMMANDS://p' -e 'q' -e '}' "$f" | grep . || basename "$f" .sh); do
           sudo ln -sf "$f" /usr/local/bin/"$name"
       done
   done
   ```

No `PATH` change needed for this one. Steps 2 through 5 are also what `sudo bash funcupdate.sh` does, pulling the latest copy from GitHub.

To update later, run `sudo funcupdate`.

### What funcupdate does

It clones the repo to a temp directory, removes every symlink in the `bin` directory that points into the `lib/shell_functions` directory along with the old scripts, then copies and links the new set (plus `zshrc` and `bashrc`). That clean-out step is what keeps a renamed or removed script from leaving a dead command behind.

It's careful about what it touches:

- if the clone fails or comes back empty, the current install is left exactly as it was
- symlinks it didn't create are left alone
- a command name that's already taken by a file it didn't create gets skipped with a warning, not overwritten

### Upgrading from the hyphenated layout

Older installs used `lib/shell-functions`. Updating moves you over on its own:

1. Run `sudo funcupdate` (Option B) or `bash funcupdate.sh -u` from a fresh clone (Option A). On Option B, run it a second time this once: the first run still executes your old copy of funcupdate, the second runs the new one, which removes the old directory and its links.
2. Open a new terminal, so your shell forgets the old command paths.

The scripts move their own files the first time they run:

- `pw_manager` moves `~/.pw-manager-config` and `~/.pw-manager-vaults` into `~/.config/pw_manager/`
- `media_transcode` moves `~/.config/media-transcode/` and `~/.local/state/media-transcode/` to the underscore names, and the `.media-transcode/` folder in a scanned library to `.media_transcode/` on its next run there
- `ripcd` moves `~/.cache/simplecd-ripper/` to `~/.cache/ripcd/`

DON'T RUN AN OLD AND A NEW `media_transcode` ON THE SAME LIBRARY AT THE SAME TIME. Their lock folders have different names, so they can't see each other's locks and may grab the same file.

`system_update` and `funcupdate` now log to `/var/log/system_update.log`. The old `/var/log/system-update.log` is left where it is; delete it whenever you like.

### media_transcode 11 converts HDR by default

Up to version 10, `media_transcode` skipped every HDR and BT.2020 file. From 11 on it converts them to SDR BT.709, and saved profiles without an `HDR_MODE` line get that too. If a profile runs from cron with originals set to delete, that means your HDR originals get deleted after conversion. IF YOU WANT TO KEEP HDR MASTERS, ADD `HDR_MODE="skip"` TO THAT PROFILE OR SWITCH ORIGINALS TO MOVE BEFORE THE NEXT RUN.

How it picks a backend: libplacebo first, since it tone maps on the GPU and is the only one that reads the Dolby Vision RPU. It gets a one-frame test at start, and if it can't get a Vulkan device the run says why and uses zscale on the CPU. zscale does HDR10, HLG and Dolby Vision files that carry an HDR10 or HLG base layer (profiles 7, 8.1, 8.4). Dolby Vision without one (profile 5, common on streaming-service rips) is skipped and logged when only zscale works, because it comes out green and purple without the RPU.

Tone mapping to 8-bit is dithered, but `--10bit` still gives smoother gradients in skies and dark scenes. I'd use it for converted HDR files.

## Where things end up

| Command | Paths it writes |
|---|---|
| `media_transcode` | Profiles in `~/.config/media_transcode/` (respects `$XDG_CONFIG_HOME`), run logs in `~/.local/state/media_transcode/` (respects `$XDG_STATE_HOME`), and inside the scanned directory: `_HDR_files_to_check.log` and a `.media_transcode/` folder holding per-file locks and the no-gain list. |
| `pw_manager` | Settings and the known-vaults list in `~/.config/pw_manager/` (respects `$XDG_CONFIG_HOME`), open vaults in `/dev/shm` (or `$XDG_RUNTIME_DIR`), backups in a `backups/` folder next to each vault. |
| `ripcd` | Output defaults to `~/Music` (it asks), resume checkpoints in `~/.cache/ripcd/` (respects `$XDG_CACHE_HOME`), removed once a disc rips cleanly. |
| `use_my_zsh` | `~/.zshrc` and `/root/.zshrc` (the old ones kept as `.zshrc.bak-<date>`), `/etc/shells`, and with `-n` the useradd defaults. |
| `system_update`, `sudo funcupdate` | `/var/log/system_update.log`, only with `-l` / `--log`. |
| `funcupdate -u` | `~/.local/state/shell_functions/funcupdate.log`, only with `-l` / `--log`. |

Everything else writes only where you point it.

Note that `media_transcode`, `pw_manager` and `ripcd` use the home directory of whoever runs them. Run them with `sudo` and they read and write under `/root`, not under your home.

## Uninstalling

Option A: `find ~/.local/bin -maxdepth 1 -type l -lname "$HOME/.local/lib/shell_functions/*" -delete && rm -rf ~/.local/lib/shell_functions`

Option B: `sudo find /usr/local/bin -maxdepth 1 -type l -lname '/usr/local/lib/shell_functions/*' -delete && sudo rm -rf /usr/local/lib/shell_functions`

Both only remove symlinks that point into the install directory, so nothing else in your `bin` gets caught.

## Included shell config (`zshrc` / `bashrc`)

The repo also ships a `zshrc` and a `bashrc`: my prompt, history settings, completion, and a git-aware prompt. They're optional and the commands work fine without them.

The prompt colors come from my kitty themes in [NullAngst/kitty-themes](https://github.com/NullAngst/kitty-themes), so the prompt matches whichever one kitty is running. Kawaii Dark is the default. The others are `kawaii-light`, `amber`, `blurple`, `modern-dark`, `modern-light` and `verdigris-copper`. To switch, set `ZSH_PROMPT_THEME=amber` (zsh) or `BASH_PROMPT_THEME=amber` (bash) before the rc file runs, in `~/.zshenv` say, or edit the default line near the top of the file.

The prompt color tells you where you are: red as root, blue in a git repo, green in a Python project, the theme's accent color everywhere else. The arrow on the second line turns red when the last command failed.

The bash prompt hook goes in front of whatever `PROMPT_COMMAND` already holds instead of replacing it, so terminal integrations that use it keep working.

Both define three aliases, which `funchelp` also lists. Each one is only set if the tool underneath supports it, so a machine without rsync still has a working `cp`.

- `ls` runs `ls --color=auto -Flartchs`
- `grep` runs `grep --color=auto -i -n -I`, so it is always case-insensitive
- `cp` runs `rsync -vpartlXEHhP --ignore-existing`

Watch the `cp` alias. `--ignore-existing` silently skips any file that already exists at the destination instead of overwriting it, and rsync's trailing-slash rules for directories differ from `cp`'s. Aliases only apply in interactive shells, so scripts still get the real `cp`, but it will catch you out at the prompt at some point. Delete the line if you'd rather keep the real `cp`. The same goes for `grep` if you don't want case-insensitive by default.

Both add `~/.local/bin` to `PATH`, so they cover step 6 of Option A.

### Setting it up with use_my_zsh

`use_my_zsh` does the whole zsh switch in one go. It checks that zsh is installed and actually runs before changing anything, offers to install it with your package manager if it isn't (apt, dnf, yum, zypper, pacman, apk, xbps, emerge, or eopkg), adds it to `/etc/shells` if it's missing there, installs the `zshrc` for you and for root with your old one backed up, and sets zsh as the login shell for both.

1. Run it with sudo from your own account: `sudo use_my_zsh`, since it figures out "you" from sudo
2. Log out and back in, or just run `zsh`.

Options:

- `-t amber` makes a different theme the default in the installed file
- `-u name` sets up a different user than the one running sudo
- `-R` leaves root's shell and zshrc alone
- `-n` also makes zsh the default shell for accounts created later
- `-k` also installs my kitty themes for you, with the same theme active (needs `git`)
- `-y` installs zsh without asking

It uses the `zshrc` sitting next to it when there is one (the install steps above put it there), and downloads it from this repo otherwise. Either way it checks that the file really is this repo's zshrc and passes `zsh -n` before installing it.

IF YOUR ACCOUNT COMES FROM LDAP, SSSD OR SIMILAR, THE SHELL CHANGE WON'T STICK LOCALLY. The script tells you when that happens; change the shell wherever the account lives.

Now every command is on your `PATH`, runs the same from Bash or Zsh, `funchelp` lists them whenever you forget one, and your prompt matches your terminal. Tinker as you see fit.
