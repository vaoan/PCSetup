#!/bin/bash
# =============================================================================
# Spotify -> Discord bridge: cloud VPS installer (Debian/Ubuntu, x86_64 or ARM).
# =============================================================================
# Run as root on a fresh VPS (RackNerd / Hetzner / any KVM Linux box):
#
#   curl -fsSL https://raw.githubusercontent.com/vaoan/PCSetup/main/spotify-discord/cloud/setup-cloud.sh -o setup-cloud.sh
#   DISCORD_BOT_TOKEN=... DISCORD_GUILD_ID=... DISCORD_VOICE_CHANNEL_ID=... bash setup-cloud.sh
#
# (Or run it without the env vars, then edit /etc/spotify-discord.env and
#  `systemctl restart spotify-discord-bot`.)
#
# After install, do the one-time Spotify login (see login-spotify-cloud.sh).
# Unlike the WSL host, a real VPS has clean outbound UDP, so Discord voice and
# the OAuth callback work without any networking tricks.
set -e

REPO_RAW="https://raw.githubusercontent.com/vaoan/PCSetup/main/spotify-discord"
APP_DIR="/opt/spotify-discord"
CONFIG_DIR="/root/.config/go-librespot"
FIFO="/tmp/spotify-discord.fifo"
ENV_FILE="/etc/spotify-discord.env"
BIN="/usr/local/bin/go-librespot"

echo "[setup-cloud] Installing system dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y ffmpeg curl ca-certificates tar build-essential python3

# Stop needrestart (used by unattended-upgrades) from auto-restarting services on
# library updates — otherwise a security-update cycle bounces go-librespot and the
# bot mid-stream, dropping the playback session ("no sound"). 'l' = list only.
mkdir -p /etc/needrestart/conf.d
printf "%s\n" "\$nrconf{restart} = 'l';" > /etc/needrestart/conf.d/99-no-autorestart.conf

# -- Node.js 22 ---------------------------------------------------------------
NODE_MAJOR=0
command -v node >/dev/null 2>&1 && NODE_MAJOR=$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || echo 0)
if [ "$NODE_MAJOR" -lt 20 ]; then
    echo "[setup-cloud] Installing Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
else
    echo "[setup-cloud] Node.js $(node --version) OK"
fi

# -- go-librespot (arch-aware) ------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)        GLR_ASSET="go-librespot_linux_x86_64.tar.gz" ;;
    aarch64|arm64) GLR_ASSET="go-librespot_linux_arm64.tar.gz" ;;
    *) echo "[setup-cloud] Unsupported arch: $ARCH"; exit 1 ;;
esac
echo "[setup-cloud] Installing go-librespot ($GLR_ASSET)..."
curl -fsSL "https://github.com/devgianlu/go-librespot/releases/latest/download/$GLR_ASSET" -o /tmp/glr.tar.gz
tar -xzf /tmp/glr.tar.gz -C /usr/local/bin go-librespot
chmod +x "$BIN"
rm -f /tmp/glr.tar.gz

# -- Restore saved go-librespot credentials (skip OAuth on rebuild) -----------
# Pass SPOTIFY_GO_LIBRESPOT_STATE_B64=... (from GitHub Secrets / .secrets) to
# drop the reusable Spotify credentials straight in — no login step needed.
mkdir -p "$CONFIG_DIR"
if [ -n "${SPOTIFY_GO_LIBRESPOT_STATE_B64:-}" ] && [ ! -f "$CONFIG_DIR/state.json" ]; then
    echo "$SPOTIFY_GO_LIBRESPOT_STATE_B64" | base64 -d > "$CONFIG_DIR/state.json" 2>/dev/null \
        && echo "[setup-cloud] Restored saved Spotify credentials (no login needed)." \
        || echo "[setup-cloud] Could not decode SPOTIFY_GO_LIBRESPOT_STATE_B64; will need login."
fi

# -- App files (from the repo, so the VPS needs no local checkout) ------------
echo "[setup-cloud] Fetching bot + config from GitHub..."
mkdir -p "$APP_DIR" "$CONFIG_DIR"
curl -fsSL "$REPO_RAW/bot.js"       -o "$APP_DIR/bot.js"
curl -fsSL "$REPO_RAW/dj.js"        -o "$APP_DIR/dj.js"
curl -fsSL "$REPO_RAW/package.json" -o "$APP_DIR/package.json"
curl -fsSL "$REPO_RAW/config.yml"   -o "$CONFIG_DIR/config.yml"
echo "[setup-cloud] Installing npm dependencies..."
( cd "$APP_DIR" && npm install --omit=dev --no-audit --no-fund )

# -- Environment file ---------------------------------------------------------
if [ ! -f "$ENV_FILE" ] || [ -n "${DISCORD_BOT_TOKEN:-}" ]; then
    cat > "$ENV_FILE" << ENVEOF
DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN:-replace_me}
DISCORD_GUILD_ID=${DISCORD_GUILD_ID:-replace_me}
DISCORD_VOICE_CHANNEL_ID=${DISCORD_VOICE_CHANNEL_ID:-}
SPOTIFY_FIFO=$FIFO
SPOTIFY_PIPE_RATE=44100
SPOTIFY_CLIENT_ID=${SPOTIFY_CLIENT_ID:-}
SPOTIFY_CLIENT_SECRET=${SPOTIFY_CLIENT_SECRET:-}
ENVEOF
    chmod 600 "$ENV_FILE"
    echo "[setup-cloud] Wrote $ENV_FILE"
fi

# -- systemd services ---------------------------------------------------------
cat > /etc/systemd/system/go-librespot.service << SERVICEEOF
[Unit]
Description=go-librespot Spotify Connect device (Discord)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=HOME=/root
ExecStartPre=/bin/sh -c '[ -p $FIFO ] || mkfifo $FIFO'
ExecStart=$BIN --config_dir $CONFIG_DIR
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF

cat > /etc/systemd/system/spotify-discord-bot.service << SERVICEEOF
[Unit]
Description=Spotify to Discord voice bridge bot
After=network-online.target go-librespot.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStartPre=/bin/sh -c '[ -p $FIFO ] || mkfifo $FIFO'
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/node $APP_DIR/bot.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable go-librespot spotify-discord-bot >/dev/null 2>&1 || true

# -- First-run check ----------------------------------------------------------
if ls "$CONFIG_DIR"/*.json >/dev/null 2>&1; then
    systemctl restart go-librespot spotify-discord-bot
    echo "[setup-cloud] Services restarted (credentials present)."
else
    systemctl start go-librespot 2>/dev/null || true
    echo ""
    echo "[setup-cloud] ============================================================"
    echo "  ONE-TIME SPOTIFY LOGIN REQUIRED"
    echo "  From YOUR computer, SSH in with a tunnel for the OAuth callback:"
    echo ""
    echo "    ssh -L 8898:localhost:8898 root@<this-vps-ip>"
    echo ""
    echo "  Then on the VPS run:"
    echo "    bash <(curl -fsSL $REPO_RAW/cloud/login-spotify-cloud.sh)"
    echo "  and open the printed URL in your local browser."
    echo "[setup-cloud] ============================================================"
fi

if grep -q 'replace_me' "$ENV_FILE" 2>/dev/null; then
    echo ""
    echo "[setup-cloud] NOTE: edit $ENV_FILE (DISCORD_BOT_TOKEN / GUILD_ID / VOICE_CHANNEL_ID),"
    echo "  then: systemctl restart spotify-discord-bot"
fi

echo ""
echo "[setup-cloud] Done. Logs: journalctl -u go-librespot -u spotify-discord-bot -f"
