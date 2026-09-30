# shell_functions

A set of Bash scripts for everyday terminal work on Linux (moving files, extracting archives, converting audio, shrinking video, encrypting files, updating the system), installed as plain commands that work the same from Bash or Zsh.

## How it works

Every `.sh` file in this repo is a script with a `#!/usr/bin/env bash` shebang. You copy them into one directory, then symlink each one onto your `PATH` under its command name, so `vmv.sh` becomes `vmv`. Since they always run under bash via the shebang, your interactive shell doesn't matter. Zsh users install them exactly like Bash users do.

The files come in two kinds:

- **Functions** can be run as a command (the normal way, through the symlink) or `source`d into your shell to define the function directly. Each one checks at runtime whether it was sourced or executed, under either bash or zsh, and behaves accordingly.
- **Standalone scripts** only run as their own process. Don't `source` them. Some call `exit`, and that will close your shell.

One file can provide more than one command. `audio_convert_functions.sh` declares `# COMMANDS: 2mp3 2flac 2ogg` in its header, so the install step makes three symlinks to it and the script picks what to do from the name it was called by. Running it as `./audio_convert_functions.sh` directly isn't valid, use one of the three names.

Every command below is the file name without `.sh`, unless the file has a `COMMANDS:` line.

## Functions

| File | Command | What it does | Needs |
|---|---|---|---|
| `vmv.sh` | `vmv` | Verbose move via `rsync`. Removes source files as they transfer, then deletes source directories left empty. `vmv <src> [src...] <dest>` | `rsync` |
| `vcp.sh` | `vcp` | Verbose copy via `rsync`, skipping files that already exist at the destination. `vcp <src> [src...] <dest>` | `rsync` |
| `unpack.sh` | `unpack` | Recursively extracts archives into their own directory, including archives inside archives, then deletes the source on success. Handles tar, tar.gz/tgz, tar.bz2/tbz2/tbz, tar.xz/txz, tar.zst/tzst, zip, rar, 7z, bare gz/bz2/xz/zst, and split sets (`.partN.rar`, `.rNN`, `.zNN`, `.zip.NNN`, `.7z.NNN`, `name.tar.001`). `-k` keeps sources, `-n` is a dry run, `-v` shows extractor output, `-d N` caps nesting depth (default 8). | `tar`, plus `gzip`/`bzip2`/`xz`/`zstd`, `unrar` or `7z`, and `7z`/`7zz`/`7za`, only for the formats it actually hits |
| `scrmgr.sh` | `scrmgr` | One entry point for GNU `screen`: `scrmgr start <name>`, `resume <name>`, `kill <name>`, `list`, `wipe`. | `screen` |
| `moveav.sh` | `moveav` | Sorts files into `images/`, `videos/`, and `audio/` subfolders by extension. `moveav [-R] [dir]`, `-R` sorts each subdirectory on its own. | nothing extra |
| `shredfile.sh` | `shredfile` | `shred -vzu` on one file after a confirmation prompt. | `shred` (coreutils) |
| `shredfolder.sh` | `shredfolder` | `shred -vzu` on every file in a directory, then removes the directory, after a confirmation prompt. | `shred` (coreutils) |
| `ffile.sh` | `ffile` | Forensic file analysis: stat, md5/sha1/sha256/sha512/b2 checksums, lsattr, getfattr, getfacl, lsof, package ownership, hex header and tail, printable strings, exiftool metadata, binwalk signatures, byte entropy. A missing optional tool just means less output. | optional: `exiftool`, `binwalk`, `xxd` or `hexdump`, `strings`, `getfattr`, `getfacl`, `lsof`, `ent` or `python3` |
| `cleandir.sh` | `cleandir` | Removes empty directories in the current directory. `-r` recurses. | nothing extra |
| `audio_convert_functions.sh` | `2mp3`, `2flac`, `2ogg` | Converts audio with `ffmpeg`. A file converts next to itself. A directory batch-converts every audio file directly inside it (not recursive) into a `converted/` subfolder, skipping files already in the target format and never overwriting output. `-v` uses the top VBR mode for MP3/OGG instead of fixed bitrate; FLAC ignores it. | `ffmpeg` |
| `funchelp.sh` | `funchelp` | Prints a summary of every command in this set and the aliases from the bundled rc files. | nothing extra |

A heads up on `shredfile` and `shredfolder`: `shred` does not reliably wipe data on SSDs or on copy-on-write filesystems like Btrfs, since the overwrite can land on different blocks than the original data. Both prompts say so. Believe them.

## Standalone Scripts

