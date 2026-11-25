# Maintenance

What to check every couple of months to keep these scripts working, and how to update them. Plan on 20 to 30 minutes.

## Prerequisites

- A clone of the repo: `git clone https://github.com/NullAngst/shell_functions.git`
- `shellcheck`. I use apt, so in my case `sudo apt install shellcheck`. It depends on your system.
- `zsh`, for checking the zshrc.
- `ffmpeg`, `gpg` and `zstd` or `7z` for the smoke tests in step 3. Skip the tests for whatever you don't have.

## 1. Lint everything

1. Step into the clone and pull: `cd shell_functions && git pull`
2. Run shellcheck on every script: `shellcheck *.sh`, since every one of them has to pass with no output at all, notes included
3. Run it on the bash config too: `shellcheck -s bash bashrc`
4. Syntax-check the zsh config: `zsh -n zshrc`

A new shellcheck release sometimes adds checks. Fix what it finds rather than adding a disable comment, unless the code is right and shellcheck can't tell (trap handlers, jq filters in single quotes). Every existing disable has a comment saying why. Trap handlers carry both `SC2317` and `SC2329`, since shellcheck 0.9 and 0.10+ report the same thing under different codes.

## 2. Check the house rules still hold

These greps should print nothing. Anything they find is a regression.

1. No echo: `grep -nE '(^|[^a-z_-])echo( |$)' *.sh`
2. No GNU-only flags: `grep -nE 'sed -i|grep -[a-zA-Z]*P|readlink -f|date -d|-printf|stat -c|xargs -r|grep -m|sort -z|mktemp -[pt]|df -B|realpath -m' *.sh | grep -v '^[^:]*:[0-9]*: *#'`
3. No GNU `\|` alternation in sed or grep patterns: `grep -n '\\|' *.sh | grep -v '^[^:]*:[0-9]*: *#'`
4. No bash-only root check: `grep -n 'EUID' *.sh`
5. No variables in printf format strings: `grep -nE 'printf "[^"]*\$' *.sh`
6. No eval or getopt: `grep -nwE 'eval|getopt' *.sh | grep -v '^[^:]*:[0-9]*: *#'`
7. Every script in strict mode: `grep -L 'set -euo pipefail' *.sh`
8. No hyphens in script names: `find . -maxdepth 1 -name '*-*.sh'`

Two rules don't grep well, so read new code for them: `[[ ]]` only where it does pattern matching (`==` with a glob, or `=~`), plain tests use `[ ]`; and `(( ))` only for `for` loops, with `$(( ))` inside `[ ]` for everything else.

## 3. Smoke test the cheap ones

None of these change anything outside a temp directory. Run them with `bash`, since files uploaded through the GitHub web UI lose their executable bit.

1. `bash decode.sh 'SGVsbG8='` should print `Hello` on the first line
2. `bash ffile.sh /bin/sh | head -20` should show the IDENTITY and STAT sections
3. `bash funchelp.sh` should list every `.sh` file in the repo. If you added or renamed a script, update it there and in the README too.
4. `bash media_transcode.sh --help` should print usage, and `bash media_transcode.sh --bogus` should fail with "Unknown option"
5. `for f in *.sh; do bash "$f" -h >/dev/null 2>&1 || printf '%s\n' "$f"; done` should only list scripts whose required tool you don't have installed (screen, ufw, rsync), plus `audio_convert_functions.sh`, which only answers to 2mp3, 2flac or 2ogg
6. Make a temp dir with a zip inside a folder inside a tar.gz and run `bash unpack.sh -n` on it, then without `-n`. The zip should come out too.
7. Make a short clip with `ffmpeg -f lavfi -i testsrc -f lavfi -i sine -t 3 -c:v libx264 -c:a flac clip.mkv`, then run `bash media_transcode.sh -d . -m 0 -H 0 --keep --max-ratio 0 -y` on its folder
8. `sudo bash system_update.sh` on one machine, since package manager flags drift (see below)

For `pw_manager`, make a throwaway vault in a temp directory, add an entry, save, reopen it, export to CSV and import that CSV into a second vault. That covers every gpg and tar path in it.

## 4. Things that change upstream

Check these against current docs when something breaks, or once or twice a year anyway.

- Package managers (`system_update`, `use_my_zsh`): dnf5 replacing dnf on Fedora, zypper on Leap vs Tumbleweed, `transactional-update` on MicroOS/Aeon/Kalpa, `pacman -Sc` prompts, yay/paru flags, `xbps-remove -Oo`, `apk cache clean`, `eopkg` subcommand names, `emerge --ask=n`. A new distro family means a new branch in both scripts.
- MusicBrainz and the Cover Art Archive (`ripcd`): the `discid` lookup URL, the `inc=` list (composers need `work-rels`, `recording-level-rels`, `work-level-rels` and `artist-rels`), the JSON field names (`artist-credit`, `media`, `track-count`, `cover-art-archive`, `relations`, `target-type`), and the thumbnail keys (`1200`, `large`). MusicBrainz also wants a real User-Agent with a contact URL; that's `USER_AGENT` at the top of `ripcd.sh`.
- ffmpeg (`media_transcode`, `2mp3`/`2flac`/`2ogg`): NVENC preset names (`p1` to `p7`), `-rc vbr -cq`, VAAPI filter names (`scale_vaapi`, `hwupload`), and x265 parameter names in `X265_PARAMS`. `media_transcode` reads `ffmpeg -encoders` and `-filters` at start, so a missing encoder shows up as a validation error rather than a crash.
- GnuPG (`pw_manager`, `file_encrypt`, `folder_encrypt`): the `--s2k-*` options and `--pinentry-mode loopback`. If gpg ever changes its defaults, existing vaults still open, since gpg reads the parameters from the file itself.
- kitty themes: the prompt palettes in `zshrc` and `bashrc` are copied from [NullAngst/kitty-themes](https://github.com/NullAngst/kitty-themes). If a theme there changes color or a new one shows up, update the `_prompt_palette` lines in both files (accent = cursor, white = foreground, black = background, red/green/blue = color1/color2/color4, gray = color8), the theme list in `use_my_zsh.sh`, and the README.
- The raw GitHub URL in `use_my_zsh.sh` (`ZSHRC_URL`) and the clone URL in `funcupdate.sh` (`REPO_URL`) assume the repo stays at NullAngst/shell_functions with `main` as the default branch.

## 5. Old-name migrations

`pw_manager`, `media_transcode`, `ripcd` and `funcupdate` each move files from their old hyphenated names on first run. Once you're sure every machine has run the new versions (give it a few months), the `OLD_*` variables and the `migrate_dir` / `init_config_dir` / old-lib-dir cleanup code can go. Leave them in until then, since removing them strands anyone who updates late.

## 6. Updating

1. Make the change on a branch.
2. Repeat steps 1 through 3 above.
3. Bump the version where a script has one (`VERSION` in `media_transcode.sh`, `SCRIPT_REVISION` in `ripcd.sh`). A release bumps the minor number, no patch numbers.
4. Add an entry at the top of `changes.md` in the usual format.
5. Push, then `sudo funcupdate` (or `funcupdate -u`) on the machines that use it.

Now the scripts are linted, tested, and current with upstream, and everything is working as it should be.
