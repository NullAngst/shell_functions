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
| `funchelp.sh` | `funchelp` | Prints a summary of the aliases and functions in this set. |

`system_update.sh` is documented separately under [System updates](#system-updates)
below. It's a standalone script, not a sourced function.

## Installation

Every function file works the same way regardless of shell: copy it
somewhere, `source` it from your rc file, done. Pick a setup below depending
on whether you use zsh, bash, or both, and whether you want this for just
your account or every user on the machine.

### Zsh

#### Option A: just your user

```zsh
mkdir -p ~/.config/zsh/functions
cp *.sh ~/.config/zsh/functions/
chmod +x ~/.config/zsh/functions/*.sh
```

Add one `source` line per function to your `~/.zshrc`:

```zsh
ZSH_FUNCTIONS_DIR="$HOME/.config/zsh/functions"
source "$ZSH_FUNCTIONS_DIR/cleandir.sh"
source "$ZSH_FUNCTIONS_DIR/vmv.sh"
source "$ZSH_FUNCTIONS_DIR/vcp.sh"
source "$ZSH_FUNCTIONS_DIR/unpack.sh"
source "$ZSH_FUNCTIONS_DIR/scrmgr.sh"
source "$ZSH_FUNCTIONS_DIR/moveav.sh"
source "$ZSH_FUNCTIONS_DIR/shredfile.sh"
source "$ZSH_FUNCTIONS_DIR/shredfolder.sh"
source "$ZSH_FUNCTIONS_DIR/ffile.sh"
source "$ZSH_FUNCTIONS_DIR/audio_convert_functions.sh"
source "$ZSH_FUNCTIONS_DIR/ripcd.sh
source "$ZSH_FUNCTIONS_DIR/funchelp.sh"
source "$ZSH_FUNCTION_DIR/system_update.sh"
```

Open a new terminal, or run `source ~/.zshrc`, and the functions are live.

To also invoke them directly as commands, add the directory to `PATH` in
`~/.zshrc`, above the `source` lines:

```zsh
export PATH="$HOME/.config/zsh/functions:$PATH"
```

That lets you run `vmv.sh foo bar` from anywhere, in addition to `vmv foo bar`
after sourcing.

#### Option B: every user on the machine

```zsh
sudo mkdir -p /usr/local/lib/shell-functions
sudo cp *.sh /usr/local/lib/shell-functions/
sudo chmod +x /usr/local/lib/shell-functions/*.sh
```

Source from that shared location, either per-user in each `~/.zshrc` or
system-wide in `/etc/zsh/zshrc`:

```zsh
ZSH_FUNCTIONS_DIR="/usr/local/lib/shell-functions"
source "$ZSH_FUNCTIONS_DIR/cleandir.sh"
source "$ZSH_FUNCTIONS_DIR/vmv.sh"
source "$ZSH_FUNCTIONS_DIR/vcp.sh"
source "$ZSH_FUNCTIONS_DIR/unpack.sh"
source "$ZSH_FUNCTIONS_DIR/scrmgr.sh"
source "$ZSH_FUNCTIONS_DIR/moveav.sh"
source "$ZSH_FUNCTIONS_DIR/shredfile.sh"
source "$ZSH_FUNCTIONS_DIR/shredfolder.sh"
source "$ZSH_FUNCTIONS_DIR/ffile.sh"
source "$ZSH_FUNCTIONS_DIR/audio_convert_functions.sh"
source "$ZSH_FUNCTIONS_DIR/ripcd.sh
source "$ZSH_FUNCTIONS_DIR/funchelp.sh"
source "$ZSH_FUNCTION_DIR/system_update.sh"
```

For direct invocation as commands without sourcing, symlink each script (no
`.sh` extension) into a directory already on everyone's `PATH`:

```zsh
for f in /usr/local/lib/shell-functions/*.sh; do
    name=$(basename "$f" .sh)
    sudo ln -sf "$f" "/usr/local/bin/$name"
done
```

### Bash

#### Option A: just your user

```bash
mkdir -p ~/.config/bash/functions
cp *.sh ~/.config/bash/functions/
chmod +x ~/.config/bash/functions/*.sh
```

Add one `source` line per function to your `~/.bashrc`:

```bash
BASH_FUNCTIONS_DIR="$HOME/.config/bash/functions"
source "$BASH_FUNCTIONS_DIR/cleandir.sh"
source "$BASH_FUNCTIONS_DIR/vmv.sh"
source "$BASH_FUNCTIONS_DIR/vcp.sh"
source "$BASH_FUNCTIONS_DIR/unpack.sh"
source "$BASH_FUNCTIONS_DIR/scrmgr.sh"
source "$BASH_FUNCTIONS_DIR/moveav.sh"
source "$BASH_FUNCTIONS_DIR/shredfile.sh"
source "$BASH_FUNCTIONS_DIR/shredfolder.sh"
source "$BASH_FUNCTIONS_DIR/ffile.sh"
source "$BASH_FUNCTIONS_DIR/audio_convert_functions.sh"
source "$BASH_FUNCTIONS_DIR/ripcd.sh"
source "$BASH_FUNCTIONS_DIR/funchelp.sh"
source "$BASH_FUNCTION_DIR/system_update.sh"
```

Open a new terminal, or run `source ~/.bashrc`, and the functions are live.

To also invoke them directly as commands, add the directory to `PATH` in
`~/.bashrc`, above the `source` lines:

```bash
export PATH="$HOME/.config/bash/functions:$PATH"
```

#### Option B: every user on the machine

```bash
sudo mkdir -p /usr/local/lib/shell-functions
sudo cp *.sh /usr/local/lib/shell-functions/
sudo chmod +x /usr/local/lib/shell-functions/*.sh
```

Source from that shared location, either per-user in each `~/.bashrc` or
system-wide in `/etc/bash.bashrc`:

```bash
BASH_FUNCTIONS_DIR="/usr/local/lib/shell-functions"
source "$BASH_FUNCTIONS_DIR/cleandir.sh"
source "$BASH_FUNCTIONS_DIR/vmv.sh"
source "$BASH_FUNCTIONS_DIR/vcp.sh"
source "$BASH_FUNCTIONS_DIR/unpack.sh"
source "$BASH_FUNCTIONS_DIR/scrmgr.sh"
source "$BASH_FUNCTIONS_DIR/moveav.sh"
source "$BASH_FUNCTIONS_DIR/shredfile.sh"
source "$BASH_FUNCTIONS_DIR/shredfolder.sh"
source "$BASH_FUNCTIONS_DIR/ffile.sh"
source "$BASH_FUNCTIONS_DIR/audio_convert_functions.sh"
source "$BASH_FUNCTIONS_DIR/ripcd.sh"
source "$BASH_FUNCTIONS_DIR/funchelp.sh"
source "$BASH_FUNCTION_DIR/system_update.sh"
```

For direct invocation as commands without sourcing, symlink each script (no
`.sh` extension) into a directory already on everyone's `PATH`:

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
