# ================== CONFIG ==================
$inputFolder  = "G:\Kids Videos from HDCAM\2016 - 2022\STREAM\00000.MTS"
$outputFolder = "G:\Kids Videos from HDCAM\2016 - 2022\Archive_1080p"
$ffmpeg       = "ffmpeg"

if (!(Test-Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder | Out-Null
}

Write-Host "Converting MTS to 1080p HEVC Archive (50p Deinterlace)"
Write-Host ""

Get-ChildItem -Path $inputFolder -Filter *.MTS | ForEach-Object {

    $outputPath = Join-Path $outputFolder ($_.BaseName + ".mp4")

    Write-Host "Processing $($_.Name)..."

    & $ffmpeg `
        -y `
        -fflags +genpts `
        -i "$($_.FullName)" `
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

    Write-Host "Done: $outputPath" -ForegroundColor Green
    Write-Host ""
}

Write-Host "ALL FILES CONVERTED - 1080p ARCHIVE READY" -ForegroundColor Cyan
