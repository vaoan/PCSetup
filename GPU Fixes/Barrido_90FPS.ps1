# BARRIDO 2560x1600 - busca los GHz de CPU y MHz de GPU MAS ALTOS que no provocan throttling (perdida de rendimiento por calor).
# Solo se tocan: tope de frecuencia CPU (powercfg) y tope de reloj GPU (nvidia-smi). Nada de W, voltajes ni ventiladores.
# Carga real completa al 100 %: GPU FurMark Vulkan SIN tope de FPS + CPU Prime95 TODOS los hilos con AVX + toda la RAM libre (menos 1,5 GB para Windows).
# Throttling = CPU cae a 45 W, GPU con freno termico, ventiladores bajando, o FPS < 90.
# Fase 1: GPU (CPU fija 4400/3400) de mayor a menor. Fase 2: CPU (con esa GPU) de mayor a menor. Fase 3: 20 min la combinacion.
# Para detenerlo: crear el archivo DETENER en Resultados\
param([int]$Min = 10, [int]$MinFinal = 20, [switch]$Prueba, [switch]$Cuatro, [switch]$SoloCPU, [switch]$SoloGPU,
      [switch]$Una, [int]$P = 4000, [int]$E = 3000, [int]$G = 0)
$ErrorActionPreference = 'Continue'
$FPS_PRUEBA = 100; $FPS_JUEGO = 90
$CPU_FIJA = @(4400,3400)
$base = Split-Path $PSCommandPath
$res  = Join-Path $base "Resultados"; New-Item -ItemType Directory -Force $res | Out-Null
$lock = Join-Path $res "barrido.lock"; $stop = Join-Path $res "DETENER"; $log = Join-Path $res "BARRIDO_90FPS.txt"
if (Test-Path $lock) { $old = Get-Content $lock; if (Get-Process -Id $old -ErrorAction SilentlyContinue) { "Ya hay un barrido corriendo (PID $old)"; exit 1 } }
$PID | Out-File $lock -Encoding ascii
Remove-Item $stop -ErrorAction SilentlyContinue
function Log($t) { $l = "$(Get-Date -Format 'HH:mm:ss')  $t"; Write-Host $l; $l | Out-File $log -Append -Encoding utf8 }

$lhm = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter "LibreHardwareMonitor*" | Select-Object -First 1 -ExpandProperty FullName
$p95 = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter "mersenne.prime95*" | Select-Object -First 1 -ExpandProperty FullName
$fm  = "C:\Program Files\Geeks3D\FurMark2_x64\furmark.exe"
Get-ChildItem $lhm -Filter *.dll | ForEach-Object { try { [void][Reflection.Assembly]::LoadFrom($_.FullName) } catch {} }
$acer = Get-CimInstance -Namespace root\wmi -ClassName AcerGamingFunction -ErrorAction SilentlyContinue
function Get-Rpm($x) { try { $o = [uint64](Invoke-CimMethod -InputObject $acer -MethodName GetGamingSysInfo -Arguments @{gmInput=[uint32]$x}).gmOutput; [int](($o -shr 8) -band 0xFFFF) } catch { 0 } }

function Set-Cpu([int]$P, [int]$E) {
  foreach ($s in 'PROCFREQMAX','PROCFREQMAX1') { powercfg -attributes SUB_PROCESSOR $s -ATTRIB_HIDE 2>$null }
  $schemes = powercfg /list | Select-String '([0-9a-f]{8}-[0-9a-f-]{27})' | ForEach-Object { $_.Matches[0].Value }
  foreach ($sch in $schemes) { foreach ($x in @(@('PROCFREQMAX1',$P), @('PROCFREQMAX',$E))) {
    powercfg /setacvalueindex $sch SUB_PROCESSOR $x[0] $x[1]; powercfg /setdcvalueindex $sch SUB_PROCESSOR $x[0] $x[1] } }
  powercfg /setactive SCHEME_CURRENT
}
function Set-Gpu([int]$G) { & nvidia-smi -rmc | Out-Null; if ($G -gt 0) { & nvidia-smi -lgc "210,$G" | Out-Null } else { & nvidia-smi -rgc | Out-Null } }
# PredatorSense se usa 24/7: debe estar ABIERTO (con ventana) durante todas las pruebas para que su consumo cuente
$PS_APP = "shell:AppsFolder\ULICTekInc.PredatorSenseforNotebook_nt9dgb7efx6bt!PredatorSense"
function Open-PS { for ($k = 0; $k -lt 3; $k++) {
    if (Get-Process PredatorSense -ErrorAction SilentlyContinue | Where-Object MainWindowTitle) { return $true }
    Start-Process explorer.exe $PS_APP; Start-Sleep 8 }
  return [bool](Get-Process PredatorSense -ErrorAction SilentlyContinue | Where-Object MainWindowTitle) }