| File | Command | What it does | Needs |
|---|---|---|---|
| `decode.sh` | `decode` | Prints every plausible decoding of one string: base64 (standard and URL-safe), base32, base85/Z85, hex, octal, decimal, binary, URL/percent, ROT13, ROT47, Atbash, HTML entities, and all 25 Caesar shifts. Schemes that don't fit are left blank. `decode '<string>'` | `basenc` (coreutils 8.31+) for Z85 |
| `file_encrypt.sh` | `file_encrypt` | GPG symmetric AES-256. `file_encrypt FILE` encrypts, `file_encrypt -D FILE.gpg` decrypts. Asks before deleting the source afterward. | `gpg` |
| `folder_encrypt.sh` | `folder_encrypt` | Tars and GPG-encrypts a folder, `-D` reverses it. `-R` is bulk mode: every subdirectory of the target is handled on its own (or every `.gpg` inside it, with `-D`), and loose files in the target get moved into `loose_files/` first so they aren't left out. Asks before deleting sources. | `gpg`, `tar` |
| `pw-manager.sh` | `pw-manager` | Menu-driven password manager. Vaults are GPG-encrypted tar archives (`.gpg` single password, `.gpg2` two-layer, two passwords), unpacked to `/dev/shm` while open. Search, add, and edit entries in a TUI, import/export CSV compatible with Bitwarden and KeePassXC, per-vault locking, rolling backups with a retention period. | `gpg`, `tar`; `python3` for CSV; `wl-copy`, `xclip`, `xsel`, or `pbcopy` for clipboard |
| `ripcd.sh` | `ripcd` | Interactive CD ripper. Pulls metadata and cover art from MusicBrainz, supports multi-disc releases, writes ReplayGain tags on FLAC. | `cdparanoia`, `curl`, `jq`, `eject`, `metaflac`; `flac`, `lame`, or `oggenc` for the formats you pick |
| `media_transcode.sh` | `media_transcode` | Batch-shrinks large SDR video to HEVC in MKV, with optional downscaling, on CPU (libx265), NVIDIA (NVENC), or AMD/Intel (VAAPI). HDR10, HLG, Dolby Vision, and BT.2020 files are skipped and logged for you to handle by hand. No arguments opens a settings screen; flags or a saved profile plus `--yes` run it unattended (cron, systemd). See `media_transcode --help`. | bash 4.4+, `ffmpeg`, `ffprobe`; `flock` if you run more than one instance on the same library |
| `system_update.sh` | `system_update` | Finds the native package manager (apt, dnf, yum, zypper, pacman plus yay/paru for AUR, apk, xbps, emerge, or nix), runs its full upgrade and cleanup, then updates Flatpak and Snap if they're installed. `-l` / `--log` also appends to `/var/log/system-update.log`. | root |
| `ufw_tui.sh` | `ufw_tui` | Menu-driven front end for `ufw`: list, add, and remove rules, allow or deny by port (`80/tcp`) or source IP, set default policies, enable/disable/reload, or reset. | `ufw`, root |
| `funcupdate.sh` | `funcupdate` | Re-clones this repo and redeploys it to the system-wide layout (Option B below). `-l` / `--log` appends to `/var/log/system-update.log`. | `git`, root |

## Prerequisites

- Linux with bash 4.4 or newer. Your login shell can be Bash or Zsh, it doesn't matter since every script runs under bash.
- `git`, if you want to clone the repo or use `funcupdate`.
- Whatever the "Needs" column lists for the commands you actually plan to use. Nothing is required up front. A command tells you what's missing when you run it.

I'm on openSUSE, so in my case the common ones are `sudo zypper install rsync ffmpeg gpg2 screen`. Package names vary, so check yours: Debian and Ubuntu call it `gnupg` instead of `gpg2`, for example.

## Installation

Pick one option. Option A installs for just your user, Option B for everyone on the machine. Both use the same layout: scripts in a `lib/shell-functions` directory, command symlinks in a `bin` directory.

Every command below works when pasted into either Bash or Zsh.

### Option A: just your user

1. Clone the repo and step into it: `git clone https://github.com/NullAngst/shell_functions.git && cd shell_functions`
2. Make the directories: `mkdir -p ~/.local/lib/shell-functions ~/.local/bin`
3. Copy the scripts: `cp *.sh ~/.local/lib/shell-functions/`
4. Make them executable: `chmod 755 ~/.local/lib/shell-functions/*.sh`
5. Symlink each command into `~/.local/bin`:

   ```sh
   for f in ~/.local/lib/shell-functions/*.sh; do
       for name in $(grep -m1 '^# COMMANDS:' "$f" | cut -d: -f2- | grep . || basename "$f" .sh); do
           ln -sf "$f" ~/.local/bin/"$name"
       done
   done
   ```

   That uses the `COMMANDS:` names when a file has them, and the file name minus `.sh` when it doesn't.

6. Make sure `~/.local/bin` is on your `PATH`. A lot of distros already add it; check with `echo $PATH`. If it's missing, add this line to `~/.bashrc` or `~/.zshrc` (or whichever rc file your shell reads): `export PATH="$HOME/.local/bin:$PATH"`
7. Open a new terminal, or `source` the rc file you just edited.

