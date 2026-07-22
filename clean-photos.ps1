# =====================================================================
#  clean-photos.ps1  ·  Strip hidden metadata (EXIF/GPS) from photos
# ---------------------------------------------------------------------
#  HOW TO USE
#  1. Put your original photos in the  photos-raw  folder
#  2. Right-click this file > "Run with PowerShell"  (or run it in a
#     PowerShell window:  .\clean-photos.ps1 )
#  3. Cleaned, metadata-free copies appear in the  photos  folder,
#     resized to max 1600px on the long side and named 1.jpg, 2.jpg ...
#     Those are the ones you publish. Your originals stay untouched.
# =====================================================================

Add-Type -AssemblyName System.Drawing

$root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir = Join-Path $root 'photos-raw'
$outDir = Join-Path $root 'photos'
$maxSide   = 1600         # max long-side in pixels (good quality, small file)
$quality   = 88           # JPEG quality 0-100
$watermark = 'Milan'      # text stamped on each photo ('' = no watermark)
$wmOpacity = 110          # watermark strength, 0 (invisible) - 255 (solid)

New-Item -ItemType Directory -Force -Path $srcDir | Out-Null
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$files = Get-ChildItem -Path $srcDir -File |
         Where-Object { $_.Extension -match '\.(jpg|jpeg|png|webp|bmp)$' } |
         Sort-Object Name

if ($files.Count -eq 0) {
    Write-Host "No images found in: $srcDir" -ForegroundColor Yellow
    Write-Host "Put your photos there first, then run this again." -ForegroundColor Yellow
    return
}

# JPEG encoder for quality control
$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
             Where-Object { $_.MimeType -eq 'image/jpeg' }
$encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
$encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
    [System.Drawing.Imaging.Encoder]::Quality, [long]$quality)

$i = 0
foreach ($f in $files) {
    $i++
    $img = [System.Drawing.Image]::FromFile($f.FullName)

    # Respect EXIF orientation before we drop metadata (tag 274)
    if ($img.PropertyIdList -contains 274) {
        $o = $img.GetPropertyItem(274).Value[0]
        switch ($o) {
            3 { $img.RotateFlip('Rotate180FlipNone') }
            6 { $img.RotateFlip('Rotate90FlipNone') }
            8 { $img.RotateFlip('Rotate270FlipNone') }
        }
    }

    # Compute new size (keep aspect ratio)
    $w = $img.Width; $h = $img.Height
    $scale = [Math]::Min(1.0, $maxSide / [Math]::Max($w, $h))
    $nw = [int]($w * $scale); $nh = [int]($h * $scale)

    # Draw onto a fresh bitmap -> this DROPS all EXIF/GPS metadata
    $bmp = New-Object System.Drawing.Bitmap($nw, $nh)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.InterpolationMode = 'HighQualityBicubic'
    $gfx.SmoothingMode = 'HighQuality'
    $gfx.PixelOffsetMode = 'HighQuality'
    $gfx.DrawImage($img, 0, 0, $nw, $nh)

    # Subtle watermark, bottom-right corner
    if ($watermark -ne '') {
        $gfx.TextRenderingHint = 'AntiAlias'
        $fontSize = [Math]::Max(14, [int]($nw * 0.030))
        $wmFont = New-Object System.Drawing.Font('Georgia', $fontSize, [System.Drawing.FontStyle]::Italic)
        $textSize = $gfx.MeasureString($watermark, $wmFont)
        $tx = $nw - $textSize.Width - ($nw * 0.025)
        $ty = $nh - $textSize.Height - ($nh * 0.02)
        # soft shadow for readability on light and dark photos
        $shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb([int]($wmOpacity*0.6),0,0,0))
        $gold   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($wmOpacity,230,201,131))
        $gfx.DrawString($watermark, $wmFont, $shadow, ($tx+2), ($ty+2))
        $gfx.DrawString($watermark, $wmFont, $gold,   $tx, $ty)
        $wmFont.Dispose(); $shadow.Dispose(); $gold.Dispose()
    }

    $outPath = Join-Path $outDir ("{0}.jpg" -f $i)
    $bmp.Save($outPath, $jpegCodec, $encParams)

    $gfx.Dispose(); $bmp.Dispose(); $img.Dispose()
    Write-Host ("Cleaned  {0}  ->  photos\{1}.jpg  ({2}x{3})" -f $f.Name, $i, $nw, $nh) -ForegroundColor Green
}

Write-Host ""
Write-Host ("Done. {0} photo(s) cleaned into: {1}" -f $files.Count, $outDir) -ForegroundColor Cyan
Write-Host "All GPS/EXIF metadata removed. Safe to publish." -ForegroundColor Cyan
if ($watermark -ne '') { Write-Host ("Watermark '{0}' added to each photo." -f $watermark) -ForegroundColor Cyan }
