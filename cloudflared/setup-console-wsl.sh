#!/bin/bash
# WSL setup for the web console.
# Run as root inside Ubuntu-24.04 WSL after a fresh Windows install.
# Usage: wsl -d Ubuntu-24.04 --user root bash /mnt/z/Users/Heiner/Documents/PCSetup/scripts/setup-console-wsl.sh
set -e

echo "[setup-console-wsl] Starting WSL console setup..."

WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r\n')
WIN_HOST=$(cmd.exe /c "echo %COMPUTERNAME%" 2>/dev/null | tr -d '\r\n')
SSHWIFTY_KEY_DIR="/mnt/c/Users/$WIN_USER/Documents/Cloudflare/sshwifty/keys"
PCSETUP_DIR="/mnt/z/Users/Heiner/Documents/PCSetup"
ECLIPSE_DIR="/mnt/z/Github/eclipse-con"
CANDYSHOP_DIR="/mnt/z/Github/candystore"
CODE_USER=$(getent passwd | awk -F: '$3 >= 1000 && $1 != "nobody" && $7 !~ /(false|nologin)$/ { print $1; exit }')
if [ -z "$CODE_USER" ]; then
    CODE_USER="root"
fi
CODE_HOME=$(getent passwd "$CODE_USER" | cut -d: -f6)
if [ -z "$CODE_HOME" ]; then
    CODE_HOME="/root"
fi

ensure_keypair() {
    local base_path="$1"
    local comment="$2"
    if [ ! -f "$base_path" ]; then
        ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$base_path" >/dev/null
    fi
}

restrict_key_permissions() {
    local base_path="$1"
    local win_path
    win_path=$(wslpath -w "$base_path")
    powershell.exe -NoProfile -Command "
        \$p = '$win_path'
        \$acl = Get-Acl \$p
        \$acl.SetAccessRuleProtection(\$true, \$false)
        foreach (\$rule in @(\$acl.Access)) { [void]\$acl.RemoveAccessRuleSpecific(\$rule) }
        foreach (\$rule in @(
            [Security.AccessControl.FileSystemAccessRule]::new('$WIN_USER', 'FullControl', 'Allow'),
            [Security.AccessControl.FileSystemAccessRule]::new('SYSTEM', 'FullControl', 'Allow'),
            [Security.AccessControl.FileSystemAccessRule]::new('Administrators', 'FullControl', 'Allow')
        )) { \$acl.AddAccessRule(\$rule) }
        Set-Acl -Path \$p -AclObject \$acl
    " >/dev/null 2>&1 || true
}

mkdir -p "$SSHWIFTY_KEY_DIR"
ensure_keypair "$SSHWIFTY_KEY_DIR/wsl-terminal" 'sshwifty-wsl-terminal'
ensure_keypair "$SSHWIFTY_KEY_DIR/wsl-shell" 'sshwifty-wsl-shell'
ensure_keypair "$SSHWIFTY_KEY_DIR/candystore" 'sshwifty-candystore'
ensure_keypair "$SSHWIFTY_KEY_DIR/candystore-shell" 'sshwifty-candystore-shell'
ensure_keypair "$SSHWIFTY_KEY_DIR/eclipse-con" 'sshwifty-eclipse-con'
ensure_keypair "$SSHWIFTY_KEY_DIR/eclipse-con-shell" 'sshwifty-eclipse-con-shell'
ensure_keypair "$SSHWIFTY_KEY_DIR/pcsetup" 'sshwifty-pcsetup'
ensure_keypair "$SSHWIFTY_KEY_DIR/pcsetup-shell" 'sshwifty-pcsetup-shell'
restrict_key_permissions "$SSHWIFTY_KEY_DIR/wsl-terminal"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/wsl-shell"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/candystore"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/candystore-shell"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/eclipse-con"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/eclipse-con-shell"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/pcsetup"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/pcsetup-shell"

# Remove stale code-server apt sources from older installs so apt-get update works on fresh machines.
if [ -f /etc/apt/sources.list.d/code-server.list ] && grep -q 'packagecloud.io/coder/code-server/any' /etc/apt/sources.list.d/code-server.list; then
    rm -f /etc/apt/sources.list.d/code-server.list
    echo "[setup-console-wsl] Removed stale code-server apt source"
fi

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

cat > /root/.ssh/authorized_keys << AUTHKEYS
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s console'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/wsl-terminal.pub") sshwifty
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/wsl-shell.pub") sshwifty-shell
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s candyshop -c /mnt/z/Github/candystore'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/candystore.pub") sshwifty-candystore
command="bash -c '/usr/local/bin/mount-windows-drives.sh; cd /mnt/z/Github/candystore && exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/candystore-shell.pub") sshwifty-candystore-shell
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s eclipse-con -c /mnt/z/Github/eclipse-con'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/eclipse-con.pub") sshwifty-eclipse-con
command="bash -c '/usr/local/bin/mount-windows-drives.sh; cd /mnt/z/Github/eclipse-con && exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/eclipse-con-shell.pub") sshwifty-eclipse-con-shell
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s pcsetup -c /mnt/z/Users/Heiner/Documents/PCSetup'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/pcsetup.pub") sshwifty-pcsetup
command="bash -c '/usr/local/bin/mount-windows-drives.sh; cd /mnt/z/Users/Heiner/Documents/PCSetup && exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/pcsetup-shell.pub") sshwifty-pcsetup-shell
AUTHKEYS

