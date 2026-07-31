# Mac Client Setup

Configuration needed on the Mac to connect to the Windows PC via Cloudflare Tunnel.

---

## Prerequisites

### Install cloudflared
```bash
brew install cloudflared
```

---

## SSH Config

Add to `~/.ssh/config`:

```
Host windows-remote
    HostName pc.ffxiv.be
    User Heiner
    ProxyCommand cloudflared access tcp --hostname %h --listener -
```

### Quick setup command:
```bash
cat >> ~/.ssh/config << 'EOF'

Host windows-remote
    HostName pc.ffxiv.be
    User Heiner
    ProxyCommand cloudflared access tcp --hostname %h --listener -
EOF
```

---

## Connecting

### Basic SSH
```bash
ssh windows-remote
```

### VS Code Remote SSH
1. Install "Remote - SSH" extension in VS Code
2. `Cmd+Shift+P` → "Remote-SSH: Connect to Host..."
3. Select `windows-remote`

---

## Persistent terminals

The MSYS2/tmux session feature was removed — MSYS2 is not installed on this machine.
Use the web console instead, which runs tmux **inside WSL**:

- **https://ttyd.ffxiv.be** → *Persistent* — phone-friendly terminal, tmux session `phone`
- **https://console.ffxiv.be** → quick-connect presets, each attaching to its own tmux session
- **https://code.ffxiv.be** — VS Code in the browser, no local client needed

Detach from tmux with `Ctrl+B`, then `D`.

---

## Troubleshooting

### "Could not resolve hostname windows-remote"
SSH config is missing. Add the Host entry to `~/.ssh/config` (see above).

### "cloudflared: command not found"
```bash
brew install cloudflared
```

### "open terminal failed: not a terminal"
Wrap the tmux attach in `script` so it gets a PTY:
```bash
script -c "tmux attach -t <session>" /dev/null
```

### Connection refused / timeout
Check that the SSH tunnel is running on Windows:
- The `ssh-tunnel` scheduled task should be running
- Toggle via "Toggle SSH Tunnel" desktop shortcut on Windows

---

## Summary

| What | Command/Location |
|------|------------------|
| Install cloudflared | `brew install cloudflared` |
| SSH config | `~/.ssh/config` |
| Connect SSH | `ssh windows-remote` |
| VS Code connect | Remote-SSH → `windows-remote` |
| Persistent terminal | https://ttyd.ffxiv.be → *Persistent* |
| Browser VS Code | https://code.ffxiv.be |
| Detach tmux | `Ctrl+B`, then `D` |
