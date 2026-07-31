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
ensure_keypair "$SSHWIFTY_KEY_DIR/candystore" 'sshwifty-candystore'
ensure_keypair "$SSHWIFTY_KEY_DIR/candystore-shell" 'sshwifty-candystore-shell'
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
restrict_key_permissions "$SSHWIFTY_KEY_DIR/candystore"
restrict_key_permissions "$SSHWIFTY_KEY_DIR/candystore-shell"
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
command="bash -c '/usr/local/bin/mount-windows-drives.sh; exec tmux new-session -A -s candyshop -c /mnt/z/Github/candystore'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/candystore.pub") sshwifty-candystore
command="bash -c '/usr/local/bin/mount-windows-drives.sh; cd /mnt/z/Github/candystore && exec bash -l'",no-port-forwarding,no-X11-forwarding,no-agent-forwarding $(cat "$SSHWIFTY_KEY_DIR/candystore-shell.pub") sshwifty-candystore-shell
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
exec tmux new-session -A -s main -c /mnt/z/Github/candystore
WETTYSHELL
chmod +x /usr/local/bin/wetty-start-shell.sh

# -- 6. Install wetty (fallback web terminal, runs on port 7681) --------------
if [ ! -x /usr/local/bin/wetty ]; then
    echo "[setup-console-wsl] Installing wetty..."
    /usr/bin/npm install -g wetty@2.7.0
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

# -- 8b. Replace code-server icons with the classic pink VS Code logo ---------
# Newer code-server versions stopped bundling the multi-blue VS Code "ribbon"
# logo (4.126 / Code 1.126 ships a different, simpler icon), which silently
# broke the old "find + recolor the bundled icon" approach. So we embed the
# canonical VS Code logo here (base64) and recolor its three blues to pink.
# This is version-independent: it no longer depends on whatever icon
# code-server happens to bundle.
apt-get install -y -q librsvg2-bin imagemagick
MEDIA=/usr/lib/code-server/src/browser/media

if [ -d "$MEDIA" ]; then
    base64 -d > /tmp/cs-logo.svg << 'CSLOGOEOF'
