# Cloudflared Merge — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate `Z:\Users\Heiner\Documents\Cloudflare\` into PCSetup under `cloudflared/`, bringing all Cloudflare-related scripts and docs into one git repo.

**Architecture:** Create `cloudflared/` at PCSetup root. Copy the standalone Cloudflare project files in. Git-move the existing `scripts/`, root `.bat`, and `uninstall/console` files into it. Fix two hardcoded paths. Merge CLAUDE.md sections and `.claude/` recovery artifacts. No functional changes to any script logic.

**Tech Stack:** PowerShell (file copy), git mv (tracked file moves), plain text edits

---

## File Map

| Action | Source | Destination |
|---|---|---|
| Copy | `Z:\...\Cloudflare\.cloudflared\config.yml` | `cloudflared\.cloudflared\config.yml` |
| Copy | `Z:\...\Cloudflare\post-format-recovery.ps1` | `cloudflared\post-format-recovery.ps1` |
| Copy | `Z:\...\Cloudflare\install-tunnel.ps1` | `cloudflared\install-tunnel.ps1` |
| Copy | `Z:\...\Cloudflare\install-ssh-tunnel.ps1` | `cloudflared\install-ssh-tunnel.ps1` |
| Copy | `Z:\...\Cloudflare\install-claude-session.ps1` | `cloudflared\install-claude-session.ps1` |
| Copy | `Z:\...\Cloudflare\install-scheduled-tasks.ps1` | `cloudflared\install-scheduled-tasks.ps1` |
| Copy | `Z:\...\Cloudflare\manage-tunnel.ps1` | `cloudflared\manage-tunnel.ps1` |
| Copy | `Z:\...\Cloudflare\run-tunnel-hidden.ps1` | `cloudflared\run-tunnel-hidden.ps1` |
| Copy | `Z:\...\Cloudflare\toggle-tunnel.bat` | `cloudflared\toggle-tunnel.bat` |
| Copy | `Z:\...\Cloudflare\toggle-ssh-tunnel.bat` | `cloudflared\toggle-ssh-tunnel.bat` |
| Copy | `Z:\...\Cloudflare\toggle-claude-session.bat` | `cloudflared\toggle-claude-session.bat` |
| Copy | `Z:\...\Cloudflare\create-shortcuts.ps1` | `cloudflared\create-shortcuts.ps1` |
| Copy | `Z:\...\Cloudflare\start-claude-session.sh` | `cloudflared\start-claude-session.sh` |
| Copy | `Z:\...\Cloudflare\claude-aliases.sh` | `cloudflared\claude-aliases.sh` |
| Copy | `Z:\...\Cloudflare\README.md` | `cloudflared\README.md` |
| Copy | `Z:\...\Cloudflare\INSTALL.md` | `cloudflared\INSTALL.md` |
| Copy | `Z:\...\Cloudflare\SETUP_GUIDE.md` | `cloudflared\SETUP_GUIDE.md` |
| Copy | `Z:\...\Cloudflare\MAC_CLIENT_SETUP.md` | `cloudflared\MAC_CLIENT_SETUP.md` |
| `git mv` | `scripts\console-proxy.js` | `cloudflared\console-proxy.js` |
| `git mv` | `scripts\console-launcher.js` | `cloudflared\console-launcher.js` |
| `git mv` | `scripts\dashboard.js` | `cloudflared\dashboard.js` |
| `git mv` | `scripts\git-proxy.js` | `cloudflared\git-proxy.js` |
| `git mv` | `scripts\ttyd-proxy.js` | `cloudflared\ttyd-proxy.js` |
| `git mv` | `scripts\setup-console-windows.ps1` | `cloudflared\setup-console-windows.ps1` |
| `git mv` | `scripts\setup-console-wsl.sh` | `cloudflared\setup-console-wsl.sh` |
| `git mv` | `scripts\start-console.ps1` | `cloudflared\start-console.ps1` |
| `git mv` | `scripts\sync-secrets.ps1` | `cloudflared\sync-secrets.ps1` |
| `git mv` + edit | `start-console.bat` | `cloudflared\start-console.bat` |
| `git mv` + edit | `sync-secrets.bat` | `cloudflared\sync-secrets.bat` |
| `git mv` | `uninstall\uninstall-console.bat` | `cloudflared\uninstall-console.bat` |
| `git mv` | `uninstall\uninstall-console.ps1` | `cloudflared\uninstall-console.ps1` |
| Create | — | `.claude\commands\recovery.md` |
| Create | — | `.claude\skills\recovery.md` |
| Modify | `CLAUDE.md` | `CLAUDE.md` |
| Delete | `scripts\` (empty) | — |

---

### Task 1: Copy Cloudflare project files into `cloudflared/`

**Files:**
- Create: `cloudflared\.cloudflared\config.yml` and all listed files above (Copy group)

- [ ] **Step 1: Copy files**

```powershell
$src = "Z:\Users\Heiner\Documents\Cloudflare"
$dst = "Z:\Users\Heiner\Documents\PCSetup\cloudflared"

