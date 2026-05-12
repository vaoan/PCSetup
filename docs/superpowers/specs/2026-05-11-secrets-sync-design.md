# Secrets Sync — Design Spec

**Date:** 2026-05-11  
**Status:** Approved

## Overview

A mechanism for storing personal secrets (API keys, tokens, certificates) in GitHub repository secrets and pulling them down to a local `.secrets` file on demand. Used both to supply keys consumed by PCSetup scripts at runtime, and as a general personal vault on fresh Windows installs.

## Architecture

```
[GitHub Secrets store]
        │
        │  gh workflow run --field passphrase=<random>
        ▼
[sync-secrets.yml GitHub Actions workflow]
  1. Read named secrets from GitHub Secrets env
  2. Write to secrets-plain.txt
  3. openssl aes-256-cbc -pbkdf2 -in secrets-plain.txt -out secrets-encrypted.bin -pass env:PASSPHRASE
  4. Upload secrets-encrypted.bin as artifact (1-day retention)
  5. rm -f secrets-plain.txt
        │
        │  gh run download
        ▼
[scripts/sync-secrets.ps1 on local Windows machine]
  1. gh auth status check
  2. Generate 64-char random hex passphrase (RNGCryptoServiceProvider)
  3. gh workflow run ... --field passphrase=<hex>
  4. Poll gh run list until completed (5s interval, 120s timeout)
  5. gh run download → .secrets-download/secrets-encrypted.bin
  6. openssl.exe aes-256-cbc -d -pbkdf2 → .secrets-decrypted.tmp
  7. Move to .secrets, clean up temp files
        │
        ▼
[.secrets] (gitignored, KEY=VALUE format)
```

## Files

| File | Purpose |
|------|---------|
| `scripts/sync-secrets.ps1` | PowerShell sync script (auto-elevates to admin) |
| `sync-secrets.bat` | One-click wrapper that calls the PS1 |
| `.github/workflows/sync-secrets.yml` | Workflow that packages GitHub Secrets as an encrypted artifact |
| `.secrets.example` | Template documenting available keys and encode/decode helpers |
| `.gitignore` additions | `.secrets`, `.secrets-download/`, `.secrets-decrypted.tmp` |

## Secrets List

| Secret Name | Description |
|-------------|-------------|
| `FFXIVBE_PEM_B64` | Base64-encoded PEM cert/key for ffxivbe.org (used with cloudflared) |
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflared tunnel token for ffxivbe.org |
| `GITHUB_PAT` | Personal access token for authenticated git/gh operations |

Multi-line values (PEM files, SSH keys) are stored base64-encoded. Decode helpers:
```powershell
# Encode a PEM/key file before adding to GitHub Secrets:
[Convert]::ToBase64String([IO.File]::ReadAllBytes('ffxivbe.pem')) | clip

# Decode from .secrets to a file:
[IO.File]::WriteAllBytes('ffxivbe.pem', [Convert]::FromBase64String($env:FFXIVBE_PEM_B64))
```

## Dependencies

- `gh` CLI — installed by `2-setup-windows.bat`, must be authenticated (`gh auth login`)
- `openssl.exe` — bundled with Git for Windows (`C:\Program Files\Git\usr\bin\openssl.exe`), installed by `2-setup-windows.bat`
- No Node.js required

## Security Properties

- The passphrase is randomly generated per-run and never stored
- The encrypted artifact has 1-day retention on GitHub — deleted shortly after download
- The workflow deletes the unencrypted file in an `if: always()` cleanup step
- `.secrets` is gitignored and never committed
- The workflow requires `workflow_dispatch` (cannot be triggered without `gh auth`)

## Usage

```bat
sync-secrets.bat
```

Or directly:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\sync-secrets.ps1
```

To add a new secret:
1. Add the key/value in GitHub → Settings → Secrets and variables → Actions
2. Add the key to the `env:` block and the `run:` output section in `.github/workflows/sync-secrets.yml`
3. Add a placeholder line to `.secrets.example`
