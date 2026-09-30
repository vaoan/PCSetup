# icon-writer.ps1 - dot-sourced by make-*-icon.ps1. Writes a Windows .ico whose every entry is
# NATIVE: each size is rendered by the caller's Render scriptblock at exactly that pixel size,
# and stored the way Explorer actually reads it.
#
# Two things made the first icons look "scaled up" in Explorer:
#   1. Every entry was PNG-compressed. Only the 256 px entry is supposed to be (Vista+); for the
#      smaller sizes many shell paths ignore PNG entries and fall back to downscaling the 256 one,
#      which is soft. Below 256 an entry must be a plain 32-bit DIB (BITMAPINFOHEADER, BGRA rows
#      bottom-up, then the 1-bit AND mask) - that is what this writes.
#   2. The sizes Explorer asks for were missing. At 100 % it wants 16 (list/details), 32, 48
#      (medium), 96 (large) and 256 (extra large); at 125 % also 20/40/60/120; at 150 % 24/36/72/144.
#      A missing size is the nearest one resampled. The default list below covers all of them.
Add-Type -AssemblyName System.Drawing

function ConvertTo-IconDib([System.Drawing.Bitmap]$Bitmap) {
    $w = $Bitmap.Width; $h = $Bitmap.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $px = New-Object byte[] ($stride * $h)
    [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $px, 0, $px.Length)
    $Bitmap.UnlockBits($data)
    $maskStride = [int]([Math]::Ceiling($w / 32.0) * 4)
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter $ms
    # BITMAPINFOHEADER: height is doubled because the AND mask follows the colour bits.
    $bw.Write([int32]40); $bw.Write([int32]$w); $bw.Write([int32]($h * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int32]0); $bw.Write([int32]($w * $h * 4 + $maskStride * $h)); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0)
    # XOR bits: rows bottom-up; Format32bppArgb is already B,G,R,A in memory.
    for ($y = $h - 1; $y -ge 0; $y--) { $bw.Write($px, $y * $stride, $w * 4) }
    # AND mask: 1 = transparent, MSB first, rows bottom-up, padded to 4 bytes.
    for ($y = $h - 1; $y -ge 0; $y--) {
        $row = New-Object byte[] $maskStride
        for ($x = 0; $x -lt $w; $x++) {
            # ($x -shr 3), not [int]($x / 8): PowerShell's [int] cast rounds to even, so 15/8 -> 2.
            if ($px[$y * $stride + $x * 4 + 3] -eq 0) { $row[$x -shr 3] = $row[$x -shr 3] -bor (0x80 -shr ($x -band 7)) }
        }
        $bw.Write($row)
    }
    $bw.Flush()
    # The comma keeps the byte[] in one piece: a bare "return $bytes" unrolls it into the pipeline
    # and it comes back as an object[], which BinaryWriter.Write then serialises as something else
    # entirely - the first native icons were 70 KB files whose entry offsets pointed past the end.
    return ,$ms.ToArray()
}

# Renders every size through $Render (a scriptblock taking the pixel size and returning a Bitmap),
# writes $Path, and drops 256 px and 32 px previews as PNGs in %TEMP% for a look.
function Write-NativeIcon([string]$Path, [scriptblock]$Render, [string]$PreviewName,
                          [int[]]$Sizes = @(256, 144, 128, 120, 96, 72, 64, 60, 48, 40, 36, 32, 24, 20, 16)) {
    $entries = @()
    foreach ($sz in $Sizes) {
        $b = & $Render $sz
        if ($sz -ge 256) {
            $ms = New-Object IO.MemoryStream
            $b.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $entries += ,@{ Size = $sz; Bytes = $ms.ToArray(); Kind = 'PNG' }
            $ms.Dispose()
        } else {
            $entries += ,@{ Size = $sz; Bytes = [byte[]](ConvertTo-IconDib $b); Kind = 'DIB' }
        }
        if ($PreviewName -and ($sz -eq 256 -or $sz -eq 32 -or $sz -eq 96)) {
            $b.Save((Join-Path $env:TEMP "$PreviewName-icon-preview-$sz.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        }
        $b.Dispose()
    }
    $out = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter $out
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$entries.Count)
    $offset = 6 + 16 * $entries.Count
    foreach ($e in $entries) {
        $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$e.Bytes.Length); $bw.Write([uint32]$offset)
        $offset += $e.Bytes.Length
    }
    foreach ($e in $entries) { $bw.Write([byte[]]$e.Bytes) }
    $bw.Flush()
    $all = $out.ToArray()
    if ($all.Length -ne $offset) { throw "icon writer: wrote $($all.Length) bytes, expected $offset - an entry was mangled" }
    [IO.File]::WriteAllBytes($Path, $all)
    "wrote $Path ($([Math]::Round((Get-Item $Path).Length/1KB)) KB, $($entries.Count) sizes: $(($entries | ForEach-Object { "$($_.Size)$(if ($_.Kind -eq 'PNG') { 'png' })" }) -join ' '))"
    if ($PreviewName) { "previews: $env:TEMP\$PreviewName-icon-preview-{256,96,32}.png" }
}
