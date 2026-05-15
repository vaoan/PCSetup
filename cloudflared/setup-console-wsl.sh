#!/bin/bash
# WSL setup for the web console.
# Run as root inside Ubuntu-24.04 WSL after a fresh Windows install.
# Usage: wsl -d Ubuntu-24.04 --user root bash /mnt/z/Users/Heiner/Documents/PCSetup/scripts/setup-console-wsl.sh
set -e

echo "[setup-console-wsl] Starting WSL console setup..."

# -- 1. Install dependencies --------------------------------------------------
apt-get update -q
apt-get install -y tmux openssh-server curl

# -- 2. Configure sshd --------------------------------------------------------
# Needed because sshwifty connects as root via key auth
SSHD_CONF=/etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONF"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONF"
# WSL mount permissions are loose — StrictModes off prevents false permission errors
grep -q '^StrictModes no' "$SSHD_CONF" || echo 'StrictModes no' >> "$SSHD_CONF"
echo "[setup-console-wsl] sshd configured"

# -- 3. SSH authorized_keys ---------------------------------------------------
# Each key maps to a specific preset in sshwifty.conf.json via forced commands.
# Persistent = tmux new-session -A (attach or create)
# Fresh      = plain bash (no tmux, new session every time)
mkdir -p /root/.ssh
chmod 700 /root/.ssh

cat > /root/.ssh/authorized_keys << 'AUTHKEYS'
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s console'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP/Vy7KSgeXaBOzETRgM5/usQ94vpqQOE2uva5694+Fq sshwifty
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEkJtboAWqZo2UMzOx+E5Xobs/A6N/Cio2FCvEQGiN7Z sshwifty-shell
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s candystore -c /mnt/z/Github/candystore'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGcAr4h8+2Vzombku1qIZcfh98qzC++hMmNwUxgeCkqb sshwifty-candystore
command="bash -c '/usr/local/bin/mount-windows-drives.sh; cd /mnt/z/Github/candystore && exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGsUVqv8X2CclQ2z+bhKZgSjFEsy8rXPLgYHEKo/F1PZ sshwifty-candystore-shell
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s eclipse-con -c /mnt/z/Github/eclipse-con'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIdXt0oNdbi7kg3oJ6/gnxBs3WygODGzVZ+QH/BKTvtm sshwifty-eclipse-con
command="bash -c '/usr/local/bin/mount-windows-drives.sh; cd /mnt/z/Github/eclipse-con && exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAsUda1YPReX3hGNBUyvodZZeBKSAlRfAWcXKB9Cntno sshwifty-eclipse-con-shell
AUTHKEYS

chmod 600 /root/.ssh/authorized_keys
echo "[setup-console-wsl] authorized_keys written (6 keys = 6 console presets)"

# -- 4. mount-windows-drives.sh -----------------------------------------------
cat > /usr/local/bin/mount-windows-drives.sh << 'MOUNTSCRIPT'
#!/bin/bash
# Auto-mount all available Windows drives into WSL
drives=$(cmd.exe /c "wmic logicaldisk get name" 2>/dev/null | grep -oP '[A-Z]:' | tr -d '\r')
for drive in $drives; do
    letter=$(echo "$drive" | tr '[:upper:]' '[:lower:]' | tr -d ':')
    mountpoint="/mnt/$letter"
    if mountpoint "$mountpoint" &>/dev/null 2>&1; then
        continue
    fi
    mkdir -p "$mountpoint"
    mount -t drvfs "$drive" "$mountpoint" 2>/dev/null
done
MOUNTSCRIPT
chmod +x /usr/local/bin/mount-windows-drives.sh
echo "[setup-console-wsl] mount-windows-drives.sh installed"

# -- 5. wetty fallback shell script -------------------------------------------
cat > /usr/local/bin/wetty-start-shell.sh << 'WETTYSHELL'
#!/bin/bash
exec tmux new-session -A -s main -c /mnt/z/Github/candystore
WETTYSHELL
chmod +x /usr/local/bin/wetty-start-shell.sh

# -- 6. Install wetty (fallback web terminal, runs on port 7681) --------------
if ! command -v wetty &>/dev/null; then
    echo "[setup-console-wsl] Installing wetty..."
    npm install -g wetty@2.7.0
fi

cat > /etc/systemd/system/wetty.service << 'WETTYSERVICE'
[Unit]
Description=WeTTY Web Terminal
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/node /usr/local/bin/wetty --port 7681 --base / --command /usr/local/bin/wetty-start-shell.sh
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
WETTYSERVICE

# -- 7. Symlink shared Windows configs ----------------------------------------
# These let WSL inherit configs already set up in Windows
for link_target in .aws .azure .docker; do
    win_path="/mnt/c/Users/$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')/$link_target"
    if [ -d "$win_path" ] && [ ! -L "/root/$link_target" ]; then
        ln -sf "$win_path" "/root/$link_target"
        echo "[setup-console-wsl] Symlinked ~/$link_target -> $win_path"
    fi
done

