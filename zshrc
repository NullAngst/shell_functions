# ~/.zshrc
#
# Amber-Hued Zsh Configuration

# ------------------------------------------------------------------------------
# --- Color Palette
# ------------------------------------------------------------------------------

# Define color variables using hex codes
# %F{...} sets the foreground color.
# We wrap it in a variable for easier use.
PROMPT_FG_AMBER='%F{#ffa71a}'
PROMPT_FG_RED='%F{#D75F5F}'
PROMPT_FG_GREEN='%F{#AFB16A}'
PROMPT_FG_BLUE='%F{#7DA3CC}'
PROMPT_FG_WHITE='%F{#E8D4A9}'
PROMPT_FG_GRAY='%F{#7A705F}'
PROMPT_FG_BLACK='%F{#0c0702}'
PROMPT_FG_NONE='%f' # Resets to default foreground color

# ------------------------------------------------------------------------------
# --- Aliases
# ------------------------------------------------------------------------------

alias ls='ls --color=auto -Flartchs'
alias cp='rsync -vpartlXEHhP --ignore-existing'
alias grep='grep --color=auto -i -n -I'

# ------------------------------------------------------------------------------
# --- Custom Functions (vmv vcp unpack scrmgr moveav ffile cleandir
#     shredfile shredfolder funchelp)
#
# Each function now lives in its own file under $ZSH_FUNCTIONS_DIR. See
# README.md alongside those files for install instructions (single-user vs
# system-wide) and what each function does.
# ------------------------------------------------------------------------------

export PATH="$HOME/.local/bin:$PATH"

# ------------------------------------------------------------------------------
# --- Zsh Configuration
# ------------------------------------------------------------------------------

# Set the default editor for command-line editing
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
# Initialize the Zsh completion system
autoload -U compinit && compinit
# Case-insensitive completion
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
# Group completions by type
zstyle ':completion:*:descriptions' group-name ''

# --- Keybindings
bindkey -e # Use Emacs keybindings

# ------------------------------------------------------------------------------
# --- Version Control System (Git) Integration
# ------------------------------------------------------------------------------
# This enables Zsh to get information from Git repositories.

autoload -Uz vcs_info
# Format for the git info (branch name)
# %b = branch, %r = repository root, %s = vcs name (git)
zstyle ':vcs_info:git:*' formats " on ${PROMPT_FG_WHITE}%b${PROMPT_FG_NONE}"
zstyle ':vcs_info:*' enable git # Enable for git

# ------------------------------------------------------------------------------
# --- FANCY PROMPT
# ------------------------------------------------------------------------------
# This section defines the appearance of your command prompt.

# precmd() is a special function that runs just before the prompt is drawn.
# We use it to check the context (user, git, python) and set the color.
precmd() {
  # Run vcs_info to get git info. It populates the scalar $vcs_info_msg_0_
  # (not an array - zsh's vcs_info exports plain underscore-suffixed scalars
  # so the values can be exported as environment variables).
  vcs_info

  # --- Detect Context and Set Color ---
  # Check if the user is root.
  if [[ $EUID -eq 0 ]]; then
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_RED
  # Check if vcs_info found a git repo here (reuses its detection instead of
  # spawning a second git process every time the prompt redraws).
  elif [[ -n "$vcs_info_msg_0_" ]]; then
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_BLUE
  # Check for common Python project files.
  elif [[ -f "setup.py" || -f "requirements.txt" || -d ".venv" || -f "pyproject.toml" ]]; then
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_GREEN
  # If none of the above, use the default amber color.
  else
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_AMBER
  fi
}

# --- Prompt Structure ---
# This sets the main prompt (PS1). It's a two-line prompt for clarity.
#
# Line 1: [user]@[hostname] in [current_directory] [git_branch]
# Line 2: ❯
#
# Breakdown:
# %n -> username
# %m -> hostname
# %~ -> current directory, with '~' for home
# ${vcs_info_msg_0_} -> The formatted git info from our zstyle above
# %(?.<ok_char>.<err_char>) -> Shows a different character if the last command failed.

setopt PROMPT_SUBST

PROMPT='
${PROMPT_FG_WHITE}%n${PROMPT_FG_GRAY}@%m ${PROMPT_FG_NONE}in ${PROMPT_CONTEXT_COLOR}%B%~%b${vcs_info_msg_0_}
${PROMPT_CONTEXT_COLOR}❯ ${PROMPT_FG_NONE}'
