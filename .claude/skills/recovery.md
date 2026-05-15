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
