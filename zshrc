# ~/.zshrc
#
# Kawaii Dark Zsh Configuration, from NullAngst/shell_functions.
# The prompt colors follow the themes in NullAngst/kitty-themes, so the
# prompt matches whatever kitty theme you run. Kawaii Dark by default.

# ------------------------------------------------------------------------------
# --- Prompt theme
# ------------------------------------------------------------------------------
# Pick a theme by setting ZSH_PROMPT_THEME before this file runs (in
# ~/.zshenv, say), or change the default on the line below. use_my_zsh -t
# rewrites this line for you.
#   kawaii-dark  kawaii-light  amber  blurple  modern-dark  modern-light  verdigris-copper

: ${ZSH_PROMPT_THEME:=kawaii-dark}

# Args: accent red green blue white gray black. Taken from each kitty theme:
# accent = cursor, white = foreground, black = background, the rest are the
# matching ANSI colors (gray is bright black).
_prompt_palette() {
  PROMPT_FG_ACCENT="%F{$1}"
  PROMPT_FG_RED="%F{$2}"
  PROMPT_FG_GREEN="%F{$3}"
  PROMPT_FG_BLUE="%F{$4}"
  PROMPT_FG_WHITE="%F{$5}"
  PROMPT_FG_GRAY="%F{$6}"
  PROMPT_FG_BLACK="%F{$7}"
  PROMPT_FG_NONE='%f'
}

case ${(L)ZSH_PROMPT_THEME} in
  kawaii-dark)      _prompt_palette '#FF8FC8' '#FF7A9A' '#7FE0B4' '#8F9CFF' '#F5D7E8' '#6C5A7A' '#221A2B' ;;
  kawaii-light)     _prompt_palette '#E0569A' '#D8456A' '#2E9A72' '#5A62D0' '#5A3B5C' '#8A6A8C' '#FFF2F7' ;;
  amber)            _prompt_palette '#FFC233' '#E0461F' '#B5A31F' '#C27C1C' '#FFB000' '#8A6520' '#140D00' ;;
  blurple)          _prompt_palette '#7983F5' '#ED4245' '#57D18A' '#6B77F5' '#DCDDF5' '#5A5D8A' '#1A1B2E' ;;
  modern-dark)      _prompt_palette '#CCCCCC' '#F25E5A' '#4CC261' '#3D93E0' '#DCDFE4' '#5C636A' '#1E2124' ;;
  modern-light)     _prompt_palette '#24292F' '#C9302C' '#1A7F37' '#0960C8' '#24292F' '#57606A' '#FAFAF8' ;;
  verdigris-copper) _prompt_palette '#E0915A' '#D6634A' '#5FB89A' '#4A9AA8' '#B8DCCB' '#4E6E66' '#13201D' ;;
  *)
    print -u2 "zshrc: unknown ZSH_PROMPT_THEME '$ZSH_PROMPT_THEME', using kawaii-dark"
    _prompt_palette '#FF8FC8' '#FF7A9A' '#7FE0B4' '#8F9CFF' '#F5D7E8' '#6C5A7A' '#221A2B'
    ;;
esac
unfunction _prompt_palette

# ------------------------------------------------------------------------------
# --- Aliases
# ------------------------------------------------------------------------------
# Each one is only set if the tool underneath supports it, so a box without
# rsync or with a BusyBox ls still has working ls/cp/grep.

if ls --color=auto -d . >/dev/null 2>&1; then
  alias ls='ls --color=auto -Flartchs'
fi
if (( $+commands[rsync] )); then
  alias cp='rsync -vpartlXEHhP --ignore-existing'
fi
if print x | grep --color=auto -q x 2>/dev/null; then
  alias grep='grep --color=auto -i -n -I'
fi

# ------------------------------------------------------------------------------
# --- Commands from NullAngst/shell_functions
#
# vmv, vcp, unpack, 2mp3 and the rest (run funchelp for the full list) are
# separate scripts symlinked onto PATH, not defined here. A single-user install
# puts those symlinks in ~/.local/bin, which the line below adds to PATH. A
# system-wide install uses /usr/local/bin, which is already on PATH.
# ------------------------------------------------------------------------------

typeset -U path
path=("$HOME/.local/bin" $path)

# ------------------------------------------------------------------------------
# --- Zsh Configuration
# ------------------------------------------------------------------------------

# Default editor for command-line editing
export EDITOR='nano'

# --- History
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt APPEND_HISTORY        # Append history to the history file
setopt SHARE_HISTORY         # Share history between all sessions
setopt HIST_IGNORE_DUPS      # Don't record duplicate commands
setopt HIST_IGNORE_ALL_DUPS  # Delete old duplicate entries from history
setopt HIST_FIND_NO_DUPS     # Don't show duplicates when searching
setopt HIST_REDUCE_BLANKS    # Remove superfluous blanks

# --- Completion
autoload -Uz compinit && compinit
# Case-insensitive completion
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
# Group completions by type
zstyle ':completion:*:descriptions' group-name ''

# --- Keybindings
bindkey -e # Emacs keybindings

# ------------------------------------------------------------------------------
# --- Git branch in the prompt
# ------------------------------------------------------------------------------

autoload -Uz vcs_info
# %b = branch
zstyle ':vcs_info:git:*' formats " on ${PROMPT_FG_WHITE}%b${PROMPT_FG_NONE}"
zstyle ':vcs_info:*' enable git

# ------------------------------------------------------------------------------
# --- Prompt
# ------------------------------------------------------------------------------
# Runs before every prompt draw and picks the color for the context:
# root, inside a git repo, inside a Python project, or none of those.
# add-zsh-hook adds to precmd instead of replacing it, so plugins that hook
# precmd keep working.

autoload -Uz add-zsh-hook

_prompt_precmd() {
  # vcs_info fills the scalar $vcs_info_msg_0_ (not an array: vcs_info uses
  # underscore-suffixed scalars so the values can be exported)
  vcs_info

  if [[ $EUID -eq 0 ]]; then
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_RED
  # Reuse vcs_info's repo detection instead of running git a second time
  elif [[ -n "$vcs_info_msg_0_" ]]; then
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_BLUE
  elif [[ -f setup.py || -f requirements.txt || -d .venv || -f pyproject.toml ]]; then
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_GREEN
  else
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_ACCENT
  fi
}
add-zsh-hook precmd _prompt_precmd

# Two lines:
#   user@host in ~/current/dir on branch
#   ❯
#
# %n user, %m host, %~ directory with ~ for home, %B/%b bold on/off.
# %(?.A.B) shows A when the last command succeeded and B when it failed,
# so the arrow turns red after an error.

setopt PROMPT_SUBST

PROMPT='
${PROMPT_FG_WHITE}%n${PROMPT_FG_GRAY}@%m ${PROMPT_FG_NONE}in ${PROMPT_CONTEXT_COLOR}%B%~%b${vcs_info_msg_0_}
%(?.${PROMPT_CONTEXT_COLOR}.${PROMPT_FG_RED})❯ ${PROMPT_FG_NONE}'