# claude alias (uses Windows claude.exe via WSL interop)
if ! grep -q "alias claude=" /root/.bashrc 2>/dev/null; then
    echo "alias claude='/mnt/c/Users/\$(cmd.exe /c \"echo %USERNAME%\" 2>/dev/null | tr -d \"\\\r\\\n\")/.local/bin/claude.exe'" >> /root/.bashrc
fi

# -- 8. Install code-server if missing ----------------------------------------
if ! command -v code-server &>/dev/null; then
    echo "[setup-console-wsl] Installing code-server..."
    curl -fsSL https://code-server.dev/install.sh | sh
fi

mkdir -p /root/.config/code-server
cat > /root/.config/code-server/config.yaml << 'CODESERVERCONF'
bind-addr: 0.0.0.0:8080
auth: none
cert: false
CODESERVERCONF
echo "[setup-console-wsl] code-server config written (port 8080, no auth)"

# -- 8b-i. code-server user settings (terminal-focused layout) ----------------
mkdir -p /root/.local/share/code-server/User
cat > /root/.local/share/code-server/User/settings.json << 'CSSETTINGS'
{
  "workbench.colorTheme": "Dark Modern",
  "workbench.iconTheme": "vscode-icons",
  "window.menuBarVisibility": "classic",

  "workbench.panel.opensMaximized": "always",

  "chat.commandCenter.enabled": false,
  "chat.agent.enabled": false,
  "inlineChat.enabled": false,
  "security.workspace.trust.enabled": false
}
CSSETTINGS
echo "[setup-console-wsl] code-server user settings written"

# -- 8b-ii. code-server workspace + terminal auto-open -----------------------
# Workspace file opens /mnt/z in the sidebar; Terminals Manager opens a shell on load
cat > /root/dev.code-workspace << 'CSWORKSPACE'
{
  "folders": [
    { "path": "/mnt/z" }
  ],
  "settings": {
    "task.allowAutomaticTasks": "on",
    "security.workspace.trust.enabled": false
  }
}
CSWORKSPACE

mkdir -p /mnt/z/.vscode
cat > /mnt/z/.vscode/terminals.json << 'CSTERMS'
{
  "autorun": false,
  "terminals": []
}
CSTERMS

# Install Terminals Manager (auto-opens terminal in panel on workspace load)
code-server --install-extension fabiospampinato.vscode-terminals 2>/dev/null || true
# Remove ChatGPT extension if present
code-server --uninstall-extension openai.chatgpt 2>/dev/null || true

# Override systemd service to open the workspace by default
mkdir -p /etc/systemd/system/code-server@root.service.d
cat > /etc/systemd/system/code-server@root.service.d/workspace.conf << 'CSOVERRIDE'
[Service]
ExecStart=
ExecStart=/usr/bin/code-server /root/dev.code-workspace
CSOVERRIDE
systemctl daemon-reload
echo "[setup-console-wsl] code-server workspace + terminal auto-open configured"

# -- 8b. Replace code-server icons with pink VS Code icon (transparent bg) ----
apt-get install -y -q librsvg2-bin imagemagick
MEDIA=/usr/lib/code-server/src/browser/media
ORIG=/usr/lib/code-server/lib/vscode/out/vs/sessions/contrib/chat/browser/media/vscode-icon.svg

# Recolor the bundled VS Code icon SVG: blue shades -> pink equivalents
# #0065A9 (dark blue)   -> #9C0054 (dark pink)
# #007ACC (medium blue) -> #CC007A (medium pink)
# #1F9CF0 (light blue)  -> #FF1493 (hot pink)
sed \
  -e 's/#0065A9/#9C0054/g' \
  -e 's/#007ACC/#CC007A/g' \
  -e 's/#1F9CF0/#FF1493/g' \
  "$ORIG" > /tmp/cs-icon-pink.svg

# SVG favicons (browsers render these directly, transparent bg preserved)
cp /tmp/cs-icon-pink.svg "$MEDIA/favicon.svg"
cp /tmp/cs-icon-pink.svg "$MEDIA/favicon-dark-support.svg"

# favicon.ico multi-size (16, 32, 48) for legacy browsers and OS pinning
rsvg-convert -w 16 -h 16 /tmp/cs-icon-pink.svg -o /tmp/cs-fav16.png
rsvg-convert -w 32 -h 32 /tmp/cs-icon-pink.svg -o /tmp/cs-fav32.png
rsvg-convert -w 48 -h 48 /tmp/cs-icon-pink.svg -o /tmp/cs-fav48.png
convert /tmp/cs-fav16.png /tmp/cs-fav32.png /tmp/cs-fav48.png "$MEDIA/favicon.ico"

# PWA regular icons (transparent bg)
rsvg-convert -w 192 -h 192 /tmp/cs-icon-pink.svg -o "$MEDIA/pwa-icon-192.png"
rsvg-convert -w 512 -h 512 /tmp/cs-icon-pink.svg -o "$MEDIA/pwa-icon-512.png"