# Create the target dirs
New-Item -ItemType Directory -Force -Path "$dst\.cloudflared" | Out-Null

# Copy tunnel config
Copy-Item "$src\.cloudflared\config.yml" "$dst\.cloudflared\config.yml"

# Copy all root-level files except .gitignore, CLAUDE.md (handled separately), and .claude/ folder
$exclude = @('.gitignore', 'CLAUDE.md')
Get-ChildItem "$src" -File | Where-Object { $_.Name -notin $exclude } | ForEach-Object {
    Copy-Item $_.FullName "$dst\$($_.Name)"
}
```

- [ ] **Step 2: Verify files exist**

```powershell
$expected = @(
    "cloudflared\.cloudflared\config.yml",
    "cloudflared\post-format-recovery.ps1",
    "cloudflared\install-tunnel.ps1",
    "cloudflared\install-ssh-tunnel.ps1",
    "cloudflared\install-claude-session.ps1",
    "cloudflared\install-scheduled-tasks.ps1",
    "cloudflared\manage-tunnel.ps1",
    "cloudflared\run-tunnel-hidden.ps1",
    "cloudflared\toggle-tunnel.bat",
    "cloudflared\toggle-ssh-tunnel.bat",
    "cloudflared\toggle-claude-session.bat",
    "cloudflared\create-shortcuts.ps1",
    "cloudflared\start-claude-session.sh",
    "cloudflared\claude-aliases.sh",
    "cloudflared\README.md",
    "cloudflared\INSTALL.md",
    "cloudflared\SETUP_GUIDE.md",
    "cloudflared\MAC_CLIENT_SETUP.md"
)
$root = "Z:\Users\Heiner\Documents\PCSetup"
$missing = $expected | Where-Object { -not (Test-Path "$root\$_") }
if ($missing) { Write-Host "MISSING: $($missing -join ', ')" } else { Write-Host "All files present" }
```

Expected output: `All files present`

- [ ] **Step 3: Stage and commit**

```powershell
git add cloudflared/
git commit -m "feat(cloudflared): import Cloudflare project files into cloudflared/"
```

---

### Task 2: Git-move `scripts/` content into `cloudflared/`

**Files:**
- Move: all 9 files in `scripts/` → `cloudflared/`
- Delete: `scripts/` folder

- [ ] **Step 1: Git-move all scripts/ files**

```powershell
$files = @(
    "console-proxy.js",
    "console-launcher.js",
    "dashboard.js",
    "git-proxy.js",
    "ttyd-proxy.js",
    "setup-console-windows.ps1",
    "setup-console-wsl.sh",
    "start-console.ps1",
    "sync-secrets.ps1"
)
foreach ($f in $files) {
    git mv "scripts/$f" "cloudflared/$f"
}
```

- [ ] **Step 2: Verify scripts/ is now empty**

```powershell
$remaining = Get-ChildItem "Z:\Users\Heiner\Documents\PCSetup\scripts" -ErrorAction SilentlyContinue
if ($remaining) { Write-Host "Still has files: $($remaining.Name -join ', ')" } else { Write-Host "scripts/ is empty" }
```

Expected output: `scripts/ is empty`

- [ ] **Step 3: Remove empty scripts/ folder**

```powershell
Remove-Item "Z:\Users\Heiner\Documents\PCSetup\scripts" -Force
```

- [ ] **Step 4: Commit**

```powershell
git add -A
git commit -m "refactor(cloudflared): git-move scripts/ into cloudflared/"
```

---

### Task 3: Git-move root `.bat` launchers into `cloudflared/` and fix paths

**Files:**
- Move+Edit: `start-console.bat` → `cloudflared\start-console.bat`
- Move+Edit: `sync-secrets.bat` → `cloudflared\sync-secrets.bat`

- [ ] **Step 1: Git-move both files**

```powershell
git mv start-console.bat cloudflared/start-console.bat
git mv sync-secrets.bat cloudflared/sync-secrets.bat
```

- [ ] **Step 2: Fix path in `cloudflared\start-console.bat`**

Open `Z:\Users\Heiner\Documents\PCSetup\cloudflared\start-console.bat`.

Change line 9 from:
```batch
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-console.ps1"
```
To:
```batch
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-console.ps1"
```

- [ ] **Step 3: Fix path in `cloudflared\sync-secrets.bat`**

Open `Z:\Users\Heiner\Documents\PCSetup\cloudflared\sync-secrets.bat`.

Change line 8 from:
```batch
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\sync-secrets.ps1"
```
To:
```batch
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-secrets.ps1"
```

- [ ] **Step 4: Verify the edits look correct**

```powershell
Select-String -Path "Z:\Users\Heiner\Documents\PCSetup\cloudflared\start-console.bat" -Pattern "scripts\\"
Select-String -Path "Z:\Users\Heiner\Documents\PCSetup\cloudflared\sync-secrets.bat" -Pattern "scripts\\"
```

Expected output: no output (the old `scripts\` path is gone from both files).

- [ ] **Step 5: Commit**

```powershell
git add cloudflared/start-console.bat cloudflared/sync-secrets.bat
git commit -m "refactor(cloudflared): move root launchers into cloudflared/, fix internal paths"
```

---

### Task 4: Git-move uninstall console scripts into `cloudflared/`

**Files:**
- Move: `uninstall\uninstall-console.bat` → `cloudflared\uninstall-console.bat`
- Move: `uninstall\uninstall-console.ps1` → `cloudflared\uninstall-console.ps1`

- [ ] **Step 1: Git-move both uninstall files**

```powershell
git mv uninstall/uninstall-console.bat cloudflared/uninstall-console.bat
git mv uninstall/uninstall-console.ps1 cloudflared/uninstall-console.ps1
```

- [ ] **Step 2: Verify uninstall/ still has the two non-console scripts**

```powershell
Get-ChildItem "Z:\Users\Heiner\Documents\PCSetup\uninstall" | Select-Object Name
```

Expected output:
```
Name
----
context-menu-take-ownership.bat
context-menu-terminal.bat
```

- [ ] **Step 3: Commit**

```powershell
git commit -m "refactor(cloudflared): move uninstall console scripts into cloudflared/"
```

---

### Task 5: Add `.claude/commands/recovery.md` and `.claude/skills/recovery.md`

**Files:**
- Create: `.claude\commands\recovery.md`
- Create: `.claude\skills\recovery.md`

The source content comes from the Cloudflare project's `.claude/` folder, with the working directory path updated from the old Cloudflare location to the new `cloudflared/` location.

- [ ] **Step 1: Create `.claude/commands/` directory**

```powershell
New-Item -ItemType Directory -Force -Path "Z:\Users\Heiner\Documents\PCSetup\.claude\commands" | Out-Null
```

- [ ] **Step 2: Write `.claude/commands/recovery.md`**

Create `Z:\Users\Heiner\Documents\PCSetup\.claude\commands\recovery.md` with this content (paths updated from Cloudflare → PCSetup):

```markdown
# Post-Format Recovery

