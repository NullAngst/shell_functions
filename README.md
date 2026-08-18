# shell_functions

A set of standalone shell functions for common tasks: file transfer, archive
extraction, forensic file analysis, media sorting, screen session
management, secure deletion, audio conversion, and system updates.

Every function file is written to work two ways:

- **Sourced**: defines the function in your current shell, so you can call
  it by name (`vmv foo bar`).
- **Executed directly**: run the file itself instead of sourcing it, and it
  calls the function once with whatever arguments you passed
  (`./vmv.sh foo bar`).

Each file detects at runtime whether it's running under `bash` or `zsh` and
adjusts its sourced-vs-executed check accordingly, so the same file sources
cleanly into either shell.

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
| `system_update.sh` | `system-update` | Checks for package manager and secondary managers (pacman, flatpak, snap) and runs their full update commands. |
| `funchelp.sh` | `funchelp` | Prints a summary of the aliases and functions in this set. |


## Installation

Every script works the exact same way regardless of your shell environment. You copy the files to a storage directory and symlink them into a directory that is actively read by your `$PATH`.

Pick a setup below depending on whether you use Zsh or Bash, along with whether you want this deployed for a single account or every user on the machine.

## Zsh

### Option A: just your user

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

`-l` / `--log` appends output to `/var/log/system-update.log` in addition to
printing it.

## Notes

- `shredfile` and `shredfolder` both warn, and require interactive
  confirmation, that `shred` does not reliably erase data on SSDs. Wear
  leveling means the physical cells written to aren't guaranteed to be the
  ones overwritten.
- `scrmgr` intentionally isn't named `screen`, so it won't shadow the real
  `screen` binary.
