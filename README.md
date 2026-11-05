# shell_functions

A set of Bash scripts for everyday terminal work on Linux (moving files, extracting archives, converting audio, shrinking video, encrypting files, updating the system), installed as plain commands that work the same from Bash or Zsh, plus my zsh and bash configs and a script that sets zsh up for you.

## How it works

Every `.sh` file in this repo is a standalone script with a `#!/usr/bin/env bash` shebang. You copy them into one directory, then symlink each one onto your `PATH` under its command name, so `vmv.sh` becomes `vmv`. Since they always run under bash via the shebang, your interactive shell doesn't matter. Zsh users install them exactly like Bash users do.

Every script runs in strict mode (`set -euo pipefail`), checks for the tools it needs before doing anything, and tells you which ones are missing. None of them can be `source`d. If you try, they refuse and leave your shell alone, since strict mode and `exit` would otherwise leak into it.

One file can provide more than one command. `audio_convert_functions.sh` declares `# COMMANDS: 2mp3 2flac 2ogg` in its header, so the install step makes three symlinks to it and the script picks what to do from the name it was called by. Running it as `./audio_convert_functions.sh` directly isn't valid, use one of the three names.

Every command below is the file name without `.sh`, unless the file has a `COMMANDS:` line. File names use underscores, never hyphens.

## File commands

| File | Command | What it does | Needs |
|---|---|---|---|
| `vmv.sh` | `vmv` | Verbose move via `rsync`. Removes source files as they transfer, then deletes source directories left empty. `vmv <src> [src...] <dest>` | `rsync` |
| `vcp.sh` | `vcp` | Verbose copy via `rsync`, skipping files that already exist at the destination. `vcp <src> [src...] <dest>` | `rsync` |
| `unpack.sh` | `unpack` | Recursively extracts archives into their own directory, including archives inside archives, then deletes the source on success. Handles tar, tar.gz/tgz, tar.bz2/tbz2/tbz, tar.xz/txz, tar.zst/tzst, zip, rar, 7z, bare gz/bz2/xz/zst, and split sets (`.partN.rar`, `.rNN`, `.zNN`, `.zip.NNN`, `.7z.NNN`, `name.tar.001`). `-k` keeps sources, `-n` is a dry run, `-v` shows extractor output, `-d N` caps nesting depth (default 8). | `tar`, plus `gzip`/`bzip2`/`xz`/`zstd`, `unrar` or `7z`, and `7z`/`7zz`/`7za`, only for the formats it actually hits |
| `scrmgr.sh` | `scrmgr` | One entry point for GNU `screen`: `scrmgr start <name>`, `resume <name>`, `kill <name>`, `list`, `wipe`. | `screen` |
| `moveav.sh` | `moveav` | Sorts files into `images/`, `videos/`, and `audio/` subfolders by extension. `moveav [-R] [dir]`, `-R` sorts each subdirectory on its own. A name that's already taken gets a `_1`, `_2`, ... suffix instead of being overwritten. | nothing extra |
| `shredfile.sh` | `shredfile` | `shred -vzu` on one file after a confirmation prompt. | `shred` (coreutils) |
| `shredfolder.sh` | `shredfolder` | `shred -vzu` on every file in a directory, then removes the directory, after a confirmation prompt. | `shred` (coreutils) |
| `ffile.sh` | `ffile` | Forensic file analysis: stat, md5/sha1/sha256/sha512/b2 checksums, lsattr, getfattr, getfacl, lsof, package ownership, hex header and tail, printable strings, exiftool metadata, binwalk signatures, byte entropy. A missing optional tool just means less output. | optional: `exiftool`, `binwalk`, `xxd` or `hexdump`, `strings`, `getfattr`, `getfacl`, `lsof`, `ent` or `python3` |
| `cleandir.sh` | `cleandir` | Removes empty directories in the current directory. `-r` recurses. | nothing extra |
| `audio_convert_functions.sh` | `2mp3`, `2flac`, `2ogg` | Converts audio with `ffmpeg`. A file converts next to itself. A directory batch-converts every audio file directly inside it (not recursive) into a `converted/` subfolder, skipping files already in the target format and never overwriting output. `-v` uses the top VBR mode for MP3/OGG instead of a fixed bitrate; FLAC ignores it. Cover art is kept for MP3 and FLAC. | `ffmpeg` |
| `funchelp.sh` | `funchelp` | Prints a summary of every command in this set and the aliases from the bundled rc files. | nothing extra |

A heads up on `shredfile` and `shredfolder`: `shred` does not reliably wipe data on SSDs or on copy-on-write filesystems like Btrfs, since the overwrite can land on different blocks than the original data. Both prompts say so. Believe them. Both also refuse a symlink as the target, since shred would wipe what it points at and only remove the link.

## Bigger tools