Guide the user through restoring their Windows PC configuration after a format.

## What to Restore

1. **SSH Tunnel** (pc.ffxivbe.org) - Remote SSH access via Cloudflare
2. **Web Tunnel** (ffxivbe.org) - Web proxy to localhost:9000
3. **Claude Code Session** - Persistent tmux session with auto-start

## Recovery Steps

### Step 1: Check Prerequisites

Ask the user to confirm they have installed:
- [ ] **cloudflared** - https://github.com/cloudflare/cloudflared/releases (Windows amd64 .msi)
- [ ] **MSYS2** - https://www.msys2.org/ (then run: `pacman -Syu && pacman -S tmux`)
- [ ] **Node.js** - via nvm4w or direct install
- [ ] **Claude Code** - `npm install -g @anthropic-ai/claude-code`

### Step 2: SSH Tunnel Setup (Priority - enables remote access)

Run in PowerShell as Administrator:
```powershell
cd "Z:\Users\Heiner\Documents\PCSetup\cloudflared"
.\install-ssh-tunnel.ps1 -MacPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho heinerangarita@Heiners-MacBook-Air.local"
```

This will:
- Install OpenSSH Server
- Create ssh-config.yml
- Create scheduled task (ssh-tunnel)
- Configure SSH key authentication
- Create desktop shortcut

