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
    HostName pc.ffxivbe.org
    User Heiner
    ProxyCommand cloudflared access tcp --hostname %h --listener -
```

### Quick setup command:
```bash
cat >> ~/.ssh/config << 'EOF'

Host windows-remote
    HostName pc.ffxivbe.org
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

## Attaching to Claude Session (via VS Code Remote)

VS Code Remote terminals don't support tmux natively. Use this workaround:

### 1. Add MSYS2 Bash profile to VS Code

In VS Code (while connected to Windows):
- `Cmd+Shift+P` → "Preferences: Open Remote Settings (JSON)"
- Add:
```json
{
    "terminal.integrated.profiles.windows": {
        "MSYS2 Bash": {
            "path": "C:\\msys64\\usr\\bin\\bash.exe",
            "args": ["-l"]
        }
    }
}
```

### 2. Attach to Claude

1. Open terminal in VS Code (`Ctrl+~`)
2. Click dropdown next to `+` → Select **"MSYS2 Bash"**
3. Run:
```bash
script -c "tmux attach -t snd" /dev/null
```

### 3. Detach from Claude

Press `Ctrl+B`, then `D`

---

## Troubleshooting

### "Could not resolve hostname windows-remote"
SSH config is missing. Add the Host entry to `~/.ssh/config` (see above).

### "cloudflared: command not found"
```bash
brew install cloudflared
```

### "open terminal failed: not a terminal"
Use the `script` wrapper:
```bash
script -c "tmux attach -t snd" /dev/null
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
| Attach Claude | `script -c "tmux attach -t snd" /dev/null` |
| Detach Claude | `Ctrl+B`, then `D` |