| File | Command | What it does | Needs |
|---|---|---|---|
| `decode.sh` | `decode` | Prints every plausible decoding of one string: base64 (standard and URL-safe), base32, base85/Z85, hex, octal, decimal, binary, URL/percent, ROT13, ROT47, Atbash, HTML entities, and all 25 Caesar shifts. Schemes that don't fit are left blank. `decode '<string>'` | `basenc` (coreutils 8.31+) for Z85 |
| `file_encrypt.sh` | `file_encrypt` | GPG symmetric AES-256. `file_encrypt FILE` encrypts, `file_encrypt -D FILE.gpg` decrypts. Never writes over an existing file. Asks before deleting the source afterward. | `gpg` |
| `folder_encrypt.sh` | `folder_encrypt` | Tars and GPG-encrypts a folder, `-D` reverses it. Encryption streams tar straight into gpg, so no unencrypted archive touches the disk. `-R` is bulk mode: every subdirectory of the target is handled on its own (or every `.gpg` inside it, with `-D`), and loose files in the target get moved into `loose_files/` first so they aren't left out. Asks before deleting sources, and won't extract on top of a folder that already exists. | `gpg`, `tar` |
| `pw_manager.sh` | `pw_manager` | Menu-driven password manager. Vaults are GPG-encrypted tar archives (`.gpg` single password, `.gpg2` two-layer, two passwords), unpacked to RAM (`/dev/shm` or `$XDG_RUNTIME_DIR`) while open. Search, add, and edit entries in a TUI, import/export CSV compatible with Bitwarden and KeePassXC, per-vault locking, rolling backups with a retention period. | `gpg`, `tar`; `python3` for CSV; `wl-copy` (Wayland) or `xclip`/`xsel` (X11) for clipboard |
| `ripcd.sh` | `ripcd` | Interactive CD ripper. Pulls metadata and cover art from MusicBrainz, supports multi-disc releases, retries bad reads, resumes from the first failed track, writes ReplayGain tags on FLAC. | `cdparanoia`, `curl`, `jq`, `eject`, `md5sum`; `flac` and `metaflac`, `lame`, or `oggenc` for the formats you pick |
| `media_transcode.sh` | `media_transcode` | Batch-shrinks large SDR video to HEVC in MKV, with optional downscaling, on CPU (libx265), NVIDIA (NVENC), or AMD/Intel (VAAPI). HDR10, HLG, Dolby Vision, and BT.2020 files are skipped and logged for you to handle by hand. No arguments opens a settings screen; flags or a saved profile plus `--yes` run it unattended (cron, systemd). See `media_transcode --help`. | bash 4.4+, `ffmpeg`, `ffprobe`; `flock` if you run more than one instance on the same library |
| `system_update.sh` | `system_update` | Finds the native package manager (apt, dnf, yum, zypper, pacman plus yay/paru for AUR, apk, xbps, emerge, or nix), runs its full upgrade and cleanup, then updates Flatpak and Snap if they're installed. `-l` / `--log` also appends to `/var/log/system-update.log`. | root |
| `ufw_tui.sh` | `ufw_tui` | Menu-driven front end for `ufw`: list, add, and remove rules, allow or deny by port (`80/tcp`) or source IP, set default policies, enable/disable/reload, or reset. | `ufw`, root |
| `use_my_zsh.sh` | `use_my_zsh` | Installs zsh if it's missing, makes it the login shell for you and root, and installs the bundled `zshrc` for both. See below. | root |
| `funcupdate.sh` | `funcupdate` | Re-clones this repo and redeploys it to the system-wide layout (Option B below). `-l` / `--log` appends to `/var/log/system-update.log`. | `git`, root |

## Prerequisites

- Linux with bash 4.4 or newer. Your login shell can be Bash or Zsh, it doesn't matter since every script runs under bash.
- `git`, if you want to clone the repo or use `funcupdate`.
- Whatever the "Needs" column lists for the commands you actually plan to use. Nothing is required up front. A command tells you what's missing when you run it.

I'm on Kubuntu, so in my case the common ones are `sudo apt install rsync ffmpeg gnupg screen`. Package names vary, so check yours: openSUSE calls it `gpg2` instead of `gnupg`, for example.

## Installation

Pick one option. Option A installs for just your user, Option B for everyone on the machine. Both use the same layout: scripts in a `lib/shell-functions` directory, command symlinks in a `bin` directory.

Every command below works when pasted into either Bash or Zsh.

### Option A: just your user

1. Clone the repo and step into it: `git clone https://github.com/NullAngst/shell_functions.git && cd shell_functions`
2. Make the directories: `mkdir -p ~/.local/lib/shell-functions ~/.local/bin`
3. Copy the scripts and the rc files: `cp *.sh zshrc bashrc ~/.local/lib/shell-functions/`, since `use_my_zsh` looks for `zshrc` next to itself
4. Make the scripts executable: `chmod 755 ~/.local/lib/shell-functions/*.sh`
5. Symlink each command into `~/.local/bin`:

   ```sh
   for f in ~/.local/lib/shell-functions/*.sh; do
       for name in $(sed -n -e '/^# COMMANDS:/{' -e 's/^# COMMANDS://p' -e 'q' -e '}' "$f" | grep . || basename "$f" .sh); do
           ln -sf "$f" ~/.local/bin/"$name"
       done
   done
   ```

   That uses the `COMMANDS:` names when a file has them, and the file name minus `.sh` when it doesn't.

