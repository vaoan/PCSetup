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
LIBRA_DIR="/mnt/z/Github/libra"
PUCK_DIR="/mnt/z/Github/puck"
AELEOS_DIR="/mnt/z/Github/aeleos"
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
ensure_keypair "$SSHWIFTY_KEY_DIR/libra" 'sshwifty-libra'
ensure_keypair "$SSHWIFTY_KEY_DIR/libra-shell" 'sshwifty-libra-shell'
ensure_keypair "$SSHWIFTY_KEY_DIR/eclipse-con" 'sshwifty-eclipse-con'
ensure_keypair "$SSHWIFTY_KEY_DIR/eclipse-con-shell" 'sshwifty-eclipse-con-shell'
ensure_keypair "$SSHWIFTY_KEY_DIR/puck" 'sshwifty-puck'
ensure_keypair "$SSHWIFTY_KEY_DIR/puck-shell" 'sshwifty-puck-shell'
ensure_keypair "$SSHWIFTY_KEY_DIR/aeleos" 'sshwifty-aeleos'
ensure_keypair "$SSHWIFTY_KEY_DIR/aeleos-shell" 'sshwifty-aeleos-shell'
ensure_keypair "$SSHWIFTY_KEY_DIR/pcsetup" 'sshwifty-pcsetup'
ensure_keypair "$SSHWIFTY_KEY_DIR/pcsetup-shell" 'sshwifty-pcsetup-shell'
restrict_key_permissions "$SSHWIFTY_KEY_DIR/wsl-terminal"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/wsl-shell"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/libra"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/libra-shell"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/eclipse-con"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/eclipse-con-shell"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/puck"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/puck-shell"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/aeleos"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/aeleos-shell"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/pcsetup"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/pcsetup-shell"

# Remove stale code-server apt sources from older installs so apt-get update works on fresh machines.
if [ -f /etc/apt/sources.list.d/code-server.list ] && grep -q 'packagecloud.io/coder/code-server/any' /etc/apt/sources.list.d/code-server.list; then
    rm -f /etc/apt/sources.list.d/code-server.list
    echo "[setup-console-wsl] Removed stale code-server apt source"
fi

# -- 1. Install dependencies --------------------------------------------------
apt-get update -q
apt-get install -y tmux openssh-server curl ca-certificates gnupg ttyd

install_nodesource_node() {
    echo "[setup-console-wsl] Installing Node.js 22 for WSL services..."
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
    echo "[setup-console-wsl] Node.js $(node --version) already supports console services"
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "[setup-console-wsl] npm was not found after Node.js install"
    exit 1
fi

install_native_pnpm() {
    local corepack_path
    corepack_path=$(command -v corepack || true)
    if [ -z "$corepack_path" ]; then
        echo "[setup-console-wsl] corepack is not available; skipping native pnpm provisioning"
        return
    fi

    echo "[setup-console-wsl] Provisioning native pnpm for WSL shells..."
    "$corepack_path" enable
    "$corepack_path" prepare pnpm@10.22.0 --activate

    cat > /usr/local/bin/pnpm << WRAPPER
#!/bin/bash
exec "$corepack_path" pnpm "\$@"
WRAPPER
    chmod +x /usr/local/bin/pnpm
    echo "[setup-console-wsl] Native pnpm wrapper installed at /usr/local/bin/pnpm"
}

install_native_pnpm

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
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s libra -c /mnt/z/Github/libra'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/libra.pub") sshwifty-libra
command="bash -c '/usr/local/bin/mount-windows-drives.sh; cd /mnt/z/Github/libra && exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/libra-shell.pub") sshwifty-libra-shell
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s eclipse-con -c /mnt/z/Github/eclipse-con'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/eclipse-con.pub") sshwifty-eclipse-con
command="bash -c '/usr/local/bin/mount-windows-drives.sh; cd /mnt/z/Github/eclipse-con && exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/eclipse-con-shell.pub") sshwifty-eclipse-con-shell
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s puck -c /mnt/z/Github/puck'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/puck.pub") sshwifty-puck
command="bash -c '/usr/local/bin/mount-windows-drives.sh; cd /mnt/z/Github/puck && exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/puck-shell.pub") sshwifty-puck-shell
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s aeleos -c /mnt/z/Github/aeleos'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/aeleos.pub") sshwifty-aeleos
command="bash -c '/usr/local/bin/mount-windows-drives.sh; cd /mnt/z/Github/aeleos && exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/aeleos-shell.pub") sshwifty-aeleos-shell
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

