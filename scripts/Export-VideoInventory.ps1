<#
.SYNOPSIS
    Scans a folder for video files and exports technical details to CSV.

.DESCRIPTION
    Uses ffprobe to collect codec, resolution, duration, bitrate, and date
    information for every video file found. Useful before batch conversion
    to understand source formats and plan encoding settings.

.PARAMETER RootPath
    Root folder to scan recursively.

.PARAMETER OutputFile
    Path for the CSV report. Defaults to video-inventory.csv in the current directory.

.PARAMETER Extensions
    File extensions to include. Defaults to common video formats including .MTS.

.PARAMETER FfprobePath
    Path to ffprobe executable.

.EXAMPLE
    .\Export-VideoInventory.ps1 -RootPath "D:\Camcorder" -OutputFile ".\inventory.csv"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,

    [string]$OutputFile = ".\video-inventory.csv",

    [string[]]$Extensions = @("*.mp4", "*.mts", "*.MTS", "*.avi", "*.mkv", "*.mov", "*.wmv", "*.flv", "*.m4v"),

    [string]$FfprobePath = "ffprobe"
)

try {
    $null = Get-Command $FfprobePath -ErrorAction Stop
} catch {
    Write-Error "ffprobe not found. Install FFmpeg and ensure it is in your PATH."
    exit 1
}

if (-not (Test-Path $RootPath)) {
    Write-Error "Root path not found: $RootPath"
    exit 1
}

Write-Host "Scanning $RootPath for video files..." -ForegroundColor Cyan

$videoFiles = @()
foreach ($ext in $Extensions) {
    $videoFiles += Get-ChildItem -Path $RootPath -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
}

Write-Host "Found $($videoFiles.Count) files. Analyzing..." -ForegroundColor Green

$results = @()
$counter = 0

foreach ($file in $videoFiles) {
    $counter++
    Write-Progress -Activity "Analyzing videos" -Status $file.Name -PercentComplete (($counter / $videoFiles.Count) * 100)

    try {
        $ffprobeOutput = & $FfprobePath -v quiet -print_format json -show_format -show_streams $file.FullName 2>&1 | Out-String

        if ($ffprobeOutput) {
            $videoInfo = $ffprobeOutput | ConvertFrom-Json
            $videoStream = $videoInfo.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
            $audioStream = $videoInfo.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1

            $results += [PSCustomObject]@{
                FileName         = $file.Name
                FilePath         = $file.FullName
                Directory        = $file.DirectoryName
                FileSizeMB       = [math]::Round($file.Length / 1MB, 2)
                FileCreationTime = $file.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
                FileModifiedTime = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                FormatName       = $videoInfo.format.format_long_name
                Duration         = if ($videoInfo.format.duration) { [math]::Round([double]$videoInfo.format.duration, 2) } else { "N/A" }
                DurationReadable = if ($videoInfo.format.duration) {
                    [TimeSpan]::FromSeconds([double]$videoInfo.format.duration).ToString("hh\:mm\:ss")
                } else { "N/A" }
                Bitrate          = if ($videoInfo.format.bit_rate) { [math]::Round([double]$videoInfo.format.bit_rate / 1000, 0) } else { "N/A" }
                VideoCodec       = if ($videoStream) { $videoStream.codec_name } else { "N/A" }
                VideoCodecLong   = if ($videoStream) { $videoStream.codec_long_name } else { "N/A" }
                VideoProfile     = if ($videoStream.profile) { $videoStream.profile } else { "N/A" }
                Width            = if ($videoStream) { $videoStream.width } else { "N/A" }
                Height           = if ($videoStream) { $videoStream.height } else { "N/A" }
                Resolution       = if ($videoStream) { "$($videoStream.width)x$($videoStream.height)" } else { "N/A" }
                AspectRatio      = if ($videoStream.display_aspect_ratio) { $videoStream.display_aspect_ratio } else { "N/A" }
                FrameRate        = if ($videoStream.r_frame_rate) {
                    $fps = $videoStream.r_frame_rate -split '/'
                    if ($fps.Count -eq 2 -and [double]$fps[1] -ne 0) {
                        [math]::Round([double]$fps[0] / [double]$fps[1], 2)
                    } else { $videoStream.r_frame_rate }
                } else { "N/A" }
                PixelFormat      = if ($videoStream.pix_fmt) { $videoStream.pix_fmt } else { "N/A" }
                VideoBitrate     = if ($videoStream.bit_rate) { [math]::Round([double]$videoStream.bit_rate / 1000, 0) } else { "N/A" }
                AudioCodec       = if ($audioStream) { $audioStream.codec_name } else { "N/A" }
                AudioCodecLong   = if ($audioStream) { $audioStream.codec_long_name } else { "N/A" }
                AudioSampleRate  = if ($audioStream.sample_rate) { $audioStream.sample_rate } else { "N/A" }
                AudioChannels    = if ($audioStream.channels) { $audioStream.channels } else { "N/A" }
                AudioBitrate     = if ($audioStream.bit_rate) { [math]::Round([double]$audioStream.bit_rate / 1000, 0) } else { "N/A" }
                Encoder          = if ($videoInfo.format.tags.encoder) { $videoInfo.format.tags.encoder } else { "N/A" }
                EncoderInfo      = if ($videoStream.tags.encoder) { $videoStream.tags.encoder } else { "N/A" }
            }
        }
    } catch {
        Write-Warning "Failed: $($file.FullName) - $($_.Exception.Message)"
    }
}

Write-Progress -Activity "Analyzing videos" -Completed

$results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "`nInventory complete." -ForegroundColor Green
Write-Host "  Files processed: $($results.Count)"
Write-Host "  Output:          $OutputFile"

$totalSizeGB = [math]::Round(($results | Measure-Object -Property FileSizeMB -Sum).Sum / 1024, 2)
Write-Host "`nTotal size: $totalSizeGB GB" -ForegroundColor Yellow

Write-Host "`nVideo codecs:" -ForegroundColor White
$results | Group-Object VideoCodec | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize

Write-Host "Resolutions:" -ForegroundColor White
$results | Group-Object Resolution | Sort-Object Count -Descending | Format-Table Name, Count -AutoSize
