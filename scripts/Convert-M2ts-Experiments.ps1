<#
.SYNOPSIS
    Reference script with alternative FFmpeg commands for m2ts conversion.

.DESCRIPTION
    Not intended for production use. Shows commented-out FFmpeg one-liners
    for comparing copy vs re-encode, metadata mapping, and deinterlace options.
    Uncomment the approach you want to test.

.PARAMETER InputFolder
    Folder containing .m2ts source files.

.PARAMETER OutputFolder
    Folder for .m4v output.

.PARAMETER FfmpegPath
    Path to ffmpeg executable.

.EXAMPLE
    .\Convert-M2ts-Experiments.ps1 -InputFolder "D:\BDMV\STREAM" -OutputFolder "D:\Test"
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

Write-Host "m2ts conversion experiments (edit script to change active command)" -ForegroundColor Yellow

Get-ChildItem $InputFolder -Filter *.m2ts -File | ForEach-Object {
    $in  = $_.FullName
    $out = Join-Path $OutputFolder ($_.BaseName + ".m4v")

    Write-Host "Processing: $($_.Name)"

    # Option 1: Stream copy (fastest, no re-encode)
    # & $FfmpegPath -i $in -c:v copy -c:a copy $out

    # Option 2: Copy video, re-encode audio to AAC
    # & $FfmpegPath -i $in -c:v copy -c:a aac -b:a 192k $out

    # Option 3: Copy video with metadata, AAC audio
    # & $FfmpegPath -i $in -map_metadata 0 -c:v copy -c:a aac -b:a 192k $out

    # Option 4: Full re-encode with libx264
    # & $FfmpegPath -i $in -c:v libx264 -preset medium -profile:v high -level 4.0 -pix_fmt yuv420p -c:a aac -ac 2 -b:a 160k $out

    # Option 5: Re-encode with metadata preservation
    # & $FfmpegPath -i $in -map_metadata 0 -c:v libx264 -preset medium -profile:v high -level 4.0 -pix_fmt yuv420p -c:a aac -ac 2 -b:a 160k $out

    # Option 6: Deinterlace + re-encode
    # & $FfmpegPath -i $in -vf yadif -c:v libx264 -preset medium -profile:v high -level 4.0 -pix_fmt yuv420p -c:a aac -ac 2 -b:a 160k $out

    # Active: copy video stream, AAC audio (note: -preset on copy is ignored by FFmpeg)
    & $FfmpegPath -i $in -c:v copy -c:a aac -ac 2 -b:a 160k $out
}

Write-Host "Done." -ForegroundColor Cyan
