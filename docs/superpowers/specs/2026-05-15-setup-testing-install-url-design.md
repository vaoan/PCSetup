# Setup Testing & Install URL — Design Spec
Date: 2026-05-15

## Goal

Two things: (1) test both automatic setup flows without needing a blank machine, using Docker locally; (2) provide a one-liner install URL (`irm i.ffxivbe.org | iex`) served by a Cloudflare Worker.

## Flows Being Tested

**Flow 1 — Windows setup:** `remote-call.ps1` → `run-all.bat` → numbered scripts 1-11, 99. Success = all packages installed and verifiable.

**Flow 2 — Console services:** `cloudflared/post-format-recovery.ps1` + Node.js services. Success = all localhost URLs respond HTTP 200 and WSL services are active. Tunnels are NOT opened (would break working tunnels).

---

## A: Flow 1 — Local Docker Container Test

### Environment

Docker Windows Server Core container (`mcr.microsoft.com/windows/servercore:ltsc2022`). Provides a clean, reproducible environment without needing an empty machine. Run locally whenever you want to verify — no GitHub Actions.

### CI Skip Mechanism

`PCSETUP_CI=1` env var is set inside the container before running setup. Two scripts check for it and skip their body (printing `SKIP: CI mode`):

- `5-move-profile-folders.bat` — no user profile folders to relocate in a container
- `6-setup-games.bat` — Steam/Epic/XIVLauncher/game launchers need a desktop

All other scripts run normally.

### Files

**`Dockerfile.test`** — installs everything, then runs the Pester verification suite:
```dockerfile
FROM mcr.microsoft.com/windows/servercore:ltsc2022
SHELL ["powershell", "-Command", "$ErrorActionPreference='Stop';"]

RUN Install-Module -Name Pester -Force -SkipPublisherCheck

ENV PCSETUP_CI=1
RUN irm https://raw.githubusercontent.com/vaoan/PCSetup/refs/heads/main/remote-call.ps1 | iex

COPY tests/ C:/tests/
RUN Invoke-Pester C:/tests/setup.tests.ps1 -CI
```

Build accepts an optional `BRANCH` arg for testing a specific branch:
```dockerfile
ARG BRANCH=main
ENV BRANCH=${BRANCH}
RUN irm "https://raw.githubusercontent.com/vaoan/PCSetup/refs/heads/${env:BRANCH}/remote-call.ps1" | iex
```

**`test-local.bat`** — single-command test runner:
```batch
@echo off
docker build --build-arg BRANCH=main -f Dockerfile.test . && echo ALL TESTS PASSED || echo TESTS FAILED
```

**`tests/setup.tests.ps1`** — Pester suite with one `Describe` block per numbered script. Standalone: can also be run directly on the real machine after a format to verify a real install.

Structure:
```powershell
BeforeAll { $ErrorActionPreference = 'Stop' }

Describe "1-delete-node-modules" {
    # No persistent artifacts to assert — script runs and exits
}

Describe "2-setup-windows" {
    It "Chocolatey installed"    { choco --version | Should -Match '\d+\.\d+' }
    It "Git installed"           { git --version | Should -Match 'git version' }
    It "VS Code installed"       { Test-Path 'C:\Program Files\Microsoft VS Code\Code.exe' | Should -BeTrue }
    It "WezTerm installed"       { Test-Path 'C:\Program Files\WezTerm\wezterm.exe' | Should -BeTrue }
    It "GitHub CLI installed"    { gh --version | Should -Match 'gh version' }
    It "cloudflared installed"   { Test-Path 'C:\Program Files (x86)\cloudflared\cloudflared.exe' | Should -BeTrue }
    It "PowerShell 7 installed"  { Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe' | Should -BeTrue }
    It "7-Zip installed"         { Test-Path 'C:\Program Files\7-Zip\7z.exe' | Should -BeTrue }
    It "Python installed"        { python --version | Should -Match 'Python \d+\.\d+' }
    It "WezTerm config deployed" { Test-Path "$env:USERPROFILE\.wezterm.lua" | Should -BeTrue }
    # ... one It block per package/config in 2-setup-windows.bat
}

Describe "3-setup-node" {
    It "Node.js installed"  { node --version | Should -Match 'v\d+' }
    It "npm installed"      { npm --version | Should -Match '\d+\.\d+' }
}

Describe "4-fix-execution-policy" {
    It "RemoteSigned for CurrentUser" {
        (Get-ExecutionPolicy -Scope CurrentUser) | Should -Be 'RemoteSigned'
    }
}

Describe "5-move-profile-folders" {
    It "skipped in CI" -Skip:($env:PCSETUP_CI -eq '1') { }
}

Describe "6-setup-games" {
    It "skipped in CI" -Skip:($env:PCSETUP_CI -eq '1') { }
}

Describe "7-context-menu-terminal-install" {
    It "registry key exists" {
        Get-Item 'HKCR:\Directory\shell\OpenTerminalAsAdmin' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe "9-context-menu-take-ownership" {
    It "long paths enabled" {
        (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem').LongPathsEnabled | Should -Be 1
    }
}

Describe "10-setup-exclusions" {
    # Windows Defender service may not be active in Server Core containers — skip in CI
    It "Defender exclusion for XIVLauncher" -Skip:($env:PCSETUP_CI -eq '1') {
        (Get-MpPreference).ExclusionPath | Should -Contain "$env:APPDATA\XIVLauncher"
    }
}
```

