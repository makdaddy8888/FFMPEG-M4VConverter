<#
.SYNOPSIS
    Converts .MTS camcorder files to compact HEVC MP4 for iPhone (~8:1 size).

.DESCRIPTION
    One-pass pipeline: deinterlace, scale for phone viewing, encode HEVC, and
    preserve creation_time. Bitrate is chosen from the total source size so the
    batch lands near TargetRatio (default 8:1) and never exceeds MaxOutputBytes
    (default 1 GiB) when possible.

.PARAMETER InputFolder
    Folder containing .MTS source files (recursive search).

.PARAMETER OutputFolder
    Folder for compact .mp4 output.

.PARAMETER TargetRatio
    Desired source-to-output size ratio. Default 8 (8 GB in -> ~1 GB out).

.PARAMETER MaxOutputBytes
    Hard ceiling for total output size. Default 1 GiB.

.PARAMETER Width
    Output width. Default 854 (480p-class, good on iPhone, keeps files small).

.PARAMETER Height
    Output height. Default 480.

.PARAMETER AudioBitrateKbps
    AAC audio bitrate in kbps. Default 96.

.PARAMETER MinVideoBitrateKbps
    Floor for per-file average video bitrate. Default 600.

.PARAMETER MaxVideoBitrateKbps
    Ceiling for per-file average video bitrate. Default 1800.

.PARAMETER FfmpegPath
    Path to ffmpeg executable.

.PARAMETER FfprobePath
    Path to ffprobe executable.

.PARAMETER PreferNvenc
    Prefer NVIDIA NVENC when available. Default is CPU libx265 (works on
    machines without an NVIDIA GPU). Pass -PreferNvenc:\$true to opt in.

.EXAMPLE
    .\Convert-MtsToCompact.ps1 -InputFolder "D:\Camcorder\Inbox\2026-07-20" -OutputFolder "D:\Camcorder\iPhone\2026-07-20"

.NOTES
    Designed for full-card ingest where an 8 GB SD card should become ~1 GB of
    phone-ready clips without heavy quality loss on a small screen.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFolder,

    [Parameter(Mandatory = $true)]
    [string]$OutputFolder,

    [double]$TargetRatio = 8.0,
    [long]$MaxOutputBytes = 1GB,
    [int]$Width = 854,
    [int]$Height = 480,
    [int]$AudioBitrateKbps = 96,
    [int]$MinVideoBitrateKbps = 600,
    [int]$MaxVideoBitrateKbps = 1800,
    [string]$FfmpegPath = "ffmpeg",
    [string]$FfprobePath = "ffprobe",
    [bool]$PreferNvenc = $false,
    [Nullable[bool]]$Interactive = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-RecordingTime {
    param([string]$FilePath)

    $jsonText = & $FfprobePath `
        -v quiet `
        -print_format json `
        -show_entries format_tags=creation_time `
        -show_entries stream_tags=creation_time `
        $FilePath 2>$null

    if ($LASTEXITCODE -eq 0 -and $jsonText) {
        $json = $jsonText | ConvertFrom-Json
        if ($json.format.tags.creation_time) {
            return [DateTime]::Parse($json.format.tags.creation_time)
        }
        foreach ($stream in @($json.streams)) {
            if ($stream.tags.creation_time) {
                return [DateTime]::Parse($stream.tags.creation_time)
            }
        }
    }

    return (Get-Item -LiteralPath $FilePath).CreationTime
}

function Get-MediaDurationSeconds {
    param([string]$FilePath)

    $raw = & $FfprobePath `
        -v quiet `
        -show_entries format=duration `
        -of default=noprint_wrappers=1:nokey=1 `
        $FilePath 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        return 0.0
    }

    $duration = 0.0
    if ([double]::TryParse($raw.Trim(), [ref]$duration) -and $duration -gt 0) {
        return $duration
    }
    return 0.0
}

function Get-TargetFps {
    param([string]$FilePath)
    $jsonText = & $FfprobePath -v quiet -select_streams v:0 `
        -show_entries stream=avg_frame_rate,r_frame_rate,field_order -of json $FilePath 2>$null
    if (-not $jsonText) { return "25" }
    $json = $jsonText | ConvertFrom-Json
    $s = $json.streams[0]
    function Parse-Rate([string]$r) {
        if ([string]::IsNullOrWhiteSpace($r) -or $r -eq "0/0") { return $null }
        if ($r -match "^(\d+)/(\d+)$") {
            $d = [double]$Matches[2]
            if ($d -eq 0) { return $null }
            return [double]$Matches[1] / $d
        }
        return [double]$r
    }
    $avg = Parse-Rate $s.avg_frame_rate
    $rfr = Parse-Rate $s.r_frame_rate
    $rate = if ($avg) { $avg } elseif ($rfr) { $rfr } else { 25.0 }
    $field = ($s.field_order + "").ToLower()
    if ($field -in @("tt", "bb", "tb", "bt") -or $rate -ge 48) {
        if ($rate -ge 59) { return "30000/1001" }
        if ($rate -ge 48) { return "25" }
        return [string]([math]::Round($rate / 2, 3))
    }
    if ($rate -ge 29.4 -and $rate -le 30.1) { return "30000/1001" }
    if ($rate -ge 24.9 -and $rate -le 25.1) { return "25" }
    return [string]([math]::Round($rate, 3))
}

