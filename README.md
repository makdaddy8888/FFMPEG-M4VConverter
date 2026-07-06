```
    ╔═══════════════════════════════════════════════════════════════════╗
    ║                                                                   ║
    ║   █▀▀ █▀▀ █▀▀ █▀▀   MTS / M4V  CONVERTER                         ║
    ║   █▀▀ █▀▀ █▀▀ █▀▀   HDCAM  ·  AVCHD  ·  FFmpeg  ·  PowerShell    ║
    ║                                                                   ║
    ╚═══════════════════════════════════════════════════════════════════╝

         SD Card          Archive           Phone / Plex
       ┌──────────┐      ┌──────────┐      ┌──────────┐
       │ 00012.MTS│ ───► │ 1080p MP4│ ───► │ 480p MP4 │
       │ interlaced│      │  HEVC    │      │ + dates  │
       └──────────┘      └──────────┘      └──────────┘
            │                  │                  │
            └────── ffprobe ───┴──── NVENC ───────┘
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
    .MTS on SD card
          │
          ▼
    ┌─────────────────────────────────────┐
    │  ① Convert-MtsToArchive.ps1       │  1080p HEVC master (yadif + NVENC)
    └─────────────────────────────────────┘
          │
          ▼
    ┌─────────────────────────────────────┐
    │  ② Convert-ToIphone.ps1            │  480p HEVC + creation_time metadata
    └─────────────────────────────────────┘
          │
          ▼
      iPhone · Plex · iCloud
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

## Quick Start

```powershell
# 1. Clone
git clone https://github.com/makdaddy8888/FFMPEG-M4VConverter.git
cd FFMPEG-M4VConverter

# 2. Archive — copy STREAM folder from SD card first, don't rename .MTS files
.\scripts\Convert-MtsToArchive.ps1 `
    -InputFolder "D:\Camcorder\STREAM" `
    -OutputFolder "D:\Archive"

# 3. iPhone copies — dates preserved
.\scripts\Convert-ToIphone.ps1 `
    -InputFolder "D:\Archive" `
    -OutputFolder "D:\iPhone"
```

**Verify FFmpeg is installed:**

```powershell
ffmpeg -version
ffprobe -version
```

---

## Scripts

All scripts live in [`scripts/`](scripts/) and use PowerShell **Verb-Noun** naming.
Run `Get-Help .\scripts\Convert-MtsToArchive.ps1 -Full` for any script.

| Script | In → Out | Encode | Use when |
|:-------|:---------|:-------|:---------|
| [**Convert-MtsToArchive**](scripts/Convert-MtsToArchive.ps1) | `.MTS` → 1080p `.mp4` | HEVC NVENC | **Step 1** — keep a master |
| [**Convert-ToIphone**](scripts/Convert-ToIphone.ps1) | `.mp4` → 480p `.mp4` | HEVC NVENC | **Step 2** — phone + dates |
| [**Convert-ToIphone720**](scripts/Convert-ToIphone720.ps1) | any → 720p `.mp4` | HEVC NVENC | Bigger screens |
| [**Convert-MtsToMobile**](scripts/Convert-MtsToMobile.ps1) | `.MTS` → 480p `.mp4` | HEVC, 2 Mbps cap | One-step, no archive |
| [**Convert-M2tsToMp4**](scripts/Convert-M2tsToMp4.ps1) | `.m2ts` → `.mp4` | libx264 CPU | No NVIDIA GPU |
| [**Export-VideoInventory**](scripts/Export-VideoInventory.ps1) | folder → `.csv` | ffprobe | Audit before converting |
| [**Convert-M2ts-Experiments**](scripts/Convert-M2ts-Experiments.ps1) | `.m2ts` → `.m4v` | varies | Codec experiments |

---

## Encoding Cheat Sheet

| | Archive | iPhone |
|:--|:--------|:-------|
| **Script** | `Convert-MtsToArchive` | `Convert-ToIphone` |
| **Codec** | `hevc_nvenc` | `hevc_nvenc` |
| **Deinterlace** | `yadif=mode=1` | `yadif=mode=1` |
| **Resolution** | 1080p (source) | 854 × 480 |
| **Quality** | CQ 27 · VBR · max 6M | CQ 27 · VBR |
| **Audio** | AAC 192k | AAC 128k |
| **Extras** | `+faststart` | `+faststart` · `creation_time` |

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
| Files too big | Raise `-cq` value, lower resolution, or cap `-maxrate` |

---

## Requirements

| | |
|:--|:--|
| OS | Windows · PowerShell 5.1+ |
| Tools | [FFmpeg](https://ffmpeg.org/download.html) + ffprobe on PATH |
| GPU | Optional — NVIDIA with NVENC (GTX 1070+ tested) |
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
