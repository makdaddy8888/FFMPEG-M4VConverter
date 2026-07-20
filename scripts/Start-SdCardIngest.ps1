<#
.SYNOPSIS
    Watches for an SD card, copies .MTS files to disk, then converts for iPhone.

.DESCRIPTION
    Plug an AVCHD / HDCAM SD card into the front reader. This script detects the
    card (looks for PRIVATE\AVCHD\BDMV\STREAM or any .MTS files), copies clips to
    a dated Inbox folder on the hard drive, then runs Convert-MtsToCompact.ps1 so
    the final phone copies stay near an 8:1 size ratio (e.g. 8 GB card -> <= 1 GB).

.PARAMETER DestRoot
    Root folder on the hard drive for inbox, iPhone output, and logs.
    Default: $env:USERPROFILE\Videos\CamcorderIngest

.PARAMETER PollSeconds
    How often to scan for a new card when watching. Default 2.

.PARAMETER Once
    Process a card that is already inserted, then exit (no watch loop).

.PARAMETER DriveLetter
    Optional drive letter to use immediately (e.g. "E"). Skips auto-detect.

.PARAMETER TargetRatio
    Passed through to Convert-MtsToCompact.ps1. Default 8.

.PARAMETER MaxOutputBytes
    Passed through to Convert-MtsToCompact.ps1. Default 1 GiB.

.PARAMETER Width
    Output width for phone copies. Default 854.

.PARAMETER Height
    Output height for phone copies. Default 480.

.PARAMETER ExcludeDriveLetters
    Drives never treated as SD cards. Default C.

.PARAMETER KeepWatching
    After one successful ingest, keep watching for the next card.
    Ignored when -Once is set. Default $false (one card then exit).

.EXAMPLE
    # Sit and wait for the SD card, then copy + convert
    .\Start-SdCardIngest.ps1

.EXAMPLE
    # Card already inserted on E:
    .\Start-SdCardIngest.ps1 -Once -DriveLetter E

.EXAMPLE
    # Custom destination on D:
    .\Start-SdCardIngest.ps1 -DestRoot "D:\Camcorder"

.NOTES
    Safe to eject only after the copy stage finishes (the script prints a clear
    "safe to eject" message). Conversion runs from the hard-drive Inbox copy.
#>
[CmdletBinding()]
param(
    [string]$DestRoot = (Join-Path $env:USERPROFILE "Videos\CamcorderIngest"),
    [int]$PollSeconds = 2,
    [switch]$Once,
    [string]$DriveLetter,
    [double]$TargetRatio = 8.0,
    [long]$MaxOutputBytes = 1GB,
    [int]$Width = 854,
    [int]$Height = 480,
    [string[]]$ExcludeDriveLetters = @("C"),
    [switch]$KeepWatching
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$convertScript = Join-Path $scriptDir "Convert-MtsToCompact.ps1"

if (-not (Test-Path -LiteralPath $convertScript)) {
    Write-Error "Missing conversion script: $convertScript"
    exit 1
}

foreach ($name in @("ffmpeg", "ffprobe")) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Error "$name not found on PATH. Install FFmpeg and retry."
        exit 1
    }
}

$inboxRoot = Join-Path $DestRoot "Inbox"
$iphoneRoot = Join-Path $DestRoot "iPhone"
$logRoot = Join-Path $DestRoot "Logs"
foreach ($dir in @($DestRoot, $inboxRoot, $iphoneRoot, $logRoot)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$stamp] [$Level] $Message"
    Write-Host $line -ForegroundColor $Color
    if ($script:LogFile) {
        Add-Content -LiteralPath $script:LogFile -Value $line
    }
}

