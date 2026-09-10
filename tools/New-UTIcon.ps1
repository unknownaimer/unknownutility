<#
.SYNOPSIS
    Rebuilds assets/icon.ico (and the small window icon) from assets/icon.png.
.DESCRIPTION
    Windows picks a different size out of an .ico for every place it draws it: 16 in a title bar,
    32 on the taskbar, 48 in Explorer's medium view, 256 in the extra-large view and the Alt-Tab
    switcher on a high-DPI screen. Shipping one bitmap and letting Windows resample it is what makes
    an icon look muddy, so every size is resampled here from the full-resolution source.

    Only the 256 record is stored as PNG; every smaller one is a classic 32-bit BMP. Vista and later
    read PNG records at any size, but plenty of consumers do not: GDI+ (System.Drawing.Icon, still
    behind installers, antivirus consoles and older tools) decodes a PNG record as though it were a
    DIB and draws confetti. Windows' own icons draw the same line at 256, where a BMP record would
    cost a quarter of a megabyte on its own.
.PARAMETER Source
    The artwork. Defaults to assets/icon.png. Anything not square is centre-cropped first.
#>
[CmdletBinding()]
param([string]$Source, [string]$OutFile)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Source) { $Source = Join-Path $root 'assets\icon.png' }
if (-not $OutFile) { $OutFile = Join-Path $root 'assets\icon.ico' }
if (-not (Test-Path -LiteralPath $Source)) { throw "No artwork at $Source." }

Add-Type -AssemblyName System.Drawing

function Get-UTSquareBitmap {
    param([System.Drawing.Image]$Image, [int]$Size)
    $side = [Math]::Min($Image.Width, $Image.Height)
    $src = New-Object System.Drawing.Rectangle ([int](($Image.Width - $side) / 2)), ([int](($Image.Height - $side) / 2)), $side, $side
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $dst = New-Object System.Drawing.Rectangle 0, 0, $Size, $Size
        $g.DrawImage($Image, $dst, $src.X, $src.Y, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel)
    } finally { $g.Dispose() }
    return $bmp
}

function Get-UTPngBytes {
    param([System.Drawing.Bitmap]$Bitmap)
    $ms = New-Object System.IO.MemoryStream
    try { $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); return $ms.ToArray() } finally { $ms.Dispose() }
}

function Get-UTDibBytes {
    # A 32-bit BITMAPINFOHEADER record: bottom-up BGRA rows, then the 1-bit AND mask the format
    # still requires. The mask stays zero because the alpha channel already carries transparency.
    param([System.Drawing.Bitmap]$Bitmap)
    $w = $Bitmap.Width; $h = $Bitmap.Height
    $maskStride = [int]([Math]::Floor(($w + 31) / 32)) * 4
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    try {
        $bw.Write([int]40); $bw.Write([int]$w); $bw.Write([int]($h * 2))
        $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]0)
        $bw.Write([int]($w * 4 * $h + $maskStride * $h))
        $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)

        $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
        $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        try {
            $row = New-Object byte[] ($w * 4)
            for ($y = $h - 1; $y -ge 0; $y--) {
                [System.Runtime.InteropServices.Marshal]::Copy([IntPtr]($data.Scan0.ToInt64() + $y * $data.Stride), $row, 0, $row.Length)
                $bw.Write($row, 0, $row.Length)
            }
        } finally { $Bitmap.UnlockBits($data) }

        $bw.Write((New-Object byte[] ($maskStride * $h)), 0, $maskStride * $h)
        $bw.Flush()
        return $ms.ToArray()
    } finally { $bw.Dispose(); $ms.Dispose() }
}

function Get-UTIcoBytes {
    param([object[]]$Records)
    $out = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $out
    try {
        $bw.Write([int16]0); $bw.Write([int16]1); $bw.Write([int16]$Records.Count)
        $offset = 6 + 16 * $Records.Count
        foreach ($r in $Records) {
            # 256 is written as 0: the directory stores each dimension in a single byte.
            $dim = if ($r.Size -ge 256) { 0 } else { $r.Size }
            $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
            $bw.Write([int16]1); $bw.Write([int16]32)
            $bw.Write([int]$r.Bytes.Length); $bw.Write([int]$offset)
            $offset += $r.Bytes.Length
        }
        foreach ($r in $Records) { $bw.Write($r.Bytes, 0, $r.Bytes.Length) }
        $bw.Flush()
        return $out.ToArray()
    } finally { $bw.Dispose(); $out.Dispose() }
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$image = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Source).Path)
try {
    $records = foreach ($size in $sizes) {
        $bmp = Get-UTSquareBitmap -Image $image -Size $size
        try {
            $bytes = if ($size -ge 256) { Get-UTPngBytes -Bitmap $bmp } else { Get-UTDibBytes -Bitmap $bmp }
            [pscustomobject]@{ Size = $size; Bytes = $bytes }
        } finally { $bmp.Dispose() }
    }
    $records = @($records)
} finally { $image.Dispose() }

[System.IO.File]::WriteAllBytes($OutFile, (Get-UTIcoBytes -Records $records))
$info = Get-Item -LiteralPath $OutFile
Write-Host ("Wrote {0} ({1:N0} bytes, {2} sizes: {3})" -f $info.FullName, $info.Length, $sizes.Count, ($sizes -join ', '))

# The window icon is a second, deliberately small .ico carried inside the compiled script as base64.
# The one-liner has no file next to it to read an icon from, so the only way the running window and
# its taskbar button carry the artwork is to embed it. Only the four sizes WPF actually asks for go
# in: 16 and 24 for the title bar, 32 and 48 for the taskbar and Alt-Tab at 100% and 150% DPI.
$embedSizes = @(16, 24, 32, 48)
$embed = Get-UTIcoBytes -Records @($records | Where-Object { $embedSizes -contains $_.Size })
$b64 = [Convert]::ToBase64String($embed)
$lines = for ($i = 0; $i -lt $b64.Length; $i += 96) { "    '" + $b64.Substring($i, [Math]::Min(96, $b64.Length - $i)) + "'" }

$fnPath = Join-Path $root 'functions\private\Get-UTAppIcon.ps1'
$fn = @"
function Get-UTAppIcon {
    <#
    .SYNOPSIS
        The app icon, as a WPF image source for Window.Icon.
    .DESCRIPTION
        GENERATED by tools/New-UTIcon.ps1 from assets/icon.png. Do not edit by hand.

        A script delivered by ``irm | iex`` has no file on disk beside it, so the artwork travels
        inside it. The frame handed back belongs to an IconBitmapDecoder holding every size, and
        WPF picks the closest one per surface from that decoder rather than resampling one bitmap.
        Cosmetic: any failure returns `$null` and the window simply keeps the PowerShell icon.
    #>
    if (`$script:UTAppIconCache) { return `$script:UTAppIconCache }
    try {
        `$bytes = [Convert]::FromBase64String((`$UTAppIconData -join ''))
        `$stream = New-Object System.IO.MemoryStream (, `$bytes)
        `$decoder = New-Object System.Windows.Media.Imaging.IconBitmapDecoder `$stream, 'None', 'OnLoad'
        `$script:UTAppIconCache = `$decoder.Frames[0]
        return `$script:UTAppIconCache
    } catch { return `$null }
}

`$UTAppIconData = @(
$($lines -join "`r`n")
)
"@
[System.IO.File]::WriteAllText($fnPath, ($fn -replace "`r?`n", "`r`n"), (New-Object System.Text.ASCIIEncoding))
Write-Host ("Wrote {0} ({1:N0} bytes of base64, sizes {2})" -f $fnPath, $b64.Length, ($embedSizes -join ', '))
