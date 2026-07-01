#!/bin/bash
# WSL setup for the Spotify → Discord voice bridge.
# Run as root inside Ubuntu-24.04 WSL after a fresh Windows install.
# Usage:
#   wsl -d Ubuntu-24.04 --user root bash /mnt/z/Users/Heiner/Documents/PCSetup/spotify-discord/setup-spotify-discord-wsl.sh
#
# Installs go-librespot (Spotify Connect device) + a discord.js bot that streams
# its audio into a Discord voice channel. Both run as systemd services that
# start at boot, so the bridge is restored automatically after a format.
set -e

echo "[setup-spotify-discord] Starting..."

PCSETUP_DIR="/mnt/z/Users/Heiner/Documents/PCSetup"
SRC_DIR="$PCSETUP_DIR/spotify-discord"
APP_DIR="/opt/spotify-discord"            # Linux-native copy of the bot (fast npm/native builds)
CONFIG_DIR="/root/.config/go-librespot"
FIFO="/tmp/spotify-discord.fifo"
ENV_FILE="/etc/spotify-discord.env"
BIN="/usr/local/bin/go-librespot"

# -- 1. System dependencies ---------------------------------------------------
apt-get update -q
apt-get install -y ffmpeg curl ca-certificates tar build-essential python3

install_nodesource_node() {
    echo "[setup-spotify-discord] Installing Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
}

NODE_MAJOR=0
if command -v node >/dev/null 2>&1; then
    NODE_MAJOR=$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || echo 0)
fi
if [ "$NODE_MAJOR" -lt 20 ]; then
    install_nodesource_node
else
    echo "[setup-spotify-discord] Node.js $(node --version) is fine"
fi

# -- 2. Install go-librespot (latest x86_64 release) --------------------------
echo "[setup-spotify-discord] Installing latest go-librespot..."
TMP_TGZ="$(mktemp --suffix=.tar.gz)"
DL_URL="https://github.com/devgianlu/go-librespot/releases/latest/download/go-librespot_linux_x86_64.tar.gz"
curl -fsSL "$DL_URL" -o "$TMP_TGZ"
tar -xzf "$TMP_TGZ" -C /usr/local/bin go-librespot
chmod +x "$BIN"
rm -f "$TMP_TGZ"
echo "[setup-spotify-discord] go-librespot installed: $($BIN --version 2>/dev/null || echo unknown)"

# -- 3. go-librespot config ---------------------------------------------------
mkdir -p "$CONFIG_DIR"
cp "$SRC_DIR/config.yml" "$CONFIG_DIR/config.yml"
echo "[setup-spotify-discord] config.yml deployed to $CONFIG_DIR"

# -- 4. Copy bot to a Linux-native dir and install deps -----------------------
# (Running npm + native @discordjs/opus build straight off the Z: drvfs mount is
#  slow and permission-flaky, so we work from /opt instead.)
mkdir -p "$APP_DIR"
cp "$SRC_DIR/package.json" "$APP_DIR/package.json"
cp "$SRC_DIR/bot.js" "$APP_DIR/bot.js"
cp "$SRC_DIR/dj.js" "$APP_DIR/dj.js"
cp "$SRC_DIR/accounts.js" "$APP_DIR/accounts.js"
echo "[setup-spotify-discord] Installing npm dependencies..."
( cd "$APP_DIR" && npm install --omit=dev --no-audit --no-fund )

# -- 5. Environment file (token + ids) ----------------------------------------
# Pull Discord values from the synced .secrets file when present; otherwise write
# placeholders for the user to fill in.
read_secret() {
    local key="$1"
    if [ -f "$PCSETUP_DIR/.secrets" ]; then
        grep -E "^${key}=" "$PCSETUP_DIR/.secrets" | head -n1 | cut -d= -f2- | tr -d '\r'
    fi
}

