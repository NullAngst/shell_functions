# ~/.bashrc
#
# Amber-Hued Bash Configuration

# ------------------------------------------------------------------------------
# --- Color Palette
# ------------------------------------------------------------------------------

# Define color variables using 24-bit ANSI escape codes (R;G;B)
# \[\e[...\] is required in Bash so readline correctly calculates prompt width.
PROMPT_FG_AMBER='\[\e[38;2;255;167;26m\]'
PROMPT_FG_RED='\[\e[38;2;215;95;95m\]'
PROMPT_FG_GREEN='\[\e[38;2;175;177;106m\]'
PROMPT_FG_BLUE='\[\e[38;2;125;163;204m\]'
PROMPT_FG_WHITE='\[\e[38;2;232;212;169m\]'
PROMPT_FG_GRAY='\[\e[38;2;122;112;95m\]'
PROMPT_FG_BLACK='\[\e[38;2;12;7;2m\]'
PROMPT_FG_NONE='\[\e[0m\]' # Resets to default foreground color

# ------------------------------------------------------------------------------
# --- Aliases
# ------------------------------------------------------------------------------

alias ls='ls --color=auto -Flartchs'
alias cp='rsync -vpartlXEHhP --ignore-existing'
alias grep='grep --color=auto -i -n -I'

# ------------------------------------------------------------------------------
# --- Custom Functions (vmv vcp unpack scrmgr moveav ffile cleandir
#     shredfile shredfolder funchelp)
# ------------------------------------------------------------------------------

export PATH="$HOME/.local/bin:$PATH"

# ------------------------------------------------------------------------------
# --- Bash Configuration
# ------------------------------------------------------------------------------

# Set the default editor for command-line editing
export EDITOR='nano'

# --- History
HISTFILE=~/.bash_history
HISTSIZE=10000
HISTFILESIZE=10000
shopt -s histappend          
HISTCONTROL=ignoreboth:erasedups

# --- Completion
# Initialize the Bash completion system
if [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
elif [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
fi

# Case-insensitive completion
bind 'set completion-ignore-case on'

# --- Keybindings
set -o emacs # Use Emacs keybindings

# ------------------------------------------------------------------------------
# --- FANCY PROMPT & Version Control System (Git) Integration
# ------------------------------------------------------------------------------

# This function runs just before the prompt is drawn.
build_prompt() {
  # --- History Sharing ---
  # Write unwritten history and read new history to share across sessions
  history -a
  history -n

  # --- Git Integration ---
  local git_branch=""
  local branch
  # Suppress stderr to avoid errors when not in a git repository
  if branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); then
    git_branch=" on ${PROMPT_FG_WHITE}${branch}${PROMPT_FG_NONE}"
  fi

  # --- Detect Context and Set Color ---
  if [[ $EUID -eq 0 ]]; then
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_RED
  elif [[ -n "$git_branch" ]]; then
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_BLUE
  elif [[ -f "setup.py" || -f "requirements.txt" || -d ".venv" || -f "pyproject.toml" ]]; then
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_GREEN
  else
    PROMPT_CONTEXT_COLOR=$PROMPT_FG_AMBER
  fi

  # --- Prompt Structure ---
  # \u -> username
  # \h -> hostname
  # \w -> current directory, with '~' for home
  # \[\e[1m\] -> bold text
  # \[\e[22m\] -> normal intensity (removes bold)
  
  PS1="\n${PROMPT_FG_WHITE}\u${PROMPT_FG_GRAY}@\h ${PROMPT_FG_NONE}in ${PROMPT_CONTEXT_COLOR}\[\e[1m\]\w\[\e[22m\]${git_branch}\n${PROMPT_CONTEXT_COLOR}❯ ${PROMPT_FG_NONE}"
}

# Assign the function to PROMPT_COMMAND so it executes before every prompt
PROMPT_COMMAND="build_prompt"
