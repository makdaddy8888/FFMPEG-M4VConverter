# ---------- USER PROMPTS ----------

$inputFolder = Read-Host "Enter FULL path to input folder containing .m2ts files"
$outputFolder = Read-Host "Enter FULL path to output folder for .mp4 files"

# ---------- VALIDATION ----------

if (!(Test-Path $inputFolder)) {
    Write-Host "Input folder does not exist." -ForegroundColor Red
    exit
}

if (!(Test-Path $outputFolder)) {
    New-Item -ItemType Directory -Path $outputFolder | Out-Null
}

# ---------- FFMPEG CONFIG ----------

$ffmpeg = "ffmpeg"  # Change to full path if needed

# ---------- PROCESS FILES ----------

Get-ChildItem -Path $inputFolder -Filter *2.m2ts -Recurse | ForEach-Object {

    $relativePath = $_.FullName.Substring($inputFolder.Length).TrimStart("\")
    $outputPath = Join-Path $outputFolder ([System.IO.Path]::ChangeExtension($relativePath, ".mp4"))

    # Create subfolders in output if needed
    $outputDir = Split-Path $outputPath -Parent
    if (!(Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir | Out-Null
    }

    Write-Host "Converting: $($_.FullName)"
    Write-Host "Output to:   $outputPath"

    & $ffmpeg `
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
}

Write-Host "`nAll conversions completed successfully." -ForegroundColor Green