function Get-RemovableDriveRoots {
    param([string[]]$Exclude)

    $excludeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($letter in $Exclude) {
        $normalized = $letter.TrimEnd(":").ToUpperInvariant()
        [void]$excludeSet.Add($normalized)
    }

    $roots = New-Object System.Collections.Generic.List[object]

    try {
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop
        foreach ($disk in $disks) {
            $letter = ($disk.DeviceID -replace ":", "").ToUpperInvariant()
            if ($excludeSet.Contains($letter)) { continue }
            if (-not $disk.DeviceID) { continue }
            if (-not (Test-Path -LiteralPath "$($disk.DeviceID)\")) { continue }
            # 2 = Removable, 3 = Local (built-in SD readers often report as Local)
            if ($disk.DriveType -in 2, 3) {
                $roots.Add([pscustomobject]@{
                    Root      = "$($disk.DeviceID)\"
                    DriveType = [int]$disk.DriveType
                })
            }
        }
    }
    catch {
        foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
            $letter = $drive.Name.ToUpperInvariant()
            if ($excludeSet.Contains($letter)) { continue }
            $root = "$($drive.Name):\"
            if (Test-Path -LiteralPath $root) {
                $roots.Add([pscustomobject]@{
                    Root      = $root
                    DriveType = 2
                })
            }
        }
    }

    return @($roots)
}

function Find-MtsSources {
    param(
        [object[]]$Roots,
        [string]$ForcedDriveLetter
    )

    $candidates = @()
    if ($ForcedDriveLetter) {
        $letter = $ForcedDriveLetter.TrimEnd(":").ToUpperInvariant()
        $candidates = @([pscustomobject]@{ Root = "${letter}:\"; DriveType = 2 })
    }
    else {
        $candidates = $Roots
    }

    $results = @()
    foreach ($candidate in $candidates) {
        $root = $candidate.Root
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $streamPaths = @(
            (Join-Path $root "PRIVATE\AVCHD\BDMV\STREAM"),
            (Join-Path $root "AVCHD\BDMV\STREAM")
        )

        $foundStream = $null
        foreach ($stream in $streamPaths) {
            if (Test-Path -LiteralPath $stream) {
                $mts = @(Get-ChildItem -LiteralPath $stream -Filter *.MTS -File -ErrorAction SilentlyContinue)
                if ($mts.Count -eq 0) {
                    $mts = @(Get-ChildItem -LiteralPath $stream -Filter *.mts -File -ErrorAction SilentlyContinue)
                }
                if ($mts.Count -gt 0) {
                    $foundStream = $stream
                    break
                }
            }
        }

        if ($foundStream) {
            $results += [pscustomobject]@{
                Root       = $root
                SourcePath = $foundStream
                Kind       = "AVCHD-STREAM"
            }
            continue
        }

        # Recursive fallback only on removable media (or an explicitly forced letter).
        # Avoid walking large internal fixed disks looking for stray .MTS files.
        $allowRecursive = ($ForcedDriveLetter -or $candidate.DriveType -eq 2)
        if (-not $allowRecursive) { continue }

        try {
            $any = @(Get-ChildItem -LiteralPath $root -Filter *.MTS -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1)
            if ($any.Count -eq 0) {
                $any = @(Get-ChildItem -LiteralPath $root -Filter *.mts -File -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 1)
            }
            if ($any.Count -gt 0) {
                $results += [pscustomobject]@{
                    Root       = $root
                    SourcePath = $root
                    Kind       = "MTS-RECURSIVE"
                }
            }
        }
        catch {
            # Ignore drives that deny recursive listing
        }
    }

    return $results
}

function Get-VolumeFingerprint {
    param([string]$Root)

    try {
        $letter = $Root.Substring(0, 1)
        $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
        $serial = if ($vol.UniqueId) { $vol.UniqueId } else { $vol.FileSystemLabel }
        $size = $vol.Size
        return "$serial|$size|$($vol.FileSystemLabel)"
    }
    catch {
        try {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Root.TrimEnd('\'))'" -ErrorAction Stop
            return "$($disk.VolumeSerialNumber)|$($disk.Size)|$($disk.VolumeName)"
        }
        catch {
            return $Root
        }
    }
}

function Copy-MtsFiles {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [string]$Kind
    )

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }

    $files = @(Get-ChildItem -LiteralPath $SourcePath -Filter *.MTS -File -Recurse -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        $files = @(Get-ChildItem -LiteralPath $SourcePath -Filter *.mts -File -Recurse -ErrorAction SilentlyContinue)
    }
    $files = @($files | Sort-Object FullName -Unique)

    if ($files.Count -eq 0) {
        throw "No .MTS files found under $SourcePath"
    }

    $copied = 0
    $skipped = 0
    $bytes = [long]0

    foreach ($file in $files) {
        $destFile = Join-Path $DestinationPath $file.Name
        if (Test-Path -LiteralPath $destFile) {
            $existing = Get-Item -LiteralPath $destFile
            if ($existing.Length -eq $file.Length) {
                Write-Log "Skip (already copied): $($file.Name)" "INFO" Yellow
                $skipped++
                $bytes += $existing.Length
                continue
            }
        }

        Write-Log "Copying $($file.Name) ($([math]::Round($file.Length / 1MB, 2)) MB)..."
        Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
        # Preserve timestamps from the card when possible
        try {
            $destItem = Get-Item -LiteralPath $destFile
            $destItem.CreationTime = $file.CreationTime
            $destItem.LastWriteTime = $file.LastWriteTime
        }
        catch { }

        $bytes += (Get-Item -LiteralPath $destFile).Length
        $copied++
    }

    return [pscustomobject]@{
        Copied  = $copied
        Skipped = $skipped
        Total   = $files.Count
        Bytes   = $bytes
        Kind    = $Kind
    }
}

function Invoke-IngestForSource {
    param($Source)

    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $label = try {
        $letter = $Source.Root.Substring(0, 1)
        $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
        if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { "SDCARD" }
    }
    catch { "SDCARD" }

    $safeLabel = ($label -replace '[^\w\-]+', '_').Trim('_')
    if (-not $safeLabel) { $safeLabel = "SDCARD" }

    $batchName = "${stamp}_${safeLabel}"
    $inboxPath = Join-Path $inboxRoot $batchName
    $iphonePath = Join-Path $iphoneRoot $batchName
    $script:LogFile = Join-Path $logRoot "$batchName.log"

    Write-Log "========================================" "INFO" Cyan
    Write-Log "SD card detected: $($Source.Root) ($($Source.Kind))" "INFO" Cyan
    Write-Log "Source clips: $($Source.SourcePath)"
    Write-Log "Inbox:  $inboxPath"
    Write-Log "iPhone: $iphonePath"
    Write-Log "Log:    $script:LogFile"

    New-Item -ItemType Directory -Path $inboxPath -Force | Out-Null
    New-Item -ItemType Directory -Path $iphonePath -Force | Out-Null

    Write-Log "=== Stage 1/2: Copy .MTS off the SD card ===" "INFO" Cyan
    $copyResult = Copy-MtsFiles -SourcePath $Source.SourcePath -DestinationPath $inboxPath -Kind $Source.Kind
    Write-Log ("Copy complete: {0} copied, {1} skipped, {2} total, {3:N2} MB" -f `
        $copyResult.Copied, $copyResult.Skipped, $copyResult.Total, ($copyResult.Bytes / 1MB)) "INFO" Green

    Write-Host ""
    Write-Host "  **********************************************" -ForegroundColor Green
    Write-Host "  *  COPY DONE — safe to eject the SD card now *" -ForegroundColor Green
    Write-Host "  **********************************************" -ForegroundColor Green
    Write-Host ""
    Write-Log "Safe to eject the SD card. Conversion continues from the hard drive." "INFO" Green

    Write-Log "=== Stage 2/2: Convert to compact iPhone MP4 ===" "INFO" Cyan
    Write-Log ("Target ~{0}:1, max output {1:N0} MB, {2}x{3}" -f $TargetRatio, ($MaxOutputBytes / 1MB), $Width, $Height)

    & $convertScript `
        -InputFolder $inboxPath `
        -OutputFolder $iphonePath `
        -TargetRatio $TargetRatio `
        -MaxOutputBytes $MaxOutputBytes `
        -Width $Width `
        -Height $Height

    $convertExit = $LASTEXITCODE
    if ($convertExit -eq 0) {
        $outSize = 0L
        if (Test-Path -LiteralPath $iphonePath) {
            $outSize = (Get-ChildItem -LiteralPath $iphonePath -Filter *.mp4 -File -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
            if (-not $outSize) { $outSize = 0 }
        }
        Write-Log ("Conversion succeeded. iPhone folder: {0} ({1:N2} MB)" -f $iphonePath, ($outSize / 1MB)) "INFO" Green
    }
    else {
        Write-Log "Conversion finished with errors (exit $convertExit). See console output above." "ERROR" Red
    }

    Write-Log "Batch complete: $batchName" "INFO" Cyan
    return $convertExit
}

Write-Host ""
Write-Host "  SD Card Auto-Ingest" -ForegroundColor Cyan
Write-Host "  DestRoot: $DestRoot"
Write-Host "  Target:   ~${TargetRatio}:1  (max $([math]::Round($MaxOutputBytes/1MB)) MB total output)"
Write-Host "  Output:   ${Width}x${Height} HEVC for iPhone"
if ($Once) {
    Write-Host "  Mode:     once (no watch loop)"
}
elseif ($KeepWatching) {
    Write-Host "  Mode:     watch (process every new card)"
}
else {
    Write-Host "  Mode:     watch until first card, then exit"
}
Write-Host ""

$processedFingerprints = New-Object 'System.Collections.Generic.HashSet[string]'

if ($DriveLetter) {
    $forced = Find-MtsSources -Roots @() -ForcedDriveLetter $DriveLetter
    if ($forced.Count -eq 0) {
        Write-Error "No .MTS files found on drive $DriveLetter"
        exit 1
    }
    $exitCode = Invoke-IngestForSource -Source $forced[0]
    exit $exitCode
}

if ($Once) {
    $found = Find-MtsSources -Roots (Get-RemovableDriveRoots -Exclude $ExcludeDriveLetters)
    if ($found.Count -eq 0) {
        Write-Error "No SD card with .MTS files detected. Insert the card and retry, or pass -DriveLetter."
        exit 1
    }
    if ($found.Count -gt 1) {
        Write-Host "Multiple cards found; using the first: $($found[0].Root)" -ForegroundColor Yellow
    }
    $exitCode = Invoke-IngestForSource -Source $found[0]
    exit $exitCode
}

Write-Host "Waiting for an SD card with .MTS files..." -ForegroundColor Yellow
Write-Host "Insert the card into the front reader. Press Ctrl+C to cancel."
Write-Host ""

while ($true) {
    $roots = Get-RemovableDriveRoots -Exclude $ExcludeDriveLetters
    $found = Find-MtsSources -Roots $roots

    foreach ($source in $found) {
        $fp = Get-VolumeFingerprint -Root $source.Root
        if ($processedFingerprints.Contains($fp)) {
            continue
        }

        [void]$processedFingerprints.Add($fp)
        $exitCode = Invoke-IngestForSource -Source $source

        if (-not $KeepWatching) {
            exit $exitCode
        }

        Write-Host ""
        Write-Host "Ready for the next SD card..." -ForegroundColor Yellow
    }

    Start-Sleep -Seconds $PollSeconds
}