function Restart-PS { Log "Reiniciando PredatorSense"; Stop-Process -Name PredatorSense -Force -ErrorAction SilentlyContinue; Start-Sleep 3
  Start-Process explorer.exe $PS_APP; Start-Sleep 20; [void](Open-PS) }
function Wait-Cool { $t = (Get-Date).AddSeconds(120); while ((Get-Date) -lt $t) { $g = [int](& nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits); if ($g -le 50) { break }; Start-Sleep 5 } }
function Txt-Cpu($p,$e) { if ($p) { "$p/$e MHz" } else { 'fabrica' } }
function Txt-Gpu($g) { if ($g) { "$g MHz" } else { 'fabrica' } }

# Prime95: TODOS los hilos (32) con AVX, FFT medianas/grandes para usar RAM = juego + stream + programas abiertos.
# NUNCA limitar hilos: la prueba debe representar el uso real completo.
@"
V24OptionsConverted=1
WGUID_version=2
StressTester=1
UsePrimenet=0
MinTortureFFT=64
MaxTortureFFT=4096
TortureMem=$([math]::Max(2048, [math]::Floor((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1KB) - 1536))
TortureTime=3
TortureThreads=$([Environment]::ProcessorCount)
"@ | Set-Content "$p95\prime.txt" -Encoding ascii
$localTxt = "$p95\local.txt"; $localBak = "$p95\local.txt.bak_barrido"

function Run-Test($id, $cpuP, $cpuE, $gpu, $min) {
  Set-Cpu $cpuP $cpuE | Out-Null; Set-Gpu $gpu | Out-Null
  if (-not (Open-PS)) { Log "AVISO: no se pudo abrir la ventana de PredatorSense" }
  $etq = "$id | CPU $(Txt-Cpu $cpuP $cpuE) | GPU $(Txt-Gpu $gpu)"
  Log "INICIO $etq ($min min)"
  $stamp = Get-Date -Format "yyyy-MM-dd_HH-mm"; $csv = Join-Path $res "b90_${id}_$stamp.csv"; $fmOut = Join-Path $res "b90_${id}_${stamp}_fps.txt"
  if (Test-Path "$p95\results.txt") { Remove-Item "$p95\results.txt" -Force }
  $c = New-Object LibreHardwareMonitor.Hardware.Computer; $c.IsCpuEnabled = $true; $c.IsGpuEnabled = $true; $c.IsMemoryEnabled = $true; $c.Open()
  $t0 = Get-Date
  Start-Process "$p95\prime95.exe" -ArgumentList '-t' -WorkingDirectory $p95 -WindowStyle Minimized
  Start-Process $fm -ArgumentList "--demo furmark-vk --width 2560 --height 1600 --hpgfx 1 --vsync 0 --max-time $($min*60+30) --no-score-box --print-render-speed" -WorkingDirectory (Split-Path $fm) -RedirectStandardOutput $fmOut
  "hora,cpu_c,cpu_w,pcore_mhz,ecore_mhz,gpu_c,hot_c,gpu_w,gpu_mhz,gpu_util,gpu_freno_termico,ram_gb,vent_cpu,vent_gpu" | Out-File $csv -Encoding utf8
  $rows = @(); $motivo = ''
  try {
    while ((Get-Date) -lt $t0.AddMinutes($min)) {
      if (Test-Path $stop) { $motivo = 'DETENIDO POR USUARIO'; break }
      $r = @{}; foreach ($h in $c.Hardware) { $h.Update(); foreach ($s in $h.Sensors) { if ($s.Value -ne $null) { $r["$($s.SensorType)|$($s.Name)"] = [double]$s.Value } } }
      $pm = ($r.Keys | Where-Object { $_ -match '^Clock\|P-Core #' } | ForEach-Object { $r[$_] } | Measure-Object -Average).Average
      $em = ($r.Keys | Where-Object { $_ -match '^Clock\|E-Core #' } | ForEach-Object { $r[$_] } | Measure-Object -Average).Average
      $g = (& nvidia-smi --query-gpu=temperature.gpu,power.draw,clocks.gr,utilization.gpu,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown --format=csv,noheader,nounits) -split ',\s*'
      $freno = [int](($g[4] -match '^Active') -or ($g[5] -match '^Active'))
      $hot = if ($r.ContainsKey('Temperature|GPU Hot Spot')) { [math]::Round($r['Temperature|GPU Hot Spot'],1) } else { 0 }
      $ram = if ($r.ContainsKey('Data|Memory Used')) { [math]::Round($r['Data|Memory Used'],1) } else { 0 }
      $vc = @(); $vg = @(); 1..5 | ForEach-Object { $vc += (Get-Rpm 0x0201); $vg += (Get-Rpm 0x0601); Start-Sleep 1 }
      $row = [pscustomobject]@{ cpu=[math]::Round($r['Temperature|CPU Package']); cpuw=[math]::Round($r['Power|CPU Package']); pmhz=[math]::Round($pm); emhz=[math]::Round($em);
        gpu=[double]$g[0]; hot=$hot; gpuw=[double]$g[1]; gmhz=[int]$g[2]; util=[int]$g[3]; freno=$freno; ram=$ram;
        vc=($vc|Where-Object {$_ -gt 0}|Measure-Object -Minimum).Minimum; vg=($vg|Where-Object {$_ -gt 0}|Measure-Object -Minimum).Minimum }
      $rows += $row
      "$(Get-Date -Format HH:mm:ss),$($row.cpu),$($row.cpuw),$($row.pmhz),$($row.emhz),$($row.gpu),$($row.hot),$($row.gpuw),$($row.gmhz),$($row.util),$($row.freno),$($row.ram),$($row.vc),$($row.vg)" | Out-File $csv -Append -Encoding utf8
      if (-not (Get-Process furmark -ErrorAction SilentlyContinue)) { $motivo = 'FURMARK SE CERRO (posible crash GPU)'; break }
      if (-not (Get-Process prime95 -ErrorAction SilentlyContinue)) { $motivo = 'PRIME95 SE CERRO'; break }
      if ($row.cpu -ge 95 -or $row.hot -ge 97) { $motivo = 'CORTE DE EMERGENCIA POR TEMPERATURA'; break }
      if (-not (Get-Process PredatorSense -ErrorAction SilentlyContinue | Where-Object MainWindowTitle)) { $motivo = 'PREDATORSENSE SE CERRO (prueba invalida)'; break }
    }
  } finally { Stop-Process -Name prime95,furmark -Force -ErrorAction SilentlyContinue; $c.Close() }

  $s = @($rows | Select-Object -Skip 18); if (-not $s) { $s = $rows }    # ignora 90 s de calentamiento
  $mx = { param($p) [math]::Round(($s | Measure-Object $p -Maximum).Maximum,1) }; $av = { param($p) [math]::Round(($s | Measure-Object $p -Average).Average,1) }
  $fps = @(Select-String $fmOut -Pattern 'FPS: (\d+)' -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Matches[0].Groups[1].Value } | Select-Object -Skip 90)
  $fAvg = 0; $fP1 = 0; $fMin = 0
  if ($fps.Count) { $o = $fps | Sort-Object; $fAvg = [math]::Round(($fps | Measure-Object -Average).Average,1); $fP1 = $o[[math]::Floor($o.Count*0.01)]; $fMin = $o[0] }
  $p95err = if (Test-Path "$p95\results.txt") { @(Select-String "$p95\results.txt" -Pattern 'FATAL|ERROR|failure|rounding').Count } else { 0 }
  $ev = @(Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$t0} -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match 'WHEA|nvlddmkm|Display' -and $_.Level -le 3 }).Count
  # throttling (muestras de 5 s despues del calentamiento)
  $capP = if ($cpuP) { $cpuP } else { 5800 }
  $tCpu  = @($s | Where-Object { $_.cpuw -le 46 -and $_.pmhz -lt 0.85 * $capP }).Count   # cae a 45 W SIN haber llegado a su tope
  $tGpu  = @($s | Where-Object { $_.freno -eq 1 }).Count
  $tVent = @($s | Where-Object { ($_.vc -gt 0 -and $_.vc -lt 5000) -or ($_.vg -gt 0 -and $_.vg -lt 4400) }).Count
  $o = [pscustomobject]@{ id=$id; cpuP=$cpuP; cpuE=$cpuE; gpuL=$gpu; cpu=(& $mx 'cpu'); cpuAvg=(& $av 'cpu'); cpuW=(& $av 'cpuw'); pmhz=(& $av 'pmhz'); emhz=(& $av 'emhz');
    gpu=(& $mx 'gpu'); hot=(& $mx 'hot'); gpuW=(& $av 'gpuw'); gmhz=(& $av 'gmhz'); util=(& $av 'util'); ram=(& $mx 'ram'); fps=$fAvg; p1=$fP1; fmin=$fMin;
    tCpu=$tCpu; tGpu=$tGpu; tVent=$tVent; err=$p95err; ev=$ev; motivo=$motivo }
  $o | Add-Member fpsOk ($fAvg -ge ($FPS_JUEGO + 2) -and $fP1 -ge $FPS_JUEGO)
  $o | Add-Member estable (-not $motivo -and $p95err -eq 0 -and $ev -eq 0)
  $o | Add-Member sinThrottle ($tCpu -le 1 -and $tGpu -le 1 -and $tVent -le 1)
  $o | Add-Member throttle ($tCpu + $tGpu + $tVent)
  Log ("FIN {0}: FPS {1} (1% {2}, min {3}) | CPU max {4}C prom {5}C {6}W P {7}MHz E {8}MHz | GPU max {9}C hot {10}C {11}W {12}MHz util {13}% | RAM {14} GB | THROTTLE cpu45W {15} gpuFreno {16} vent {17} (de {18} muestras) | err {19} ev {20} {21} => FPS {22} SIN-THROTTLE {23} ESTABLE {24}" -f `
    $etq,$o.fps,$o.p1,$o.fmin,$o.cpu,$o.cpuAvg,$o.cpuW,$o.pmhz,$o.emhz,$o.gpu,$o.hot,$o.gpuW,$o.gmhz,$o.util,$o.ram,$tCpu,$tGpu,$tVent,$s.Count,$o.err,$o.ev,$o.motivo,$o.fpsOk,$o.sinThrottle,$o.estable)
  $o | Export-Csv (Join-Path $res "b90_tabla.csv") -Append -NoTypeInformation -Encoding utf8 -Force
  if (-not $Prueba) { Wait-Cool | Out-Null }
  return $o
}

$todos = @()
try {
  & "$base\Limite_FPS.ps1" -Quitar -SinPausa | Out-Null    # prueba SIN tope: GPU al 100 %
  if ($Prueba) {
    Log "=== PRUEBA RAPIDA (2 min): comprobar que la CPU llega a sus GHz con la carga tipo juego ==="
    $r = Run-Test "PRUEBA" $CPU_FIJA[0] $CPU_FIJA[1] 1800 2
    return
  }
  if ($SoloGPU) {
    # Solo GPU con CPU FIJA en $P/$E. Gana el MHz MAS ALTO estable, sin throttling y >=90 FPS.
    Log "=== SOLO GPU | CPU fija $(Txt-Cpu $P $E) | FurMark SIN tope + Prime95 $([Environment]::ProcessorCount) hilos AVX + RAM libre - 1,5 GB + PredatorSense abierto | $Min min c/u ==="
    Restart-PS
    $Gel = $null; $tab = @()
    foreach ($g in 1950,1800,1700,1600) {
      if (Test-Path $stop) { break }
      $r = Run-Test "GPU$g" $P $E $g $Min; $tab += $r
      $ok = $r.estable -and $r.sinThrottle -and $r.fpsOk
      Log ("  -> GPU {0} MHz: estable (sin corte/errores) {1} | sin throttling {2} | FPS>=90 {3} => {4}" -f $g, $r.estable, $r.sinThrottle, $r.fpsOk, $(if ($ok) {'ELEGIDA'} else {'no cumple'}))
      if ($ok) { $Gel = $g; break }
      if (-not $r.fpsOk -and $r.estable) { Log "  Ya no da 90 FPS: no se baja mas"; break }
    }
    if (-not $Gel) {
      $m = $tab | Where-Object { $_.estable -and $_.fpsOk } | Sort-Object throttle, @{e={$_.gpuL}; Descending=$true} | Select-Object -First 1
      if ($m) { $Gel = $m.gpuL; Log "Ninguna 100% sin throttling; la mas alta estable con 90 FPS y menos throttling: $Gel MHz" }
    }
    $tab | Select-Object id, fps, p1, fmin, cpu, cpuAvg, cpuW, pmhz, emhz, gpu, hot, gpuW, gmhz, tCpu, tGpu, tVent, err, ev, motivo |
      Format-Table -AutoSize | Out-String -Width 300 | Out-File $log -Append -Encoding utf8
    Set-Cpu $P $E | Out-Null
    if ($Gel) { Set-Gpu $Gel | Out-Null; Log "APLICADO: CPU $(Txt-Cpu $P $E) + GPU $Gel MHz"
      "Juego 90 FPS (CPU $(Txt-Cpu $P $E), GPU $Gel MHz, tope 90 FPS)  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Out-File (Join-Path $base "perfil_actual.txt") -Encoding ascii }
    else { Set-Gpu 0 | Out-Null; Log "NINGUNA GPU estable con 90 FPS; GPU queda de fabrica" }
    return
  }
  if ($Una) {
    # Una sola prueba con CPU $P/$E y GPU $G; al final deja CPU 4000/3000 y GPU de fabrica
    Log "=== PRUEBA UNICA | FurMark SIN tope + Prime95 $([Environment]::ProcessorCount) hilos AVX + RAM libre - 1,5 GB + PredatorSense abierto | $Min min ==="
    Restart-PS
    $r = Run-Test "CPU$P-GPU$G" $P $E $G $Min
    Log ("  -> temp CPU<=80 {0} | sin throttling {1} | FPS>=90 {2} | estable {3}" -f ($r.cpu -le 80), $r.sinThrottle, $r.fpsOk, $r.estable)
    Set-Cpu 4000 3000 | Out-Null; Set-Gpu 0 | Out-Null
    return
  }
  if ($SoloCPU) {
    # Solo CPU: GPU de fabrica. Gana el tope MAS ALTO con CPU <=80 C, sin throttling, estable y sin perder FPS vs fabrica.
    $antes = foreach ($x in 'PROCFREQMAX1','PROCFREQMAX') { [Convert]::ToInt32(((powercfg /query SCHEME_CURRENT SUB_PROCESSOR $x | Select-String 'Current AC' | Select-Object -First 1) -replace '.*0x',''),16) }
    Log "=== SOLO CPU | GPU fabrica | FurMark SIN tope + Prime95 $([Environment]::ProcessorCount) hilos AVX + RAM libre - 1,5 GB + PredatorSense abierto | $Min min c/u ==="
    Restart-PS
    $base0 = $null; $C = $null; $tab = @()
    # fabrica y 5,0 se descartan (se calientan de mas); minimo 4,0 GHz
    foreach ($cc in @(@(4600,3600), @(4200,3200), @(4000,3000))) {
      if (Test-Path $stop) { break }
      $r = Run-Test "CPU$($cc[0])" $cc[0] $cc[1] 0 $Min; $tab += $r
      if (-not $base0) { $base0 = $r }
      $sinPerdida = $r.fps -ge ($base0.fps - 1) -and $r.p1 -ge $FPS_JUEGO
      $ok = $r.estable -and $r.sinThrottle -and $r.cpu -le 80 -and $sinPerdida
      Log ("  -> CPU {0}: temp<=80 {1} | sin throttling {2} | sin perdida FPS (fabrica {3}) {4} | estable {5} => {6}" -f (Txt-Cpu $cc[0] $cc[1]), ($r.cpu -le 80), $r.sinThrottle, $base0.fps, $sinPerdida, $r.estable, $(if ($ok) {'ELEGIDA'} else {'no cumple'}))
      if ($ok) { $C = $cc; break }
      if (-not $sinPerdida -and $cc[0] -gt 0) { Log "  Ya pierde FPS: no se baja mas"; break }
    }
    $tab | Select-Object id, fps, p1, fmin, cpu, cpuAvg, cpuW, pmhz, emhz, gpu, hot, gpuW, gmhz, tCpu, tGpu, tVent, err, ev, motivo |
      Format-Table -AutoSize | Out-String -Width 300 | Out-File $log -Append -Encoding utf8
    if ($C) { Set-Cpu $C[0] $C[1] | Out-Null; Log "CPU ELEGIDA Y APLICADA: $(Txt-Cpu $C[0] $C[1])"
      "CPU $(Txt-Cpu $C[0] $C[1]) (prueba solo CPU), GPU fabrica, tope 90 FPS  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Out-File (Join-Path $base "perfil_actual.txt") -Encoding ascii }
    else { Set-Cpu $antes[0] $antes[1] | Out-Null; Log "NINGUNA CPU cumplio todo; topes restaurados a $($antes[0])/$($antes[1])" }
    Set-Gpu 0 | Out-Null
    return
  }
  if ($Cuatro) {
    # Guarda los topes de CPU actuales para dejarlos igual al final (el usuario elige despues)
    $antes = foreach ($x in 'PROCFREQMAX1','PROCFREQMAX') { [Convert]::ToInt32(((powercfg /query SCHEME_CURRENT SUB_PROCESSOR $x | Select-String 'Current AC' | Select-Object -First 1) -replace '.*0x',''),16) }
    Log "=== 4 CONFIGURACIONES | FurMark SIN tope (GPU 100%) + Prime95 $([Environment]::ProcessorCount) hilos AVX + RAM libre - 1,5 GB + PredatorSense abierto | $Min min c/u ==="
    Restart-PS
    $lista = @( @{n='1-Fabrica';     p=0;    e=0;    g=0},
                @{n='2-Rendimiento'; p=4600; e=3600; g=1950},
                @{n='3-Equilibrado'; p=4200; e=3200; g=1800},
                @{n='4-Fresco';      p=3800; e=2800; g=1700} )
    $tab = @()
    foreach ($k in $lista) { if (Test-Path $stop) { break }; $tab += Run-Test $k.n $k.p $k.e $k.g $Min }
    $tab | Select-Object id, fps, p1, fmin, cpu, cpuW, pmhz, emhz, gpu, hot, gpuW, gmhz, tCpu, tGpu, tVent, err, ev, motivo |
      Format-Table -AutoSize | Out-String -Width 300 | Out-File $log -Append -Encoding utf8
    Set-Cpu $antes[0] $antes[1] | Out-Null; Set-Gpu 0 | Out-Null
    Log "Topes de CPU restaurados a $($antes[0])/$($antes[1]); GPU de fabrica. Elige una configuracion para aplicarla."
    return
  }
  Log "=== BARRIDO 2560x1600 | FurMark SIN tope (GPU 100%) + Prime95 $([Environment]::ProcessorCount) hilos AVX + RAM libre - 1,5 GB | elige lo MAS ALTO sin throttling y >= $FPS_JUEGO FPS | $Min min por prueba ==="
  Restart-PS

  # FASE 1: GPU de mayor a menor -> la primera sin throttling y con >=90 FPS
  $G = $null; $candG = @()
  foreach ($g in 0,2100,1950,1800,1700,1650) {
    if (Test-Path $stop) { break }
    $r = Run-Test "G$g" $CPU_FIJA[0] $CPU_FIJA[1] $g $Min; $todos += $r
    if ($r.fpsOk -and $r.estable) { $candG += $r }
    if ($r.fpsOk -and $r.estable -and $r.sinThrottle) { $G = $g; break }
    if (-not $r.fpsOk -and $g -gt 0) { Log "GPU $g MHz ya no sostiene $FPS_JUEGO FPS: no se baja mas"; break }
  }
  if ($null -eq $G) {
    $m = $candG | Sort-Object throttle, @{e={ if ($_.gpuL) { $_.gpuL } else { 9999 } }; Descending=$true} | Select-Object -First 1
    $G = if ($m) { $m.gpuL } else { 0 }
    Log "Ninguna GPU quedo 100% sin throttling; se usa la de menos throttling: $(Txt-Gpu $G)"
  }
  Log "FASE 1 elegida: GPU $(Txt-Gpu $G)"

  # FASE 2: CPU de mayor a menor -> la primera sin throttling
  $C = $null; $candC = @()
  foreach ($cc in @(@(0,0), @(5000,4000), @(4600,3600), @(4200,3200), @(3800,2800))) {
    if (Test-Path $stop) { break }
    $r = Run-Test "C$($cc[0])" $cc[0] $cc[1] $G $Min; $todos += $r
    if ($r.fpsOk -and $r.estable) { $candC += $r }
    if ($r.fpsOk -and $r.estable -and $r.sinThrottle) { $C = $cc; break }
  }
  if (-not $C) {
    $m = $candC | Sort-Object throttle, @{e={ if ($_.cpuP) { $_.cpuP } else { 9999 } }; Descending=$true} | Select-Object -First 1
    $C = if ($m) { @($m.cpuP, $m.cpuE) } else { $CPU_FIJA }
    Log "Ninguna CPU quedo 100% sin throttling; se usa la de menos throttling: $(Txt-Cpu $C[0] $C[1])"
  }
  Log "FASE 2 elegida: CPU $(Txt-Cpu $C[0] $C[1])"

  # FASE 3: validacion larga de la combinacion
  if (-not (Test-Path $stop)) {
    $v = Run-Test "FINAL" $C[0] $C[1] $G $MinFinal; $todos += $v
    Log "=== VALIDACION FINAL: $(if ($v.fpsOk -and $v.estable -and $v.sinThrottle) {'APROBADA'} else {'CON OBSERVACIONES (ver arriba)'}) ==="
    "ELEGIDA;$($C[0]);$($C[1]);$G" | Out-File (Join-Path $res "b90_elegida.txt") -Encoding ascii
    Set-Cpu $C[0] $C[1] | Out-Null; Set-Gpu $G | Out-Null
    "Juego 90 FPS (CPU $(Txt-Cpu $C[0] $C[1]), GPU $(Txt-Gpu $G), tope $FPS_JUEGO FPS)  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Out-File (Join-Path $base "perfil_actual.txt") -Encoding ascii
    Log "Configuracion elegida APLICADA."
  }
} catch { Log "ERROR DEL BARRIDO: $($_.Exception.Message)" }
finally {
  Stop-Process -Name prime95,furmark -Force -ErrorAction SilentlyContinue
  if (Test-Path $localBak) { Copy-Item $localBak $localTxt -Force; Remove-Item $localBak -Force } else { Remove-Item $localTxt -ErrorAction SilentlyContinue }
  & "$base\Limite_FPS.ps1" -Fps $FPS_JUEGO -SinPausa | Out-Null   # siempre vuelve al tope de juego (90)
  Remove-Item $lock -ErrorAction SilentlyContinue
  Log "=== FIN ==="
}
