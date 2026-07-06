<#
.SYNOPSIS
    Downscales archive MP4 files to iPhone-friendly 480p HEVC with preserved dates.

.DESCRIPTION
    Step 2 of the recommended pipeline. Reads the original recording timestamp
    from ffprobe, downscales to 854x480, encodes HEVC via NVENC, writes
    creation_time metadata, and syncs Windows file timestamps.

.PARAMETER InputFolder
    Folder containing source .mp4 files (typically archive output from Convert-MtsToArchive).

.PARAMETER OutputFolder
    Folder for iPhone-sized .mp4 output.

.PARAMETER FfmpegPath
    Path to ffmpeg executable.

.PARAMETER FfprobePath
    Path to ffprobe executable.

.EXAMPLE
    .\Convert-ToIphone.ps1 -InputFolder "D:\Archive" -OutputFolder "D:\iPhone"

.NOTES
    Get-RecordingTime checks format tags, stream tags, then filesystem dates.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFolder,

    [Parameter(Mandatory = $true)]
    [string]$OutputFolder,

    [string]$FfmpegPath = "ffmpeg",
    [string]$FfprobePath = "ffprobe"
)

function Get-RecordingTime {
    param([string]$FilePath)

    $json = & $FfprobePath `
        -v quiet `
        -print_format json `
        -show_entries format_tags=creation_time `
        -show_entries stream_tags=creation_time `
        $FilePath | ConvertFrom-Json

    if ($json.format.tags.creation_time) {
        return [DateTime]::Parse($json.format.tags.creation_time)
    }

    foreach ($stream in $json.streams) {
        if ($stream.tags.creation_time) {
            return [DateTime]::Parse($stream.tags.creation_time)
        }
    }

    return (Get-Item $FilePath).CreationTime
}

if (-not (Test-Path $InputFolder)) {
    Write-Error "Input folder not found: $InputFolder"
    exit 1
}

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

Write-Host "Converting to iPhone 480p HEVC (preserving recording dates)" -ForegroundColor Cyan
Write-Host "  Input:  $InputFolder"
Write-Host "  Output: $OutputFolder"
Write-Host ""

$files = Get-ChildItem -Path $InputFolder -Filter *.mp4 -File
if ($files.Count -eq 0) {
    Write-Warning "No .mp4 files found in $InputFolder"
    exit 0
}

foreach ($file in $files) {
    $recordedDate = Get-RecordingTime $file.FullName
    $creationTime = $recordedDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $outputPath = Join-Path $OutputFolder ($file.BaseName + ".mp4")

    Write-Host "Converting: $($file.Name)"
    Write-Host "  Recorded: $creationTime"

    & $FfmpegPath `
        -y `
        -hwaccel cuda `
        -i "$($file.FullName)" `
        -map 0:v:0 -map 0:a? `
        -vf "yadif=mode=1,scale=854:480" `
        -fps_mode vfr `
        -c:v hevc_nvenc `
        -preset p5 `
        -rc vbr `
        -cq 27 `
        -pix_fmt yuv420p `
        -c:a aac `
        -b:a 128k `
        -movflags +faststart+use_metadata_tags `
        -metadata creation_time="$creationTime" `
        -metadata title="$($file.BaseName)" `
        "$outputPath"

    if (-not (Test-Path $outputPath)) {
        Write-Host "  Encode failed" -ForegroundColor Red
        continue
    }

    # Match Windows file timestamps to the original recording date
    $output = Get-Item $outputPath
    $output.CreationTime = $recordedDate
    $output.LastWriteTime = $recordedDate

    Write-Host "  Done: $outputPath" -ForegroundColor Green
    Write-Host ""
}

Write-Host "iPhone conversion complete." -ForegroundColor Cyan
