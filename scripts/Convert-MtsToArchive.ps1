<#
.SYNOPSIS
    Converts AVCHD .MTS files to 1080p HEVC MP4 archive copies.

.DESCRIPTION
    Step 1 of the recommended pipeline. Deinterlaces interlaced camcorder
    footage (yadif), encodes to HEVC via NVIDIA NVENC, and remuxes audio
    to AAC. Requires an NVIDIA GPU with NVENC support.

    Source files are typically copied from an SD card:
    PRIVATE/AVCHD/BDMV/STREAM/*.MTS

.PARAMETER InputFolder
    Folder containing .MTS source files.

.PARAMETER OutputFolder
    Folder for 1080p .mp4 archive output.

.PARAMETER FfmpegPath
    Path to ffmpeg executable. Defaults to 'ffmpeg' on PATH.

.EXAMPLE
    .\Convert-MtsToArchive.ps1 -InputFolder "D:\Camcorder\STREAM" -OutputFolder "D:\Archive"

.NOTES
    CPU-only fallback: replace hevc_nvenc with libx265 and remove GPU-specific flags.
    See docs/WORKFLOW.md for flag explanations.
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

Write-Host "Converting MTS to 1080p HEVC archive (deinterlaced)" -ForegroundColor Cyan
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
        -vf "yadif=mode=1" `
        -map 0:v:0 -map 0:a? `
        -vsync vfr `
        -af aresample=async=1 `
        -c:v hevc_nvenc `
        -preset p5 `
        -profile:v main `
        -pix_fmt yuv420p `
        -rc vbr `
        -cq 27 `
        -maxrate 6M `
        -bufsize 12M `
        -movflags +faststart `
        -c:a aac `
        -b:a 192k `
        "$outputPath"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Done: $outputPath" -ForegroundColor Green
    } else {
        Write-Host "  Failed: $($file.Name)" -ForegroundColor Red
    }
    Write-Host ""
}

Write-Host "Archive conversion complete." -ForegroundColor Cyan