### Step 3: Web Tunnel Setup (Optional)

If the user needs the web proxy to localhost:9000:
```powershell
.\install-tunnel.ps1
```

This will:
- Create config.yml
- Create scheduled task (ffxivbe-tunnel)
- Create desktop shortcut

### Step 4: Claude Code Persistent Sessions (Optional)

```powershell
cd "Z:\Users\Heiner\Documents\PCSetup\cloudflared"
.\install-claude-session.ps1
```

## Verification

After setup, verify everything works:

```powershell
# Check scheduled tasks
Get-ScheduledTask -TaskName "ssh-tunnel" | Select TaskName, State
Get-ScheduledTask -TaskName "ffxivbe-tunnel" | Select TaskName, State
Get-ScheduledTask -TaskName "claude-session" | Select TaskName, State

# Test SSH from Mac
ssh windows-remote
```

## Key Information

- **SSH Tunnel ID**: `8dffdb51-77cc-43ca-8dc8-8a0c720607a5`
- **Web Tunnel ID**: `c552cb9c-62bd-4c8b-9ec6-16627b1b8af3`
- **Mac SSH Key**: `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho`

## Mac SSH Config (already configured on Mac)

```
Host windows-remote
    HostName pc.ffxivbe.org
    User Heiner
    ProxyCommand cloudflared access tcp --hostname %h --listener -
```
```

- [ ] **Step 3: Write `.claude/skills/recovery.md`**

Create `Z:\Users\Heiner\Documents\PCSetup\.claude\skills\recovery.md` with this content (paths updated):

```markdown
# Skill: Post-Format Recovery

Restore Windows PC configuration after a format. This skill guides through setting up Cloudflare tunnels and Claude Code persistent sessions.

## Trigger

Use when user says things like:
- "I want to setup all the configs I had before"
- "I formatted my PC, restore everything"
- "Run recovery"
- "Setup tunnels and Claude"

## Components to Restore

| Component | Script | Priority |
|-----------|--------|----------|
| SSH Tunnel | `cloudflared\install-ssh-tunnel.ps1` | High (enables remote access) |
| Web Tunnel | `cloudflared\install-tunnel.ps1` | Medium |
| Claude Sessions | `cloudflared\install-claude-session.ps1` | Optional |

## Prerequisites Checklist

Before running recovery, ensure installed:
1. **cloudflared** - https://github.com/cloudflare/cloudflared/releases
2. **MSYS2** - https://www.msys2.org/ + `pacman -S tmux`
3. **Node.js** - via nvm4w
4. **Claude Code** - `npm install -g @anthropic-ai/claude-code`

## Recovery Commands

### SSH Tunnel (run first)
```powershell
cd "Z:\Users\Heiner\Documents\PCSetup\cloudflared"
.\install-ssh-tunnel.ps1 -MacPublicKey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho heinerangarita@Heiners-MacBook-Air.local"
```

### Web Tunnel
```powershell
.\install-tunnel.ps1
```

### Claude Code Sessions
```powershell
.\install-claude-session.ps1
```

## Critical IDs (hardcoded in scripts)

- SSH Tunnel: `8dffdb51-77cc-43ca-8dc8-8a0c720607a5`
- Web Tunnel: `c552cb9c-62bd-4c8b-9ec6-16627b1b8af3`

## Verification

```powershell
Get-ScheduledTask | Where-Object { $_.TaskName -match 'tunnel|claude' } | Format-Table TaskName, State
```

## Notes

- Cloudflare dashboard config (DNS, Zero Trust routes, WAF rules) persists and doesn't need reconfiguration
- Scripts auto-elevate to Administrator when needed
- Desktop shortcuts are created automatically by installers
```

- [ ] **Step 4: Verify both files exist**

```powershell
Test-Path "Z:\Users\Heiner\Documents\PCSetup\.claude\commands\recovery.md"
Test-Path "Z:\Users\Heiner\Documents\PCSetup\.claude\skills\recovery.md"
```

Expected output: `True` twice.

- [ ] **Step 5: Commit**

```powershell
git add .claude/commands/recovery.md .claude/skills/recovery.md
git commit -m "feat(cloudflared): add recovery command and skill from Cloudflare project"
```

---

### Task 6: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md` — 6 targeted edits plus one new section