function Get-DateSuffix {
    param([DateTime]$When)
    return $When.ToString("ddMMyyyy")
}

function Get-OutputBaseName {
    param([string]$Stem, [DateTime]$When)
    return "{0}-{1}" -f $Stem, (Get-DateSuffix $When)
}

function Invoke-InteractiveReview {
    param(
        [string]$FilePath,
        [string]$DefaultTitle,
        [string]$CreationIso,
        [string]$SourceFps,
        [string]$TargetFps
    )
    Write-Host ""
    Write-Host "  Review clip: $(Split-Path $FilePath -Leaf)" -ForegroundColor Cyan
    Write-Host "  Recorded: $CreationIso"
    Write-Host "  Source fps: $SourceFps  ->  output: $TargetFps fps progressive"
    try { Invoke-Item $FilePath } catch { Write-Host "  Open the file manually: $FilePath" }
    Write-Host ""
    $title = Read-Host "  Title [$DefaultTitle]"
    if ([string]::IsNullOrWhiteSpace($title)) { $title = $DefaultTitle }
    $desc = Read-Host "  Description / what happens in this clip"
    $loc = Read-Host "  Location name"
    $lat = Read-Host "  Latitude (decimal)"
    $lon = Read-Host "  Longitude (decimal)"
    $iso6709 = ""
    if ($lat -and $lon) {
        $latN = [double]$lat
        $lonN = [double]$lon
        $iso6709 = ("{0}{1:F4}{2}{3:F4}/" -f ($(if ($latN -ge 0) { "+" } else { "" }), $latN, $(if ($lonN -ge 0) { "+" } else { "" }), $lonN)
    }
    $creation = $CreationIso
    $dateOverride = Read-Host "  Recording date override (DDMMYYYY, blank = keep)"
    if ($dateOverride) {
        try {
            $dt = [DateTime]::ParseExact($dateOverride, "ddMMyyyy", $null)
            $creation = $dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        catch { Write-Host "  Invalid date; keeping original." -ForegroundColor Yellow }
    }
    $notes = Read-Host "  Notes (private log)"
    return [pscustomobject]@{
        Title = $title; Description = $desc; Location = $loc
        Latitude = $lat; Longitude = $lon; Iso6709 = $iso6709
        Creation = $creation; Notes = $notes
    }
}

function Set-Mp4Metadata {
    param(
        [string]$InputPath, [string]$OutputPath,
        [string]$Creation, [string]$Title, [string]$Description,
        [string]$Location, [string]$Iso6709
    )
    $args = @("-y", "-hide_banner", "-loglevel", "error", "-i", $InputPath, "-map", "0", "-c", "copy",
        "-movflags", "+faststart+use_metadata_tags",
        "-metadata", "creation_time=$Creation",
        "-metadata", "title=$Title",
        "-metadata", "date=$Creation")
    if ($Description) {
        $args += @("-metadata", "description=$Description", "-metadata", "comment=$Description")
    }
    if ($Location) { $args += @("-metadata", "location=$Location") }
    if ($Iso6709) {
        $args += @("-metadata", "com.apple.quicktime.location.ISO6709=$Iso6709")
    }
    $args += $OutputPath
    & $FfmpegPath @args
}

function Test-NvencAvailable {
    param([string]$Ffmpeg)

    $help = & $Ffmpeg -hide_banner -encoders 2>&1 | Out-String
    if ($help -notmatch "hevc_nvenc") {
        return $false
    }

    # Quick encode probe; ignore failures from missing GPU.
    $null = & $Ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=64x64:d=0.1 `
        -c:v hevc_nvenc -f null - 2>&1
    return ($LASTEXITCODE -eq 0)
}

if (-not (Test-Path -LiteralPath $InputFolder)) {
    Write-Error "Input folder not found: $InputFolder"
    exit 1
}

if (-not (Test-CommandExists $FfmpegPath)) {
    Write-Error "ffmpeg not found: $FfmpegPath"
    exit 1
}
if (-not (Test-CommandExists $FfprobePath)) {
    Write-Error "ffprobe not found: $FfprobePath"
    exit 1
}

if (-not (Test-Path -LiteralPath $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

$runInteractive = if ($null -ne $Interactive) { $Interactive } else { [Environment]::UserInteractive }
$metadataCsv = Join-Path $OutputFolder "metadata-log.csv"

$files = @(Get-ChildItem -LiteralPath $InputFolder -Filter *.MTS -File -Recurse)
if ($files.Count -eq 0) {
    $files = @(Get-ChildItem -LiteralPath $InputFolder -Filter *.mts -File -Recurse)
}
# Deduplicate case-insensitive matches on Windows
$files = @($files | Sort-Object FullName -Unique)

if ($files.Count -eq 0) {
    Write-Warning "No .MTS files found under $InputFolder"
    exit 0
}

$totalSourceBytes = ($files | Measure-Object -Property Length -Sum).Sum
$budgetFromRatio = [long][math]::Floor($totalSourceBytes / [math]::Max($TargetRatio, 1.0))
$targetTotalBytes = [math]::Min($MaxOutputBytes, [math]::Max($budgetFromRatio, 1))

Write-Host "Probing durations for bitrate budget..." -ForegroundColor Cyan
$fileMeta = @()
$totalDuration = 0.0
foreach ($file in $files) {
    $duration = Get-MediaDurationSeconds -FilePath $file.FullName
    if ($duration -le 0) {
        # Rough fallback: assume ~17 Mbps AVCHD average
        $duration = ($file.Length * 8.0) / 17000000.0
    }
    $totalDuration += $duration
    $fileMeta += [pscustomobject]@{
        File     = $file
        Duration = $duration
    }
}

# Leave ~5% headroom under the budget for container overhead.
$usableBits = [double]$targetTotalBytes * 8.0 * 0.95
$audioBitsPerSec = $AudioBitrateKbps * 1000.0
$videoBitsAvailable = $usableBits - ($audioBitsPerSec * $totalDuration)
if ($videoBitsAvailable -lt ($MinVideoBitrateKbps * 1000.0 * $totalDuration)) {
    $videoBitsAvailable = $MinVideoBitrateKbps * 1000.0 * $totalDuration
}

$avgVideoKbps = if ($totalDuration -gt 0) {
    [int][math]::Round(($videoBitsAvailable / $totalDuration) / 1000.0)
} else {
    $MinVideoBitrateKbps
}
$avgVideoKbps = [math]::Max($MinVideoBitrateKbps, [math]::Min($MaxVideoBitrateKbps, $avgVideoKbps))
$maxrateKbps = [int][math]::Round($avgVideoKbps * 1.35)
$bufsizeKbps = [int][math]::Round($avgVideoKbps * 2.0)

$useNvenc = $false
if ($PreferNvenc) {
    $useNvenc = Test-NvencAvailable -Ffmpeg $FfmpegPath
}

$encoderLabel = if ($useNvenc) { "hevc_nvenc" } else { "libx265 (CPU)" }

Write-Host "Compact iPhone conversion (~${TargetRatio}:1 budget)" -ForegroundColor Cyan
Write-Host ("  Input:     {0}" -f $InputFolder)
Write-Host ("  Output:    {0}" -f $OutputFolder)
Write-Host ("  Clips:     {0}" -f $files.Count)
Write-Host ("  Source:    {0:N2} MB" -f ($totalSourceBytes / 1MB))
Write-Host ("  Budget:    {0:N2} MB (cap {1:N0} MB)" -f ($targetTotalBytes / 1MB), ($MaxOutputBytes / 1MB))
Write-Host ("  Duration:  {0:N1} s" -f $totalDuration)
Write-Host ("  Video:     ~{0} kbps avg, max {1} kbps, {2}x{3}" -f $avgVideoKbps, $maxrateKbps, $Width, $Height)
Write-Host ("  Audio:     AAC {0} kbps" -f $AudioBitrateKbps)
Write-Host ("  Encoder:   {0}" -f $encoderLabel)
Write-Host ("  Review:    {0}" -f ($(if ($runInteractive) { "interactive" } else { "batch" })))
Write-Host ("  Naming:    CLIP-DDMMYYYY.mp4")
Write-Host ""

$ok = 0
$failed = 0
$outputBytes = [long]0

foreach ($item in $fileMeta) {
    $file = $item.File
    $recordedDate = Get-RecordingTime -FilePath $file.FullName
    $creationTime = $recordedDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $outBase = Get-OutputBaseName -Stem $file.BaseName -When $recordedDate
    $outputPath = Join-Path $OutputFolder ($outBase + ".mp4")
    $jsonSidecar = Join-Path $OutputFolder ($outBase + ".json")
    $tmpPath = Join-Path $OutputFolder ($outBase + ".tmp.mp4")

    if (Test-Path -LiteralPath $outputPath) {
        Write-Host "Skipping existing: $outBase.mp4" -ForegroundColor Yellow
        $outputBytes += (Get-Item -LiteralPath $outputPath).Length
        $ok++
        continue
    }

    $targetFps = Get-TargetFps -FilePath $file.FullName
    $sourceFps = (& $FfprobePath -v quiet -select_streams v:0 -show_entries stream=avg_frame_rate,field_order -of default=noprint_wrappers=1 $file.FullName 2>$null) -join " "

    Write-Host "Processing $($file.Name) ($([math]::Round($item.Duration, 1))s)..."
    Write-Host "  Recorded:    $creationTime"
    Write-Host "  Output name: $outBase.mp4"
    Write-Host "  Target fps:  $targetFps (progressive)"

    $vf = "yadif=mode=1,fps=${targetFps},scale=${Width}:${Height}:flags=lanczos"

    $ffmpegArgs = @(
        "-y", "-hide_banner", "-loglevel", "error", "-stats",
        "-fflags", "+genpts", "-i", $file.FullName,
        "-vf", $vf,
        "-map", "0:v:0", "-map", "0:a?",
        "-fps_mode", "cfr", "-r", $targetFps,
        "-af", "aresample=async=1:first_pts=0",
        "-c:a", "aac", "-b:a", "${AudioBitrateKbps}k",
        "-pix_fmt", "yuv420p"
    )

    if ($useNvenc) {
        $ffmpegArgs += @(
            "-c:v", "hevc_nvenc", "-preset", "p5", "-profile:v", "main", "-rc", "vbr",
            "-b:v", "${avgVideoKbps}k", "-maxrate", "${maxrateKbps}k", "-bufsize", "${bufsizeKbps}k",
            "-cq", "28"
        )
    }
    else {
        $ffmpegArgs += @(
            "-c:v", "libx265", "-preset", "medium",
            "-b:v", "${avgVideoKbps}k", "-maxrate", "${maxrateKbps}k", "-bufsize", "${bufsizeKbps}k",
            "-x265-params", "log-level=error"
        )
    }

    $ffmpegArgs += $tmpPath

    & $FfmpegPath @ffmpegArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmpPath)) {
        Write-Host "  Failed: $($file.Name)" -ForegroundColor Red
        $failed++
        Write-Host ""
        continue
    }

    $metaTitle = $outBase
    $metaDesc = ""
    $metaLoc = ""
    $metaIso6709 = ""
    $metaCreation = $creationTime
    $metaNotes = ""

    if ($runInteractive) {
        $review = Invoke-InteractiveReview -FilePath $tmpPath -DefaultTitle $outBase `
            -CreationIso $creationTime -SourceFps $sourceFps -TargetFps $targetFps
        $metaTitle = $review.Title
        $metaDesc = $review.Description
        $metaLoc = $review.Location
        $metaIso6709 = $review.Iso6709
        $metaCreation = $review.Creation
        $metaNotes = $review.Notes
        $recordedDate = [DateTime]::Parse($metaCreation).ToLocalTime()
        $outBase = Get-OutputBaseName -Stem $file.BaseName -When $recordedDate
        $outputPath = Join-Path $OutputFolder ($outBase + ".mp4")
        $jsonSidecar = Join-Path $OutputFolder ($outBase + ".json")
    }

    Set-Mp4Metadata -InputPath $tmpPath -OutputPath $outputPath `
        -Creation $metaCreation -Title $metaTitle -Description $metaDesc `
        -Location $metaLoc -Iso6709 $metaIso6709
    Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue

    $sidecar = @{
        source_file = $file.FullName
        output_file = $outputPath
        creation_time = $metaCreation
        title = $metaTitle
        description = $metaDesc
        location_name = $metaLoc
        iso6709 = $metaIso6709
        source_fps = $sourceFps
        output_fps = $targetFps
        notes = $metaNotes
    } | ConvertTo-Json -Depth 3
    Set-Content -LiteralPath $jsonSidecar -Value $sidecar -Encoding UTF8

    if (-not (Test-Path -LiteralPath $metadataCsv)) {
        "source_file,output_file,creation_time,title,description,location_name,latitude,longitude,iso6709,source_fps,output_fps,notes" | Set-Content $metadataCsv
    }
    Add-Content -LiteralPath $metadataCsv -Value (
        """$($file.FullName)"",""$outputPath"",""$metaCreation"",""$metaTitle"",""$metaDesc"",""$metaLoc"","""",""$metaIso6709"",""$sourceFps"",""$targetFps"",""$metaNotes"""
    )

    $outItem = Get-Item -LiteralPath $outputPath
    try {
        $outItem.CreationTime = $recordedDate
        $outItem.LastWriteTime = $recordedDate
    }
    catch { }

    $outputBytes += $outItem.Length
    $ratio = if ($file.Length -gt 0) { $file.Length / [double]$outItem.Length } else { 0 }
    Write-Host ("  Done: {0} ({1:N2} MB, {2:N1}:1)" -f $outputPath, ($outItem.Length / 1MB), $ratio) -ForegroundColor Green
    Write-Host ("  Sidecar: {0}" -f $jsonSidecar)
    Write-Host ""
    $ok++
}

Write-Host "Compact conversion complete." -ForegroundColor Cyan
Write-Host ("  Succeeded: {0}  Failed: {1}" -f $ok, $failed)
Write-Host ("  Metadata log: {0}" -f $metadataCsv)
Write-Host ("  Output total: {0:N2} MB / budget {1:N2} MB" -f ($outputBytes / 1MB), ($targetTotalBytes / 1MB))
if ($outputBytes -gt $MaxOutputBytes) {
    Write-Warning "Output exceeded MaxOutputBytes. Re-run with a lower MaxVideoBitrateKbps or Height."
}

if ($failed -gt 0) {
    exit 2
}
exit 0
