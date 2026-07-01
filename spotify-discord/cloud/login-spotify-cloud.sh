#!/bin/bash
# One-time Spotify OAuth login for the cloud VPS.
#
# The go-librespot login callback listens on 127.0.0.1:8898 ON THE VPS, but your
# browser is on your own computer. So SSH in with a tunnel FIRST:
#
#   ssh -L 8898:localhost:8898 root@<vps-ip>
#
# ...then run this script on the VPS. Open the printed URL in your LOCAL browser;
# the tunnel carries the 127.0.0.1:8898 callback back to the VPS. A "connection
# reset" page after Agree is fine — the login still completes.
set -u

CONFIG_DIR="/root/.config/go-librespot"
DROPIN=/etc/systemd/system/go-librespot.service.d/nologin-restart.conf

if grep -q '"data":"' "$CONFIG_DIR/state.json" 2>/dev/null; then
    echo "[login] Already logged in (credentials present). Nothing to do."
    exit 0
fi

echo "[login] Pinning a stable go-librespot process (auto-restart off)..."
mkdir -p "$(dirname "$DROPIN")"
printf '[Service]\nRestart=no\n' > "$DROPIN"
systemctl daemon-reload
systemctl reset-failed go-librespot 2>/dev/null || true
systemctl restart go-librespot
sleep 4

URL=$(journalctl -u go-librespot -n 15 --no-pager | sed -E 's/\x1b\[[0-9;]*m//g' | grep -oE 'https://accounts\.spotify\.com/authorize\S+' | tail -1)
echo ""
echo "==================================================================="
echo " Make sure you SSH'd in with:  ssh -L 8898:localhost:8898 root@<vps-ip>"
echo " Open this URL in your LOCAL browser, log in (Premium), click Agree:"
echo ""
echo "$URL"
echo ""
echo " Waiting for credentials to save (Ctrl+C to abort)..."
echo "==================================================================="

for i in $(seq 1 150); do
    if grep -q '"data":"' "$CONFIG_DIR/state.json" 2>/dev/null; then
        echo "[login] SUCCESS — credentials saved."
        break
    fi
    sleep 2
done

echo "[login] Restoring normal service (auto-restart on)..."
rm -f "$DROPIN"
systemctl daemon-reload
systemctl enable go-librespot >/dev/null 2>&1 || true
systemctl restart go-librespot spotify-discord-bot 2>/dev/null || true

if grep -q '"data":"' "$CONFIG_DIR/state.json" 2>/dev/null; then
    echo "[login] Done. The 'Discord' device is now live in Spotify Connect."
else
    echo "[login] Timed out — re-run after confirming the SSH -L 8898 tunnel is up."
    exit 1
fi
