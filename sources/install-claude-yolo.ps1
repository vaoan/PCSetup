# Makes `claude --yolo` mean `claude --dangerously-skip-permissions`, on Windows and in WSL.
#
# Called by 2-setup-windows.bat right after Claude Code is installed (Windows) and again after it
# is installed in WSL (-WslDistro). Idempotent: re-running rewrites the same wrapper and leaves an
# existing ~/.bashrc block alone. Check -> act -> verify; exits 1 if anything did not stick.
#
# Windows: %USERPROFILE%\.local\claude-wrap\claude.cmd, a 5-line wrapper that swaps --yolo and then
#   runs the real %USERPROFILE%\.local\bin\claude.exe. Its folder is put FIRST in the User PATH, so
#   `claude` resolves to the wrapper (cmd, PowerShell, WezTerm) and claude.exe stays untouched -
#   the native updater can replace it freely.
# WSL: a `claude` shell function in ~/.bashrc that does the same swap per argument.
#
# Lives in its own file, not in echo lines of the .bat: the wrapper is made of %VAR% and
# %_a:--yolo=...% expansions, and every % would have to be doubled for CMD to write it.
param([string]$WslDistro = '')

$failures = New-Object System.Collections.Generic.List[string]

if (-not $WslDistro) {
    $realExe = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    $wrapDir = Join-Path $env:USERPROFILE '.local\claude-wrap'
    $wrap = Join-Path $wrapDir 'claude.cmd'
    $content = @(
        '@echo off'
        'rem claude --yolo  ->  claude --dangerously-skip-permissions   (PCSetup: sources\install-claude-yolo.ps1)'
        'setlocal DisableDelayedExpansion'
        'set _a=%*'
        'if defined _a set _a=%_a:--yolo=--dangerously-skip-permissions%'
        '"%USERPROFILE%\.local\bin\claude.exe" %_a%'
    ) -join "`r`n"

    if (-not (Test-Path -LiteralPath $realExe)) {
        Write-Host "claude --yolo: $realExe not found, so there is nothing to wrap yet." -ForegroundColor Red
        $failures.Add('claude.exe missing')
    }
    else {
        $null = New-Item -ItemType Directory -Path $wrapDir -Force
        [IO.File]::WriteAllText($wrap, $content + "`r`n", [Text.Encoding]::ASCII)

        # Wrapper folder first in the User PATH (User PATH is appended after Machine PATH, and
        # .local\bin is in the User PATH, so first-in-User is enough to win over claude.exe).
        $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
        $parts = @($userPath -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $wrapDir })
        $newPath = (@($wrapDir) + $parts) -join ';'
        if ($newPath -ne $userPath) { [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User') }
        $env:PATH = $wrapDir + ';' + (($env:PATH -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $wrapDir }) -join ';')

        # Verify: the file is what we wrote, it is first on PATH, and it really runs claude.exe.
        $first = (@([Environment]::GetEnvironmentVariable('PATH', 'User') -split ';'))[0]
        $resolved = (Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $version = (& $wrap --version 2>$null | Select-Object -First 1)
        if ([IO.File]::ReadAllText($wrap) -notmatch 'dangerously-skip-permissions') { $failures.Add('wrapper content') }
        elseif ($first -ne $wrapDir) { $failures.Add('wrapper not first in User PATH') }
        elseif ($resolved -ne $wrap) { $failures.Add("claude resolves to $resolved") }
        elseif (-not $version) { $failures.Add('wrapper does not run claude.exe') }
        else { Write-Host "claude --yolo ready on Windows ($wrap -> $version)." -ForegroundColor Green }
    }
}
else {
    $block = @(
        '# >>> PCSetup claude --yolo >>>'
        'claude() {'
        '  local a=() x'
        '  for x in "$@"; do'
        '    if [ "$x" = "--yolo" ]; then a+=(--dangerously-skip-permissions); else a+=("$x"); fi'
        '  done'
        '  command claude "${a[@]}"'
        '}'
        '# <<< PCSetup claude --yolo <<<'
        ''
    ) -join "`n"
    # Base64 so no quote, $ or newline has to survive PowerShell 5.1's native-argument passing.
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("`n" + $block))
    & wsl.exe -d $WslDistro -e bash -c "grep -qs 'PCSetup claude --yolo' ~/.bashrc || echo $b64 | base64 -d >> ~/.bashrc"
    $type = (& wsl.exe -d $WslDistro -e bash -ic "type claude" 2>$null) -join "`n"
    if ($type -match 'dangerously-skip-permissions') { Write-Host "claude --yolo ready in WSL ($WslDistro)." -ForegroundColor Green }
    else { $failures.Add("WSL $WslDistro bash function") }
}

if ($failures.Count -gt 0) {
    Write-Host ("claude --yolo setup FAILED: {0}" -f ($failures -join ', ')) -ForegroundColor Red
    exit 1
}
exit 0
