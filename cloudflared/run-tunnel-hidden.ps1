# Wrapper script to run tunnel hidden
# Use full path for Smart App Control compatibility (must use signed MSI version)
$cloudflaredPath = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$configPath = Join-Path $env:USERPROFILE ".cloudflared\config.yml"

& $cloudflaredPath tunnel --config $configPath run ffxivbe-tunnel