6. Make sure `~/.local/bin` is on your `PATH`. A lot of distros already add it; check with `printf '%s\n' "$PATH"`. If it's missing, add this line to `~/.bashrc` or `~/.zshrc` (or whichever rc file your shell reads): `export PATH="$HOME/.local/bin:$PATH"`
7. Open a new terminal, or `source` the rc file you just edited.

To update later, pull the repo and repeat steps 3 through 5. `funcupdate` doesn't touch this layout.

### Option B: every user on the machine

1. Clone the repo and step into it: `git clone https://github.com/NullAngst/shell_functions.git && cd shell_functions`
2. Make the directory: `sudo mkdir -p /usr/local/lib/shell-functions`
3. Copy the scripts and the rc files: `sudo cp *.sh zshrc bashrc /usr/local/lib/shell-functions/`
4. Make the scripts executable: `sudo chmod 755 /usr/local/lib/shell-functions/*.sh`
5. Symlink each command into `/usr/local/bin`, which is already on everyone's `PATH`:

   ```sh
   for f in /usr/local/lib/shell-functions/*.sh; do
       for name in $(sed -n -e '/^# COMMANDS:/{' -e 's/^# COMMANDS://p' -e 'q' -e '}' "$f" | grep . || basename "$f" .sh); do
           sudo ln -sf "$f" /usr/local/bin/"$name"
       done
   done
   ```

No `PATH` change needed for this one.

To update later, run `sudo funcupdate`. It clones the repo to a temp directory, removes every symlink in `/usr/local/bin` that points into `/usr/local/lib/shell-functions` along with the old scripts, then copies and links the new set (plus `zshrc` and `bashrc`). That clean-out step is what keeps a renamed or removed script from leaving a dead command behind. Symlinks it didn't create are left alone, and if the clone fails nothing gets removed.

### Coming from the old pw-manager name

`pw-manager` is now `pw_manager`. On Option B, `sudo funcupdate` drops the old command on its own. If your installed `funcupdate` predates this release, run it twice this one time: the first run still executes the old copy, the second uses the new one. On Option A, delete the dead link yourself: `rm ~/.local/bin/pw-manager ~/.local/lib/shell-functions/pw-manager.sh`

Your vault list and settings carry over, since `pw_manager` still reads `~/.pw-manager-config` and `~/.pw-manager-vaults`.

## Where things end up

| Command | Paths it writes |
|---|---|
| `media_transcode` | Profiles in `~/.config/media-transcode/` (respects `$XDG_CONFIG_HOME`), run logs in `~/.local/state/media-transcode/` (respects `$XDG_STATE_HOME`), and inside the scanned directory: `_HDR_files_to_check.log` and a `.media-transcode/` folder holding per-file locks and the no-gain list. |
| `pw_manager` | Config in `~/.pw-manager-config`, known vault list in `~/.pw-manager-vaults`, open vaults in `/dev/shm` (or `$XDG_RUNTIME_DIR`), backups in a `backups/` folder next to each vault. |
| `ripcd` | Output defaults to `~/Music` (it asks), resume checkpoints in `~/.cache/simplecd-ripper/` (respects `$XDG_CACHE_HOME`), removed once a disc rips cleanly. |
| `use_my_zsh` | `~/.zshrc` and `/root/.zshrc` (the old ones kept as `.zshrc.bak-<date>`), `/etc/shells`, and with `-n` the useradd defaults. |
| `system_update`, `funcupdate` | `/var/log/system-update.log`, only with `-l` / `--log`. |

Everything else writes only where you point it.

Note that `media_transcode` and `pw_manager` use the home directory of whoever runs them. Run them with `sudo` and they read and write under `/root`, not under your home.

## Uninstalling

Option A: `find ~/.local/bin -maxdepth 1 -type l -lname "$HOME/.local/lib/shell-functions/*" -delete && rm -rf ~/.local/lib/shell-functions`

Option B: `sudo find /usr/local/bin -maxdepth 1 -type l -lname '/usr/local/lib/shell-functions/*' -delete && sudo rm -rf /usr/local/lib/shell-functions`

Both only remove symlinks that point into the install directory, so nothing else in your `bin` gets caught.

## Included shell config (`zshrc` / `bashrc`)

The repo also ships a `zshrc` and a `bashrc`: my prompt, history settings, completion, and a git-aware prompt. They're optional and the commands work fine without them.

The prompt colors come from my kitty themes in [NullAngst/kitty-themes](https://github.com/NullAngst/kitty-themes), so the prompt matches whichever one kitty is running. Kawaii Dark is the default. The others are `kawaii-light`, `amber`, `blurple`, `modern-dark`, `modern-light` and `verdigris-copper`. To switch, set `ZSH_PROMPT_THEME=amber` (zsh) or `BASH_PROMPT_THEME=amber` (bash) before the rc file runs, in `~/.zshenv` say, or edit the default line near the top of the file.

The prompt color tells you where you are: red as root, blue in a git repo, green in a Python project, the theme's accent color everywhere else. The arrow on the second line turns red when the last command failed.

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