- [ ] **Step 1: Update `sync-secrets.bat` section header and path**

In `CLAUDE.md`, change line 58:
```markdown
### sync-secrets.bat
```
To:
```markdown
### cloudflared/sync-secrets.bat
```

- [ ] **Step 2: Update WSL first-time setup command (line 226)**

Change:
```
   wsl -d Ubuntu-24.04 --user root bash /mnt/z/Users/Heiner/Documents/PCSetup/scripts/setup-console-wsl.sh
```
To:
```
   wsl -d Ubuntu-24.04 --user root bash /mnt/z/Users/Heiner/Documents/PCSetup/cloudflared/setup-console-wsl.sh
```

- [ ] **Step 3: Update populate-secrets step (line 232)**

Change:
```markdown
3. **Populate secrets** — run `sync-secrets.bat` (requires `SSHWIFTY_CONF_B64` in GitHub Secrets).
```
To:
```markdown
3. **Populate secrets** — run `cloudflared\sync-secrets.bat` (requires `SSHWIFTY_CONF_B64` in GitHub Secrets).
```

- [ ] **Step 4: Update Windows setup step (line 235)**

Change:
```markdown
   scripts\setup-console-windows.ps1
```
To:
```markdown
   cloudflared\setup-console-windows.ps1
```

- [ ] **Step 5: Update start-console.bat references (lines 238-244)**

Change:
```markdown
5. **Start the console:**
   ```
   start-console.bat
   ```

### Daily use

Run `start-console.bat` after each login (or reboot)
```
To:
```markdown
5. **Start the console:**
   ```
   cloudflared\start-console.bat
   ```

### Daily use

Run `cloudflared\start-console.bat` after each login (or reboot)
```

- [ ] **Step 6: Replace the entire Console scripts table (lines 248-260)**

Replace:
```markdown
| File | Purpose |
|---|---|
| `start-console.bat` | One-click launcher (calls `scripts\start-console.ps1`) |
| `scripts/start-console.ps1` | Refreshes portproxies, restarts all services + cloudflared |
| `scripts/setup-console-windows.ps1` | First-time Windows setup: provisions tunnel + DNS, writes configs, creates scheduled tasks |
| `scripts/setup-console-wsl.sh` | First-time WSL setup: sshd, authorized_keys, code-server, ttyd services |
| `scripts/console-proxy.js` | Node.js proxy (Windows 7681→7682) that injects the quick-connect panel |
| `scripts/console-launcher.js` | Quick-connect panel UI injected into sshwifty's HTML |
| `scripts/ttyd-proxy.js` | Node.js landing page + proxy (WSL 7683→7684/7685) for ttyd.ffxivbe.org |
| `scripts/dashboard.js` | Node.js static server (WSL 7686) for tools.ffxivbe.org |
| `scripts/git-proxy.js` | Node.js repo list landing page + proxy (WSL 7687→7688) for git.ffxivbe.org |
| `uninstall/uninstall-console.ps1` | Full teardown: kills services, removes tasks/portproxies/files, deletes Cloudflare DNS + tunnel |
| `uninstall/uninstall-console.bat` | Admin wrapper for uninstall-console.ps1 |
```
With:
```markdown
| File | Purpose |
|---|---|
| `cloudflared/start-console.bat` | One-click launcher (calls `start-console.ps1`) |
| `cloudflared/start-console.ps1` | Refreshes portproxies, restarts all services + cloudflared |
| `cloudflared/setup-console-windows.ps1` | First-time Windows setup: provisions tunnel + DNS, writes configs, creates scheduled tasks |
| `cloudflared/setup-console-wsl.sh` | First-time WSL setup: sshd, authorized_keys, code-server, ttyd services |
| `cloudflared/console-proxy.js` | Node.js proxy (Windows 7681→7682) that injects the quick-connect panel |
| `cloudflared/console-launcher.js` | Quick-connect panel UI injected into sshwifty's HTML |
| `cloudflared/ttyd-proxy.js` | Node.js landing page + proxy (WSL 7683→7684/7685) for ttyd.ffxivbe.org |
| `cloudflared/dashboard.js` | Node.js static server (WSL 7686) for tools.ffxivbe.org |
| `cloudflared/git-proxy.js` | Node.js repo list landing page + proxy (WSL 7687→7688) for git.ffxivbe.org |
| `cloudflared/sync-secrets.bat` | Syncs secrets from GitHub → local `.secrets` file |
| `cloudflared/sync-secrets.ps1` | Secrets sync implementation |
| `cloudflared/uninstall-console.ps1` | Full teardown: kills services, removes tasks/portproxies/files, deletes Cloudflare DNS + tunnel |
| `cloudflared/uninstall-console.bat` | Admin wrapper for uninstall-console.ps1 |
```

