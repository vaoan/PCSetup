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
ExecStart=/usr/bin/ungit --port 7687 --no-launchBrowser --rootPath /mnt/z/Github --ungitBindIp 0.0.0.0
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
UNGITSERVICE
systemctl daemon-reload
echo "[setup-console-wsl] ungit service configured (port 7687)"

systemctl enable ssh wetty code-server@root ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit 2>/dev/null || true
service ssh start
echo "[setup-console-wsl] SSH service started"
systemctl start code-server@root ttyd-persistent ttyd-fresh ttyd-proxy dashboard ungit 2>/dev/null || true
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
