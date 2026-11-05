# ~/.bashrc
#
# Kawaii Dark Bash Configuration, from NullAngst/shell_functions.
# The bash twin of the bundled zshrc: same themes, same prompt layout.

# Everything below is for interactive shells only. scp, rsync and the like
# start non-interactive shells that read this file too.
case $- in
    *i*) ;;
    *) return ;;
esac

# ------------------------------------------------------------------------------
# --- Prompt theme
# ------------------------------------------------------------------------------
# Pick a theme by setting BASH_PROMPT_THEME before this file runs, or change
# the default on the line below. Same names as the kitty themes:
#   kawaii-dark  kawaii-light  amber  blurple  modern-dark  modern-light  verdigris-copper

: "${BASH_PROMPT_THEME:=kawaii-dark}"

# 24-bit color escape for a #RRGGBB value. \[ \] tell readline the escape
# takes no space, so line wrapping stays right.
_prompt_rgb() {
    local h="${1#\#}"
    printf '\\[\\e[38;2;%d;%d;%dm\\]' "$((16#${h:0:2}))" "$((16#${h:2:2}))" "$((16#${h:4:2}))"
}

# Args: accent red green blue white gray black, taken from each kitty theme
_prompt_palette() {
    PROMPT_FG_ACCENT="$(_prompt_rgb "$1")"
    PROMPT_FG_RED="$(_prompt_rgb "$2")"
    PROMPT_FG_GREEN="$(_prompt_rgb "$3")"
    PROMPT_FG_BLUE="$(_prompt_rgb "$4")"
    PROMPT_FG_WHITE="$(_prompt_rgb "$5")"
    PROMPT_FG_GRAY="$(_prompt_rgb "$6")"
    # shellcheck disable=SC2034  # not used by the prompt, kept for your own use
    PROMPT_FG_BLACK="$(_prompt_rgb "$7")"
    PROMPT_FG_NONE='\[\e[0m\]'
}

case "${BASH_PROMPT_THEME,,}" in
    kawaii-dark)      _prompt_palette '#FF8FC8' '#FF7A9A' '#7FE0B4' '#8F9CFF' '#F5D7E8' '#6C5A7A' '#221A2B' ;;
    kawaii-light)     _prompt_palette '#E0569A' '#D8456A' '#2E9A72' '#5A62D0' '#5A3B5C' '#8A6A8C' '#FFF2F7' ;;
    amber)            _prompt_palette '#FFC233' '#E0461F' '#B5A31F' '#C27C1C' '#FFB000' '#8A6520' '#140D00' ;;
    blurple)          _prompt_palette '#7983F5' '#ED4245' '#57D18A' '#6B77F5' '#DCDDF5' '#5A5D8A' '#1A1B2E' ;;
    modern-dark)      _prompt_palette '#CCCCCC' '#F25E5A' '#4CC261' '#3D93E0' '#DCDFE4' '#5C636A' '#1E2124' ;;
    modern-light)     _prompt_palette '#24292F' '#C9302C' '#1A7F37' '#0960C8' '#24292F' '#57606A' '#FAFAF8' ;;
    verdigris-copper) _prompt_palette '#E0915A' '#D6634A' '#5FB89A' '#4A9AA8' '#B8DCCB' '#4E6E66' '#13201D' ;;
    *)
        printf "bashrc: unknown BASH_PROMPT_THEME '%s', using kawaii-dark\n" "$BASH_PROMPT_THEME" >&2
        _prompt_palette '#FF8FC8' '#FF7A9A' '#7FE0B4' '#8F9CFF' '#F5D7E8' '#6C5A7A' '#221A2B'
        ;;
esac
unset -f _prompt_rgb _prompt_palette

# ------------------------------------------------------------------------------
# --- Aliases
# ------------------------------------------------------------------------------
# Each one is only set if the tool underneath supports it, so a box without
# rsync or with a BusyBox ls still has working ls/cp/grep.

if ls --color=auto -d . >/dev/null 2>&1; then
    alias ls='ls --color=auto -Flartchs'
fi
if command -v rsync >/dev/null 2>&1; then
    alias cp='rsync -vpartlXEHhP --ignore-existing'
fi
if printf 'x\n' | grep --color=auto -q x 2>/dev/null; then
    alias grep='grep --color=auto -i -n -I'
fi

# ------------------------------------------------------------------------------
# --- Commands from NullAngst/shell_functions
#
# vmv, vcp, unpack, 2mp3 and the rest (run funchelp for the full list) are
# separate scripts symlinked onto PATH, not defined here. A single-user install
# puts those symlinks in ~/.local/bin, which the lines below add to PATH once.
# A system-wide install uses /usr/local/bin, which is already on PATH.
# ------------------------------------------------------------------------------

case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# ------------------------------------------------------------------------------
# --- Bash Configuration
# ------------------------------------------------------------------------------

# Default editor for command-line editing
export EDITOR='nano'

# --- History
HISTFILE=~/.bash_history
HISTSIZE=10000
HISTFILESIZE=10000
shopt -s histappend
HISTCONTROL=ignoreboth:erasedups

# --- Completion
# shellcheck disable=SC1091  # distro file, not part of this repo
if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
fi

# Case-insensitive completion
bind 'set completion-ignore-case on'

# --- Keybindings
set -o emacs

# ------------------------------------------------------------------------------
# --- Prompt with git branch
# ------------------------------------------------------------------------------
# Runs before every prompt draw: shares history between sessions, then picks
# the color for the context (root, git repo, Python project, or none).

_prompt_build() {
    # Grab the exit status before anything else overwrites it
    local last_rc=$?

    history -a
    history -n

    local git_branch="" branch arrow_color
    PROMPT_GIT_BRANCH=""
    if branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); then
        # The branch name goes in by reference, not pasted into PS1. Git
        # allows $( in branch names, and PS1 text gets expanded, so a pasted
        # name would run as a command the moment you cd into that repo.
        # shellcheck disable=SC2034  # read when PS1 is expanded
        PROMPT_GIT_BRANCH=$branch
        # shellcheck disable=SC2016  # the literal ${PROMPT_GIT_BRANCH} is the point
        git_branch=" on ${PROMPT_FG_WHITE}"'${PROMPT_GIT_BRANCH}'"${PROMPT_FG_NONE}"
    fi

    if [ "$EUID" -eq 0 ]; then
        PROMPT_CONTEXT_COLOR=$PROMPT_FG_RED
    elif [ -n "$git_branch" ]; then
        PROMPT_CONTEXT_COLOR=$PROMPT_FG_BLUE
    elif [ -f setup.py ] || [ -f requirements.txt ] || [ -d .venv ] || [ -f pyproject.toml ]; then
        PROMPT_CONTEXT_COLOR=$PROMPT_FG_GREEN
    else
        PROMPT_CONTEXT_COLOR=$PROMPT_FG_ACCENT
    fi

    # The arrow turns red after a failed command
    arrow_color=$PROMPT_CONTEXT_COLOR
    if [ "$last_rc" -ne 0 ]; then
        arrow_color=$PROMPT_FG_RED
    fi

    # \u user, \h host, \w directory with ~ for home, \e[1m / \e[22m bold on/off
    PS1="\n${PROMPT_FG_WHITE}\u${PROMPT_FG_GRAY}@\h ${PROMPT_FG_NONE}in ${PROMPT_CONTEXT_COLOR}\[\e[1m\]\w\[\e[22m\]${git_branch}\n${arrow_color}❯ ${PROMPT_FG_NONE}"
}

PROMPT_COMMAND="_prompt_build"