To update later, pull the repo and repeat steps 3 through 5. `funcupdate` doesn't touch this layout.

### Option B: every user on the machine

1. Clone the repo and step into it: `git clone https://github.com/NullAngst/shell_functions.git && cd shell_functions`
2. Make the directory: `sudo mkdir -p /usr/local/lib/shell-functions`
3. Copy the scripts: `sudo cp *.sh /usr/local/lib/shell-functions/`
4. Make them executable: `sudo chmod 755 /usr/local/lib/shell-functions/*.sh`
5. Symlink each command into `/usr/local/bin`, which is already on everyone's `PATH`:

   ```sh
   for f in /usr/local/lib/shell-functions/*.sh; do
       for name in $(grep -m1 '^# COMMANDS:' "$f" | cut -d: -f2- | grep . || basename "$f" .sh); do
           sudo ln -sf "$f" /usr/local/bin/"$name"
       done
   done
   ```

No `PATH` change needed for this one.

To update later, run `sudo funcupdate`. It clones the repo to a temp directory, removes every symlink in `/usr/local/bin` that points into `/usr/local/lib/shell-functions` along with the old scripts, then copies and links the new set. That clean-out step is what keeps a renamed or removed script from leaving a dead command behind. Symlinks it didn't create are left alone.

If you installed before `Media_Transcode.sh` was renamed to `media_transcode.sh`, run `sudo funcupdate` twice this one time. The first run still executes your old copy of `funcupdate`, which doesn't clean up. The second run uses the new one and removes the stale `Media_Transcode` command.

### Sourcing the functions instead (optional)

You don't need this. The symlinks already make every command available. But if you want the functions defined in your shell itself, add lines like these to `~/.bashrc` or `~/.zshrc`, pointing at wherever you installed them (Option B path shown):

```sh
for f in vmv vcp unpack scrmgr moveav shredfile shredfolder ffile cleandir audio_convert_functions funchelp; do
    source /usr/local/lib/shell-functions/$f.sh
done
```

ONLY SOURCE THE FILES LISTED UNDER FUNCTIONS. The standalone scripts will run the moment they're sourced, and some of them `exit`, which closes your terminal.

## Where things end up

| Command | Paths it writes |
|---|---|
| `media_transcode` | Profiles in `~/.config/media-transcode/` (respects `$XDG_CONFIG_HOME`), run logs in `~/.local/state/media-transcode/` (respects `$XDG_STATE_HOME`), and inside the scanned directory: `_HDR_files_to_check.log` and a `.media-transcode/` folder holding per-file locks and the no-gain list. |
| `pw-manager` | Config in `~/.pw-manager-config`, known vault list in `~/.pw-manager-vaults`, open vaults in `/dev/shm`. |
| `ripcd` | Output defaults to `~/Music` (it asks), resume checkpoints in `~/.cache/simplecd-ripper/`. |
| `system_update`, `funcupdate` | `/var/log/system-update.log`, only with `-l` / `--log`. |

Everything else writes only where you point it.

Note that `media_transcode` and `pw-manager` use the home directory of whoever runs them. Run them with `sudo` and they read and write under `/root`, not under your home.

## Uninstalling

Option A: `find ~/.local/bin -maxdepth 1 -type l -lname "$HOME/.local/lib/shell-functions/*" -delete && rm -rf ~/.local/lib/shell-functions`

Option B: `sudo find /usr/local/bin -maxdepth 1 -type l -lname '/usr/local/lib/shell-functions/*' -delete && sudo rm -rf /usr/local/lib/shell-functions`

Both only remove symlinks that point into the install directory, so nothing else in your `bin` gets caught.

## Included shell config (`bashrc` / `zshrc`)

The repo also ships a `bashrc` and a `zshrc`: my amber prompt theme, history settings, completion, and a git-aware prompt. They're optional, nothing above installs them, and the commands work fine without them. If you want one, copy it into place yourself (`cp bashrc ~/.bashrc` or `cp zshrc ~/.zshrc`) and add back anything from your old config. Both already add `~/.local/bin` to `PATH`, so they cover step 6 of Option A.

Both define three aliases, which `funchelp` also lists:

- `ls` runs `ls --color=auto -Flartchs`
- `grep` runs `grep --color=auto -i -n -I`, so it is always case-insensitive
- `cp` runs `rsync -vpartlXEHhP --ignore-existing`

Watch the `cp` alias. `--ignore-existing` silently skips any file that already exists at the destination instead of overwriting it, and rsync's trailing-slash rules for directories differ from `cp`'s. Aliases only apply in interactive shells, so scripts still get the real `cp`, but it will catch you out at the prompt at some point. Delete the line if you'd rather keep the real `cp`. The same goes for `grep` if you don't want case-insensitive by default.

Now every command is on your `PATH`, runs the same from Bash or Zsh, and `funchelp` will list them whenever you forget one. Tinker as you see fit.
