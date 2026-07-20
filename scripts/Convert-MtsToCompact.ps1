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
    Prefer NVIDIA NVENC when available (default $true). Falls back to libx265.

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
    [bool]$PreferNvenc = $true
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
Write-Host ""

$ok = 0
$failed = 0
$outputBytes = [long]0

foreach ($item in $fileMeta) {
    $file = $item.File
    $outputPath = Join-Path $OutputFolder ($file.BaseName + ".mp4")
    if (Test-Path -LiteralPath $outputPath) {
        Write-Host "Skipping existing: $($file.Name)" -ForegroundColor Yellow
        $outputBytes += (Get-Item -LiteralPath $outputPath).Length
        $ok++
        continue
    }

    $recordedDate = Get-RecordingTime -FilePath $file.FullName
    $creationTime = $recordedDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    Write-Host "Processing $($file.Name) ($([math]::Round($item.Duration, 1))s)..."
    Write-Host "  Recorded: $creationTime"

    $vf = "yadif=mode=1,scale=${Width}:${Height}:flags=lanczos"

    $ffmpegArgs = @(
        "-y",
        "-hide_banner",
        "-loglevel", "error",
        "-stats",
        "-fflags", "+genpts",
        "-i", $file.FullName,
        "-vf", $vf,
        "-map", "0:v:0", "-map", "0:a?",
        "-fps_mode", "vfr",
        "-af", "aresample=async=1",
        "-c:a", "aac",
        "-b:a", "${AudioBitrateKbps}k",
        "-movflags", "+faststart+use_metadata_tags",
        "-metadata", "creation_time=$creationTime",
        "-metadata", "title=$($file.BaseName)",
        "-pix_fmt", "yuv420p"
    )

    if ($useNvenc) {
        $ffmpegArgs += @(
            "-c:v", "hevc_nvenc",
            "-preset", "p5",
            "-profile:v", "main",
            "-rc", "vbr",
            "-b:v", "${avgVideoKbps}k",
            "-maxrate", "${maxrateKbps}k",
            "-bufsize", "${bufsizeKbps}k",
            "-cq", "28"
        )
    }
    else {
        $ffmpegArgs += @(
            "-c:v", "libx265",
            "-preset", "medium",
            "-b:v", "${avgVideoKbps}k",
            "-maxrate", "${maxrateKbps}k",
            "-bufsize", "${bufsizeKbps}k",
            "-x265-params", "log-level=error"
        )
    }

    $ffmpegArgs += $outputPath

    & $FfmpegPath @ffmpegArgs
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputPath)) {
        Write-Host "  Failed: $($file.Name)" -ForegroundColor Red
        $failed++
        Write-Host ""
        continue
    }

    $outItem = Get-Item -LiteralPath $outputPath
    try {
        $outItem.CreationTime = $recordedDate
        $outItem.LastWriteTime = $recordedDate
    }
    catch {
        # Non-fatal on filesystems that reject timestamp changes
    }

    $outputBytes += $outItem.Length
    $ratio = if ($file.Length -gt 0) { $file.Length / [double]$outItem.Length } else { 0 }
    Write-Host ("  Done: {0} ({1:N2} MB, {2:N1}:1)" -f $outputPath, ($outItem.Length / 1MB), $ratio) -ForegroundColor Green
    Write-Host ""
    $ok++
}

Write-Host "Compact conversion complete." -ForegroundColor Cyan
Write-Host ("  Succeeded: {0}  Failed: {1}" -f $ok, $failed)
Write-Host ("  Output total: {0:N2} MB / budget {1:N2} MB" -f ($outputBytes / 1MB), ($targetTotalBytes / 1MB))
if ($outputBytes -gt $MaxOutputBytes) {
    Write-Warning "Output exceeded MaxOutputBytes. Re-run with a lower MaxVideoBitrateKbps or Height."
}

if ($failed -gt 0) {
    exit 2
}
exit 0
