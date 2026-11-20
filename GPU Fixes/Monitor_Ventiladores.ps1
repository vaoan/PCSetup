# Monitor en vivo de ventiladores (sensor real de Acer). Cierra la ventana para salir.
$host.UI.RawUI.WindowTitle = "MONITOR VENTILADORES"
$i = Get-CimInstance -Namespace root\wmi -ClassName AcerGamingFunction
function Get-S($x) { $o = [uint64](Invoke-CimMethod -InputObject $i -MethodName GetGamingSysInfo -Arguments @{gmInput=[uint32]$x}).gmOutput; [int](($o -shr 8) -band 0xFFFF) }
Write-Host "Normal en 'Max': CPU ~5357 rpm, GPU ~4615 rpm fijos.`n" -ForegroundColor Cyan
while ($true) {
  $c = Get-S 0x0201; $g = Get-S 0x0601; $t = Get-S 0x0101
  $col = if ($c -lt 5000 -or $g -lt 4200) { 'Red' } else { 'Green' }
  Write-Host ("{0}   Vent CPU {1,5} rpm   Vent GPU {2,5} rpm   CPU {3} C" -f (Get-Date -f HH:mm:ss), $c, $g, $t) -ForegroundColor $col
  Start-Sleep -Milliseconds 700
}
