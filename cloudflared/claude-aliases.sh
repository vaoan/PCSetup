#!/bin/bash
# Claude Code tmux session aliases
# Source this file in your .bashrc: source /z/Users/Heiner/Documents/Cloudflare/claude-aliases.sh

CLOUDFLARE_DIR="/z/Users/Heiner/Documents/Cloudflare"

# Attach to Claude session (or start if not running)
claude() {
    if tmux has-session -t claude 2>/dev/null; then
        tmux attach -t claude
    else
        echo "Starting claude session..."
        "$CLOUDFLARE_DIR/start-claude-session.sh" claude "/z/Users/Heiner/Documents/Cloudflare"
    fi
}

# Attach to ClaimAngel session (or start if not running)
claimangel() {
    if tmux has-session -t claimangel 2>/dev/null; then
        tmux attach -t claimangel
    else
        echo "Starting claimangel session..."
        "$CLOUDFLARE_DIR/start-claude-session.sh" claimangel "/z/Github/ClaimAngel/frontend"
    fi
}

# Attach to SND session (or start if not running)
snd() {
    if tmux has-session -t snd 2>/dev/null; then
        tmux attach -t snd
    else
        echo "Starting snd session..."
        "$CLOUDFLARE_DIR/start-claude-session.sh" snd "/z/Users/Heiner/Documents/Luas/SND" --no-claude
    fi
}

# List all tmux sessions
sessions() {
    echo "Available tmux sessions:"
    tmux list-sessions 2>/dev/null || echo "  No sessions running"
}

# Kill a session
killsession() {
    local session="${1:-}"
    if [ -z "$session" ]; then
        echo "Usage: killsession <session-name>"
        echo "Available sessions:"
        tmux list-sessions 2>/dev/null || echo "  No sessions running"
        return 1
    fi
    tmux kill-session -t "$session" 2>/dev/null && echo "Session '$session' killed" || echo "Session '$session' not found"
}

echo "Claude session aliases loaded: claude, claimangel, snd, sessions, killsession"
