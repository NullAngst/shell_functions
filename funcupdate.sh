#!/usr/bin/env bash

# Check for the logging flag
if [[ "$1" == "-l" || "$1" == "--log" ]]; then
    # Ensure we have permissions to write to the log before redirecting
    touch /var/log/system-update.log 2>/dev/null || { echo "Cannot write to /var/log/system-update.log. Run with sudo."; exit 1; }
    
    # Redirect all stdout and stderr to tee, appending to the log
    exec > >(tee -a /var/log/system-update.log) 2>&1
    echo "==== Update started at $(date) ===="
fi

# System-wide installation requires root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script modifies /usr/local/ directories. Run it with sudo."
   exit 1
fi

# Detect the actual user's shell, bypassing the root shell invoked by sudo
if [ -n "$SUDO_USER" ]; then
    USER_SHELL=$(getent passwd "$SUDO_USER" | cut -d: -f7)
else
    USER_SHELL=$SHELL
fi
DETECTED_SHELL=$(basename "$USER_SHELL")

echo "Detected primary shell: $DETECTED_SHELL"

# Create a temporary directory for pulling the repo and ensure it gets deleted on exit
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "Pulling latest scripts from GitHub..."
if ! git clone -q https://github.com/NullAngst/shell_functions.git "$TEMP_DIR"; then
    echo "Error: Failed to clone repository."
    exit 1
fi

echo "Deploying files for all users..."

# Create target directory
mkdir -p /usr/local/lib/shell-functions

# Copy all .sh files to the shared library directory
cp "$TEMP_DIR"/*.sh /usr/local/lib/shell-functions/

# Make the copied scripts executable
chmod +x /usr/local/lib/shell-functions/*.sh

# Symlink each script into /usr/local/bin so they are on everyone's PATH
for f in /usr/local/lib/shell-functions/*.sh; do
    name=$(basename "$f" .sh)
    ln -sf "$f" "/usr/local/bin/$name"
    echo "Symlinked: $name -> $f"
done

echo "Update complete. The latest functions are available system-wide."