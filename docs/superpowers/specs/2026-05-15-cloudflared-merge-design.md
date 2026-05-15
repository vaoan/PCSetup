# Cloudflared Merge — Design Spec
Date: 2026-05-15

## Goal

Consolidate the standalone `Z:\Users\Heiner\Documents\Cloudflare\` project into PCSetup under a `cloudflared/` subfolder. Both projects serve the same physical machine, are run at the same moments (post-format recovery), and benefit from shared version control. The Cloudflare scripts are a manual, optional flow — not part of the numbered auto-install sequence.

## What Gets Moved

### Into `cloudflared/` (new folder at PCSetup root)

**From `Z:\Users\Heiner\Documents\Cloudflare\`** (everything except `.gitignore`, `CLAUDE.md`, `.claude/`):
- `.cloudflared/config.yml` — tunnel routing config (no secrets, safe to commit)
- `post-format-recovery.ps1` — master recovery script
- `install-tunnel.ps1`, `install-ssh-tunnel.ps1`, `install-claude-session.ps1`, `install-scheduled-tasks.ps1`
- `manage-tunnel.ps1`, `run-tunnel-hidden.ps1`
- `toggle-tunnel.bat`, `toggle-ssh-tunnel.bat`, `toggle-claude-session.bat`
- `create-shortcuts.ps1`, `start-claude-session.sh`, `claude-aliases.sh`
- `README.md`, `INSTALL.md`, `SETUP_GUIDE.md`, `MAC_CLIENT_SETUP.md`

**From `PCSetup/scripts/`** (all files — the folder is entirely cloudflared-related):
- `console-proxy.js`, `console-launcher.js`, `dashboard.js`, `git-proxy.js`, `ttyd-proxy.js`
- `setup-console-windows.ps1`, `setup-console-wsl.sh`, `start-console.ps1`, `sync-secrets.ps1`

**From `PCSetup/` root**:
- `start-console.bat`
- `sync-secrets.bat`

**From `PCSetup/uninstall/`**:
- `uninstall-console.bat`, `uninstall-console.ps1`

### Merged (not moved as files)

- `Cloudflare/CLAUDE.md` → content added as new section in `PCSetup/CLAUDE.md`
- `Cloudflare/.claude/commands/recovery.md` → `PCSetup/.claude/commands/recovery.md`
- `Cloudflare/.claude/skills/recovery.md` → `PCSetup/.claude/skills/recovery.md`

### Deleted

- `PCSetup/scripts/` folder (empty after the move)
- `Cloudflare/.gitignore` (superseded by PCSetup root `.gitignore`)
- `Cloudflare/CLAUDE.md` (content merged)
- `Cloudflare/.claude/` (content merged)

## Script Changes (path fixes only)

Two scripts reference hardcoded `scripts\` paths and need single-line updates:

| File | Old path | New path |
|---|---|---|
| `cloudflared/start-console.bat` | `%~dp0scripts\start-console.ps1` | `%~dp0start-console.ps1` |
| `cloudflared/sync-secrets.bat` | `%~dp0scripts\sync-secrets.ps1` | `%~dp0sync-secrets.ps1` |

The `recovery` command and skill also reference `cd "Z:\Users\Heiner\Documents\Cloudflare"` — update to `cd "Z:\Users\Heiner\Documents\PCSetup\cloudflared"`.

All other scripts use `%~dp0` or `$PSScriptRoot` and work correctly in any location without changes.

## CLAUDE.md Updates

1. Add new **"Cloudflare SSH & Remote Access"** section (from Cloudflare CLAUDE.md): covers SSH tunnel, web tunnel, Claude Code tmux sessions, tunnel IDs, scheduled tasks, Mac SSH setup, troubleshooting.
2. Update all `scripts\` path references in the existing **Web Console** section to `cloudflared\`.
3. Update the WSL first-time setup command: `scripts/setup-console-wsl.sh` → `cloudflared/setup-console-wsl.sh`.
4. Update the Console scripts table with new `cloudflared/` paths.
5. Update daily-use instructions: `start-console.bat` → `cloudflared\start-console.bat`.

## Folder State After Merge

```
PCSetup/
  cloudflared/
    .cloudflared/config.yml
    post-format-recovery.ps1        ← SSH/web tunnel master recovery
    install-tunnel.ps1
    install-ssh-tunnel.ps1
    install-claude-session.ps1
    install-scheduled-tasks.ps1
    manage-tunnel.ps1
    run-tunnel-hidden.ps1
    toggle-tunnel.bat
    toggle-ssh-tunnel.bat
    toggle-claude-session.bat
    create-shortcuts.ps1
    start-claude-session.sh
    claude-aliases.sh
    README.md / INSTALL.md / SETUP_GUIDE.md / MAC_CLIENT_SETUP.md
    console-proxy.js                ← web console services
    console-launcher.js
    dashboard.js
    git-proxy.js
    ttyd-proxy.js
    setup-console-windows.ps1
    setup-console-wsl.sh
    start-console.ps1
    start-console.bat               ← moved from root, path fixed
    sync-secrets.ps1
    sync-secrets.bat                ← moved from root, path fixed
    uninstall-console.ps1
    uninstall-console.bat
  scripts/                          ← DELETED (empty after move)
  uninstall/
    context-menu-terminal.bat       ← stays (not cloudflared)
    context-menu-take-ownership.bat ← stays (not cloudflared)
  .claude/
    commands/recovery.md            ← new, merged from Cloudflare project
    skills/recovery.md              ← new, merged from Cloudflare project
```

## What Does NOT Change

- Numbered setup scripts (1-11, 99) — untouched
- `optional/` folder — untouched
- `uninstall/context-menu-*.bat` — untouched
- `run-all.bat`, `remote-call.ps1`, `sync-secrets.bat` pattern — `sync-secrets.bat` moves but its behavior is identical
- `.gitignore` — no additions needed (Cloudflare's exclusions were only `*.log` and `.DS_Store`, already covered)

## Out of Scope

- Restructuring the Cloudflare scripts to follow PCSetup naming conventions
- Adding auto-elevation to Cloudflare scripts that lack it
- Any changes to numbered install scripts