# -- 4b. terminal-recovery helper ---------------------------------------------
cat > /usr/local/bin/fix-terminal << 'FIXTERMINAL'
#!/bin/bash
stty sane 2>/dev/null || true
if command -v tput >/dev/null 2>&1; then
    tput rmkx 2>/dev/null || true
fi
printf '\e[?1l\e>\e[?2004l'
echo
echo "[fix-terminal] Reset terminal input modes (stty sane, normal cursor keys, bracketed paste off)."
FIXTERMINAL
chmod +x /usr/local/bin/fix-terminal
echo "[setup-console-wsl] fix-terminal helper installed"

# -- 5. wetty fallback shell script -------------------------------------------
cat > /usr/local/bin/wetty-start-shell.sh << 'WETTYSHELL'
#!/bin/bash
exec tmux new-session -A -s main -c /mnt/z/Github/libra
WETTYSHELL
chmod +x /usr/local/bin/wetty-start-shell.sh

# Where `npm install -g` actually puts binaries. On this machine Node comes from
# the NodeSource package, whose npm prefix is /usr — so global bins land in
# /usr/bin, NOT /usr/local/bin. Hardcoding /usr/local/bin made validate_ungit
# check a path that can never exist: ungit installed fine to /usr/bin/ungit,
# the check failed anyway, and the script exited 1 every run. Resolve it.
# (Our OWN scripts genuinely do live in /usr/local/bin — only npm-installed
# binaries need this.)
NPM_BIN="$(/usr/bin/npm prefix -g 2>/dev/null)/bin"
[ -d "$NPM_BIN" ] || NPM_BIN=/usr/local/bin
echo "[setup-console-wsl] npm global bin resolved to $NPM_BIN"

# -- 6. Install wetty (fallback web terminal, runs on port 7681) --------------
# wetty is an unused FALLBACK — the `systemctl start` line below deliberately
# omits it. Its gc-stats dependency compiles a native module and needs `make`
# (build-essential), which a fresh Ubuntu does not have. Combined with `set -e`
# at the top of this script, that failure used to abort the ENTIRE setup: on a
# fresh machine code-server, ttyd, ungit, dashboard and git-proxy were never
# configured because an optional terminal nobody uses failed to build.
# Never let one optional item stop the rest.
WETTY_OK=0
if [ -x "$NPM_BIN/wetty" ]; then
    WETTY_OK=1
else
    echo "[setup-console-wsl] Installing wetty (optional fallback)..."
    if /usr/bin/npm install -g wetty@2.7.0 >/tmp/wetty-install.log 2>&1 && [ -x "$NPM_BIN/wetty" ]; then
        WETTY_OK=1
    else
        echo "[setup-console-wsl] WARNING: wetty install failed - skipping it (log: /tmp/wetty-install.log)."
        echo "[setup-console-wsl]          wetty is the unused fallback terminal; ttyd.ffxiv.be is unaffected."
    fi
fi

if [ "$WETTY_OK" = "1" ]; then
cat > /etc/systemd/system/wetty.service << WETTYSERVICE
[Unit]
Description=WeTTY Web Terminal
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/node $NPM_BIN/wetty --port 7681 --base / --command /usr/local/bin/wetty-start-shell.sh
Restart=on-failure
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
WETTYSERVICE
fi

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

# -- 8. Install / upgrade code-server to latest -------------------------------
# install.sh is idempotent: installs if missing, upgrades in place if already
# present. Running it unconditionally keeps code.ffxiv.be on the latest release.
echo "[setup-console-wsl] Installing/upgrading code-server to latest..."
curl -fsSL https://code-server.dev/install.sh | sh

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
  "terminal.integrated.gpuAcceleration": "off",
  "terminal.integrated.altClickMovesCursor": false,
  "terminal.integrated.enablePersistentSessions": false,
  "terminal.integrated.localEchoEnabled": false,

  "chat.commandCenter.enabled": false,
  "chat.agent.enabled": false,
  "inlineChat.enabled": false,
  "security.workspace.trust.enabled": false
}
CSSETTINGS
cat > "$CODE_HOME/.local/share/code-server/User/keybindings.json" << 'CSKEYBINDINGS'
[
  {
    "key": "ctrl+r",
    "command": "workbench.action.reloadWindow"
  },
  {
    "key": "cmd+r",
    "command": "workbench.action.reloadWindow"
  }
]
CSKEYBINDINGS
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
runuser -u "$CODE_USER" -- code-server --install-extension GlobalArt.reload-window-button 2>/dev/null || true
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