DISCORD_BOT_TOKEN_VAL="$(read_secret DISCORD_BOT_TOKEN)"
DISCORD_GUILD_ID_VAL="$(read_secret DISCORD_GUILD_ID)"
DISCORD_VOICE_CHANNEL_ID_VAL="$(read_secret DISCORD_VOICE_CHANNEL_ID)"

if [ -f "$ENV_FILE" ] && [ -z "$DISCORD_BOT_TOKEN_VAL" ]; then
    echo "[setup-spotify-discord] Keeping existing $ENV_FILE (no token in .secrets)"
else
    cat > "$ENV_FILE" << ENVEOF
# Spotify → Discord bridge environment. Filled from .secrets when available.
DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN_VAL:-replace_me}
DISCORD_GUILD_ID=${DISCORD_GUILD_ID_VAL:-replace_me}
# Empty (not a placeholder) when unset: the bot then waits for /join instead of
# trying to auto-join a bogus channel id on boot.
DISCORD_VOICE_CHANNEL_ID=${DISCORD_VOICE_CHANNEL_ID_VAL}
SPOTIFY_FIFO=$FIFO
SPOTIFY_PIPE_RATE=44100
SPOTIFY_CLIENT_ID=$(read_secret SPOTIFY_CLIENT_ID)
SPOTIFY_CLIENT_SECRET=$(read_secret SPOTIFY_CLIENT_SECRET)
ENVEOF
    chmod 600 "$ENV_FILE"
    echo "[setup-spotify-discord] Wrote $ENV_FILE"
fi

# -- 6. systemd services ------------------------------------------------------
cat > /etc/systemd/system/go-librespot.service << SERVICEEOF
[Unit]
Description=go-librespot Spotify Connect device (Discord)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# go-librespot calls os.UserConfigDir() before parsing --config_dir, so HOME
# must be set even though we pass the dir explicitly.
Environment=HOME=/root
ExecStartPre=/bin/sh -c '[ -p $FIFO ] || mkfifo $FIFO'
ExecStart=$BIN --config_dir $CONFIG_DIR
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

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
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable go-librespot spotify-discord-bot >/dev/null 2>&1 || true
echo "[setup-spotify-discord] systemd services installed + enabled"

# -- 7. First-run check -------------------------------------------------------
# go-librespot needs a one-time OAuth login before it can register the device.
HAS_CREDS=0
if ls "$CONFIG_DIR"/*.json >/dev/null 2>&1; then
    HAS_CREDS=1
fi

echo ""
if [ "$HAS_CREDS" -eq 1 ]; then
    systemctl restart go-librespot spotify-discord-bot
    echo "[setup-spotify-discord] Services (re)started."
else
    echo "[setup-spotify-discord] ============================================================"
    echo "  ONE-TIME LOGIN REQUIRED"
    echo "  go-librespot has no saved Spotify credentials yet. Run:"
    echo ""
    echo "    wsl -d Ubuntu-24.04 --user root bash $SRC_DIR/login-spotify.sh"
    echo ""
    echo "  Then open the printed URL in your Windows browser and authorize."
    echo "  After that the 'Discord' device appears in Spotify Connect everywhere."
    echo "[setup-spotify-discord] ============================================================"
fi

if grep -q 'replace_me' "$ENV_FILE" 2>/dev/null; then
    echo ""
    echo "[setup-spotify-discord] NOTE: $ENV_FILE still has placeholders."
    echo "  Add DISCORD_BOT_TOKEN / DISCORD_GUILD_ID / DISCORD_VOICE_CHANNEL_ID to"
    echo "  the repo .secrets (or edit $ENV_FILE directly), then:"
    echo "    systemctl restart spotify-discord-bot"
fi

echo ""
echo "[setup-spotify-discord] Done."
echo "  Logs:   journalctl -u go-librespot -u spotify-discord-bot -f"
echo "  Device: pick 'Discord' in your Spotify app's Connect (speaker) menu."
