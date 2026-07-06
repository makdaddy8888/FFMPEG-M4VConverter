<#
.SYNOPSIS
    Converts Blu-ray .m2ts files to MP4 using CPU encoding (no GPU required).

.DESCRIPTION
    Interactive script for systems without NVIDIA NVENC. Prompts for input and
    output folders, deinterlaces with yadif, and encodes with libx264.
    Preserves subfolder structure in the output path.

.PARAMETER InputFolder
    Folder containing .m2ts files. If omitted, prompts interactively.

.PARAMETER OutputFolder
    Destination folder for .mp4 files. If omitted, prompts interactively.

.PARAMETER FfmpegPath
    Path to ffmpeg executable.

.EXAMPLE
    .\Convert-M2tsToMp4.ps1

.EXAMPLE
    .\Convert-M2tsToMp4.ps1 -InputFolder "D:\BDMV\STREAM" -OutputFolder "D:\Output"
#>
[CmdletBinding()]
param(
    [string]$InputFolder,
    [string]$OutputFolder,
    [string]$FfmpegPath = "ffmpeg"
)

if (-not $InputFolder) {
    $InputFolder = Read-Host "Enter FULL path to input folder containing .m2ts files"
}
if (-not $OutputFolder) {
    $OutputFolder = Read-Host "Enter FULL path to output folder for .mp4 files"
}

$InputFolder = $InputFolder.Trim('"')
$OutputFolder = $OutputFolder.Trim('"')

if (-not (Test-Path $InputFolder)) {
    Write-Error "Input folder not found: $InputFolder"
    exit 1
}

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

Write-Host "Converting m2ts to MP4 (CPU / libx264)" -ForegroundColor Cyan
Write-Host "  Input:  $InputFolder"
Write-Host "  Output: $OutputFolder"
Write-Host ""

Get-ChildItem -Path $InputFolder -Filter *.m2ts -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring($InputFolder.Length).TrimStart("\")
    $outputPath = Join-Path $OutputFolder ([System.IO.Path]::ChangeExtension($relativePath, ".mp4"))

    $outputDir = Split-Path $outputPath -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    Write-Host "Converting: $($_.FullName)"
    Write-Host "  Output:   $outputPath"

    & $FfmpegPath `
        -y `
        -i "$($_.FullName)" `
        -map 0:v:0 -map 0:a? `
        -vf yadif `
        -c:v libx264 `
        -profile:v high `
        -level 4.1 `
        -pix_fmt yuv420p `
        -crf 20 `
        -preset slow `
        -c:a aac `
        -b:a 160k `
        -movflags +faststart `
        "$outputPath"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Done" -ForegroundColor Green
    } else {
        Write-Host "  Failed" -ForegroundColor Red
    }
    Write-Host ""
}

Write-Host "All conversions completed." -ForegroundColor Cyan
