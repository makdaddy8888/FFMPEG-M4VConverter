# Video File Inventory Script using ffprobe
# Scans a drive for video files and exports technical details to CSV

param(
    [string]$RootPath = "G:\Kids Videos from HDCAM",
    [string]$OutputFile = "C:\ffmpeg\claude\video-inventory.csv",
    [string[]]$Extensions = @("*.mp4", "*.mts", "*.MTS", "*.avi", "*.mkv", "*.mov", "*.wmv", "*.flv", "*.m4v")
)

# Check if ffprobe is available
try {
    $null = Get-Command ffprobe -ErrorAction Stop
} catch {
    Write-Error "ffprobe not found. Please install FFmpeg and ensure it's in your PATH."
    exit 1
}

Write-Host "Scanning $RootPath for video files..." -ForegroundColor Cyan
Write-Host "This may take a while for large drives..." -ForegroundColor Yellow

# Find all video files
$videoFiles = @()
foreach ($ext in $Extensions) {
    Write-Host "Searching for $ext files..." -ForegroundColor Gray
    $videoFiles += Get-ChildItem -Path $RootPath -Filter $ext -Recurse -File -ErrorAction SilentlyContinue
}

Write-Host "`nFound $($videoFiles.Count) video files. Analyzing..." -ForegroundColor Green

# Initialize results array
$results = @()
$counter = 0

foreach ($file in $videoFiles) {
    $counter++
    Write-Progress -Activity "Analyzing videos" -Status "Processing $($file.Name)" -PercentComplete (($counter / $videoFiles.Count) * 100)
    
    try {
        # Get ffprobe output in JSON format
        $ffprobeOutput = ffprobe -v quiet -print_format json -show_format -show_streams "$($file.FullName)" 2>&1 | Out-String
        
        if ($ffprobeOutput) {
            $videoInfo = $ffprobeOutput | ConvertFrom-Json
            
            # Extract video stream info (first video stream)
            $videoStream = $videoInfo.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
            
            # Extract audio stream info (first audio stream)
            $audioStream = $videoInfo.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1
            
            # Build result object
            $result = [PSCustomObject]@{
                FileName = $file.Name
                FilePath = $file.FullName
                Directory = $file.DirectoryName
                FileSizeMB = [math]::Round($file.Length / 1MB, 2)
                FileCreationTime = $file.CreationTime.ToString("yyyy-MM-dd HH:mm:ss")
                FileModifiedTime = $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                
                # Format/Container info
                FormatName = $videoInfo.format.format_long_name
                Duration = if ($videoInfo.format.duration) { [math]::Round([double]$videoInfo.format.duration, 2) } else { "N/A" }
                DurationReadable = if ($videoInfo.format.duration) { 
                    $ts = [TimeSpan]::FromSeconds([double]$videoInfo.format.duration)
                    $ts.ToString("hh\:mm\:ss")
                } else { "N/A" }
                Bitrate = if ($videoInfo.format.bit_rate) { [math]::Round([double]$videoInfo.format.bit_rate / 1000, 0) } else { "N/A" }
                
                # Video stream info
                VideoCodec = if ($videoStream) { $videoStream.codec_name } else { "N/A" }
                VideoCodecLong = if ($videoStream) { $videoStream.codec_long_name } else { "N/A" }
                VideoProfile = if ($videoStream.profile) { $videoStream.profile } else { "N/A" }
                Width = if ($videoStream) { $videoStream.width } else { "N/A" }
                Height = if ($videoStream) { $videoStream.height } else { "N/A" }
                Resolution = if ($videoStream) { "$($videoStream.width)x$($videoStream.height)" } else { "N/A" }
                AspectRatio = if ($videoStream.display_aspect_ratio) { $videoStream.display_aspect_ratio } else { "N/A" }
                FrameRate = if ($videoStream.r_frame_rate) { 
                    $fps = $videoStream.r_frame_rate -split '/'
                    if ($fps.Count -eq 2 -and [double]$fps[1] -ne 0) {
                        [math]::Round([double]$fps[0] / [double]$fps[1], 2)
                    } else { $videoStream.r_frame_rate }
                } else { "N/A" }
                PixelFormat = if ($videoStream.pix_fmt) { $videoStream.pix_fmt } else { "N/A" }
                VideoBitrate = if ($videoStream.bit_rate) { [math]::Round([double]$videoStream.bit_rate / 1000, 0) } else { "N/A" }
                
                # Audio stream info
                AudioCodec = if ($audioStream) { $audioStream.codec_name } else { "N/A" }
                AudioCodecLong = if ($audioStream) { $audioStream.codec_long_name } else { "N/A" }
                AudioSampleRate = if ($audioStream.sample_rate) { $audioStream.sample_rate } else { "N/A" }
                AudioChannels = if ($audioStream.channels) { $audioStream.channels } else { "N/A" }
                AudioBitrate = if ($audioStream.bit_rate) { [math]::Round([double]$audioStream.bit_rate / 1000, 0) } else { "N/A" }
                
                # Encoder info
                Encoder = if ($videoInfo.format.tags.encoder) { $videoInfo.format.tags.encoder } else { "N/A" }
                EncoderInfo = if ($videoStream.tags.encoder) { $videoStream.tags.encoder } else { "N/A" }
            }
            
            $results += $result
        }
        
    } catch {
        Write-Warning "Failed to process: $($file.FullName) - $($_.Exception.Message)"
    }
}

Write-Progress -Activity "Analyzing videos" -Completed

# Export to CSV
$results | Export-Csv -Path $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host "`n=== Inventory Complete ===" -ForegroundColor Green
Write-Host "Total files processed: $($results.Count)" -ForegroundColor Cyan
Write-Host "Output saved to: $OutputFile" -ForegroundColor Cyan

# Display summary statistics
Write-Host "`n=== Summary Statistics ===" -ForegroundColor Yellow
$totalSize = ($results | Measure-Object -Property FileSizeMB -Sum).Sum
Write-Host "Total size: $([math]::Round($totalSize / 1024, 2)) GB" -ForegroundColor White

$codecStats = $results | Group-Object VideoCodec | Select-Object Name, Count | Sort-Object Count -Descending
Write-Host "`nVideo Codecs:" -ForegroundColor White
$codecStats | Format-Table -AutoSize

$resolutionStats = $results | Group-Object Resolution | Select-Object Name, Count | Sort-Object Count -Descending
Write-Host "Resolutions:" -ForegroundColor White
$resolutionStats | Format-Table -AutoSize
