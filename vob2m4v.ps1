# ================== CONFIG ==================
$inputFolder  = "G:\Kids Videos from HDCAM\2016 - 2022\STREAM\"
$outputFolder = "G:\Kids Videos from HDCAM\2016 - 2022\STREAM\Done"
$ffmpeg       = "ffmpeg"

if (!(Test-Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder | Out-Null
}

Write-Host "🎞 Converting VOB → iPhone (Fixed Size, NVENC)"
Write-Host ""

Get-ChildItem -Path $inputFolder -Filter *.MTS | ForEach-Object {

    $outputPath = Join-Path $outputFolder ($_.BaseName + ".mp4")

    Write-Host "▶ Processing $($_.Name)..."

    & $ffmpeg `
        -y `
        -fflags +genpts `
        -i "$($_.FullName)" `
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

    Write-Host "✅ Done: $outputPath" -ForegroundColor Green
    Write-Host ""
}

Write-Host "🎉 ALL FILES CONVERTED (CONTROLLED SIZE)" -ForegroundColor Cyan
