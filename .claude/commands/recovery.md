# Post-Format Recovery

Restore this PC's Cloudflare setup after a format.

Run the one entry point (it elevates itself, is unattended, and is safe to re-run):

```powershell
cloudflared\setup-cloudflare.bat   # from the repo root
```

It brings up the web tunnel (www/chat.ffxiv.be), the SSH tunnel (pc.ffxiv.be, with OpenSSH Server
and the Mac key), the web console (console/dev/code/ttyd/tools/git.ffxiv.be), the ConsoleHealth
watchdog, and then runs `verify-console.ps1`.

Afterwards report: the exit code (0 verified / 1 failures listed at the end / 2 reboot pending,
resumes at next sign-in), the tail of `%LOCALAPPDATA%\PCSetup\setup-cloudflare.log`, and any
failing rows in `%USERPROFILE%\.cloudflared\reports\latest.md`.

Prerequisite: `0-init-prereqs.bat` has run, so WSL and Ubuntu-24.04 exist.