chmod 600 /root/.ssh/authorized_keys
echo "[setup-console-wsl] authorized_keys written (8 keys = 8 console presets)"

# -- 3b. CLI wrappers for Windows-hosted tools --------------------------------
cat > /usr/local/bin/claude << WRAPPER
#!/bin/bash
exec /mnt/c/Users/$WIN_USER/.local/bin/claude.exe "\$@"
WRAPPER
chmod +x /usr/local/bin/claude

cat > /usr/local/bin/codex << WRAPPER
#!/bin/bash
exec /mnt/c/Users/$WIN_USER/AppData/Local/Programs/OpenAI/Codex/bin/codex.exe "\$@"
WRAPPER
chmod +x /usr/local/bin/codex
echo "[setup-console-wsl] claude/codex wrappers installed"

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
for target_home in /root "$CODE_HOME"; do
    mkdir -p "$target_home"
    for link_target in .aws .azure .docker; do
        win_path="/mnt/c/Users/$WIN_USER/$link_target"
        if [ -d "$win_path" ] && [ ! -L "$target_home/$link_target" ]; then
            ln -sf "$win_path" "$target_home/$link_target"
            echo "[setup-console-wsl] Symlinked $target_home/$link_target -> $win_path"
        fi
    done
done

# -- 8. Install code-server if missing ----------------------------------------
if ! command -v code-server &>/dev/null; then
    echo "[setup-console-wsl] Installing code-server..."
    curl -fsSL https://code-server.dev/install.sh | sh
fi

mkdir -p "$CODE_HOME/.config/code-server"
cat > "$CODE_HOME/.config/code-server/config.yaml" << 'CODESERVERCONF'
bind-addr: 0.0.0.0:8080
auth: none
cert: false
CODESERVERCONF
chown -R "$CODE_USER:$CODE_USER" "$CODE_HOME/.config"
echo "[setup-console-wsl] code-server config written (port 8080, no auth)"

# -- 8b-i. code-server user settings (terminal-focused layout) ----------------
mkdir -p "$CODE_HOME/.local/share/code-server/User"
cat > "$CODE_HOME/.local/share/code-server/User/settings.json" << 'CSSETTINGS'
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
chown -R "$CODE_USER:$CODE_USER" "$CODE_HOME/.local"
echo "[setup-console-wsl] code-server user settings written"

# -- 8b-ii. code-server workspace + terminal auto-open -----------------------
# Workspace file opens /mnt/z in the sidebar; Terminals Manager opens a shell on load
cat > "$CODE_HOME/dev.code-workspace" << 'CSWORKSPACE'
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
chown "$CODE_USER:$CODE_USER" "$CODE_HOME/dev.code-workspace"

mkdir -p /mnt/z/.vscode
cat > /mnt/z/.vscode/terminals.json << 'CSTERMS'
{
  "autorun": false,
  "terminals": []
}
CSTERMS

# Install Terminals Manager (auto-opens terminal in panel on workspace load)
runuser -u "$CODE_USER" -- code-server --install-extension fabiospampinato.vscode-terminals 2>/dev/null || true
# Remove ChatGPT extension if present
runuser -u "$CODE_USER" -- code-server --uninstall-extension openai.chatgpt 2>/dev/null || true

# Override systemd service to open the workspace by default
mkdir -p "/etc/systemd/system/code-server@${CODE_USER}.service.d"
cat > "/etc/systemd/system/code-server@${CODE_USER}.service.d/workspace.conf" << CSOVERRIDE
[Service]
ExecStart=
ExecStart=/usr/bin/code-server $CODE_HOME/dev.code-workspace
CSOVERRIDE
systemctl daemon-reload
if [ "$CODE_USER" != "root" ]; then
    systemctl disable code-server@root 2>/dev/null || true
    systemctl stop code-server@root 2>/dev/null || true
    rm -rf /etc/systemd/system/code-server@root.service.d 2>/dev/null || true
fi
echo "[setup-console-wsl] code-server workspace + terminal auto-open configured for $CODE_USER"

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

cp /mnt/z/Users/Heiner/Documents/PCSetup/cloudflared/ttyd-proxy.js /usr/local/bin/ttyd-proxy.js

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
cp /mnt/z/Users/Heiner/Documents/PCSetup/cloudflared/dashboard.js /usr/local/bin/dashboard.js

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

cp /mnt/z/Users/Heiner/Documents/PCSetup/cloudflared/git-proxy.js /usr/local/bin/git-proxy.js

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

systemctl enable ssh wetty "code-server@${CODE_USER}" ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit git-proxy 2>/dev/null || true
service ssh start
echo "[setup-console-wsl] SSH service started"
systemctl start "code-server@${CODE_USER}" ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit git-proxy 2>/dev/null || true
echo "[setup-console-wsl] code-server started for $CODE_USER (port 8080)"
echo "[setup-console-wsl] ttyd started (proxy:7683, persistent:7684, fresh:7685)"

echo ""
echo "[setup-console-wsl] WSL setup complete."
echo "  SSH listening on port 22 (exposed to Windows as localhost:2222 via portproxy)"
echo "  code-server: port 8080 (exposed to Windows as localhost:8080 via portproxy)"
echo "  ttyd (tmux): port 7683 (exposed to Windows as localhost:7683 via portproxy)"
echo "  Wetty fallback: port 7681 (systemd service)"
echo "  8 console presets configured in authorized_keys"
echo ""
echo "  Next: run setup-console-windows.ps1 on the Windows side."
