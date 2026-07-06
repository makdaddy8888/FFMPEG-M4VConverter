<#
.SYNOPSIS
    Batch-converts videos to 720p HEVC for larger phone/tablet screens.

.DESCRIPTION
    Recursively finds mp4, mkv, avi, and mov files and encodes them to
    1280x720 HEVC using CUDA scaling and NVENC. Skips files already converted.
    Does not preserve creation_time metadata — use Convert-ToIphone.ps1 if dates matter.

.PARAMETER InputFolder
    Root folder to scan recursively for video files.

.PARAMETER OutputFolder
    Folder for 720p .mp4 output (suffix _iphone.mp4).

.PARAMETER FfmpegPath
    Path to ffmpeg executable.

.EXAMPLE
    .\Convert-ToIphone720.ps1 -InputFolder "D:\Videos" -OutputFolder "D:\iPhone720"

.NOTES
    Optimized for NVIDIA GPUs with CUDA and NVENC (e.g. GTX 1070).
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

Write-Host "Converting to 720p iPhone HEVC (GPU accelerated)" -ForegroundColor Cyan
Write-Host "  Input:  $InputFolder"
Write-Host "  Output: $OutputFolder"
Write-Host ""

$files = Get-ChildItem -Path $InputFolder -Include *.mp4, *.mkv, *.avi, *.mov -Recurse -File

foreach ($file in $files) {
    $outputFile = Join-Path $OutputFolder ($file.BaseName + "_iphone.mp4")

    if (Test-Path $outputFile) {
        Write-Host "Skipping (exists): $($file.Name)"
        continue
    }

    Write-Host "Converting: $($file.Name)"

    & $FfmpegPath -y `
        -hwaccel cuda `
        -hwaccel_output_format cuda `
        -i "$($file.FullName)" `
        -vf "scale_cuda=1280:720,hwdownload,format=yuv420p" `
        -c:v hevc_nvenc `
        -preset p5 `
        -rc vbr `
        -cq 28 `
        -b:v 0 `
        -pix_fmt yuv420p `
        -profile:v main `
        -level 4.1 `
        -movflags +faststart `
        -c:a aac `
        -b:a 128k `
        $outputFile

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Finished: $($file.Name)" -ForegroundColor Green
    } else {
        Write-Host "  Failed: $($file.Name)" -ForegroundColor Red
    }
    Write-Host ""
}

Write-Host "All files processed." -ForegroundColor Cyan
