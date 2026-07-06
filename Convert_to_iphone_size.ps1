# ================================
# Convert_to_iphone_size.ps1
# GTX 1070 GPU Optimized HEVC Script
# ================================

$inputFolder  = "G:\Kids Videos from HDCAM\2007"
$outputFolder = "G:\Kids Videos from HDCAM\iPhone_Converted"
$ffmpeg       = "ffmpeg"

if (!(Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder
}

Write-Host "Converting Videos → iPhone HEVC (Full GPU Acceleration)"
Write-Host ""

$files = Get-ChildItem -Path $InputFolder -Include *.mp4, *.mkv, *.avi, *.mov -Recurse

foreach ($file in $files) {

    $outputFile = Join-Path $OutputFolder ($file.BaseName + "_iphone.mp4")

    if (Test-Path $outputFile) {
        Write-Host "Skipping (already converted): $($file.Name)"
        continue
    }

    Write-Host "Converting: $($file.Name)"

    ffmpeg -y `
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
    "$outputFile"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Finished: $($file.Name)"
    } else {
        Write-Host "ERROR converting: $($file.Name)"
    }

    Write-Host ""
}

Write-Host "ALL FILES PROCESSED"
