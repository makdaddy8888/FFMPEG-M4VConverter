```
    ╔═══════════════════════════════════════════════════════════════════╗
    ║                                                                   ║
    ║   █▀▀ █▀▀ █▀▀ █▀▀   MTS / M4V  CONVERTER                         ║
    ║   █▀▀ █▀▀ █▀▀ █▀▀   HDCAM  ·  AVCHD  ·  FFmpeg  ·  PowerShell    ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝

         SD Card          Auto ingest         Phone-ready
       ┌──────────┐      ┌──────────┐      ┌──────────┐
       │ 00012.MTS│ ───► │ copy HDD │ ───► │ 480p MP4 │
       │  ~8 GB   │      │ + convert│      │  ~1 GB   │
       └──────────┘      └──────────┘      └──────────┘
                              │
                    Start-SdCardIngest.ps1
```

# FFmpeg MTS / M4V Converter

> Turn forgotten camcorder clips on SD cards into watchable, shareable video —
> without losing the day they were actually filmed.

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/)
[![FFmpeg](https://img.shields.io/badge/FFmpeg-required-007808?style=flat-square&logo=ffmpeg&logoColor=white)](https://ffmpeg.org/)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue?style=flat-square)](LICENSE.txt)
[![Platform](https://img.shields.io/badge/Platform-Windows-lightgrey?style=flat-square&logo=windows)](https://github.com/makdaddy8888/FFMPEG-M4VConverter)

---

## The Problem

```
  BEFORE                              AFTER
  ─────────────────────────────       ─────────────────────────────
  PRIVATE/AVCHD/BDMV/STREAM/          My_Family_2016.mp4
    └── 00012.MTS                     ✓ Plays on iPhone
        ✗ Interlaced 50i/60i           ✓ 1/10th the file size
        ✗ 500 MB per clip              ✓ Correct recording date
        ✗ Won't play on iPhone         ✓ Ready for Plex / iCloud
        ✗ No useful metadata
```

Years of family video sat on **Sony HDCAM SD cards** in a proprietary AVCHD layout.
Filenames like `00012.MTS` meant nothing in Plex or the Photos app, and most converters
stripped the original **creation date** — the one thing that matters when you are
sorting decades of home movies.

This repo is the **FFmpeg pipeline that actually worked**: deinterlace, compress with
HEVC, preserve dates, and fork it for your own camcorder.

---

## Pipeline at a Glance

```
    Plug SD card into front reader
          │
          ▼
    ┌─────────────────────────────────────┐
    │  ① Start-SdCardIngest.ps1          │  detect card → copy .MTS to HDD
    └─────────────────────────────────────┘
          │
          ▼
    ┌─────────────────────────────────────┐
    │  ② Convert-MtsToCompact.ps1        │  ~8:1 480p HEVC for iPhone
    └─────────────────────────────────────┘
          │
          ▼
      iPhone · Plex · iCloud

    (Optional two-step archive path still available below)
```

<details>
<summary><strong>Optional:</strong> audit your files first with <code>Export-VideoInventory.ps1</code></summary>

```powershell
.\scripts\Export-VideoInventory.ps1 `
    -RootPath "D:\Camcorder" `
    -OutputFile ".\inventory.csv"
```

</details>

---

## Quick Start — Auto SD Card Ingest

Plug the card in, run one script. It copies every `.MTS` file to the hard drive,
then converts to compact iPhone HEVC aiming for an **~8:1** size ratio
(e.g. an 8 GB card → about **1 GB** of phone-ready clips).

**Hardware note:** the original archive scripts assumed **Windows + NVIDIA NVENC**.
The auto-ingest path is **CPU-first** (`libx265`) and works on Linux without a GPU.
Pass `--prefer-nvenc` / `-PreferNvenc` only if you have a working NVIDIA encoder.

### Linux (recommended on this machine)

```bash
# Smart default: SD card present → copy+convert; otherwise convert saved Inbox
./scripts/start-sd-card-ingest.sh

# Card already mounted:
./scripts/start-sd-card-ingest.sh --source-path /media/$USER/YOUR_CARD

# Force use of existing hard-drive copies only:
./scripts/start-sd-card-ingest.sh --inbox-only

./scripts/start-sd-card-ingest.sh --dest-root "$HOME/Videos/Camcorder"
```

### Windows (PowerShell)

```powershell
.\scripts\Start-SdCardIngest.ps1
.\scripts\Start-SdCardIngest.ps1 -Once -DriveLetter E
.\scripts\Start-SdCardIngest.ps1 -DestRoot "D:\Camcorder"
```

Default layout on disk:

```
~/Videos/CamcorderIngest/          (Linux)
%USERPROFILE%\Videos\CamcorderIngest\   (Windows)
  Inbox/<timestamp>_LABEL/   ← raw .MTS copies (safe to eject after copy)
  iPhone/<timestamp>_LABEL/  ← compact .mp4 for the phone
  Logs/
```

**Verify FFmpeg is installed:**

```bash
ffmpeg -version
ffprobe -version
```

<details>
<summary><strong>Manual two-step archive path</strong> (1080p master, then 480p iPhone — NVIDIA NVENC)</summary>

```powershell
.\scripts\Convert-MtsToArchive.ps1 `
    -InputFolder "D:\Camcorder\STREAM" `
    -OutputFolder "D:\Archive"

.\scripts\Convert-ToIphone.ps1 `
    -InputFolder "D:\Archive" `
    -OutputFolder "D:\iPhone"
```

</details>
---

## Scripts

All scripts live in [`scripts/`](scripts/) and use PowerShell **Verb-Noun** naming.
Run `Get-Help .\scripts\Convert-MtsToArchive.ps1 -Full` for any script.

| Script | In → Out | Encode | Use when |
|:-------|:---------|:-------|:---------|
| [**start-sd-card-ingest.sh**](scripts/start-sd-card-ingest.sh) | SD card → Inbox + iPhone | orchestrates compact convert | **Linux auto** — plug in card, copy, convert |
| [**convert-mts-to-compact.sh**](scripts/convert-mts-to-compact.sh) | `.MTS` → 480p `.mp4` | libx265 ~8:1 (CPU) | Linux phone copies with size target |
| [**Start-SdCardIngest.ps1**](scripts/Start-SdCardIngest.ps1) | SD card → Inbox + iPhone | orchestrates compact convert | **Windows auto** |
| [**Convert-MtsToCompact.ps1**](scripts/Convert-MtsToCompact.ps1) | `.MTS` → 480p `.mp4` | libx265 / optional NVENC | Windows phone copies with size target |
| [**Convert-MtsToArchive**](scripts/Convert-MtsToArchive.ps1) | `.MTS` → 1080p `.mp4` | HEVC NVENC | Keep a 1080p master (NVIDIA) |
| [**Convert-ToIphone**](scripts/Convert-ToIphone.ps1) | `.mp4` → 480p `.mp4` | HEVC NVENC | Downscale archive + dates |
| [**Convert-ToIphone720**](scripts/Convert-ToIphone720.ps1) | any → 720p `.mp4` | HEVC NVENC | Bigger screens |
| [**Convert-MtsToMobile**](scripts/Convert-MtsToMobile.ps1) | `.MTS` → 480p `.mp4` | HEVC, 2 Mbps cap | Fixed bitrate, no budget math |
| [**Convert-M2tsToMp4**](scripts/Convert-M2tsToMp4.ps1) | `.m2ts` → `.mp4` | libx264 CPU | No NVIDIA GPU |
| [**Export-VideoInventory**](scripts/Export-VideoInventory.ps1) | folder → `.csv` | ffprobe | Audit before converting |
| [**Convert-M2ts-Experiments**](scripts/Convert-M2ts-Experiments.ps1) | `.m2ts` → `.m4v` | varies | Codec experiments |
---

## Encoding Cheat Sheet

| | Auto compact (default) | Archive | iPhone (from archive) |
|:--|:-----------------------|:--------|:----------------------|
| **Script** | `convert-mts-to-compact` / `.ps1` | `Convert-MtsToArchive` | `Convert-ToIphone` |
| **Codec** | `libx265` CPU (optional NVENC) | `hevc_nvenc` | `hevc_nvenc` |
| **Deinterlace** | `yadif=mode=1` | `yadif=mode=1` | `yadif=mode=1` |
| **Resolution** | 854 × 480 | 1080p (source) | 854 × 480 |
| **Quality** | Budget bitrate (~0.6–1.8 Mbps) | CQ 27 · VBR · max 6M | CQ 27 · VBR |
| **Size goal** | ~8:1 · max 1 GB / card | Larger master | Smaller share copy |
| **Audio** | AAC 96k | AAC 192k | AAC 128k |
| **Extras** | `+faststart` · `creation_time` | `+faststart` | `+faststart` · `creation_time` |
| **GPU** | Not required | NVIDIA NVENC | NVIDIA NVENC |
**No NVIDIA GPU?** Use `Convert-M2tsToMp4.ps1`, or swap in:

```powershell
-c:v libx265 -crf 24 -preset medium -vf "yadif=mode=1"
```

---

## Preserving Recording Dates

`Convert-ToIphone.ps1` reads the original timestamp via ffprobe and writes it back:

```
  ffprobe creation_time  ──►  -metadata creation_time=...
                         ──►  Windows file timestamps matched
```

Keeps chronological order in **Plex**, **Finder**, and **Windows Explorer**.

---

## SD Card Layout

```
PRIVATE/
  └── AVCHD/
        └── BDMV/
              └── STREAM/          ◄── point -InputFolder here
                    ├── 00000.MTS
                    ├── 00001.MTS
                    └── ...
```

---

## Fork It

This is a script toolbox, not a locked app. To adapt for your camcorder:

1. **Fork** the repo
2. **Probe** one file: `ffprobe -i yourfile.MTS`
3. **Pick** the closest script from the table
4. **Pass** your paths: `-InputFolder` / `-OutputFolder`
5. **Test** one clip before batch-processing hundreds

Full guide → **[docs/WORKFLOW.md](docs/WORKFLOW.md)**

---

## Troubleshooting

| Symptom | Fix |
|:--------|:----|
| `ffmpeg` not found | Install FFmpeg, add `bin` to PATH |
| CUDA / NVENC error | Update NVIDIA drivers, or use `Convert-M2tsToMp4.ps1` |
| Audio drift | Keep `-fflags +genpts` · `aresample=async=1` · `vsync vfr` |
| Wrong date | `ffprobe -show_entries format_tags=creation_time -i file.MTS` |
| Combing lines | Add `yadif` or `yadif=mode=1` to `-vf` |
| Files too big | Use `Convert-MtsToCompact` / raise `-cq`, lower resolution, or lower `-MaxVideoBitrateKbps` |
| SD card not detected | Pass `-DriveLetter E` (or your letter); built-in readers may look like fixed disks |
| Want to eject sooner | Wait for the green **safe to eject** banner — conversion uses the HDD Inbox copy |
---

## Requirements

| | |
|:--|:--|
| OS | Linux (bash) or Windows · PowerShell 5.1+ |
| Tools | [FFmpeg](https://ffmpeg.org/download.html) + ffprobe on PATH |
| GPU | **Not required** for auto-ingest / compact convert. Optional NVIDIA NVENC for the older archive scripts |
| Docs | [WORKFLOW.md](docs/WORKFLOW.md) for the full pipeline |

---

## License & Contributing

Licensed under [GPL v3](LICENSE.txt).

Pull requests welcome — Linux/macOS ports, CPU variants, Plex `.nfo` tooling.

If this helped you rescue old camcorder footage, a ⭐ on the repo helps others find it.

```
    ┌────────────────────────────────────────┐
    │  Made with FFmpeg · shared for families │
    │  who still have clips on SD cards       │
    └────────────────────────────────────────┘
```
