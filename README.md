# shell_functions

A set of standalone shell functions for common tasks: file transfer, archive
extraction, forensic file analysis, media sorting, screen session
management, secure deletion, audio conversion, and system updates.

Most function files are written to work two ways:

- **Sourced**: defines the function in your current shell, so you can call
  it by name (`vmv foo bar`).
- **Executed directly**: run the file itself instead of sourcing it, and it
  calls the function once with whatever arguments you passed
  (`./vmv.sh foo bar`).

Each of these files detects at runtime whether it's running under `bash` or
`zsh` and adjusts its sourced-vs-executed check accordingly, so the same
file sources cleanly into either shell.

A handful of files (`file_encrypt.sh`, `folder_encrypt.sh`, `pw-manager.sh`,
`ufw_tui.sh`, `funcupdate.sh`) are standalone scripts instead of sourceable
functions; see [Standalone Scripts](#standalone-scripts) below. They still
install and symlink the same way as everything else, they just don't do
anything useful if you `source` them; run them directly.

## Functions

| File | Function | What it does |
|---|---|---|
| `cleandir.sh` | `cleandir` | Removes empty directories in the current directory. `-r` recurses into all subdirectories. |
| `vmv.sh` | `vmv` | Verbose move via `rsync`. Removes source files as they transfer and deletes any source directories left empty afterward. |
| `vcp.sh` | `vcp` | Verbose copy via `rsync`, skipping files that already exist at the destination. |
| `unpack.sh` | `unpack` | Recursively extracts `tar.gz`/`tgz`/`tar.bz2`/`tbz2`/`tar.xz`/`tar`/`zip`/`rar`/`7z`, including multi-volume/split archives, then deletes the source archive on a successful extraction. |
| `scrmgr.sh` | `scrmgr` | Single entry point for managing GNU `screen` sessions: `scrmgr start <name>`, `scrmgr resume <name>`, `scrmgr kill <name>`, `scrmgr list`, `scrmgr wipe`. |
| `moveav.sh` | `moveav` | Sorts files in a directory into `images/`, `videos/`, and `audio/` subfolders by extension. `-R` recurses, sorting each subdirectory independently. |
| `shredfile.sh` | `shredfile` | Runs `shred -vzu` against a single file after an interactive confirmation. Does not reliably wipe data on SSDs. |
| `shredfolder.sh` | `shredfolder` | Runs `shred -vzu` against every file in a directory, then removes the directory, after an interactive confirmation. Does not reliably wipe data on SSDs. |
| `ffile.sh` | `ffile` | Forensic file analysis: stat, checksums (md5/sha1/sha256/sha512/b2), lsattr, getfattr, getfacl, lsof, package ownership, hex header/tail, printable strings, exiftool metadata, binwalk signatures, and a byte-entropy estimate. |
| `audio_convert_functions.sh` | `2mp3`, `2flac`, `2ogg` | Converts audio to MP3, FLAC, or OGG via `ffmpeg`. Given a file, converts in place next to it. Given a directory, batch-converts every recognized audio file directly inside it (not recursive) into a `converted/` subfolder, skipping files already in the target format and never overwriting existing output. `-v` switches MP3/OGG to their highest-quality VBR mode instead of the fixed-bitrate default (ignored for FLAC, which is always lossless). |
| `ripcd.sh` | `ripcd` | Interactive terminal CD ripper. Fetches metadata, coverart, writes replaygain tags on FLAC. |
| `system_update.sh` | `system_update` | Checks for package manager and secondary managers (pacman, flatpak, snap) and runs their full update commands. |
| `funchelp.sh` | `funchelp` | Prints a summary of the aliases and functions in this set. |


## Standalone Scripts

These are not sourceable functions. They always run as their own process,
whether you invoke them as `./file_encrypt.sh` or as `file_encrypt` once
symlinked per the Installation steps below.

| File | Command | What it does |
|---|---|---|
| `file_encrypt.sh` | `file_encrypt` | Encrypts a file with GPG symmetric AES-256 (`file_encrypt FILE`), or decrypts with `-D` (`file_encrypt -D FILE.gpg`). Prompts before deleting the source file/archive after a successful run. |
| `folder_encrypt.sh` | `folder_encrypt` | Tars and GPG-encrypts a folder (`folder_encrypt FOLDER`), or reverses that with `-D`. `-R` switches to bulk mode: every subdirectory of the target is archived/encrypted (or every `.gpg` inside it decrypted) individually, and on encrypt, loose files directly inside the target are moved into a `loose_files/` subfolder first so they aren't left behind. Prompts before deleting sources after each successful operation. |
| `pw-manager.sh` | `pw-manager` | Terminal password manager. Vaults are GPG-encrypted tar archives (`.gpg` for single-password, `.gpg2` for a two-layer/two-password scheme), decrypted to a `/dev/shm` tmpfs while in use. Menu-driven: create/open vaults, browse/search/add/edit entries in a TUI, import/export CSV compatible with Bitwarden and KeePassXC, set a default vault directory and backup retention. Per-vault file locking prevents opening the same vault twice at once, and each write keeps rolling backups (pruned after the configured retention period). |
| `ufw_tui.sh` | `ufw_tui` | Menu-driven front end for `ufw`. List/add/remove rules, allow or deny by port (with optional protocol, e.g. `80/tcp`) or by source IP, set default incoming/outgoing policy, enable/disable/reload UFW, or reset it to factory defaults. Must be run as root. |
| `funcupdate.sh` | `funcupdate` | Re-clones this repo to a temp directory and redeploys every `.sh` file to `/usr/local/lib/shell-functions`, symlinking each into `/usr/local/bin` (System-wide Option B layout only). Must be run as root; use it to pull updates after the initial install. |

## Installation

Every script works the exact same way regardless of your shell environment. You copy the files to a storage directory and symlink them into a directory that is actively read by your `$PATH`.

Pick a setup below depending on whether you use Zsh or Bash, along with whether you want this deployed for a single account or every user on the machine.

## Zsh

### Option A: just your user
First, download or create the .sh functions you want to use in a folder, and have your terminal open there.

```zsh
mkdir -p ~/.config/zsh/functions
cp *.sh ~/.config/zsh/functions/
chmod +x ~/.config/zsh/functions/*.sh
```

To run the commands without the `.sh` extension, symlink them into your local bin directory:

```zsh
mkdir -p ~/.local/bin
for f in ~/.config/zsh/functions/*.sh; do
    name=$(basename "$f" .sh)
    ln -sf "$f" "$HOME/.local/bin/$name"
done
```

Add the bin directory to your `PATH` in `~/.zshrc`:

```zsh
export PATH="$HOME/.local/bin:$PATH"
```

Open a new terminal or run `source ~/.zshrc` to apply the changes.

### Option B: every user on the machine
First, download or create the .sh functions you want to use in a folder, and have your terminal open there.

```zsh
sudo mkdir -p /usr/local/lib/shell-functions
sudo cp *.sh /usr/local/lib/shell-functions/
sudo chmod +x /usr/local/lib/shell-functions/*.sh
```

Symlink each script (without the `.sh` extension) into a directory that is already on everyone's `PATH`:

```zsh
for f in /usr/local/lib/shell-functions/*.sh; do
    name=$(basename "$f" .sh)
    sudo ln -sf "$f" "/usr/local/bin/$name"
done
```

## Bash

### Option A: just your user
First, download or create the .sh functions you want to use in a folder, and have your terminal open there.

```bash
mkdir -p ~/.config/bash/functions
cp *.sh ~/.config/bash/functions/
chmod +x ~/.config/bash/functions/*.sh
```

To run the commands without the `.sh` extension, symlink them into your local bin directory:

```bash
mkdir -p ~/.local/bin
for f in ~/.config/bash/functions/*.sh; do
    name=$(basename "$f" .sh)
    ln -sf "$f" "$HOME/.local/bin/$name"
done
```

Add the bin directory to your `PATH` in `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Open a new terminal or run `source ~/.bashrc` to apply the changes.

### Option B: every user on the machine
First, download or create the .sh functions you want to use in a folder, and have your terminal open there.

```bash
sudo mkdir -p /usr/local/lib/shell-functions
sudo cp *.sh /usr/local/lib/shell-functions/
sudo chmod +x /usr/local/lib/shell-functions/*.sh
```

Symlink each script (without the `.sh` extension) into a directory that is already on everyone's `PATH`:

```bash
for f in /usr/local/lib/shell-functions/*.sh; do
    name=$(basename "$f" .sh)
    sudo ln -sf "$f" "/usr/local/bin/$name"
done
```

If you run both shells against the same shared `/usr/local/lib/shell-functions`
directory (Option B in each section), you only need to copy the files once.
Each rc file still needs its own `source` block, since `.bashrc` and `.zshrc`
are read independently.

`system_update -l` / `--log` appends its output to `/var/log/system-update.log`
in addition to printing it. `funcupdate -l` / `--log` appends to the same log
file, prefixed with its own start timestamp, before it does anything else.

## Notes

- `shredfile` and `shredfolder` both warn, and require interactive
  confirmation, that `shred` does not reliably erase data on SSDs. Wear
  leveling means the physical cells written to aren't guaranteed to be the
  ones overwritten.
- `scrmgr` intentionally isn't named `screen`, so it won't shadow the real
  `screen` binary.
- `ufw_tui` and `funcupdate` both require root (run with `sudo`); `pw-manager`
- `file_encrypt`/`folder_encrypt` and `pw-manager`'s vault encryption all use
  GPG symmetric AES-256, but they're independent tools with separate on-disk
  formats; a vault made by one isn't compatible with the other.
