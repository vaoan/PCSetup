# Project Instructions

## Script Requirements

When creating or editing any script file (`.bat`, `.cmd`, `.ps1`), ALWAYS include auto-elevation to Administrator at the top.

### For .bat and .cmd files:
```batch
@echo off
:: Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
```

### For .ps1 files:
```powershell
# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
```

## Checklist
- [x] Every script must auto-elevate to admin
- [x] Scripts must be unattended (no pauses) - they should close automatically when finished
- [x] Use Chocolatey, winget, and npm for package installations
- [x] **`.v` is auto-updated** by the pre-commit git hook — no manual action needed

## Script Conventions (all `.bat` setup scripts)

Every numbered script (plus `optional/setup-work.bat`) follows the same shape. When editing or
adding one, keep all five:

1. **`set "PSModulePath="` inside `setlocal`, before invoking `powershell`.** The `.bat` files spawn
   `powershell.exe`, which inherits the caller's environment — and WezTerm's default shell is PS7.
   Windows PowerShell then finds the Core-only `Microsoft.PowerShell.Utility`/`.Security`/`.Archive`
   under the PS7 module dirs *first* and refuses to load them, so `Get-FileHash`,
   `Set-ExecutionPolicy`, `Invoke-WebRequest`, `Expand-Archive`, `Add-MpPreference` and
   `Get-AppxPackage` all vanish. Symptom: the script only fails when launched from a pwsh terminal.
2. **Redirection first on every generated line: `>>"%SCRIPT%" echo ...`.** Written the other way
   round, a line ending in a *standalone* digit is parsed as a file-handle redirect — that silently
   ate `$maxAttempts = 3` in `3-setup-node.bat`. Only a standalone digit triggers it (`-bor 3072>>`
   is fine because `2` follows `7`, not a space).
3. **Check → act → verify → record.** Ask the package manager whether the thing is installed, act
   only if not, then *re-check* rather than trusting an exit code. Failures go into a `$failures`
   list and the script exits non-zero listing them.
4. **Never `throw` past a single item.** One failed download must not abort the rest of the script.
5. **Resolve paths, don't hardcode them.** Scoop moved Git, Steam and friends out of
   `C:\Program Files\...`.

### CMD escaping inside generated lines — the rules that actually apply

These bit repeatedly and are not intuitive:

| Situation | Behaviour |
|---|---|
| `^` before `&` `|` `<` `>` **outside** double quotes | escape is consumed → literal character. Correct. |
| `^` **inside** double quotes | *not* consumed — `"Settings ^> Apps"` prints a literal caret, and `"... ^&^& ..."` stores literal carets |
| `>` `&` inside double quotes | already literal; no escape needed |
| `%` | always needs `%%` (`%%V` to emit `%V`) |
| standalone digit before `>`/`>>` | parsed as a file handle |

Quote **parity** decides which case applies, and it differs line by line — the same `^&^&` came
through intact in one command string and as literal carets in the next. When a value must contain
`&` or `"`, build it in PowerShell (`([char]38).ToString() * 2`, `([char]34).ToString()`) so no
special character ever reaches CMD's parser.

> **Registry values must not be written from the batch layer.** In `9-context-menu-take-ownership.bat`
> the `&&` in the Take Ownership command fell outside the quotes at CMD level, so the line was split
> and `reg.exe` stored a **truncated** command — Take Ownership ran `takeown` and never `icacls`,
> leaving permissions half-applied. Verified against the live registry: the installed values
> contained no `icacls` at all. `reg.exe` called from PowerShell is no better (it drops empty-string
> args, so `/d ""` for `HasLUAShield` fails with "Invalid syntax", and it mangles embedded quotes),
> and the PowerShell registry provider treats the file-class key named `*` as a wildcard and hangs
> enumerating HKCR. Use the .NET API — `[Microsoft.Win32.Registry]::ClassesRoot.CreateSubKey(...)`
> and `.SetValue(...)` take the string verbatim with no parser in between.

> **The generated script runs under Windows PowerShell 5.1, so test it there — not in pwsh.**
> `Group-Object -Property Name` over an array of **hashtables** returns one group per distinct name
> in PowerShell 7, but a **single** group in 5.1 (it does not resolve hashtable keys as properties).
> In `5-move-profile-folders.bat` that meant the move loop processed only Desktop while the registry
> below repointed all 11 folders — files left behind on the old drive with nothing pointing at them.
> It looks correct when checked by hand in pwsh. Dedupe with an explicit `$seen = @{}` set instead.

### Per-script notes from the audit

- **`4-fix-execution-policy.bat`** — verifies the value stuck *and* reports the **effective** policy,
  since a Group Policy scope outranks CurrentUser and the write can succeed while the effective
  policy stays Restricted. Note `2-setup-windows.bat` sets CurrentUser/LocalMachine to `Bypass` and
  this script then sets CurrentUser to `RemoteSigned` — they intentionally disagree, and script 4
  runs later so `RemoteSigned` wins for CurrentUser.
- **`7-context-menu-terminal-install.bat`** — Git Bash and WezTerm paths are resolved at runtime
  (`scoop prefix`, then Program Files). The old hardcoded `C:\Program Files\Git\git-bash.exe` is
  dead on any machine where Scoop is the only Git. Entries are read back after writing.
- **`8-fix-steam-icons.bat`** — was a single opaque `-EncodedCommand` base64 blob; now generated as
  readable PowerShell. Steam is resolved via `scoop prefix` / Program Files / `HKCU\Software\Valve\Steam`,
  and Explorer is only restarted if an icon actually changed.
- **`10-setup-exclusions.bat`** — `Install-Module PS-SFTA` **never worked**: PS-SFTA is a GitHub repo
  containing `SFTA.ps1`, not a Gallery module, so it always failed with "No match was found". It now
  downloads the real script. Separately, Windows 11 hash-protects the `UserChoice` keys and blocks
  the default-browser change both elevated and de-elevated (`Write Reg Protocol UserChoice FAILED`),
  so that step is a **warning, not a failure** — no script can set it; use Settings.
- **`11-setup-win11debloat.bat`** / **`99-remove-windows-ai.bat`** — the remote script is downloaded
  to a file and size-checked before running, instead of piping `irm` straight into a scriptblock
  (which would execute a captive-portal page or a 404 body). Both count the target packages before
  and after and report what survived.
- **`1-delete-node-modules.bat`** — reports found/deleted/failed and GB reclaimed, and verifies each
  folder is actually gone; `-ErrorAction SilentlyContinue` used to hide locked folders entirely.
  Also prunes the **pnpm store** and clears the **pnpm metadata cache** afterwards, both counted
  into the reclaimed total. This matters: pnpm keeps packages in a content-addressable store
  *outside* `node_modules` (the `node_modules/.pnpm` folders are only hardlinks into it), so
  deleting `node_modules` alone reclaims almost nothing on a pnpm machine. The store path comes from
  `pnpm store path` rather than being assumed — on this machine it is `Z:\.pnpm-store\v11`, not
  under `%LOCALAPPDATA%`. `pnpm store prune` is used rather than deleting the store directory: it
  only drops packages no longer referenced by any project. Note prune also reports "Removed all
  cached metadata files", so the metadata-cache step is usually a no-op backstop for older pnpm.
  `pnpm config get cacheDir` prints the literal string `undefined` when unset, which is treated as
  unset rather than as a relative path.

## Naming Convention

All scripts use **kebab-case** naming: `[N-]action-target.ext`

- Numbered prefix (`1-`, `2-`, etc.) indicates execution order after fresh Windows install
- Utility scripts have no number prefix (run as needed)

## Quick Install

One-liner that works on a fresh Windows machine before any setup is run:

```powershell
irm i.ffxiv.be | iex
```

`irm` (Invoke-RestMethod) returns the script as a plain string, which `iex` executes directly. Do NOT use `iwr` (Invoke-WebRequest) — it returns a WebResponseObject that breaks `iex` in PS5.1.