- [ ] **Step 7: Add the Cloudflare SSH & Remote Access section**

Insert this new section after the `## Web Console` section (before `## Source Files`):

```markdown
## Cloudflare SSH & Remote Access

Two tunnels that run as Windows scheduled tasks, separate from the web console.

### Tunnels

| Tunnel | Hostname | Purpose |
|--------|----------|---------|
| `ffxivbe-tunnel` | ffxivbe.org | Web proxy to localhost:9000 |
| `ssh-tunnel` | pc.ffxivbe.org | SSH remote access from Mac |

Tunnel IDs (persist in Cloudflare, survive PC formats):
- `ffxivbe-tunnel`: `c552cb9c-62bd-4c8b-9ec6-16627b1b8af3`
- `ssh-tunnel`: `8dffdb51-77cc-43ca-8dc8-8a0c720607a5`

### Post-Format Recovery

Run after a fresh Windows install to restore tunnels and Claude Code sessions:

```powershell
cd "Z:\Users\Heiner\Documents\PCSetup\cloudflared"
.\post-format-recovery.ps1
```

Or run individual steps:

```powershell
.\install-ssh-tunnel.ps1    # SSH tunnel + OpenSSH
.\install-tunnel.ps1        # Web tunnel
.\install-claude-session.ps1  # Claude Code tmux sessions
```

> **Note on cloudflared installation:** Scripts auto-install the official signed MSI. Do NOT install via Chocolatey — Smart App Control blocks unsigned executables.

### Claude Code Persistent Sessions (MSYS2/tmux)

| Session | Project | Type |
|---------|---------|------|
| `claude` | Z:\Users\Heiner\Documents\PCSetup\cloudflared | Claude Code |
| `claimangel` | Z:\Github\ClaimAngel\frontend | Claude Code |
| `snd` | Z:\Users\Heiner\Documents\Luas\SND | Bash only |

Sessions start automatically at Windows login. Accessible via `ssh windows-remote` from Mac, then:
```bash
claude        # attach to claude session
claimangel    # attach to claimangel session
snd           # attach to snd session
sessions      # list all tmux sessions
```
Detach: `Ctrl+B`, then `D`.

> **Browser-based MCPs don't work in remote sessions** (Playwright, Chrome DevTools require a local display). All other Claude Code functionality works fine.

### Windows Scheduled Tasks

| Task Name | Trigger | Purpose |
|-----------|---------|---------|
| `ffxivbe-tunnel` | At logon | Web tunnel to ffxivbe.org |
| `ssh-tunnel` | At logon | SSH tunnel to pc.ffxivbe.org |
| `claude-session` | At logon | Claude Code tmux (cloudflared project) |
| `claimangel-session` | At logon | Claude Code tmux (ClaimAngel project) |
| `snd-session` | At logon | Bash tmux (SND project) |

### Mac SSH Config

```bash
brew install cloudflared

# Add to ~/.ssh/config
Host windows-remote
    HostName pc.ffxivbe.org
    User Heiner
    ProxyCommand cloudflared access tcp --hostname %h --listener -
```

Mac SSH public key (already in authorized_keys):
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho heinerangarita@Heiners-MacBook-Air.local
```

### Cloudflare Dashboard (Already Configured — Persists)