# Maskable icons: dark background (#1e1e1e, VS Code dark theme) with pink icon in safe zone
cat > /tmp/cs-icon-maskable.svg << 'SVGEOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96">
  <rect width="96" height="96" fill="#1e1e1e"/>
  <g transform="translate(16.8,16.8) scale(0.65)">
SVGEOF
sed -n '/<g filter/,/<\/svg>/p' /tmp/cs-icon-pink.svg | head -n -1 >> /tmp/cs-icon-maskable.svg
echo '  </g></svg>' >> /tmp/cs-icon-maskable.svg
rsvg-convert -w 192 -h 192 /tmp/cs-icon-maskable.svg -o "$MEDIA/pwa-icon-maskable-192.png"
rsvg-convert -w 512 -h 512 /tmp/cs-icon-maskable.svg -o "$MEDIA/pwa-icon-maskable-512.png"

rm -f /tmp/cs-icon-pink.svg /tmp/cs-icon-maskable.svg /tmp/cs-fav16.png /tmp/cs-fav32.png /tmp/cs-fav48.png
echo "[setup-console-wsl] code-server icons replaced (pink VS Code shape, transparent bg)"

# -- 9. Configure tmux mouse mode and ttyd-console service --------------------
grep -q "mouse on" /root/.tmux.conf 2>/dev/null || echo "set -g mouse on" >> /root/.tmux.conf
echo "[setup-console-wsl] tmux mouse mode enabled"

cp /mnt/z/Users/Heiner/Documents/PCSetup/scripts/ttyd-proxy.js /usr/local/bin/ttyd-proxy.js

cat > /etc/systemd/system/ttyd-persistent.service << 'TTYDSERVICE'
[Unit]
Description=ttyd persistent terminal (tmux)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ttyd -p 7684 -b /persistent -W bash -l -c "tmux new-session -A -s phone"
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
TTYDSERVICE

cat > /etc/systemd/system/ttyd-fresh.service << 'TTYDSERVICE'
[Unit]
Description=ttyd fresh terminal (bash)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ttyd -p 7685 -b /fresh -W bash -l
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
TTYDSERVICE

cat > /etc/systemd/system/ttyd-proxy.service << 'TTYDSERVICE'
[Unit]
Description=ttyd landing page proxy
After=network.target ttyd-persistent.service ttyd-fresh.service

[Service]
Type=simple
ExecStart=/usr/bin/node /usr/local/bin/ttyd-proxy.js
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
TTYDSERVICE

systemctl daemon-reload
echo "[setup-console-wsl] ttyd services configured (proxy:7683, persistent:7684, fresh:7685)"

# -- 10. Start services -------------------------------------------------------
cp /mnt/z/Users/Heiner/Documents/PCSetup/scripts/dashboard.js /usr/local/bin/dashboard.js

cat > /etc/systemd/system/dashboard.service << 'DASHSERVICE'
[Unit]
Description=Dev Tools dashboard
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/node /usr/local/bin/dashboard.js
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
DASHSERVICE
systemctl daemon-reload
echo "[setup-console-wsl] dashboard service configured (port 7686)"

# Install ungit if missing
if ! command -v ungit &>/dev/null; then
    npm install -g ungit
fi

cat > /etc/systemd/system/ungit.service << 'UNGITSERVICE'
[Unit]
Description=Ungit web Git UI
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/ungit --port 7688 --no-launchBrowser --ungitBindIp 0.0.0.0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNGITSERVICE

cp /mnt/z/Users/Heiner/Documents/PCSetup/scripts/git-proxy.js /usr/local/bin/git-proxy.js

cat > /etc/systemd/system/git-proxy.service << 'GITPROXYSERVICE'
[Unit]
Description=Git repo browser proxy
After=network.target ungit.service

[Service]
Type=simple
ExecStart=/usr/bin/node /usr/local/bin/git-proxy.js
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
GITPROXYSERVICE
systemctl daemon-reload
echo "[setup-console-wsl] ungit service configured (port 7688, internal)"
echo "[setup-console-wsl] git-proxy service configured (port 7687, public)"

systemctl enable ssh wetty code-server@root ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit git-proxy 2>/dev/null || true
service ssh start
echo "[setup-console-wsl] SSH service started"
systemctl start code-server@root ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit git-proxy 2>/dev/null || true
echo "[setup-console-wsl] code-server started (port 8080)"
echo "[setup-console-wsl] ttyd started (proxy:7683, persistent:7684, fresh:7685)"

echo ""
echo "[setup-console-wsl] WSL setup complete."
echo "  SSH listening on port 22 (exposed to Windows as localhost:2222 via portproxy)"
echo "  code-server: port 8080 (exposed to Windows as localhost:8080 via portproxy)"
echo "  ttyd (tmux): port 7683 (exposed to Windows as localhost:7683 via portproxy)"
echo "  Wetty fallback: port 7681 (systemd service)"
echo "  6 console presets configured in authorized_keys"
echo ""
echo "  Next: run setup-console-windows.ps1 on the Windows side."
