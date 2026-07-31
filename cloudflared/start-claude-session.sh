#!/bin/bash
# MSYS2 script to start/attach to a persistent Claude Code tmux session
# Usage: start-claude-session.sh <session-name> <working-dir> [--no-claude]
#
# Examples:
#   start-claude-session.sh claude /z/Users/Heiner/Documents/Cloudflare
#   start-claude-session.sh snd /z/Users/Heiner/Documents/Luas/SND --no-claude

SESSION_NAME="${1:-claude}"
WORKING_DIR="${2:-/z/Users/Heiner/Documents/Cloudflare}"
NO_CLAUDE="${3:-}"

# Use full paths for MSYS2 tools
TMUX="/usr/bin/tmux"

# Add Windows npm/node and MSYS2 to PATH for Claude Code
export PATH="/c/nvm4w/nodejs:/c/ProgramData/nvm/v22.19.0:/usr/bin:$PATH"

# Check if tmux session already exists
if $TMUX has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Session '$SESSION_NAME' already exists"
    # If running interactively, attach to it
    if [ -t 0 ]; then
        $TMUX attach-session -t "$SESSION_NAME"
    fi
else
    echo "Creating new tmux session '$SESSION_NAME'"
    # Create new detached session
    $TMUX new-session -d -s "$SESSION_NAME" -c "$WORKING_DIR"

    if [ "$NO_CLAUDE" != "--no-claude" ]; then
        # Start Claude Code with --dangerously-skip-permissions in the session
        # Use env -u to unset TMUX so Claude doesn't detect nested tmux
        $TMUX send-keys -t "$SESSION_NAME" "cd $WORKING_DIR; env -u TMUX claude --dangerously-skip-permissions" Enter
        echo "Session created. Claude Code starting with --dangerously-skip-permissions..."
    else
        $TMUX send-keys -t "$SESSION_NAME" "cd $WORKING_DIR" Enter
        echo "Session created. Bash shell ready."
    fi

    # If running interactively, attach to it
    if [ -t 0 ]; then
        $TMUX attach-session -t "$SESSION_NAME"
    fi
fi