PHN2ZyB2aWV3Qm94PSIwIDAgMTAwIDEwMCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPG1hc2sgaWQ9Im1hc2swIiBtYXNrLXR5cGU9ImFscGhhIiBtYXNrVW5pdHM9InVzZXJTcGFjZU9uVXNlIiB4PSIwIiB5PSIwIiB3aWR0aD0iMTAwIiBoZWlnaHQ9IjEwMCI+CjxwYXRoIGZpbGwtcnVsZT0iZXZlbm9kZCIgY2xpcC1ydWxlPSJldmVub2RkIiBkPSJNNzAuOTExOSA5OS4zMTcxQzcyLjQ4NjkgOTkuOTMwNyA3NC4yODI4IDk5Ljg5MTQgNzUuODcyNSA5OS4xMjY0TDk2LjQ2MDggODkuMjE5N0M5OC42MjQyIDg4LjE3ODcgMTAwIDg1Ljk4OTIgMTAwIDgzLjU4NzJWMTYuNDEzM0MxMDAgMTQuMDExMyA5OC42MjQzIDExLjgyMTggOTYuNDYwOSAxMC43ODA4TDc1Ljg3MjUgMC44NzM3NTZDNzMuNzg2MiAtMC4xMzAxMjkgNzEuMzQ0NiAwLjExNTc2IDY5LjUxMzUgMS40NDY5NUM2OS4yNTIgMS42MzcxMSA2OS4wMDI4IDEuODQ5NDMgNjguNzY5IDIuMDgzNDFMMjkuMzU1MSAzOC4wNDE1TDEyLjE4NzIgMjUuMDA5NkMxMC41ODkgMjMuNzk2NSA4LjM1MzYzIDIzLjg5NTkgNi44NjkzMyAyNS4yNDYxTDEuMzYzMDMgMzAuMjU0OUMtMC40NTI1NTIgMzEuOTA2NCAtMC40NTQ2MzMgMzQuNzYyNyAxLjM1ODUzIDM2LjQxN0wxNi4yNDcxIDUwLjAwMDFMMS4zNTg1MyA2My41ODMyQy0wLjQ1NDYzMyA2NS4yMzc0IC0wLjQ1MjU1MiA2OC4wOTM4IDEuMzYzMDMgNjkuNzQ1M0w2Ljg2OTMzIDc0Ljc1NDFDOC4zNTM2MyA3Ni4xMDQzIDEwLjU4OSA3Ni4yMDM3IDEyLjE4NzIgNzQuOTkwNUwyOS4zNTUxIDYxLjk1ODdMNjguNzY5IDk3LjkxNjdDNjkuMzkyNSA5OC41NDA2IDcwLjEyNDYgOTkuMDEwNCA3MC45MTE5IDk5LjMxNzFaTTc1LjAxNTIgMjcuMjk4OUw0NS4xMDkxIDUwLjAwMDFMNzUuMDE1MiA3Mi43MDEyVjI3LjI5ODlaIiBmaWxsPSJ3aGl0ZSIvPgo8L21hc2s+CjxnIG1hc2s9InVybCgjbWFzazApIj4KPHBhdGggZD0iTTk2LjQ2MTQgMTAuNzk2Mkw3NS44NTY5IDAuODc1NTQyQzczLjQ3MTkgLTAuMjcyNzczIDcwLjYyMTcgMC4yMTE2MTEgNjguNzUgMi4wODMzM0wxLjI5ODU4IDYzLjU4MzJDLTAuNTE1NjkzIDY1LjIzNzMgLTAuNTEzNjA3IDY4LjA5MzcgMS4zMDMwOCA2OS43NDUyTDYuODEyNzIgNzQuNzU0QzguMjk3OTMgNzYuMTA0MiAxMC41MzQ3IDc2LjIwMzYgMTIuMTMzOCA3NC45OTA1TDkzLjM2MDkgMTMuMzY5OUM5Ni4wODYgMTEuMzAyNiAxMDAgMTMuMjQ2MiAxMDAgMTYuNjY2N1YxNi40Mjc1QzEwMCAxNC4wMjY1IDk4LjYyNDYgMTEuODM3OCA5Ni40NjE0IDEwLjc5NjJaIiBmaWxsPSIjMDA2NUE5Ii8+CjxnIGZpbHRlcj0idXJsKCNmaWx0ZXIwX2QpIj4KPHBhdGggZD0iTTk2LjQ2MTQgODkuMjAzOEw3NS44NTY5IDk5LjEyNDVDNzMuNDcxOSAxMDAuMjczIDcwLjYyMTcgOTkuNzg4NCA2OC43NSA5Ny45MTY3TDEuMjk4NTggMzYuNDE2OUMtMC41MTU2OTMgMzQuNzYyNyAtMC41MTM2MDcgMzEuOTA2MyAxLjMwMzA4IDMwLjI1NDhMNi44MTI3MiAyNS4yNDZDOC4yOTc5MyAyMy44OTU4IDEwLjUzNDcgMjMuNzk2NCAxMi4xMzM4IDI1LjAwOTVMOTMuMzYwOSA4Ni42MzAxQzk2LjA4NiA4OC42OTc0IDEwMCA4Ni43NTM4IDEwMCA4My4zMzM0VjgzLjU3MjZDMTAwIDg1Ljk3MzUgOTguNjI0NiA4OC4xNjIyIDk2LjQ2MTQgODkuMjAzOFoiIGZpbGw9IiMwMDdBQ0MiLz4KPC9nPgo8ZyBmaWx0ZXI9InVybCgjZmlsdGVyMV9kKSI+CjxwYXRoIGQ9Ik03NS44NTc4IDk5LjEyNjNDNzMuNDcyMSAxMDAuMjc0IDcwLjYyMTkgOTkuNzg4NSA2OC43NSA5Ny45MTY2QzcxLjA1NjQgMTAwLjIyMyA3NSA5OC41ODk1IDc1IDk1LjMyNzhWNC42NzIxM0M3NSAxLjQxMDM5IDcxLjA1NjQgLTAuMjIzMTA2IDY4Ljc1IDIuMDgzMjlDNzAuNjIxOSAwLjIxMTQwMiA3My40NzIxIC0wLjI3MzY2NiA3NS44NTc4IDAuODczNjMzTDk2LjQ1ODcgMTAuNzgwN0M5OC42MjM0IDExLjgyMTcgMTAwIDE0LjAxMTIgMTAwIDE2LjQxMzJWODMuNTg3MUMxMDAgODUuOTg5MSA5OC42MjM0IDg4LjE3ODYgOTYuNDU4NiA4OS4yMTk2TDc1Ljg1NzggOTkuMTI2M1oiIGZpbGw9IiMxRjlDRjAiLz4KPC9nPgo8ZyBzdHlsZT0ibWl4LWJsZW5kLW1vZGU6b3ZlcmxheSIgb3BhY2l0eT0iMC4yNSI+CjxwYXRoIGZpbGwtcnVsZT0iZXZlbm9kZCIgY2xpcC1ydWxlPSJldmVub2RkIiBkPSJNNzAuODUxMSA5OS4zMTcxQzcyLjQyNjEgOTkuOTMwNiA3NC4yMjIxIDk5Ljg5MTMgNzUuODExNyA5OS4xMjY0TDk2LjQgODkuMjE5N0M5OC41NjM0IDg4LjE3ODcgOTkuOTM5MiA4NS45ODkyIDk5LjkzOTIgODMuNTg3MVYxNi40MTMzQzk5LjkzOTIgMTQuMDExMiA5OC41NjM1IDExLjgyMTcgOTYuNDAwMSAxMC43ODA3TDc1LjgxMTcgMC44NzM2OTVDNzMuNzI1NSAtMC4xMzAxOSA3MS4yODM4IDAuMTE1Njk5IDY5LjQ1MjcgMS40NDY4OEM2OS4xOTEyIDEuNjM3MDUgNjguOTQyIDEuODQ5MzcgNjguNzA4MiAyLjA4MzM1TDI5LjI5NDMgMzguMDQxNEwxMi4xMjY0IDI1LjAwOTZDMTAuNTI4MyAyMy43OTY0IDguMjkyODUgMjMuODk1OSA2LjgwODU1IDI1LjI0NkwxLjMwMjI1IDMwLjI1NDhDLTAuNTEzMzM0IDMxLjkwNjQgLTAuNTE1NDE1IDM0Ljc2MjcgMS4yOTc3NSAzNi40MTY5TDE2LjE4NjMgNTBMMS4yOTc3NSA2My41ODMyQy0wLjUxNTQxNSA2NS4yMzc0IC0wLjUxMzMzNCA2OC4wOTM3IDEuMzAyMjUgNjkuNzQ1Mkw2LjgwODU1IDc0Ljc1NEM4LjI5Mjg1IDc2LjEwNDIgMTAuNTI4MyA3Ni4yMDM2IDEyLjEyNjQgNzQuOTkwNUwyOS4yOTQzIDYxLjk1ODZMNjguNzA4MiA5Ny45MTY3QzY5LjMzMTcgOTguNTQwNSA3MC4wNjM4IDk5LjAxMDQgNzAuODUxMSA5OS4zMTcxWk03NC45NTQ0IDI3LjI5ODlMNDUuMDQ4MyA1MEw3NC45NTQ0IDcyLjcwMTJWMjcuMjk4OVoiIGZpbGw9InVybCgjcGFpbnQwX2xpbmVhcikiLz4KPC9nPgo8L2c+CjxkZWZzPgo8ZmlsdGVyIGlkPSJmaWx0ZXIwX2QiIHg9Ii04LjM5NDExIiB5PSIxNS44MjkxIiB3aWR0aD0iMTE2LjcyNyIgaGVpZ2h0PSI5Mi4yNDU2IiBmaWx0ZXJVbml0cz0idXNlclNwYWNlT25Vc2UiIGNvbG9yLWludGVycG9sYXRpb24tZmlsdGVycz0ic1JHQiI+CjxmZUZsb29kIGZsb29kLW9wYWNpdHk9IjAiIHJlc3VsdD0iQmFja2dyb3VuZEltYWdlRml4Ii8+CjxmZUNvbG9yTWF0cml4IGluPSJTb3VyY2VBbHBoYSIgdHlwZT0ibWF0cml4IiB2YWx1ZXM9IjAgMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDEyNyAwIi8+CjxmZU9mZnNldC8+CjxmZUdhdXNzaWFuQmx1ciBzdGREZXZpYXRpb249IjQuMTY2NjciLz4KPGZlQ29sb3JNYXRyaXggdHlwZT0ibWF0cml4IiB2YWx1ZXM9IjAgMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAuMjUgMCIvPgo8ZmVCbGVuZCBtb2RlPSJvdmVybGF5IiBpbjI9IkJhY2tncm91bmRJbWFnZUZpeCIgcmVzdWx0PSJlZmZlY3QxX2Ryb3BTaGFkb3ciLz4KPGZlQmxlbmQgbW9kZT0ibm9ybWFsIiBpbj0iU291cmNlR3JhcGhpYyIgaW4yPSJlZmZlY3QxX2Ryb3BTaGFkb3ciIHJlc3VsdD0ic2hhcGUiLz4KPC9maWx0ZXI+CjxmaWx0ZXIgaWQ9ImZpbHRlcjFfZCIgeD0iNjAuNDE2NyIgeT0iLTguMDc1NTgiIHdpZHRoPSI0Ny45MTY3IiBoZWlnaHQ9IjExNi4xNTEiIGZpbHRlclVuaXRzPSJ1c2VyU3BhY2VPblVzZSIgY29sb3ItaW50ZXJwb2xhdGlvbi1maWx0ZXJzPSJzUkdCIj4KPGZlRmxvb2QgZmxvb2Qtb3BhY2l0eT0iMCIgcmVzdWx0PSJCYWNrZ3JvdW5kSW1hZ2VGaXgiLz4KPGZlQ29sb3JNYXRyaXggaW49IlNvdXJjZUFscGhhIiB0eXBlPSJtYXRyaXgiIHZhbHVlcz0iMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAgMTI3IDAiLz4KPGZlT2Zmc2V0Lz4KPGZlR2F1c3NpYW5CbHVyIHN0ZERldmlhdGlvbj0iNC4xNjY2NyIvPgo8ZmVDb2xvck1hdHJpeCB0eXBlPSJtYXRyaXgiIHZhbHVlcz0iMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAgMCAwIDAgMC4yNSAwIi8+CjxmZUJsZW5kIG1vZGU9Im92ZXJsYXkiIGluMj0iQmFja2dyb3VuZEltYWdlRml4IiByZXN1bHQ9ImVmZmVjdDFfZHJvcFNoYWRvdyIvPgo8ZmVCbGVuZCBtb2RlPSJub3JtYWwiIGluPSJTb3VyY2VHcmFwaGljIiBpbjI9ImVmZmVjdDFfZHJvcFNoYWRvdyIgcmVzdWx0PSJzaGFwZSIvPgo8L2ZpbHRlcj4KPGxpbmVhckdyYWRpZW50IGlkPSJwYWludDBfbGluZWFyIiB4MT0iNDkuOTM5MiIgeTE9IjAuMjU3ODEyIiB4Mj0iNDkuOTM5MiIgeTI9Ijk5Ljc0MjMiIGdyYWRpZW50VW5pdHM9InVzZXJTcGFjZU9uVXNlIj4KPHN0b3Agc3RvcC1jb2xvcj0id2hpdGUiLz4KPHN0b3Agb2Zmc2V0PSIxIiBzdG9wLWNvbG9yPSJ3aGl0ZSIgc3RvcC1vcGFjaXR5PSIwIi8+CjwvbGluZWFyR3JhZGllbnQ+CjwvZGVmcz4KPC9zdmc+Cg==
CSLOGOEOF
    # Recolor the classic VS Code blues -> the original pink palette.
    sed \
      -e 's/#0065A9/#9C0054/gI' \
      -e 's/#007ACC/#CC007A/gI' \
      -e 's/#1F9CF0/#FF1493/gI' \
      /tmp/cs-logo.svg > /tmp/cs-icon-pink.svg

    cp /tmp/cs-icon-pink.svg "$MEDIA/favicon.svg"
    cp /tmp/cs-icon-pink.svg "$MEDIA/favicon-dark-support.svg"

    rsvg-convert -w 16 -h 16 /tmp/cs-icon-pink.svg -o /tmp/cs-fav16.png
    rsvg-convert -w 32 -h 32 /tmp/cs-icon-pink.svg -o /tmp/cs-fav32.png
    rsvg-convert -w 48 -h 48 /tmp/cs-icon-pink.svg -o /tmp/cs-fav48.png
    convert /tmp/cs-fav16.png /tmp/cs-fav32.png /tmp/cs-fav48.png "$MEDIA/favicon.ico"

    rsvg-convert -w 192 -h 192 /tmp/cs-icon-pink.svg -o "$MEDIA/pwa-icon-192.png"
    rsvg-convert -w 512 -h 512 /tmp/cs-icon-pink.svg -o "$MEDIA/pwa-icon-512.png"

    # Maskable icons: composite the pink logo (~70%, inside the maskable safe
    # zone) onto a dark background, using ImageMagick.
    convert -size 192x192 xc:'#1e1e1e' \( "$MEDIA/pwa-icon-512.png" -resize 134x134 \) -gravity center -composite "$MEDIA/pwa-icon-maskable-192.png" || true
    convert -size 512x512 xc:'#1e1e1e' \( "$MEDIA/pwa-icon-512.png" -resize 358x358 \) -gravity center -composite "$MEDIA/pwa-icon-maskable-512.png" || true

    rm -f /tmp/cs-logo.svg /tmp/cs-icon-pink.svg /tmp/cs-fav16.png /tmp/cs-fav32.png /tmp/cs-fav48.png
    echo "[setup-console-wsl] code-server icons replaced (classic pink VS Code logo)"
else
    echo "[setup-console-wsl] code-server media dir not found ($MEDIA); skipping icon replacement"
fi

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
    if [ ! -x /usr/local/bin/ungit ]; then
        return 1
    fi

    timeout 8 /usr/local/bin/ungit --port 17688 --no-launchBrowser --ungitBindIp 127.0.0.1 >"$log" 2>&1 || true
    grep -q 'Ungit started' "$log"
}

if ! validate_ungit; then
    echo "[setup-console-wsl] Installing/repairing ungit..."
    /usr/bin/npm uninstall -g ungit >/dev/null 2>&1 || true
    /usr/bin/npm install -g ungit@1.5.30
fi

if ! validate_ungit; then
    echo "[setup-console-wsl] ungit validation failed"
    cat /tmp/pcsetup-ungit-validate.log 2>/dev/null || true
    exit 1
fi

cat > /etc/systemd/system/ungit.service << 'UNGITSERVICE'
[Unit]
Description=Ungit web Git UI
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ungit --port 7688 --no-launchBrowser --ungitBindIp 0.0.0.0
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
echo "  $(grep -c '^command=' /root/.ssh/authorized_keys) console presets configured in authorized_keys"
echo ""
echo "  Next: run setup-console-windows.ps1 on the Windows side."
