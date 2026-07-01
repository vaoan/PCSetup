#!/bin/bash
# One-time Spotify OAuth login for go-librespot.
# Run as root in WSL:
#   wsl -d Ubuntu-24.04 --user root bash /mnt/z/Users/Heiner/Documents/PCSetup/spotify-discord/login-spotify.sh
#
# go-librespot will print a URL. Open it in your Windows browser, log in with
# your Premium account, and authorize. Once you see it connect successfully,
# press Ctrl+C — the credentials are saved and the systemd service takes over.
set -e

CONFIG_DIR="/root/.config/go-librespot"
BIN="/usr/local/bin/go-librespot"

echo "[login-spotify] Stopping background service so it doesn't grab the OAuth port..."
systemctl stop go-librespot 2>/dev/null || true

echo "[login-spotify] Launching go-librespot interactively."
echo "[login-spotify] Open the URL it prints below in your Windows browser, then authorize."
echo "[login-spotify] After it connects, press Ctrl+C to finish."
echo ""

# Run in foreground so the OAuth URL is visible. The trap restarts the service.
trap 'echo; echo "[login-spotify] Restarting service..."; systemctl restart go-librespot spotify-discord-bot 2>/dev/null || true; echo "[login-spotify] Done. Check: journalctl -u go-librespot -f"; exit 0' INT TERM

"$BIN" --config_dir "$CONFIG_DIR"
