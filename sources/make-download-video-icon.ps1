# Auto-elevate to Administrator
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process PowerShell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# make-download-video-icon.ps1
# Regenerates optional\download-video.ico: a Vista Aero style glass orb (Twitch purple -> YouTube
# red -> Instagram pink/orange), white download arrow, gloss cap, rim light, drop shadow. Every
# size (16..256) is drawn natively from the same 256-unit design grid so small icons stay crisp
# instead of being blurred downscales. Pure System.Drawing, no external tools.
Add-Type -AssemblyName System.Drawing
function C([int]$a, [int]$r, [int]$gg, [int]$b) { [System.Drawing.Color]::FromArgb($a, $r, $gg, $b) }
function P([single]$x, [single]$y) { New-Object System.Drawing.PointF $x, $y }

# Draws the orb natively at any size (k = scale from the 256 design grid) so small sizes stay crisp.
function Render([int]$S) {
    $k = $S / 256.0
    $bmp = New-Object System.Drawing.Bitmap $S, $S
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.CompositingQuality = 'HighQuality'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)

    $cx = 128 * $k; $cy = 116 * $k; $R = 106 * $k
    $small = $S -lt 40

    # --- tight drop shadow (few stacked ellipses, low spread)
    if (-not $small) {
        for ($i = 6; $i -ge 1; $i--) {
            $a = [int](6 + $i * 3)
            $w = (170 + $i * 4) * $k; $h = (30 + $i * 2) * $k
            $g.FillEllipse((New-Object System.Drawing.SolidBrush (C $a 40 0 40)), [single]($cx - $w/2), [single](216 * $k - $h/2), [single]$w, [single]$h)
        }
    }

    $orb = New-Object System.Drawing.Drawing2D.GraphicsPath
    $orb.AddEllipse([single]($cx - $R), [single]($cy - $R), [single](2*$R), [single](2*$R))
    $g.SetClip((New-Object System.Drawing.Region $orb), 'Replace')

    # --- brand sweep: Twitch purple -> YouTube red -> Instagram pink -> orange (left to right, slight diagonal)
    $sweep = New-Object System.Drawing.Drawing2D.LinearGradientBrush (P ($cx - $R) ($cy - 40*$k)), (P ($cx + $R) ($cy + 40*$k)), (C 255 145 70 255), (C 255 252 130 50)
    $blend = New-Object System.Drawing.Drawing2D.ColorBlend
    $blend.Colors = [System.Drawing.Color[]]@((C 255 110 30 255), (C 255 145 70 255), (C 255 255 0 0), (C 255 255 0 0), (C 255 235 45 110), (C 255 255 130 40))
    $blend.Positions = [single[]]@(0, 0.16, 0.42, 0.58, 0.82, 1)
    $sweep.InterpolationColors = $blend
    $g.FillPath($sweep, $orb)

    # --- 3D shading: clear at the light source, darker toward the edge (kept light so colours stay vivid)
    $pg = New-Object System.Drawing.Drawing2D.PathGradientBrush $orb
    $pg.CenterPoint = P ($cx - 28*$k) ($cy - 42*$k)
    $pg.CenterColor = C 0 0 0 0
    $pg.SurroundColors = [System.Drawing.Color[]]@((C 85 25 0 45))
    $g.FillPath($pg, $orb)

    # --- warm rim light hugging the bottom edge
    $rim = New-Object System.Drawing.Drawing2D.GraphicsPath
    $rim.AddEllipse([single]($cx - $R + 10*$k), [single]($cy - $R + 60*$k), [single](2*$R - 20*$k), [single](2*$R - 50*$k))
    $rimBr = New-Object System.Drawing.Drawing2D.PathGradientBrush $rim
    $rimBr.CenterPoint = P $cx ($cy + $R - 6*$k)
    $rimBr.CenterColor = C 130 255 210 150
    $rimBr.SurroundColors = [System.Drawing.Color[]]@((C 0 255 210 150))
    $g.FillPath($rimBr, $rim)

    # --- hard-edged glass highlight (classic Aero cap)
    $hl = New-Object System.Drawing.Drawing2D.GraphicsPath
    $hl.AddEllipse([single]($cx - $R + 12*$k), [single]($cy - $R + 4*$k), [single](2*$R - 24*$k), [single]($R - 4*$k))
    $hlBr = New-Object System.Drawing.Drawing2D.LinearGradientBrush (P 0 ($cy - $R + 4*$k)), (P 0 ($cy)), (C 165 255 255 255), (C 20 255 255 255)
    $g.FillPath($hlBr, $hl)
    $g.ResetClip()

    # --- crisp outline
    $ow = [Math]::Max(1.0, 3.0 * $k)
    $g.DrawEllipse((New-Object System.Drawing.Pen (C 220 60 0 55), $ow), [single]($cx - $R), [single]($cy - $R), [single](2*$R), [single](2*$R))

    # --- arrow: shaft + head, hard shadow, white with a faint warm gradient, dark outline
    $pts = @(@(108,54), @(148,54), @(148,116), @(184,116), @(128,176), @(72,116), @(108,116))
    $arrow = New-Object System.Drawing.Drawing2D.GraphicsPath
    $arrow.AddPolygon([System.Drawing.PointF[]]($pts | ForEach-Object { P ($_[0]*$k) ($_[1]*$k) }))
    $m = New-Object System.Drawing.Drawing2D.Matrix; $m.Translate([single](3*$k), [single](4*$k))
    $shadow = $arrow.Clone(); $shadow.Transform($m)
    if (-not $small) { $g.FillPath((New-Object System.Drawing.SolidBrush (C 150 60 0 50)), $shadow) }
    $aBr = New-Object System.Drawing.Drawing2D.LinearGradientBrush (P 0 (54*$k)), (P 0 (176*$k)), (C 255 255 255 255), (C 255 255 236 236)
    $g.FillPath($aBr, $arrow)
    $aw = [Math]::Max(1.0, 2.0 * $k)
    $g.DrawPath((New-Object System.Drawing.Pen (C 200 95 10 60), $aw), $arrow)

    # --- sparkle
    if (-not $small) {
        $sp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $sp.AddEllipse([single](58*$k), [single](40*$k), [single](28*$k), [single](16*$k))
        $spBr = New-Object System.Drawing.Drawing2D.PathGradientBrush $sp
        $spBr.CenterColor = C 240 255 255 255; $spBr.SurroundColors = [System.Drawing.Color[]]@((C 0 255 255 255))
        $g.FillPath($spBr, $sp)
    }
    $g.Dispose()
    return $bmp
}

$pngs = @()
foreach ($sz in 256, 128, 64, 48, 40, 32, 24, 20, 16) {
    $b = Render $sz
    $ms = New-Object IO.MemoryStream
    $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += ,@{ Size = $sz; Bytes = $ms.ToArray() }
    $ms.Dispose(); $b.Dispose()
}
$out = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter $out
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$pngs.Count)
$offset = 6 + 16 * $pngs.Count
foreach ($p in $pngs) {
    $dim = if ($p.Size -ge 256) { 0 } else { $p.Size }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$p.Bytes.Length); $bw.Write([uint32]$offset)
    $offset += $p.Bytes.Length
}
foreach ($p in $pngs) { $bw.Write($p.Bytes) }
$bw.Flush()
$ico = Join-Path (Split-Path $PSScriptRoot -Parent) 'optional\download-video.ico'
[IO.File]::WriteAllBytes($ico, $out.ToArray())
"wrote $ico ($([Math]::Round((Get-Item $ico).Length/1KB)) KB, $($pngs.Count) sizes)"
[IO.File]::WriteAllBytes((Join-Path $env:TEMP 'download-video-icon-preview.png'), $pngs[0].Bytes); "preview: $env:TEMP\download-video-icon-preview.png"
