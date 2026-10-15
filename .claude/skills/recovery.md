# Skill: Post-Format Recovery

Restore this PC's Cloudflare setup after a format: web tunnel, SSH tunnel, web console, watchdog.

## Trigger

Use when user says things like:
- "I want to setup all the configs I had before"
- "I formatted my PC, restore everything"
- "Run recovery"
- "Get my cloudflare setup online"

## The one command

There is exactly one entry point. Do not run the building blocks one by one.

```powershell
cloudflared\setup-cloudflare.bat   # from the repo root
```

It elevates, then in order: checks `.secrets` (syncs from GitHub only if keys are missing),
installs the official cloudflared MSI, runs `install-tunnel.ps1` (www/chat), `install-ssh-tunnel.ps1`
(pc + OpenSSH + Mac key), checks Ubuntu-24.04 starts, runs `setup-console-wsl.sh`,
`setup-console-windows.ps1` (dev-console tunnel, DNS, Access gating, tasks), registers the
`ConsoleHealth` watchdog, and finishes with `verify-console.ps1`. Safe to re-run; re-running is
also the repair.

Prerequisite: `0-init-prereqs.bat` has run (WSL + Ubuntu-24.04 exist). If WSL still needs a
reboot, the setup says "REBOOT NOW" (exit 2) and runs itself again at the next sign-in.

## Reading the result

- Exit 0: everything verified. Exit 1: the failures are listed at the end. Exit 2: reboot pending.
- Log: `%LOCALAPPDATA%\PCSetup\setup-cloudflare.log`
- Verification report: `%USERPROFILE%\.cloudflared\reports\latest.md`

## Notes

- `www.ffxiv.be` answers 502 until the local web stack on 7542 is running (not managed here), and
  `chat.ffxiv.be` only while the game with the ChatAnywhere plugin is open. That is expected.
- Cloudflare-side config (DNS, Zero Trust, WAF) persists across formats; the setup re-applies what
  it owns idempotently.
- Details and history: `CLAUDE.md`, "Post-Format Recovery".
