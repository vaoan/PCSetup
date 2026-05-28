# Wrapper script to start the tunnel detached and hidden.
# Use full path for Smart App Control compatibility (must use signed MSI version).
$cloudflaredPath = 'C:\Program Files (x86)\cloudflared\cloudflared.exe'
$configPath = Join-Path $env:USERPROFILE ".cloudflared\config.yml"

Start-Process -WindowStyle Hidden -FilePath $cloudflaredPath -ArgumentList @('tunnel','--config',$configPath,'run','ffxivbe-tunnel') | Out-Null



