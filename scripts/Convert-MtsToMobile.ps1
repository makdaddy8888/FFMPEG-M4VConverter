<#
.SYNOPSIS
    One-step MTS to 480p HEVC conversion with a fixed bitrate cap.

.DESCRIPTION
    Combines deinterlacing, downscaling to 854x480, and HEVC encoding in a
    single pass. Uses a 2 Mbps video bitrate cap for predictable file sizes.
    Useful when you want a mobile copy directly from raw .MTS without a
    separate archive step.

.PARAMETER InputFolder
    Folder containing .MTS source files.

.PARAMETER OutputFolder
    Folder for 480p .mp4 output.

.PARAMETER FfmpegPath
    Path to ffmpeg executable.

.EXAMPLE
    .\Convert-MtsToMobile.ps1 -InputFolder "D:\Camcorder\STREAM" -OutputFolder "D:\Mobile"

.NOTES
    For best quality, use the two-step pipeline: Convert-MtsToArchive then Convert-ToIphone.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFolder,

    [Parameter(Mandatory = $true)]
    [string]$OutputFolder,

    [string]$FfmpegPath = "ffmpeg"
)

if (-not (Test-Path $InputFolder)) {
    Write-Error "Input folder not found: $InputFolder"
    exit 1
}

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

Write-Host "Converting MTS to 480p mobile MP4 (bitrate capped)" -ForegroundColor Cyan
Write-Host "  Input:  $InputFolder"
Write-Host "  Output: $OutputFolder"
Write-Host ""

$files = Get-ChildItem -Path $InputFolder -Filter *.MTS -File
if ($files.Count -eq 0) {
    Write-Warning "No .MTS files found in $InputFolder"
    exit 0
}

foreach ($file in $files) {
    $outputPath = Join-Path $OutputFolder ($file.BaseName + ".mp4")

    Write-Host "Processing $($file.Name)..."

    & $FfmpegPath `
        -y `
        -fflags +genpts `
        -i "$($file.FullName)" `
        -vf "yadif,scale=854:480" `
        -map 0:v:0 -map 0:a? `
        -vsync vfr `
        -af aresample=async=1 `
        -c:v hevc_nvenc `
        -preset p5 `
        -profile:v main `
        -pix_fmt yuv420p `
        -rc vbr `
        -b:v 2M `
        -maxrate 2.5M `
        -bufsize 4M `
        -movflags +faststart `
        -c:a aac `
        -b:a 128k `
        "$outputPath"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Done: $outputPath" -ForegroundColor Green
    } else {
        Write-Host "  Failed: $($file.Name)" -ForegroundColor Red
    }
    Write-Host ""
}

Write-Host "Mobile conversion complete." -ForegroundColor Cyan
