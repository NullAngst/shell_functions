# Maintenance

What to check every couple of months to keep these scripts working, and how to update them. Plan on 20 to 30 minutes.

## Prerequisites

- A clone of the repo: `git clone https://github.com/NullAngst/shell_functions.git`
- `shellcheck`. I use apt, so in my case `sudo apt install shellcheck`. It depends on your system.
- `zsh`, for checking the zshrc.

## 1. Lint everything

1. Step into the clone and pull: `cd shell_functions && git pull`
2. Run shellcheck on every script: `shellcheck *.sh`, since every one of them has to pass with no warnings
3. Run it on the bash config too: `shellcheck -s bash bashrc`
4. Syntax-check the zsh config: `zsh -n zshrc`

A new shellcheck release sometimes adds checks. Fix what it finds rather than adding a disable comment, unless the code is right and shellcheck can't tell (traps, jq filters in single quotes). Every existing disable has a comment saying why.

## 2. Check the house rules still hold

These greps should print nothing. Anything they find is a regression.

1. No echo: `grep -nE '(^|[^a-z_-])echo( |$)' *.sh`
2. No GNU-only flags: `grep -nE 'sed -i|grep -[a-zA-Z]*P|readlink -f|date -d|-printf|stat -c|xargs -r|grep -m|sort -z|mktemp -[pt]|df -B|realpath -m' *.sh`
3. Every script in strict mode: `grep -L 'set -euo pipefail' *.sh`
4. No hyphens in script names: `ls *-*.sh 2>/dev/null`

## 3. Smoke test the cheap ones

None of these change anything outside a temp directory.

1. `./decode.sh 'SGVsbG8='` should print `Hello` on the first line
2. `./ffile.sh /bin/sh | head -20` should show the IDENTITY and STAT sections
3. `./funchelp.sh` should list every `.sh` file in the repo. If you added or renamed a script, update it here too.
4. `./media_transcode.sh --help` should print usage
5. Make a temp dir with a zip inside a tar.gz and run `./unpack.sh -n` on it, then without `-n`
6. `sudo ./system_update.sh` on one machine, since package manager flags drift (see below)

For `pw_manager`, make a throwaway vault in a temp directory, add an entry, save, reopen it, export to CSV and import that CSV into a second vault. That covers every gpg and tar path in it.

## 4. Things that change upstream

Check these against current docs when something breaks, or once or twice a year anyway.

- Package managers (`system_update`, `use_my_zsh`): dnf5 replacing dnf on Fedora, zypper on Leap vs Tumbleweed, `pacman -Sc` prompts, yay/paru flags, `xbps-remove -Oo`, `apk cache clean`. A new distro family means a new branch in both scripts.
- MusicBrainz and the Cover Art Archive (`ripcd`): the `discid` lookup URL, the JSON field names (`artist-credit`, `media`, `track-count`, `cover-art-archive`), and the thumbnail keys (`1200`, `large`). MusicBrainz also wants a real User-Agent with a contact URL; that's `USER_AGENT` at the top of `ripcd.sh`.
- ffmpeg (`media_transcode`, `2mp3`/`2flac`/`2ogg`): NVENC preset names (`p1` to `p7`), `-rc vbr -cq`, VAAPI filter names (`scale_vaapi`, `hwupload`), and x265 parameter names in `X265_PARAMS`. `media_transcode` reads `ffmpeg -encoders` and `-filters` at start, so a missing encoder shows up as a validation error rather than a crash.
- GnuPG (`pw_manager`, `file_encrypt`, `folder_encrypt`): the `--s2k-*` options and `--pinentry-mode loopback`. If gpg ever changes its defaults, existing vaults still open, since gpg reads the parameters from the file itself.
- kitty themes: the prompt palettes in `zshrc` and `bashrc` are copied from [NullAngst/kitty-themes](https://github.com/NullAngst/kitty-themes). If a theme there changes color or a new one shows up, update the `_prompt_palette` lines in both files (accent = cursor, white = foreground, black = background, red/green/blue = color1/color2/color4, gray = color8), the theme list in `use_my_zsh.sh`, and the README.
- The raw GitHub URL in `use_my_zsh.sh` (`ZSHRC_URL`) assumes the default branch is `main`.

## 5. Updating

1. Make the change on a branch.
2. Repeat steps 1 through 3 above.
3. Bump the version where a script has one (`VERSION` in `media_transcode.sh`, `SCRIPT_REVISION` in `ripcd.sh`).
4. Add an entry at the top of `changes.md` in the usual format.
5. Push, then `sudo funcupdate` on the machines that use Option B.

Now the scripts are linted, tested, and current with upstream, and everything is working as it should be.
