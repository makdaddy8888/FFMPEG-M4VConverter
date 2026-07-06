$inputFolder = "D:\BDMV\STREAM\"
$outputFolder = "F:\Kids Videos from HDCAM\1"

Get-ChildItem $inputFolder -Filter *2.m2ts | ForEach-Object {
    $in = $_.FullName
    $out = Join-Path $outputFolder ($_.BaseName + ".m4v")

\\    ffmpeg -i "$in" -c:v copy -c:a copy "$out"
\\    ffmpeg -i "$in" -c:v copy -c:a aac -b:a 192k "$out"
\\    ffmpeg -i "$in" -map_metadata 0 -c:v copy -c:a aac -b:a 192k "$out"
\\    ffmpeg -i "$in" -c:v libx264 -preset medium -profile:v high -level 4.0 -pix_fmt yuv420p -c:a aac -ac 2 -b:a 160k "$out"
\\    ffmpeg -i "$in" -map_metadata 0 -c:v libx264 -preset medium -profile:v high -level 4.0 -pix_fmt yuv420p -c:a aac -ac 2 -b:a 160k "$out"
\\    ffmpeg -i "$in" -vf yadif -c:v libx264 -preset medium -profile:v high -level 4.0 -pix_fmt yuv420p -c:a aac -ac 2 -b:a 160k "$out"
      ffmpeg -i "$in" -c:v copy -preset medium -profile:v high -level 4.0 -pix_fmt yuv420p -c:a aac -ac 2 -b:a 160k "$out"


}