### `remote-call.ps1` Change

Add optional `$Branch` parameter (default `"main"`) so specific branches can be tested:
```powershell
param([string]$Branch = "main")
$repoZipUrl = "https://github.com/vaoan/PCSetup/archive/refs/heads/$Branch.zip"
```

### Script CI Skip Changes

`5-move-profile-folders.bat` — add near top:
```batch
if "%PCSETUP_CI%"=="1" (
    echo SKIP: CI mode - skipping profile folder move
    exit /b 0
)
```

`6-setup-games.bat` — add near top:
```batch
if "%PCSETUP_CI%"=="1" (
    echo SKIP: CI mode - skipping games setup
    exit /b 0
)
```

---

## B: Flow 2 — Local Console URL Verifier

### `cloudflared/verify-console.ps1`

Standalone script run after `start-console.bat`. No tunnels, no Cloudflare — purely localhost.

**Checks performed (in order):**

1. **Port listening** — `Test-NetConnection -Port N -InformationLevel Quiet` for Windows-side ports: 7686, 7681, 7683, 7687
2. **HTTP response** — `Invoke-WebRequest` to each URL, asserts HTTP 200:
   - `http://localhost:7686` — dashboard
   - `http://localhost:7681` — console-proxy (sshwifty + panel)
   - `http://localhost:7683` — ttyd landing page
   - `http://localhost:7687` — git repo list
3. **WSL services** — `wsl systemctl is-active <service>` for: `ssh`, `code-server@root`, `ttyd-proxy`, `ttyd-persistent`, `ttyd-fresh`, `git-proxy`, `ungit`

**Output:** color-coded pass/fail table per row. Exits 0 if all pass, 1 if any fail.

```
Service               Port   HTTP   Status
─────────────────────────────────────────
dashboard             7686   200    PASS
console-proxy         7681   200    PASS
ttyd-proxy            7683   200    PASS
git-proxy             7687   200    PASS
WSL: ssh              —      —      PASS
WSL: code-server      —      —      PASS
WSL: ttyd-proxy       —      —      PASS
WSL: ttyd-persistent  —      —      PASS
WSL: ttyd-fresh       —      —      PASS
WSL: git-proxy        —      —      PASS
WSL: ungit            —      —      PASS
```

---

## C: `i.ffxivbe.org` Cloudflare Worker

### Purpose

Always-on install URL. Works on a fresh machine before any tunnel is running. Free tier (100k req/day, permanent).

### Install command

```powershell
irm i.ffxivbe.org | iex
```

(`irm` = `Invoke-RestMethod`, returns content as string — use this, not `iwr` which returns a WebResponseObject that breaks `iex` in PS5.1)

### Files

**`cloudflared/install-worker/index.js`:**
```javascript
export default {
  async fetch(request) {
    const url = 'https://raw.githubusercontent.com/vaoan/PCSetup/refs/heads/main/remote-call.ps1';
    const res = await fetch(url);
    const text = await res.text();
    return new Response(text, {
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-cache',
      },
    });
  }
};
```

**`cloudflared/install-worker/wrangler.toml`:**
```toml
name = "pcsetup-install"
main = "index.js"
compatibility_date = "2024-01-01"

routes = [{ pattern = "i.ffxivbe.org/*", zone_name = "ffxivbe.org" }]
```

### Deployment (one-time)

```bash
cd cloudflared/install-worker
npm install -g wrangler
wrangler login
wrangler deploy
```

Cloudflare auto-creates the DNS record. No further maintenance required — Worker always fetches `main` branch live from GitHub.

---

## File Changes Summary

| File | Action |
|---|---|
| `Dockerfile.test` | Create |
| `test-local.bat` | Create |
| `tests/setup.tests.ps1` | Create |
| `cloudflared/verify-console.ps1` | Create |
| `cloudflared/install-worker/index.js` | Create |
| `cloudflared/install-worker/wrangler.toml` | Create |
| `remote-call.ps1` | Modify — add `$Branch` param |
| `5-move-profile-folders.bat` | Modify — add CI skip |
| `6-setup-games.bat` | Modify — add CI skip |
| `CLAUDE.md` | Modify — document `irm i.ffxivbe.org | iex`, test commands, verify-console.ps1 |

## Prerequisites

- Docker Desktop with Windows containers mode enabled (right-click tray icon → "Switch to Windows containers")
- Wrangler CLI (`npm install -g wrangler`) + `wrangler login` for one-time Worker deploy

## Out of Scope

- GitHub Actions workflows (none added beyond existing secrets sync)
- Modifying any other numbered scripts
- Testing the cloudflared tunnel connection itself (only local services are tested in Flow 2)
- Automated scheduling of the Docker test
