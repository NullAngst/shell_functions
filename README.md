# shell_functions

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
| `funchelp.sh` | `funchelp` | Prints a summary of the aliases and functions in this set. Renamed from `cfhelp`. |

`vmv`, `vcp`, `unpack`, `scrmgr`, `moveav`, `shredfile`, `shredfolder`, `ffile`,
`cleandir`, `audio_convert_functions`, and `funchelp` are plain bash and work

## Installation

Every file is written so it works two ways:

- **Sourced**: defines the function in your current shell, so you can call
  it by name (`vmv foo bar`).
- **Executed directly**: if you run the file itself instead of sourcing it,
  it calls the function once with whatever arguments you passed
  (`./vmv.sh foo bar`), same as running any other script.

Pick one of the two setups below depending on whether you want these
available for just your account or for every user on the machine.

### Option A: just your user

```bash
mkdir -p ~/.config/zsh/functions
cp *.sh ~/.config/zsh/functions/
chmod +x ~/.config/zsh/functions/*.sh
```

Then add one `source` line per function to your `~/.zshrc` (the provided
`zshrc` in this set already has these):

```bash
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
source "$ZSH_FUNCTIONS_DIR/funchelp.sh"
```

Open a new terminal, or run `source ~/.zshrc`, and the functions are live.

If you'd also like to be able to invoke them directly as commands (not just
as sourced shell functions), add the directory to your `PATH` in `~/.zshrc`,
above the `source` lines:

```bash
export PATH="$HOME/.config/zsh/functions:$PATH"
```

That lets you run `vmv.sh foo bar` from anywhere, in addition to `vmv foo bar`
after sourcing.

### Option B: every user on the machine

Install to a directory already on the system `PATH`, owned by root:

```bash
sudo mkdir -p /usr/local/lib/zsh-functions
sudo cp *.sh /usr/local/lib/zsh-functions/
sudo chmod +x /usr/local/lib/zsh-functions/*.sh
```

Then have each user (or a system-wide config like `/etc/zsh/zshrc`) source
from that shared location:

```bash
ZSH_FUNCTIONS_DIR="/usr/local/lib/zsh-functions"
source "$ZSH_FUNCTIONS_DIR/cleandir.sh"
# ...same list as above
```

For direct invocation as commands without sourcing, symlink each script (no
`.sh` extension) into a directory that's already on everyone's `PATH`, such
as `/usr/local/bin`:

```bash
for f in /usr/local/lib/zsh-functions/*.sh; do
    name=$(basename "$f" .sh)
    sudo ln -sf "$f" "/usr/local/bin/$name"
done
```

That gives every user on the machine `vmv`, `unpack`, `ffile`, etc. as
regular commands, whether or not they've sourced anything into their shell.

## Notes

- `shredfile` and `shredfolder` both warn, and require interactive
  confirmation, that `shred` does not reliably erase data on SSDs (wear
  leveling means the physical cells written to aren't guaranteed to be the
  ones overwritten).
- `scrmgr` intentionally isn't named `screen`, so it won't shadow the real
  `screen` binary.