Already set up, survives PC formats:
1. DNS CNAMEs pointing to tunnel IDs
2. Zero Trust route for SSH tunnel (`pc.ffxivbe.org` → ssh://localhost:22)
3. WAF bypass rule for `pc.ffxivbe.org`

### cloudflared/ Scripts

| File | Purpose |
|---|---|
| `cloudflared/post-format-recovery.ps1` | Master recovery script — does everything |
| `cloudflared/install-tunnel.ps1` | Web tunnel installer (standalone) |
| `cloudflared/install-ssh-tunnel.ps1` | SSH tunnel + OpenSSH installer |
| `cloudflared/install-claude-session.ps1` | Claude Code tmux sessions installer |
| `cloudflared/install-scheduled-tasks.ps1` | Reinstall scheduled tasks only |
| `cloudflared/toggle-tunnel.bat` | Start/stop web tunnel |
| `cloudflared/toggle-ssh-tunnel.bat` | Start/stop SSH tunnel |
| `cloudflared/toggle-claude-session.bat` | Start/stop any Claude/tmux session |
| `cloudflared/manage-tunnel.ps1` | Status checker for web tunnel |
| `cloudflared/create-shortcuts.ps1` | Creates desktop shortcuts |
| `cloudflared/start-claude-session.sh` | MSYS2 script to start/attach tmux session |
| `cloudflared/claude-aliases.sh` | Bash aliases (claude, claimangel, snd, etc.) |
| `cloudflared/.cloudflared/config.yml` | ffxivbe-tunnel routing config |

### Troubleshooting

```powershell
# Tunnel not connecting — check task status
Get-ScheduledTask -TaskName "ssh-tunnel" | Select State
Get-ScheduledTask -TaskName "ffxivbe-tunnel" | Select State

# SSH "Permission denied" — re-add SSH key
$key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM8m6E4YRx8s+55ZLd198jlsppY/w8MIcKtnymXLSYho heinerangarita@Heiners-MacBook-Air.local"
Set-Content -Path "C:\ProgramData\ssh\administrators_authorized_keys" -Value $key
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'
Restart-Service sshd

# Claude session not starting
Get-ScheduledTask -TaskName "claude-session" | Select State
Start-ScheduledTask -TaskName "claude-session"

# Cloudflared blocked by Smart App Control
# → Uninstall Chocolatey version, install from official MSI:
choco uninstall cloudflared -y
Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi' -OutFile "$env:TEMP\cloudflared.msi"
Start-Process msiexec.exe -ArgumentList '/i', "$env:TEMP\cloudflared.msi", '/quiet' -Wait
```
```

- [ ] **Step 8: Verify no old `scripts/` or root `start-console.bat` paths remain in CLAUDE.md**

```powershell
Select-String -Path "Z:\Users\Heiner\Documents\PCSetup\CLAUDE.md" -Pattern "scripts/"
Select-String -Path "Z:\Users\Heiner\Documents\PCSetup\CLAUDE.md" -Pattern "scripts\\"
```

Expected output: no matches (all references updated to `cloudflared/`).

- [ ] **Step 9: Commit**

```powershell
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with cloudflared/ paths and add SSH/remote access section"
```

---

### Task 7: Final verification

- [ ] **Step 1: Confirm final structure**

```powershell
Write-Host "=== cloudflared/ ===" 
Get-ChildItem "Z:\Users\Heiner\Documents\PCSetup\cloudflared" | Select-Object Name | Format-Table -AutoSize

Write-Host "=== scripts/ should not exist ===" 
if (Test-Path "Z:\Users\Heiner\Documents\PCSetup\scripts") { Write-Host "ERROR: scripts/ still exists" } else { Write-Host "OK: scripts/ is gone" }

Write-Host "=== uninstall/ ===" 
Get-ChildItem "Z:\Users\Heiner\Documents\PCSetup\uninstall" | Select-Object Name | Format-Table -AutoSize

Write-Host "=== .claude/commands/ ===" 
Get-ChildItem "Z:\Users\Heiner\Documents\PCSetup\.claude\commands" | Select-Object Name | Format-Table -AutoSize
```

Expected:
- `cloudflared/` has all listed files
- `scripts/` does not exist
- `uninstall/` has only `context-menu-take-ownership.bat` and `context-menu-terminal.bat`
- `.claude/commands/` has `recovery.md`

- [ ] **Step 2: Confirm git status is clean**

```powershell
git status
```

Expected: `nothing to commit, working tree clean`

- [ ] **Step 3: (Optional) Delete the original standalone Cloudflare folder**

Once you've confirmed all files are in `cloudflared/` and the git history is clean, the original folder is no longer needed:

```powershell
Remove-Item -Recurse -Force "Z:\Users\Heiner\Documents\Cloudflare"
```

This is outside the git repo — it's a manual cleanup. Do it only after confirming the new location is working.

- [ ] **Step 4: Confirm no broken `scripts\` references remain anywhere in the repo**

```powershell
git grep -l "scripts\\\\" -- "*.bat" "*.ps1" "*.md" 2>$null
git grep -l "scripts/" -- "*.bat" "*.ps1" "*.md" 2>$null
```

Expected: no output (or only matches that are legitimately about the `scripts/` folder name in docs).