The URL is served by a Cloudflare Worker (`cloudflared/install-worker/`) that proxies `remote-call.ps1` from GitHub raw. Free tier (100k req/day). To deploy the worker one-time: `cd cloudflared/install-worker && wrangler deploy`.

## Run All Scripts

### remote-call.ps1
Downloads the repo ZIP into memory, materializes the top-level `.bat`, `.config`, and `.v` files **plus `sources\*.ps1` / `sources\*.reg`** into a temporary folder under `%TEMP%`, writes a source manifest there, executes `run-all.bat` from that isolated temp workspace, and cleans up afterward. Use this when you want the latest remote setup flow without depending on the current local repo folder.

> **Anything a numbered script reads at runtime must be on the allowlist**, or the temp workspace
> is missing it and the script fails in a way that looks like a broken download. `sources\` is
> there because `0-init-prereqs.bat` runs `sources\init-prereqs.ps1`. Add a new folder by adding it
> to `$allowedSubdirectories` (one level deep only — deeper paths and anything containing `..` are
> still rejected).

### run-all.bat
Master script that executes all numbered setup scripts in sequential order. Automatically finds and runs any script matching `[N]-*.bat` pattern, sorted by number.

**Staging:** before running anything it robocopies the top-level `*.bat`, `*.config`, `.v` **and the
whole `sources\` folder** into a fresh `%TEMP%\PCSetup-run-<guid>` and executes from there.

> **`sources\` must be staged.** `0-init-prereqs.bat` runs `%~dp0sources\init-prereqs.ps1`, so a
> top-level-only staging copy made script 0 abort with `ERROR: Missing prerequisite script` — and
> that is the script that installs Scoop and Java, so every later script failed too. If you add a
> script that reads a repo file, stage that file as well.

> **The enumeration filters on a leading digit, and that filter is load-bearing.** `*-*.bat` on its
> own also matches the staged `run-all.bat` (which then calls *itself*, recursively) and
> `test-local.bat` (which launches the Docker suite in the middle of a setup run). Worse, both
> sorted to the **front**: `[int]'run'` throws inside the `Sort-Object` scriptblock, and
> `Sort-Object` emits the item anyway rather than dropping it, so the error is only a red herring
> in the log. The guard is `Where-Object { [char]::IsDigit($_.BaseName[0]) }` — deliberately not a
> `'^\d+-'` regex, because a caret inside a `for /f` backtick block is eaten by CMD as an escape
> character before PowerShell ever sees it.

**Auto-download & version check:** On each run, `run-all.bat` does the following (no Git required — uses PowerShell's `Invoke-WebRequest` only):
- If no numbered scripts are found → downloads the full repo ZIP from GitHub, extracts it, copies all files into the **same folder as `run-all.bat`**, then runs.
- If scripts exist → fetches `.v` from GitHub raw and compares to local `.v`. If remote version is higher, re-downloads and updates all scripts. If offline or same version, runs as-is.

**To release an update:** update `.v` with the current UTC ISO 8601 timestamp and push. Users will auto-update next time they run `run-all.bat`. Comparison uses PowerShell's `-gt` string operator (not CMD's `GTR`) — ISO 8601 strings are lexicographically sortable so this works correctly.

> **Important for editing:** When writing the download logic, use a single inline PowerShell `-Command` string — do NOT use grouped `echo` blocks or `^` line continuations to build a temp `.ps1` file. Parentheses in echoed PS code (`if (...)`, `try {`) break CMD's block parser. The inline approach avoids all quoting issues and has no moving parts.
>
> The `Copy-Item` call uses `-Exclude 'run-all.bat'` to skip overwriting the currently running script. Without this, CMD's internal file position pointer gets corrupted when the file is replaced mid-execution, causing execution to silently stop. By excluding it, the script falls through naturally to `:run_scripts` after the download. Do NOT use `start "" cmd /c` to relaunch — `start` from an elevated process does not inherit elevation (uses ShellExecute, not CreateProcess), which triggers UAC again and causes the window to flash and close.

### cloudflared/sync-secrets.bat
Pulls secrets from GitHub repository secrets to a local `.secrets` file (gitignored). Reads a decryption passphrase from `%USERPROFILE%\.pcsetup-sync-passphrase`, triggers `.github/workflows/sync-secrets.yml` via `gh workflow run`, waits for the workflow to complete, downloads the AES-256-CBC encrypted artifact, decrypts it with `openssl.exe` (bundled with Git for Windows), and writes `.secrets`.

**Prerequisites:** `gh auth login` must have been run. Git for Windows must be installed. `%USERPROFILE%\.pcsetup-sync-passphrase` must exist (see `.secrets.example` first-time setup instructions).

To add a new secret:
1. Add it in GitHub → Settings → Secrets and variables → Actions
2. Add it to the `env:` block and `run:` output section in `.github/workflows/sync-secrets.yml`
3. Add a placeholder line to `.secrets.example`

## Testing

### Flow 1 — Windows setup (Docker)

Runs the full install inside a Windows Server Core container and verifies all packages with Pester. Requires Docker Desktop in Windows containers mode.

```batch
test-local.bat            # test against main branch
test-local.bat my-branch  # test against a specific branch
```

The `PCSETUP_CI=1` env var is set inside the container. Scripts 5 and 6 detect it and skip their body (profile folder relocation and game launchers don't work in containers).

> **Assert against the package manager that actually installs the app.** The WinRAR/VLC/Streamlabs
> checks hardcoded Chocolatey-era `C:\Program Files\...` paths and were never updated when the repo
> moved to Scoop, so they were permanently red — which is exactly why VLC being genuinely
> uninstalled went unnoticed. They now use `Test-ScoopPackageInstalled`, which is `scoop prefix`
> based for the same reason the setup scripts are: `scoop list` still lists a failed install.

### Flow 2 — Console service verifier

Run after `cloudflared\start-console.bat` to verify all local services are healthy without opening Cloudflare tunnels:

```powershell
cloudflared\verify-console.ps1
```

Checks port connectivity, HTTP 200 responses, and WSL systemd service status. Exits 0 if all pass, 1 if any fail.

### Flow 3 — Recovery contract tests

```powershell
tests\run-tests.ps1 -Path tests\recovery.tests.ps1
```

The post-format recovery scripts **cannot be executed in a test** — they create Cloudflare
tunnels and DNS records, register scheduled tasks and install MSIs. So this suite asserts the
invariants instead. Every check corresponds to a defect that actually shipped:

| Check | Bug it would have caught |
|---|---|
| Tunnel names exist in the account | recovery hunted for `dev-tunnel`; the tunnel is `dev-console`, so provisioning silently skipped |
| Web origin port agrees everywhere | `7542` in two files, `9000` in two others |
| Hostname vars are zone roots | `$webHostname = "www.ffxiv.be"` composed into `www.www.ffxiv.be` |
| No retired domain in executable lines | `Dockerfile.test` still fetched `i.ffxivbe.org` — missed by an extension-filtered sweep, so this check reads extensionless files too |
| Deployed copies are drift-checked | launcher PWA assets were deployed but unverified, serving a stale icon |
| Referenced scripts exist | deleting a script left callers pointing at nothing |
| Every tunnelled hostname is Access-gated | a hostname with DNS + ingress but no Access app is public |

Needs `CLOUDFLARE_ACCOUNT_API_TOKEN` in `.secrets` for the two live-contract checks; they skip
without it. All other checks are offline.

> **Gotcha:** the `-Skip:` condition is evaluated at Pester **discovery** time, before `BeforeAll`
> runs. A flag set inside `BeforeAll` is still `$null` then, so the gated tests skip silently and
> the run still looks green. The token probe therefore sits at script scope, not in `BeforeAll`.

> **Verify the tests, not just the code.** These were validated by reintroducing each of the five
> real bugs one at a time and confirming the matching test failed, then reverting. A suite that
> has only ever been green is not evidence of anything.

## Setup Scripts (Run in Order)

### 0-init-prereqs.bat
Runs `sources\init-prereqs.ps1`. Lays down the toolchain every later script assumes: **portable git
and gh first**, then Chocolatey, Scoop + buckets, 7-Zip, Python, VC++ redistributables, .NET
runtimes, Temurin JDK 17/8, nvm + Node LTS, and the WSL2 prerequisites.

> **git is bootstrapped from a zip before any package manager exists, and the order is the whole
> point.** Scoop cannot function without git — `scoop update` and every `scoop bucket add` are git
> operations. The original order ran `scoop update` and only *then* installed git *through Scoop*,
> so on a genuinely fresh machine the run died at `Scoop update failed` before ever reaching the
> line that would have fixed it. Now MinGit (`git-for-windows/git`) and gh (`cli/cli`) are
> extracted from their official release zips into `%ProgramData%\PCSetup\bootstrap` — no
> Chocolatey, no Scoop, no MSI, no installer. Only git is strictly required by Scoop; gh rides
> along because `sync-secrets` and script 3 need it and it is the same two lines.

> **Bootstrap PATH entries are appended last, never prepended.** Scoop installs its own managed
> `git`/`gh` later, and those shims have to win over the portable copies. `Refresh-SetupEnvironment`
> rebuilds `$env:Path` from scratch on every call, so it re-appends `$script:BootstrapPaths` at the
> end — drop that and the bootstrap disappears from PATH mid-run, taking `scoop bucket add` with it.

> The bootstrap deliberately uses `[Net.WebClient]` + `[IO.Compression.ZipFile]` instead of
> `Invoke-WebRequest` + `Expand-Archive`. Those cmdlets live in `Microsoft.PowerShell.Utility` /
> `.Archive`, which an inherited PS7 `PSModulePath` can make unloadable — the same failure this
> script already works around with `Ensure-GetFileHashCommand`, and which `0-init-prereqs.bat` now
> prevents outright with `set "PSModulePath="`.

### 1-delete-node-modules.bat
Recursively finds and deletes all `node_modules` folders on all fixed hard drives. Useful for reclaiming disk space.

### 2-setup-windows.bat
Main Windows application setup. **Chocolatey, Scoop, 7-Zip, Python, Git, gh, VC++ redistributables
and the .NET runtimes come from `0-init-prereqs.bat`**, not from here. This script installs the
applications, deploys the WezTerm config + PowerShell profile block, and sets up WSL + Claude Code.

Apps are declared in two tables — `$scoopApps` and `$wingetApps` (a row is `Id`, `Name`, and
optional `Source` for msstore-only packages). Every entry is verified after install and anything
that failed is listed at the end, with the script exiting non-zero.

**Scoop:** Chrome, Discord, WinRAR, VLC, Spotify, HandBrake, ShareX, Notepad++, Telegram, qBittorrent, Cloudflared, Firefox, PuTTY, WinSCP, BleachBit, WizTree, EarTrumpet, Sourcetree, VS Code, GitHub Desktop, OnTopReplica, OnlyOffice, Streamlabs OBS, Clink (autorun-enabled), Bulk Crap Uninstaller, JetBrainsMono Nerd Font
**winget:** K-Lite Codec Pack Mega, pCloud Drive, Remote Desktop Manager, Cloudflare WARP, AdGuard, ProtonVPN, DirectX Runtime, Winamp, 2FAGuard, Claude Desktop, Kiro, Rufus, PowerShell 7, WezTerm, NVIDIA App (msstore)
**Direct download:** Discord Canary, Chrome Remote Desktop, Mudfish, IceDrive (+ Dokan)
**Other:** Claude Code (Windows and inside WSL), WSL itself

> **A failed Scoop install is sticky, and detection must not use `scoop list`.** Scoop keeps a
> failed app in `scoop list` forever with an empty `Version` and `Info='Install failed'`, so the old
> `$installed -match "(?m)^\s*$package\s+"` check matched it and printed *"already installed,
> skipping"* on every subsequent run. **VLC sat uninstalled for weeks because of this** — the one
> app that had failed was the one app the script would never retry. Detection is now
> `scoop prefix <app>`, which resolves the `current` junction that a failed install does not have;
> `scoop install` then purges the broken copy and retries on its own.

> **A direct-installer failure must not `throw`.** `Install-DirectExe`/`Install-DirectMsi` and the
> Mudfish/IceDrive blocks used to throw on failure, which aborted the entire script — one bad
> download meant *everything after it* (2FAGuard, Claude Desktop, Kiro, Rufus, PowerShell 7,
> WezTerm, the config deployment, Claude Code and the whole WSL section) silently never ran. They
> now record the failure and continue.

> **Never trust winget's exit code.** It returns nonzero for benign states such as "no applicable
> upgrade found", so `return ($LASTEXITCODE -eq 0)` reported false failures. Installs are confirmed
> with `winget list --id <id> -e` instead.

> **Two entries were dead and failing silently:** `winamp` was removed from every Scoop bucket
> upstream (now installed as `Winamp.Winamp` via winget), and `Nvidia.NVIDIAApp` has never been a
> valid winget ID — the NVIDIA App is msstore-only, so it uses `XP8CLZL93F5Z4P` with
> `--source msstore`.

Also deploys `%USERPROFILE%\.wezterm.lua` (GPU-accelerated config with Catppuccin Mocha theme, multi-shell profiles, Ctrl+Shift keybindings for tabs/panes) and appends a WezTerm bell-notification block to `$PROFILE` (fires a Windows toast + tab flash when a command takes ≥ 10 seconds).

### 3-setup-node.bat
Installs the npm-based CLI tools. **nvm and Node LTS are installed by `0-init-prereqs.bat`**, not
here — this script requires them and exits 1 with a pointer to script 0 if they are missing. Each
package is retried up to 3 times and verified by resolving its shim afterwards; the script exits
non-zero listing anything that failed.

**Installed packages:** OpenAI Codex CLI (`@openai/codex`), GitHub Copilot CLI (`@github/copilot`)

Packages are declared in one `$npmPackages` table — add a CLI by adding a row (`Package`, `Name`,
`Command`). The installed-check lives *inside* `Install-NpmGlobalPackage`, mirroring
`Install-ScoopPackage` in `sources\init-prereqs.ps1`, so every row is guaranteed to end up
installed or reported as a failure; no call site can quietly opt a package out.

> **There is deliberately no gh-copilot extension step, and it cannot be added back.** The
> `github/gh-copilot` repo was archived in October 2025, and modern `gh` ships a built-in
> `gh copilot` command — so `gh extension install github/gh-copilot` now aborts with
> `"copilot" matches the name of a built-in command or alias` (exit 1) no matter how the machine is
> authenticated. `gh copilot` shells out to the standalone Copilot CLI that this script installs,
> so the capability is fully covered. The old branch could only ever fail or be skipped.

> **Redirection goes first on every generated line: `>>"%SCRIPT%" echo ...`.** Written the other
> way round, a line ending in a **standalone digit** is read by CMD as a file-handle redirect.
> `echo     $maxAttempts = 3>>"%SCRIPT%"` meant "append handle 3 to the file" — the `3` was eaten
> and `$maxAttempts = ` went to the console instead of the script. `$maxAttempts` was then `$null`,
> `1 -le $null` is false, so the retry loop **never ran a single attempt**: neither CLI was ever
> installed, every run printed `installation failed after  attempts` (note the missing number), and
> the script still exited 0. Only a *standalone* digit triggers this — the neighbouring
> `-bor 3072>>"%SCRIPT%"` is fine because `2` is preceded by `7`, not a space.

> **Script 3 no longer needs `gh` at all**, now that the extension step is gone — it only reports
> that `gh copilot` is built in. Nothing here depends on `gh auth login` having been run.

### 4-fix-execution-policy.bat
Sets PowerShell execution policy to `RemoteSigned` for the current user, allowing scripts like Claude Code to run in PowerShell.

### 5-move-profile-folders.bat
Relocates Windows user profile folders (Desktop, Documents, Music, Pictures, Videos, etc.) to a different drive (default: Z:). Updates registry entries and optionally moves existing files. Run early before accumulating files. Note: Downloads folder is handled separately in `optional/move-downloads-folder.bat`.

### 6-setup-games.bat
Game-related applications setup. Installs gaming platforms, launchers, and tools. Every item is
verified after install (`scoop prefix`, `winget list`, or a known install path) rather than trusted
to have worked, and the script exits non-zero listing whatever failed.

**Installed packages:** Steam, Epic Games Launcher, Prism Launcher, CurseForge (via winget), Temurin JDK 17/8, XIVLauncher (Custom FFXIV Launcher), TexTools (FFXIV Modding Tool), FFLogs Uploader

> **The `games` Scoop bucket is added here, not by `0-init-prereqs.bat`.** `steam`,
> `epic-games-launcher`, and `prismlauncher` live only in `games`; without it Scoop cannot resolve
> them and the installs silently no-op. `steam` also exists in `versions`, so all three are
> installed bucket-qualified (`games/steam`) — an unqualified ambiguous name lets Scoop pick a
> bucket for you.

> **Never let Windows PowerShell inherit PowerShell 7's `PSModulePath`.** The `.bat` files spawn
> `powershell.exe`, which inherits the caller's environment — and WezTerm's default shell is PS7.
> PS5 then finds the Core-only `Microsoft.PowerShell.Utility`/`.Security` under the PS7 module dirs
> *first* and refuses to load them, so `Get-FileHash` and `Set-ExecutionPolicy` vanish. Every Scoop
> install then dies with the deeply unhelpful `URL <...> is not valid` (that is Scoop failing to
> hash the download), and the script still reports success. `set "PSModulePath="` before the
> `powershell` call makes it rebuild the correct default. Symptom to watch for: installs fail only
> when the script is launched from a pwsh terminal, and work when launched from Explorer or cmd.

> **TexTools ships zip-only since v3.1.1.3b.** The `Install_TexTools.exe` release asset is gone, so
> the script prefers the installer if present and otherwise extracts the portable zip (no top-level
> folder) to `%LOCALAPPDATA%\TexTools`. The old code piped an empty URL into curl and then tried to
> run a file that was never downloaded.

> **FFLogs installs to `%LOCALAPPDATA%\Programs\FF Logs Uploader`** — not `\FFLogs` or
> `\Programs\fflogs`. Checking only those two meant the 178 MB installer was re-downloaded and
> re-run on every single invocation.

### 7-context-menu-terminal-install.bat
Enables the classic Windows context menu (always shows full menu instead of Windows 11's simplified version) and adds "Open in Terminal as Administrator", "Open in PowerShell as Administrator", "Open Git Bash here as Administrator", and "Open in WezTerm as Administrator" to the context menu for directories, directory backgrounds, and drives. Also removes the default non-admin "Open WezTerm here" entries added by WezTerm's own installer (so only the admin entry appears).

### 8-fix-steam-icons.bat
Fixes broken Steam game shortcut icons on the desktop. Scans for Steam URL shortcuts, downloads missing icons from Steam CDN, and clears the Windows icon cache. Run after Steam games are installed and shortcuts created.

### 9-context-menu-take-ownership.bat
Enables Windows long paths support and adds "Take Ownership" to the context menu for files, folders, and drives. Useful for fixing permission issues on files/folders you can't access.

### 10-setup-exclusions.bat
Adds Windows Security (Defender) folder exclusions to prevent false positives and DLL blocking for trusted applications. Run after installing applications that need exclusions.

**Exclusions added:** XIVLauncher/Dalamud (`%APPDATA%\XIVLauncher`), FINAL FANTASY XIV game folder, WezTerm (`%PROGRAMFILES%\WezTerm`)

### WezTerm configuration

WezTerm is installed by `2-setup-windows.bat` via winget to `%PROGRAMFILES%\WezTerm\` (system-wide, since setup runs as admin). Its config lives at `%USERPROFILE%\.wezterm.lua` and is deployed by the same script (only if the file doesn't already exist).

**Font:** Uses WezTerm's bundled `JetBrains Mono` by default (no install needed). Automatically switches to `JetBrainsMono Nerd Font` once `choco install nerd-fonts-jetbrainsmono` has run — just change the font line in `.wezterm.lua`.

**Default shell:** Auto-detects PS7 at `C:\Program Files\PowerShell\7\pwsh.exe`; falls back to `powershell.exe` (PS5) if PS7 is not installed.

**Profiles available** (launch menu via `Ctrl+Shift+L` or right-click the `+` button):
- PowerShell 7 (if installed, otherwise PS5 is used as default)
- PowerShell 5
- CMD
- Git Bash
- WSL

**Key bindings:**

| Shortcut | Action |
|---|---|
| `Ctrl+Shift+T` | New tab |
| `Ctrl+Shift+W` | Close tab |
| `Ctrl+Shift+D` | Split pane horizontal |
| `Ctrl+Shift+E` | Split pane vertical |
| `Ctrl+Shift+Arrow` | Navigate between panes |

**Notifications:** The PowerShell `$PROFILE` is modified by `2-setup-windows.bat` to ring the terminal bell and show a Windows toast notification whenever a command takes ≥ 10 seconds to complete. WezTerm flashes the tab bar in response to the bell. To modify the threshold, edit `$PROFILE` and change `10` in `$elapsed.TotalSeconds -ge 10`.

To manually edit the WezTerm config: `code $env:USERPROFILE\.wezterm.lua` or ask Claude Code to modify it.

### 11-setup-win11debloat.bat
Runs Win11Debloat in unattended mode to apply default tweaks and remove common optional apps (OneDrive, Phone Link, Camera, Photos, Media Player, Remote Desktop, Whiteboard). It also runs OneDrive's built-in uninstaller, removes its startup entry, disables reinstallation via policy, and deletes leftover local OneDrive folders.

### 99-remove-windows-ai.bat
Removes Windows AI features (Copilot, Recall, etc.) using the RemoveWindowsAI script from zoicware.

## Optional Scripts (`optional/`)

### optional/setup-work.bat
Work environment setup. Installs work-related applications via Chocolatey and Winget.

**Installed packages:** Slack, AWS CLI, Linear, Figma

### optional/move-downloads-folder.bat
Relocates the Windows Downloads folder to a different drive (default: Z:). Separated from the main profile folders script for users who prefer Downloads on the system drive.

### optional/setup-start-menu.bat
Backup and restore tool for Windows 11 Start Menu pinned apps layout, backed by `start-menu-backup.bin`
in the same folder. Takes `backup` or `restore` as an argument so it can run unattended (the repo's
no-pauses rule); with no argument it falls back to the interactive prompt. Both directions verify by
file size — a 0-byte backup is refused rather than silently restoring an empty Start Menu.

### Undocumented optional scripts
These exist in `optional/` and are **not** covered by the audit above — they still have the original
no-verification shape:

| File | Purpose |
|---|---|
| `optional/setup-optional-software.bat` | Additional software installs |
| `optional/shallow-clone-ffxiv-profiles.bat` | Shallow-clones FFXIV profile repos |
| `optional/open-rufus-latest.bat` | Opens the latest Rufus |

### optional/setup-makeplace-ffxiv.bat
Downloads and installs Re:MakePlace (community-maintained fork) directly from GitHub. Re:MakePlace is a standalone FFXIV housing layout preview/editor tool that lets you design and share housing layouts. Installs to `%LOCALAPPDATA%\ReMakePlace` since the app requires write permissions. Downloads 7-Zip portable if not already installed. Does not require Chocolatey. Launches the app after installation.

**Installed packages:** Re:MakePlace (from GitHub), 7-Zip (signed installer, if needed)

## Uninstall Scripts (`uninstall/`)

### uninstall/context-menu-terminal.bat
Removes the context menu entries added by `7-context-menu-terminal-install.bat`.

### uninstall/context-menu-take-ownership.bat
Removes the "Take Ownership" context menu entries added by `9-context-menu-take-ownership.bat`.

## Web Console

Four hostnames served through a single Cloudflare Zero Trust tunnel, all requiring Cloudflare Access authentication.

### Hostnames

| Hostname | Purpose |
|---|---|
| `tools.ffxiv.be` | Dashboard — links to all dev tools |
| `console.ffxiv.be` | SSH web client (sshwifty) with 8 quick-connect presets |
| `dev.ffxiv.be` | Direct SSH to WSL (for native SSH clients) |
| `code.ffxiv.be` | VS Code in the browser (code-server) |
| `ttyd.ffxiv.be` | Phone-friendly terminal — landing page with Persistent/Fresh buttons |
| `git.ffxiv.be` | Ungit — visual web Git UI, shows all repos under `/mnt/z/Github` |

### Architecture

```
Browser (Cloudflare Access auth)
  → Cloudflare tunnel
      tools.ffxiv.be → Windows:7686
        → netsh portproxy (Windows:7686 → WSL IP:7686)
          → WSL dashboard.js (Node.js, static HTML landing page)

      console.ffxiv.be → Windows:7681
        → console-proxy.js (injects quick-connect panel)
          → sshwifty_windows_amd64.exe (Windows:7682, SSH client UI)
            → netsh portproxy (Windows:2222 → WSL IP:22)
              → WSL sshd (authorized_keys forced commands → tmux/bash)

      dev.ffxiv.be → ssh://Windows:22
        → netsh portproxy (Windows:22 → WSL IP:22)
          → WSL sshd

      code.ffxiv.be → Windows:8080
        → netsh portproxy (Windows:8080 → WSL IP:8080)
          → WSL code-server (systemd: code-server@root)

      ttyd.ffxiv.be → Windows:7683
        → netsh portproxy (Windows:7683 → WSL IP:7683)
          → WSL ttyd-proxy.js (Node.js landing page)
              /persistent → WSL ttyd-persistent (7684) → tmux session 'phone'
              /fresh      → WSL ttyd-fresh (7685)      → bash -l

      git.ffxiv.be → Windows:7687
        → netsh portproxy (Windows:7687 → WSL IP:7687)
          → WSL git-proxy.js (Node.js repo list landing page, port 7687)
              / → repo list (scans /mnt/z/Github for .git dirs)
              /* → WSL ungit (port 7688, git graph viewer)
```

### First-time setup (after a fresh Windows install)

1. **Run WSL setup (once):**
   ```
   wsl -d Ubuntu-24.04 --user root bash /mnt/z/Users/Heiner/Documents/PCSetup/cloudflared/setup-console-wsl.sh
   ```
2. **Authenticate cloudflared** (one-time, browser login):
   ```
   cloudflared tunnel login
   ```
3. **Populate secrets** — run `cloudflared\sync-secrets.bat` (requires `SSHWIFTY_CONF_B64` in GitHub Secrets).
4. **Run Windows setup** (creates tunnel, DNS, and downloads sshwifty automatically):
   ```
   cloudflared\setup-console-windows.ps1
   ```
5. **Start the console:**
   ```
   cloudflared\start-console.bat
   ```

### Daily use

All console + tunnel services come up automatically at logon/boot — you should **not** need to run anything by hand after a reboot. The `web-console`, `UpdateWSLPortProxy`, and `WSLKeepAlive` scheduled tasks run at logon/startup. `start-console.bat` is only for a manual refresh (e.g. after editing a service).

> **Tunnels survive the reboot network race (important):** cloudflared runs a startup precheck and **exits** (does not retry) if the Cloudflare edge isn't reachable yet — which at boot it often isn't, because ProtonVPN/DNS is still coming up. That's why the tunnels used to be dead after every reboot even though the scheduled tasks reported `0x0`. All three tunnels (`web-console` → dev-console, `ffxivbe-tunnel`, `ssh-tunnel`) now launch cloudflared through `tunnel-supervisor.ps1`, which **waits** for `region*.v2.argotunnel.com:7844` to be reachable before starting cloudflared and **relaunches** it if it ever exits. The two direct-tunnel tasks now run the supervisor as their own long-lived process (State shows `Running`) with `ExecutionTimeLimit 0` — do **not** remove that, or the task's 3-day default would kill the tunnel. Supervisor activity is logged to `~/.cloudflared\<name>-supervisor.log`.

> **`WSLKeepAlive` task (important):** WSL2 shuts the VM down when no session is held open. When that happens, code-server (`code.ffxiv.be`) and the other WSL-backed services die, and on restart WSL can grab a new IP that the Windows TCP relays no longer point at — so console hostnames start returning 502. The `WSLKeepAlive` scheduled task runs `wsl -d Ubuntu-24.04 --user root -- sleep infinity` at logon/startup to hold the VM open. If `code.ffxiv.be` is down, first check `Get-ScheduledTask WSLKeepAlive` is `Running` and that `wsl --list --running` shows the distro; if not, run `Start-ScheduledTask WSLKeepAlive` then `cloudflared\start-console.bat`.

> **Mirrored networking (WSL2):** this machine runs WSL in **mirrored** mode
> (`networkingMode=mirrored` + `hostAddressLoopback=true` in `%USERPROFILE%\.wslconfig`,
> written by `spotify-discord\setup-wsl-mirrored.ps1`) — required for the
> Spotify→Discord bridge's voice/UDP. In mirrored mode WSL and Windows **share the
> network stack**, so: (1) the Windows `tcp-relay.js`/`ssh-proxy.js` relays are
> **not used** — cloudflared reaches WSL services directly on `127.0.0.1`; and
> (2) WSL sshd runs on **2222** (Windows OpenSSH keeps 22). `start-console.ps1`
> auto-detects the mode (`wslinfo --networking-mode`) and skips relays + fixes the
> ssh port accordingly. If you ever revert to NAT, the same script restores the
> relay behaviour automatically. `netsh portproxy` is not used in mirrored mode.

### Zero Trust Access gating

Every console hostname (`console`, `dev`, `code`, `ttyd`, `tools`, `git`) sits behind a
Cloudflare Zero Trust **Access application**. Without one, the tunnel + DNS alone would
expose the hostname to the whole internet — so gating is provisioned as part of setup, not
by hand in the dashboard.

Gating uses **two reusable (account-level) policies**, defined once and attached to all six
apps by ID (not duplicated inline per app):

| Reusable policy | Decision | Effect |
|---|---|---|
| `PCSetup - Owner email allow` | `allow` | Requires Cloudflare Access login as an allowed email (`heinerangarita@gmail.com`, `pagose876@hotmail.com`) — edit the `-Emails` list in `setup-access-apps.ps1` to add/remove |
| `PCSetup - This-PC IP bypass` | `bypass` | This PC's public IP skips the login prompt entirely |

Each app references `[bypass (precedence 1), allow (precedence 2)]` and gets
`session_duration = 8760h` (**1 year** — the "maximum but not annoying" login lifetime;
effective re-auth is `min(app session, org-global session)`, and the org-global is set to
the same value). So: at home you're never prompted (IP bypass); from a phone/other network
you log in with your email roughly once a year.

- **Provision / repair:** `cloudflared\setup-access-apps.ps1` — idempotent; (re)creates the
  reusable policies, ensures all six apps reference them, sets the session duration, and
  migrates any old per-app inline policies to the reusable model. Run automatically by
  `setup-console-windows.ps1` (step 3b) right after DNS routes.
- **IP changed?** `cloudflared\allowlist-current-ip.ps1` rewrites the one bypass policy with
  this PC's current public IP (all apps update at once). `-IpCidr a,b` to set explicitly,
  `-DryRun` to preview.
- **Testing:** `verify-public-routes.ps1` turns gating **off** (points every app at a temp
  everyone-bypass reusable policy), runs the Playwright route check, then turns it back **on**
  (re-points apps at the canonical reusable gate and deletes the temp policy). It never deletes
  the shared reusable policies, and restore is crash-safe (re-points by policy name, so a
  half-finished prior run self-heals on the next run).

### Console scripts

| File | Purpose |
|---|---|
| `cloudflared/start-console.bat` | One-click launcher (calls `start-console.ps1`) |
| `cloudflared/start-console.ps1` | Refreshes portproxies, restarts all services + launches cloudflared via `tunnel-supervisor.ps1` |
| `cloudflared/tunnel-supervisor.ps1` | Self-healing cloudflared wrapper — waits for the Cloudflare edge to be reachable (`region*.v2.argotunnel.com:7844`) before launching cloudflared, and relaunches it if it exits. Makes tunnels survive the reboot network race (see note below). Used by all 3 tunnels (`web-console`, `ffxivbe-tunnel`, `ssh-tunnel`). |
| `cloudflared/verify-console.ps1` | Verifies all console services are healthy (ports, HTTP 200, WSL systemd) — run after start-console.bat |
| `cloudflared/setup-access-apps.ps1` | Provisions Zero Trust Access gating: reusable email-allow + this-PC IP-bypass policies attached to all 6 console apps, `8760h` (1yr) session. Idempotent; migrates old inline policies. Requires `CLOUDFLARE_ACCOUNT_API_TOKEN`. |
| `cloudflared/allowlist-current-ip.ps1` | Rewrites the `PCSetup - This-PC IP bypass` reusable policy with this PC's current public IP (so home skips the login prompt). `-IpCidr` / `-DryRun` supported. |
| `cloudflared/set-access-sessions.ps1` | Sets `session_duration` on every Zero Trust Access app + the org-global timeout (default `8760h` ≈ 1 year). Requires `CLOUDFLARE_ACCOUNT_API_TOKEN` in `.secrets`. |
| `cloudflared/setup-console-windows.ps1` | First-time Windows setup: provisions tunnel + DNS, gates hostnames via `setup-access-apps.ps1`, writes configs, creates scheduled tasks |
| `cloudflared/setup-console-wsl.sh` | First-time WSL setup: sshd, authorized_keys, code-server, ttyd services |
| `cloudflared/restore-code-server-icons.sh` | Repaints code-server's icons with the classic pink VS Code logo. **Re-run after every code-server upgrade** — see below. |
| `cloudflared/console-proxy.js` | Node.js proxy (Windows 7681→7682) that injects the quick-connect panel + PWA manifest, and serves the PWA assets |
| `cloudflared/console-launcher.js` | Quick-connect panel UI injected into sshwifty's HTML |
| `cloudflared/console-pwa-manifest.webmanifest` | PWA manifest ("SSH Console") served at `/console-pwa-manifest.webmanifest` |
| `cloudflared/console-pwa-sw.js` | Minimal pass-through service worker (satisfies Chrome's installability requirement; no caching) |
| `cloudflared/console-pwa-icon-192.png` / `console-pwa-icon-512.png` | App icons (dark tile, green `>_` glyph) |
| `cloudflared/console-pwa-installtest.mjs` | Headless-Chrome installability test (Playwright + CDP); exit 0 = install icon will appear. See PWA gotchas below |
| `cloudflared/ttyd-proxy.js` | Node.js landing page + proxy (WSL 7683→7684/7685) for ttyd.ffxiv.be |
| `cloudflared/dashboard.js` | Node.js static server (WSL 7686) for tools.ffxiv.be |
| `cloudflared/git-proxy.js` | Node.js repo list landing page + proxy (WSL 7687→7688) for git.ffxiv.be |
| `cloudflared/sync-secrets.bat` | Syncs secrets from GitHub → local `.secrets` file |
| `cloudflared/sync-secrets.ps1` | Secrets sync implementation |
| `cloudflared/uninstall-console.ps1` | Full teardown: kills services, removes tasks/portproxies/files, deletes Cloudflare DNS + tunnel |
| `cloudflared/uninstall-console.bat` | Admin wrapper for uninstall-console.ps1 |

### Installable app (PWA)

`console.ffxiv.be` is installable as a Chrome/Edge app ("SSH Console"). Open it in
Chrome → address-bar **Install** icon (or ⋮ → *Cast, save, and share* → *Install page as app*);
on Android/iOS use *Add to Home screen*. It then launches in its own standalone window.

`console-proxy.js` provides everything for this — no changes to sshwifty:
- **Serves** `/console-pwa-manifest.webmanifest`, `/console-pwa-sw.js`, and the two icons
  directly (intercepted before forwarding to sshwifty).
- **Injects** `<link rel="manifest">` + a service-worker registration into every HTML page,
  and **strips sshwifty's own** `<link rel="manifest">` (browsers honour the *first* manifest
  link, so ours must replace it) and renames its `application-name` / `apple-mobile-web-app-title`
  to "SSH Console".

> **Gotcha 1 — manifest must be in `<head>`:** the `<link rel="manifest">` is injected into
> `<head>`, **not** before `</body>`. Chrome silently ignores a body-placed manifest link
> (`getAppManifest` returns nothing → no install icon), regardless of auth. This was the actual
> blocker. Scripts (SW registration, launcher) can stay in `<body>`.
>
> **Gotcha 2 — Cloudflare Access + PWA:** the manifest link **must** also carry
> `crossorigin="use-credentials"`. Chrome fetches the manifest (and its icons) *without*
> credentials by default, so Cloudflare Access 302-redirects those requests to its login page,
> the manifest fails to parse, and **no install icon appears** even though the page itself loads
> fine. `use-credentials` makes the fetches send the `CF_Authorization` cookie. (The service
> worker script fetch already defaults to same-origin credentials, so it needs no change.)
>
> **Verify with:** `node cloudflared\console-pwa-installtest.mjs` — drives headless Chrome
> against the local proxy (via a `Host: console.ffxiv.be` shim, since sshwifty 403s other
> Hosts) and asserts Chrome's own installability signals. Exit 0 = the install icon will appear.
> `--headed` to watch it; `<url> --cf-cookie <JWT>` to test the real public hostname through Access.

The service worker (`console-pwa-sw.js`) does **no caching** — it's a transparent pass-through
whose only purpose is to satisfy Chrome's installability requirement (a registered SW with a
`fetch` handler). sshwifty is a live SSH session, so nothing is cached offline. HTTPS (the
install prerequisite) is provided by the Cloudflare tunnel. To edit the app name/colors, change
`console-pwa-manifest.webmanifest`; to change the icon, regenerate the two PNGs. Deploy by
re-running `start-console.bat` (restarts the proxy).

### WSL services

| Service | Port | Description |
|---|---|---|
| `ssh` | 22 | OpenSSH server |
| `dashboard` | 7686 | Dev Tools dashboard (tools.ffxiv.be) |
| `code-server@root` | 8080 | VS Code server |
| `ttyd-proxy` | 7683 | Landing page + router for ttyd.ffxiv.be |
| `ttyd-persistent` | 7684 | ttyd → `tmux new-session -A -s phone` |
| `ttyd-fresh` | 7685 | ttyd → `bash -l` |
| `git-proxy` | 7687 | Repo list landing page + proxy to ungit (git.ffxiv.be) |
| `ungit` | 7688 | Ungit git graph viewer (internal, behind git-proxy) |
| `wetty` | 7681 | Fallback web terminal (unused by default) |

> **Upgrading code-server silently reverts its custom icon.** The official
> `code-server.dev/install.sh` replaces all of `/usr/lib/code-server`, including
> `src/browser/media`, so the pink VS Code logo goes back to stock every time. After any
> upgrade:
>
> ```powershell
> wsl -d Ubuntu-24.04 --user root -- bash /mnt/z/Users/Heiner/Documents/PCSetup/cloudflared/restore-code-server-icons.sh
> wsl -d Ubuntu-24.04 --user root -- systemctl restart code-server@root
> ```
>
> Verify with `grep 9C0054 /usr/lib/code-server/src/browser/media/favicon.svg` — stock icons
> contain none of `#9C0054` / `#CC007A` / `#FF1493`. Note dpkg preserves upstream mtimes, so a
> recent-looking timestamp on those files means *the package built then*, not that your
> customization survived.

> **The Node proxies run from copies, not from this repo.** `setup-console-wsl.sh` copies
> `dashboard.js`, `git-proxy.js`, and `ttyd-proxy.js` to `/usr/local/bin/`, and systemd runs them
> from there. Editing them here and restarting the service does **nothing** — that is how the
> tools dashboard kept serving dead `*.ffxivbe.org` links for days after the hostname migration.
> `start-console.ps1` now re-copies all three on every run, so the repo is the source of truth;
> to check by hand, compare `wsl -d Ubuntu-24.04 --user root -- stat -c %y /usr/local/bin/dashboard.js`
> against the repo file's timestamp.
>
> When scripting that copy, loop in PowerShell and call `wsl -- cp` directly. Wrapping it as
> ``bash -c "for f in ...; do cp ... `$f ...; done"`` looks correct but the loop variable does not
> survive `wsl.exe` argument passing — the copy silently no-ops and the stale file keeps serving.
> Equally, from Git Bash a bare `/usr/local/bin/...` path gets rewritten to
> `C:/Program Files/Git/usr/local/...`; set `MSYS_NO_PATHCONV=1` or the check reads a nonexistent
> file and reports a falsely clean result.

### Cloudflare tunnel

Tunnel name: `dev-console` — ID: `9aa4a452-a07e-413a-9d1d-0915d170bb7a`

> The ID above was stale for a while (`9c355567-…`) — the tunnel had been recreated without the
> docs following. Trust `~/.cloudflared\dev-config.yml` and `cloudflared tunnel list` over this
> line; DNS CNAMEs built against a dead tunnel ID fail in a way that looks like a routing bug.

### Secrets required

| Secret | Description | How to encode |
|---|---|---|
| `SSHWIFTY_CONF_B64` | `sshwifty.conf.json` (contains embedded SSH private keys) | `[Convert]::ToBase64String([IO.File]::ReadAllBytes("$env:USERPROFILE\Documents\Cloudflare\sshwifty\sshwifty.conf.json")) \| clip` |

Cloudflare tunnel credentials are **not stored in secrets** — `cloudflared/setup-console-windows.ps1` creates a fresh tunnel automatically using `cert.pem` from `cloudflared tunnel login`.

### SSH presets (authorized_keys forced commands)

Each preset uses a unique ED25519 key embedded in `sshwifty.conf.json`. The forced command determines the session type:

| Preset | tmux session | Directory |
|---|---|---|
| WSL Persistent | `console` | `~` |
| WSL Fresh | *(plain bash)* | `~` |
| Candystore Persistent | `candyshop` | `/mnt/z/Github/candystore` |
| Candystore Fresh | *(plain bash)* | `/mnt/z/Github/candystore` |
| Eclipse-con Persistent | `eclipse-con` | `/mnt/z/Github/eclipse-con` |
| Eclipse-con Fresh | *(plain bash)* | `/mnt/z/Github/eclipse-con` |
| Puck Persistent | `puck` | `/mnt/z/Github/puck` |
| Puck Fresh | *(plain bash)* | `/mnt/z/Github/puck` |
| PCSetup Persistent | `pcsetup` | `/mnt/z/Users/Heiner/Documents/PCSetup` |
| PCSetup Fresh | *(plain bash)* | `/mnt/z/Users/Heiner/Documents/PCSetup` |

Persistent = `tmux new-session -A` (attach or create). Fresh = `exec bash -l` (new shell every time).

## Cloudflare SSH & Remote Access

Two tunnels that run as Windows scheduled tasks, separate from the web console.

### Tunnels

| Tunnel | Hostname | Purpose |
|--------|----------|---------|
| `ffxivbe-tunnel` | www.ffxiv.be, chat.ffxiv.be | Web services proxy (reverse proxy on :7542) |
| `ssh-tunnel` | pc.ffxiv.be | SSH remote access from Mac |

Tunnel IDs (persist in Cloudflare, survive PC formats):
- `ffxivbe-tunnel`: `c552cb9c-62bd-4c8b-9ec6-16627b1b8af3`
- `ssh-tunnel`: `8dffdb51-77cc-43ca-8dc8-8a0c720607a5`

#### ffxivbe-tunnel hostnames

All main app routes go through a local reverse proxy on port 7542. The PC setup does not manage local Supabase services.

| Hostname | Backend |
|---|---|
| `www.ffxiv.be` | `localhost:7542` |
| `chat.ffxiv.be` | `localhost:3000` |

Config lives at `cloudflared/.cloudflared/config.yml` in this repo and is deployed to `C:\Users\Heiner\.cloudflared\config.yml` by `install-tunnel.ps1`.

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
```

> **Note on cloudflared installation:** Scripts auto-install the official signed MSI. Do NOT install via Chocolatey — Smart App Control blocks unsigned executables.

> **Browser-based MCPs don't work in remote sessions** (Playwright, Chrome DevTools require a local display). All other Claude Code functionality works fine.

> **Removed:** the MSYS2/tmux persistent Claude session feature (`claude-session` / `snd-session`
> scheduled tasks, `install-claude-session.ps1`, `claude-aliases.sh`, `start-claude-session.sh`,
> `toggle-claude-session.bat`). MSYS2 is not used on this machine. Persistent terminals now come
> from the web console instead — `ttyd.ffxiv.be` (tmux session `phone`) and the `console.ffxiv.be`
> quick-connect presets, both of which run tmux **inside WSL**, not MSYS2.

### Windows Scheduled Tasks

| Task Name | Trigger | Purpose |
|-----------|---------|---------|
| `ffxivbe-tunnel` | At logon | Web tunnel to www.ffxiv.be |
| `ssh-tunnel` | At logon | SSH tunnel to pc.ffxiv.be |

### Mac SSH Config

```bash
brew install cloudflared

# Add to ~/.ssh/config
Host windows-remote
    HostName pc.ffxiv.be
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
2. Zero Trust route for SSH tunnel (`pc.ffxiv.be` → ssh://localhost:22)
3. WAF bypass rule for `pc.ffxiv.be`

### cloudflared/ Scripts

| File | Purpose |
|---|---|
| `cloudflared/post-format-recovery.ps1` | Master recovery script — does everything |
| `cloudflared/install-tunnel.ps1` | Web tunnel installer (standalone). Registers the `ffxivbe-tunnel` task to run `tunnel-supervisor.ps1` (waits for edge + self-heals; survives the reboot network race). |
| `cloudflared/install-ssh-tunnel.ps1` | SSH tunnel + OpenSSH installer. Registers the `ssh-tunnel` task to run `tunnel-supervisor.ps1` (waits for edge + self-heals). |
| `cloudflared/tunnel-supervisor.ps1` | Self-healing cloudflared wrapper shared by all 3 tunnels — see the Web Console section. |
| `cloudflared/install-scheduled-tasks.ps1` | Reinstall scheduled tasks only |
| `cloudflared/toggle-tunnel.bat` | Start/stop web tunnel |
| `cloudflared/toggle-ssh-tunnel.bat` | Start/stop SSH tunnel |
| `cloudflared/manage-tunnel.ps1` | Status checker for web tunnel |
| `cloudflared/uninstall-tunnel.ps1` | Stops task, kills processes, leaves config/DNS intact |
| `cloudflared/create-shortcuts.ps1` | Creates desktop shortcuts |
| `cloudflared/.cloudflared/config.yml` | ffxivbe-tunnel routing config |
| `cloudflared/transfer-ffxiv-be.ps1` | Transfers `ffxiv.be` to DNSimple and delegates DNS to Cloudflare. Dry-runs by default; needs `-AuthCode <code> -Execute` to actually buy. Requires `DNSIMPLE_API_TOKEN`. See "Domain: ffxiv.be" below. |

### Domain: ffxiv.be

`ffxiv.be` is the intended primary domain, replacing `ffxivbe.org`. Two constraints shape how
it is wired, and both were dead ends before landing on the current setup:

- **Cloudflare Registrar does not support `.be`.** Some ccTLDs are supported (`.co`, `.uk`,
  `.us`, `.ca`, `.nz`, `.mx`) but not Belgium — so the registration must permanently live at a
  third-party registrar. Only DNS moves to Cloudflare.
- **Rebrandly-purchased domains cannot have their nameservers changed.** They are hard-wired to
  link shortening, per Rebrandly's own docs. Transferring out is the only escape, which is why
  the DNS Belgium transfer code matters rather than being something to invalidate.

Resulting split: **DNSimple holds the registration** (~$14.80/yr, chosen because its Registrar
API can drive the transfer, delegation, and auto-renew programmatically), **Cloudflare hosts the
zone** and everything operational — DNS, Workers, tunnels, Access, SSL, WAF.

Cloudflare zone: `94976213dc6ffb09e95facdea6176622` · nameservers `kellen.ns.cloudflare.com`,
`paislee.ns.cloudflare.com`.

Transfer completed 2026-07-31. `.be` transfers are **instant** once the auth code validates —
no multi-day wait — and the term resets to one year from completion rather than adding to the
previous expiry.

> **DNSimple API gotcha:** `.be` requires the auth code **twice** — once as `auth_code` and again
> as an extended attribute named `auth`. Without the second, the transfer endpoint returns
> `{"message":"Invalid extended attributes","errors":{"auth":["it's required"]}}`. DNSimple's own
> `GET /v2/tlds/be/extended_attributes` returns `[]` and their docs don't mention it.
> `transfer-ffxiv-be.ps1` sends both.

#### Link shortener (replaced Rebrandly)

Rebrandly is retired. Its 10 short links were exported to
`cloudflared/rebrandly-links-export.{json,csv}` and now run on a Cloudflare Worker.

| File | Purpose |
|---|---|
| `cloudflared/ffxiv-be-shortener.js` | The Worker. Slugs live in the `LINKS` map — few enough that KV would be more moving parts than it's worth. |
| `cloudflared/deploy-shortener.ps1` | Uploads the Worker, then smoke-tests every slug against live `https://ffxiv.be` (`-BaseUrl` to override, `-SkipVerify` to skip). |
| `cloudflared/rebrandly-links-export.{json,csv}` | The original Rebrandly export, kept as the migration record. |

**To add or change a link:** edit the `LINKS` map in `ffxiv-be-shortener.js`, then run
`cloudflared\deploy-shortener.ps1`. It verifies all slugs and exits non-zero if any fail.

Redirects are **302**, matching Rebrandly — a 301 gets cached hard by browsers and would make a
destination change effectively unfixable. Lookups fall back to case-insensitive (`/enl1` finds
`ENL1`), and query strings pass through to the destination.

> **Deploys take up to ~60s to reach every edge PoP.** A slug 404ing seconds after upload is
> propagation, not a bad map — `deploy-shortener.ps1` retries rather than reporting a false
> failure. Verify with `curl.exe`, not `Invoke-WebRequest`: in PS7 `-MaximumRedirection 0` throws
> on a 3xx instead of returning it, so every working redirect reads as a failure.

> **The `workers.dev` preview URL is deliberately disabled** so `ffxiv.be` is the only public
> entry point. Re-enabling it would give the shortener a second address serving the same
> redirects. This is also why verification targets the live hostname — it exercises DNS and the
> Worker route as well as the script.

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


# Cloudflared blocked by Smart App Control
# → Uninstall Chocolatey version, install from official MSI:
choco uninstall cloudflared -y
Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.msi' -OutFile "$env:TEMP\cloudflared.msi"
Start-Process msiexec.exe -ArgumentList '/i', "$env:TEMP\cloudflared.msi", '/quiet' -Wait
```

## Spotify → Discord Bridge (`spotify-discord/`)

Makes a Discord bot act as a **Spotify Connect speaker**. Pick **Discord** from
the Connect/devices menu in any Spotify app (phone/PC/web) and audio plays into a
Discord voice channel. Playback is controlled from Spotify; the bot is just the
output device. Requires **Spotify Premium**.

```
Spotify app → go-librespot (Connect device, OAuth login) → /tmp/spotify-discord.fifo
  → bot.js → ffmpeg (44.1→48 kHz) → @discordjs/voice → Discord voice channel
```

Runs as two **WSL systemd services** (`go-librespot`, `spotify-discord-bot`),
enabled at boot, held alive by `WSLKeepAlive`, and (re)started at logon by the
`SpotifyDiscordBridge` scheduled task. OAuth login (not LAN zeroconf) is used so
the device appears in Connect over the internet.

> **Requires WSL2 mirrored networking** (`networkingMode=mirrored` +
> `hostAddressLoopback=true` in `%USERPROFILE%\.wslconfig`). Discord voice's UDP
> handshake and the OAuth callback are unreliable under WSL2 NAT. See the "Web
> Console" section note — mirrored mode also changes how the console is wired.

> **The critical fix: `@discordjs/voice` ≥ 0.19 (voice gateway v8).** Older 0.18
> uses v4, which Discord now rejects (voice ws opens, gets Hello, then closes →
> "operation was aborted", `net-state 1 → 6`, never reaches UDP). NAT vs mirrored
> was a red herring *for voice* — the outdated library was the real blocker.

### Setup / restore

1. Secrets: add `DISCORD_BOT_TOKEN`, `DISCORD_GUILD_ID`, `DISCORD_VOICE_CHANNEL_ID`
   to GitHub Secrets, then `cloudflared\sync-secrets.bat` (or edit
   `/etc/spotify-discord.env` in WSL directly).
2. Install: `spotify-discord\setup-spotify-discord.bat` — runs mirrored-networking
   setup → WSL install → `SpotifyDiscordBridge` scheduled task, in that order.
3. One-time Spotify OAuth (can't live in a secret):
   `powershell -ExecutionPolicy Bypass -File spotify-discord\login-spotify.ps1`
   — opens the auth URL; log in, Agree (a "connection reset" page after Agree is fine).

Slash commands: `/join`, `/leave`, `/reconnect`, `/status`.
Logs: `journalctl -u go-librespot -u spotify-discord-bot -f`.
Full details + gotchas in `spotify-discord/README.md`.

| File | Purpose |
|---|---|
| `spotify-discord/bot.js` | discord.js bot: reads pipe, joins voice, streams |
| `spotify-discord/config.yml` | go-librespot config (pipe output + OAuth, callback_port 8898) |
| `spotify-discord/setup-spotify-discord.bat` | One-click: mirrored net → WSL install → task |
| `spotify-discord/setup-wsl-mirrored.ps1` | Sets WSL mirrored networking (prereq) |
| `spotify-discord/setup-spotify-discord-wsl.sh` | WSL installer + systemd services |
| `spotify-discord/install-scheduled-task.ps1` | Registers `SpotifyDiscordBridge` logon task |
| `spotify-discord/login-spotify.ps1` | One-time Spotify OAuth (mirrored-aware) |

## Source Files (`sources/`)

Backup registry files that can be imported directly if the batch scripts don't work.

### sources/Add_Take_Ownership_to_context_menu.reg
Original Take Ownership registry file. Double-click to import if `9-context-menu-take-ownership.bat` fails.

### sources/Longpath.reg
Enables Windows long paths support. Already handled by `9-context-menu-take-ownership.bat`.
