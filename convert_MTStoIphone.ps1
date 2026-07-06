# ================== CONFIG ==================
$inputFolder  = "G:\Kids Videos from HDCAM\2016 - 2022\Archive_1080p"
$outputFolder = "G:\Kids Videos from HDCAM\iPhone_Converted"
$ffmpeg       = "ffmpeg"
$ffprobe      = "ffprobe"

# ============== FUNCTIONS ================
function Get-RecordingTime($file) {

    $json = & $ffprobe `
        -v quiet `
        -print_format json `
        -show_entries format_tags=creation_time `
        -show_entries stream_tags=creation_time `
        "$file" | ConvertFrom-Json

    if ($json.format.tags.creation_time) {
        return [DateTime]::Parse($json.format.tags.creation_time)
    }

    foreach ($stream in $json.streams) {
        if ($stream.tags.creation_time) {
            return [DateTime]::Parse($stream.tags.creation_time)
        }
    }

    return (Get-Item $file).CreationTime
}

# ============ PROCESS FILES ===============
Get-ChildItem -Path $inputFolder -Filter *.mp4 | ForEach-Object {

    # Extract original recording time
    $recordedDate = Get-RecordingTime $_.FullName
    $creationTime = $recordedDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $dateSuffix   = $recordedDate.ToString("yyyy-MM-dd_HH-mm-ss")

    # Output filename with date appended
    #$outputFile = "$($_.BaseName)_$dateSuffix.mp4"
	$outputFile = "$($_.BaseName).mp4"
    $outputPath = Join-Path $outputFolder $outputFile

    if (!(Test-Path $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder | Out-Null
    }

    Write-Host "`nConverting: $($_.Name)"
    Write-Host "Recorded:   $creationTime"
    Write-Host "Output:     $outputFile"

    # ----------- ENCODE (GPU, HEVC for iPhone) ---------------
    & $ffmpeg `
        -y `
        -hwaccel cuda `
        -i "$($_.FullName)" `
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
        -metadata title="$($_.BaseName)" `
        "$outputPath"

    # Check that file exists
    if (!(Test-Path $outputPath)) {
        Write-Host "❌ Encode failed" -ForegroundColor Red
        return
    }

    # Match filesystem timestamps (optional)
    $mp4 = Get-Item $outputPath
    $mp4.CreationTime  = $recordedDate
    $mp4.LastWriteTime = $recordedDate

    Write-Host "✅ Done" -ForegroundColor Green
}

Write-Host "`nAll conversions completed successfully." -ForegroundColor Green
