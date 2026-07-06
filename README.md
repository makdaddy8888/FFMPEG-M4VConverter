# FFmpeg MTS / M4V Converter

PowerShell scripts and FFmpeg recipes for converting legacy **HDCAM / AVCHD camcorder footage** (`.MTS`, `.m2ts`) into high-quality archives and **iPhone-friendly MP4/M4V** files — while preserving original recording dates.

**Repository:** [github.com/makdaddy8888/FFMPEG-M4VConverter](https://github.com/makdaddy8888/FFMPEG-M4VConverter)

---

## Why This Project Exists

Years of family videos were trapped on **Sony HDCAM SD cards** in a proprietary folder layout (`PRIVATE/AVCHD/BDMV/STREAM/`) using **MPEG-TS containers** (`.MTS` files). The footage was:

- **Interlaced** (50i/60i) — unwatchable on modern phones without deinterlacing
- **Large** — full 1080p MPEG-2 or AVC streams that eat storage
- **Poorly labelled** — filenames like `00012.MTS` with no useful metadata in Plex or the Photos app
- **Hard to play** — iPhones and Apple TV want HEVC/H.264 in MP4 with `faststart`, not raw camcorder files

Commercial tools either cost money, watermarked output, or stripped the original **creation date** — which matters when you are archiving decades of family history and want videos sorted chronologically in Plex, iCloud, or Google Photos.

This project documents the **FFmpeg pipeline I actually used** on Windows with an NVIDIA GPU (GTX 1070): a two-step workflow that produces a permanent archive and smaller phone copies, with `creation_time` metadata carried through from the original recording.

It is not a polished application — it is a set of working scripts you can **fork, edit, and adapt** to your own camcorder, codec, and quality targets. See [docs/WORKFLOW.md](docs/WORKFLOW.md) for the full pipeline and forking guide.

---

## Script Naming Convention

All scripts follow PowerShell **Verb-Noun** naming and live in the [`scripts/`](scripts/) folder:

| Verb | Meaning in this repo |
|------|----------------------|
| `Convert-*` | Re-encode or remux video with FFmpeg |
| `Export-*` | Extract information without modifying files |

Run any script with built-in help:

```powershell
Get-Help .\scripts\Convert-MtsToArchive.ps1 -Full
```

---

## Script Reference

| Script | Input | Output | Encoding | Best for |
|--------|-------|--------|----------|----------|
| [`Convert-MtsToArchive.ps1`](scripts/Convert-MtsToArchive.ps1) | `.MTS` | 1080p `.mp4` | HEVC NVENC, `yadif` | **Step 1** — master archive |
| [`Convert-ToIphone.ps1`](scripts/Convert-ToIphone.ps1) | `.mp4` archive | 854×480 `.mp4` | HEVC NVENC + dates | **Step 2** — iPhone / sharing |
| [`Convert-ToIphone720.ps1`](scripts/Convert-ToIphone720.ps1) | mixed video | 1280×720 `.mp4` | HEVC NVENC + CUDA scale | Larger phone / tablet screen |
| [`Convert-MtsToMobile.ps1`](scripts/Convert-MtsToMobile.ps1) | `.MTS` | 480p `.mp4` | HEVC NVENC, bitrate cap | One-step mobile copy (no archive) |
| [`Convert-M2tsToMp4.ps1`](scripts/Convert-M2tsToMp4.ps1) | `.m2ts` | `.mp4` | libx264 CPU | No GPU / Blu-ray rips |
| [`Export-VideoInventory.ps1`](scripts/Export-VideoInventory.ps1) | any folder | `.csv` report | ffprobe only | Audit library before converting |
| [`Convert-M2ts-Experiments.ps1`](scripts/Convert-M2ts-Experiments.ps1) | `.m2ts` | `.m4v` | varies | Reference / codec experiments |

---

## Requirements

- **Windows** with PowerShell 5.1+ (FFmpeg flags work on any OS if you port the commands)
- **[FFmpeg](https://ffmpeg.org/download.html)** and **ffprobe** in your `PATH`
- **Optional:** NVIDIA GPU with NVENC for GPU scripts (CPU alternative in `Convert-M2tsToMp4.ps1`)

```powershell
ffmpeg -version
ffprobe -version
```

---

## Quick Start

### 1. Clone the repo

```powershell
git clone https://github.com/makdaddy8888/FFMPEG-M4VConverter.git
cd FFMPEG-M4VConverter
```

### 2. Copy files from your SD card

Copy the `STREAM` folder from your SD card to a working directory. Do not rename `.MTS` files before probing them.

### 3. Run the two-step pipeline

**Step A — Archive (1080p HEVC, deinterlaced):**

```powershell
.\scripts\Convert-MtsToArchive.ps1 `
    -InputFolder "D:\Camcorder\STREAM" `
    -OutputFolder "D:\Archive"
```

**Step B — iPhone copy (480p HEVC, dates preserved):**

```powershell
.\scripts\Convert-ToIphone.ps1 `
    -InputFolder "D:\Archive" `
    -OutputFolder "D:\iPhone"
```

### 4. Optional — audit your library first

```powershell
.\scripts\Export-VideoInventory.ps1 `
    -RootPath "D:\Camcorder" `
    -OutputFile ".\inventory.csv"
```

---

## Encoding Settings at a Glance

| Setting | Archive | iPhone |
|---------|---------|--------|
| Script | `Convert-MtsToArchive` | `Convert-ToIphone` |
| Video codec | `hevc_nvenc` | `hevc_nvenc` |
| Deinterlace | `yadif=mode=1` | `yadif=mode=1` |
| Resolution | source (1080p) | 854×480 |
| Quality | CQ 27, VBR, maxrate 6M | CQ 27, VBR |
| Audio | AAC 192k | AAC 128k |
| Container | MP4 `+faststart` | MP4 `+faststart` + `creation_time` |

### CPU-only fallback

Replace GPU encoding with:

```powershell
-c:v libx265 -crf 24 -preset medium -vf "yadif=mode=1"
```

Remove `-hwaccel cuda` and `hevc_nvenc` flags. See `Convert-M2tsToMp4.ps1` for a full CPU example.

---

## Preserving Recording Dates

`Convert-ToIphone.ps1` uses a `Get-RecordingTime` helper that:

1. Reads `creation_time` from ffprobe (format or stream tags)
2. Falls back to the file's filesystem creation time
3. Writes it back with `-metadata creation_time=...`
4. Sets Windows file timestamps to match

This keeps chronological order in Plex, Finder, and Windows Explorer after conversion.

---

## Forking for Your Own Conversion Challenge

1. **Fork** the repo on GitHub
2. **Probe your source** — `ffprobe -i yourfile.MTS`
3. **Pick the closest script** from the table above
4. **Pass your paths** via `-InputFolder` and `-OutputFolder` parameters
5. **Tune quality** — adjust `-cq`, `-crf`, scale, or deinterlace settings
6. **Test one file** before batch processing

Full walkthrough: **[docs/WORKFLOW.md](docs/WORKFLOW.md)**

---

## Typical AVCHD SD Card Layout

```
PRIVATE/
  AVCHD/
    BDMV/
      STREAM/
        00000.MTS
        00001.MTS
```

Point `-InputFolder` at `STREAM`.

---

## Troubleshooting

| Problem | Things to try |
|---------|---------------|
| `ffmpeg` not found | Install FFmpeg and add `bin` to PATH |
| CUDA / NVENC errors | Update NVIDIA drivers; use `Convert-M2tsToMp4.ps1` (CPU) |
| Audio out of sync | Keep `-fflags +genpts`, `aresample=async=1`, `vsync vfr` |
| Wrong dates | `ffprobe -show_entries format_tags=creation_time -i file.MTS` |
| Interlaced output | Ensure `yadif` is in the `-vf` chain |
| Files too large | Increase `-cq` number, reduce resolution, or lower `-maxrate` |

---

## License

See [LICENSE.txt](LICENSE.txt) (GNU GPL v3).

---

## Contributing

Pull requests welcome — especially Linux/macOS shell ports, CPU-only variants, and Plex `.nfo` generation.

If this helped you rescue old camcorder footage, consider starring the repo.