# -- 8b. code-server icons (classic pink VS Code logo) ------------------------
# Split into its own script: a code-server upgrade replaces /usr/lib/code-server
# and reverts this, so it must stay runnable standalone afterwards.
bash /mnt/z/Users/Heiner/Documents/PCSetup/cloudflared/restore-code-server-icons.sh

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
ExecStart=/usr/bin/ttyd -p 7684 -b /persistent -W bash -l -c "tmux new-session -A -s phone"
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
ExecStart=/usr/bin/ttyd -p 7685 -b /fresh -W bash -l
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

# Install or repair ungit. Recent ungit dependencies require Node >=20, and
# older broken installs can survive reruns unless the binary is validated.
validate_ungit() {
    local log=/tmp/pcsetup-ungit-validate.log
    rm -f "$log"
    if [ ! -x "$NPM_BIN/ungit" ]; then
        return 1
    fi

    timeout 8 "$NPM_BIN/ungit" --port 17688 --no-launchBrowser --ungitBindIp 127.0.0.1 >"$log" 2>&1 || true
    grep -q 'Ungit started' "$log"
}

if ! validate_ungit; then
    echo "[setup-console-wsl] Installing/repairing ungit..."
    /usr/bin/npm uninstall -g ungit >/dev/null 2>&1 || true
    /usr/bin/npm install -g ungit@1.5.30
fi

# ungit backs git.ffxiv.be only. A hard `exit 1` here used to abandon the rest of
# the setup — git-proxy was never configured and NOTHING was enabled or started,
# so a single broken optional service took down the whole console. Degrade to a
# warning: the other five hostnames do not depend on ungit.
UNGIT_OK=1
if ! validate_ungit; then
    UNGIT_OK=0
    echo "[setup-console-wsl] WARNING: ungit validation failed - git.ffxiv.be will not serve repo views."
    cat /tmp/pcsetup-ungit-validate.log 2>/dev/null || true
fi

cat > /etc/systemd/system/ungit.service << UNGITSERVICE
[Unit]
Description=Ungit web Git UI
After=network.target

[Service]
Type=simple
ExecStart=$NPM_BIN/ungit --port 7688 --no-launchBrowser --ungitBindIp 0.0.0.0
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

# Only enable units whose binary actually exists — enabling one whose binary is
# missing just guarantees a service that fails at every boot.
ENABLE_UNITS="ssh code-server@${CODE_USER} ttyd-persistent ttyd-fresh ttyd-proxy dashboard git-proxy"
if [ "$WETTY_OK" = "1" ]; then ENABLE_UNITS="$ENABLE_UNITS wetty"; fi
if [ "$UNGIT_OK" = "1" ]; then ENABLE_UNITS="$ENABLE_UNITS ungit"; fi
systemctl enable $ENABLE_UNITS 2>/dev/null || true
service ssh start
echo "[setup-console-wsl] SSH service started"
START_UNITS="code-server@${CODE_USER} ttyd-persistent ttyd-fresh ttyd-proxy dashboard git-proxy"
if [ "$UNGIT_OK" = "1" ]; then START_UNITS="$START_UNITS ungit"; fi
systemctl start $START_UNITS 2>/dev/null || true
echo "[setup-console-wsl] code-server started for $CODE_USER (port 8080)"
echo "[setup-console-wsl] ttyd started (proxy:7683, persistent:7684, fresh:7685)"

echo ""
echo "[setup-console-wsl] WSL setup complete."
echo "  SSH listening on port 22 (exposed to Windows as localhost:2222 via portproxy)"
echo "  code-server: port 8080 (exposed to Windows as localhost:8080 via portproxy)"
echo "  ttyd (tmux): port 7683 (exposed to Windows as localhost:7683 via portproxy)"
if [ "$WETTY_OK" = "1" ]; then
    echo "  Wetty fallback: port 7681 (systemd service)"
else
    echo "  Wetty fallback: SKIPPED (install failed; unused by default)"
fi
echo "  $(grep -c '^command=' /root/.ssh/authorized_keys) console presets configured in authorized_keys"
echo ""
echo "  Next: run setup-console-windows.ps1 on the Windows side."
