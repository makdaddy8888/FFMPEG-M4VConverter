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

## What You Get

| Goal | How this repo helps |
|------|---------------------|
| Convert `.MTS` / `.m2ts` to MP4 | Ready-made FFmpeg command lines with deinterlacing |
| Smaller files without ugly quality loss | HEVC via NVIDIA NVENC (`hevc_nvenc`) with tuned CQ/VBR |
| iPhone / iPad playback | 480p or 720p HEVC, `yuv420p`, `+faststart` |
| Keep the original recording date | `ffprobe` reads `creation_time`; FFmpeg writes it back |
| Understand your source files | Optional `video_inventory_to_csv.ps1` using ffprobe |
| Plex-friendly sidecars | Workflow docs for `.nfo` metadata (see WORKFLOW.md) |

---

## Requirements

- **Windows** with PowerShell 5.1+ (scripts can be adapted for Linux/macOS — FFmpeg flags are the same)
- **[FFmpeg](https://ffmpeg.org/download.html)** and **ffprobe** in your `PATH`
- **Optional:** NVIDIA GPU with NVENC support for fast encoding (CPU fallback documented below)
- **Optional:** [ExifTool](https://exiftool.org/) if you extend scripts for embedded metadata tags

Verify installation:

```powershell
ffmpeg -version
ffprobe -version
```

---

## Quick Start

### 1. Fork and clone

```powershell
git clone https://github.com/YOUR_USERNAME/FFMPEG-M4VConverter.git
cd FFMPEG-M4VConverter
```

### 2. Copy files from your SD card

Copy the contents of the card's `STREAM` folder (or entire `BDMV` tree) to a working directory on your PC. Do not rename `.MTS` files before probing them.

### 3. Edit paths in a script

Open a script and change the `$inputFolder` and `$outputFolder` variables at the top to your local paths. Every script follows this pattern.

### 4. Run the two-step pipeline

**Step A — Archive (1080p HEVC, deinterlaced):**

```powershell
.\convertMTS2VOB.ps1
```

**Step B — iPhone-sized copy (480p HEVC, dates preserved):**

```powershell
.\convert_MTStoIphone.ps1
```

> Script names are historical — `convertMTS2VOB.ps1` outputs `.mp4`, not VOB. See the script reference below.

---

## Script Reference

| Script | Input | Output | Encoding | Best for |
|--------|-------|--------|----------|----------|
| `convertMTS2VOB.ps1` | `.MTS` | 1080p `.mp4` | HEVC NVENC, `yadif` | Master archive |
| `convert_MTStoIphone.ps1` | `.mp4` archive | 854×480 `.mp4` | HEVC NVENC | iPhone / sharing |
| `Convert_to_iphone_size.ps1` | mixed video | 1280×720 `.mp4` | HEVC NVENC + CUDA scale | Larger phone screen |
| `convert2.ps1` | `.m2ts` (prompts for paths) | `.mp4` | libx264 CPU | No GPU / Blu-ray rips |
| `vob2m4v.ps1` | `.MTS` | 480p `.mp4` | HEVC NVENC, bitrate cap | Controlled file size |
| `video_inventory_to_csv.ps1` | any folder | `.csv` report | ffprobe only | Auditing a video library |

### Experimental / local-only (not recommended as starting points)

| Script | Notes |
|--------|-------|
| `convert.ps1` | Early codec experiments — commented alternatives left in for reference |
| `convert1a.ps1` | Incomplete parallel-encoding draft |
| `convert_encode.ps1` | Work in progress — syntax not verified |
| `convert_n_upload.ps1` | Encode + YouTube upload — requires env-var credentials, not for general use |

---

## Encoding Settings at a Glance

| Setting | Archive (`convertMTS2VOB`) | iPhone (`convert_MTStoIphone`) |
|---------|------------------------------|--------------------------------|
| Video codec | `hevc_nvenc` | `hevc_nvenc` |
| Deinterlace | `yadif=mode=1` | `yadif=mode=1` |
| Resolution | source (1080p) | 854×480 |
| Quality | CQ 27, VBR, maxrate 6M | CQ 27, VBR |
| Audio | AAC 192k | AAC 128k |
| Container | MP4 `+faststart` | MP4 `+faststart` + `creation_time` metadata |

### CPU-only fallback

Replace GPU lines with something like:

```powershell
-c:v libx265 -crf 24 -preset medium -vf "yadif=mode=1"
```

Remove `-hwaccel cuda` and `hevc_nvenc` / `h264_nvenc` flags.

---

## Preserving Recording Dates

Camcorder `.MTS` files often store the real recording timestamp in stream metadata. The `Get-RecordingTime` function in `convert_MTStoIphone.ps1`:

1. Reads `creation_time` from ffprobe (format or stream tags)
2. Falls back to the file's filesystem creation time
3. Writes it back with `-metadata creation_time=...`
4. Optionally sets the output file's Windows timestamps to match

This keeps chronological order in Plex, Finder, and Windows Explorer after conversion.

---

## Forking This Project for Your Own Challenge

This repo is intentionally **script-based, not library-based**. To adapt it:

1. **Fork** the repository on GitHub
2. **Identify your source format** — run `ffprobe -i yourfile.MTS` and note codec, resolution, frame rate, and whether video is interlaced
3. **Pick the closest script** from the table above
4. **Change only what you need** — usually `$inputFolder`, `$outputFolder`, `-vf` (scale/deinterlace), and `-cq` / `-crf` (quality)
5. **Test one file** before batch-processing hundreds of clips
6. **Commit your changes** on your fork — you might need different resolutions (4K camcorder), PAL vs NTSC deinterlacing, or `libx264` for wider device support

A detailed walkthrough — including how to tune for different camcorders, add Plex `.nfo` files, and optionally experiment with AI scene descriptions — is in **[docs/WORKFLOW.md](docs/WORKFLOW.md)**.

---

## Typical Folder Layout on an AVCHD SD Card

```
PRIVATE/
  AVCHD/
    BDMV/
      STREAM/
        00000.MTS
        00001.MTS
        ...
```

Point `$inputFolder` at `STREAM` (or a copy of it on your hard drive).

---

## Troubleshooting

| Problem | Things to try |
|---------|---------------|
| `ffmpeg` not found | Install FFmpeg and add `bin` to PATH |
| CUDA / NVENC errors | Update NVIDIA drivers; fall back to `libx264` / `libx265` |
| Audio out of sync | Scripts use `-fflags +genpts`, `aresample=async=1`, and `vsync vfr` — keep these for problematic MTS |
| Wrong dates in output | Run `ffprobe -show_entries format_tags=creation_time -i file.MTS` on the source |
| Interlaced output | Ensure `yadif` or `yadif=mode=1` is in the `-vf` chain |
| Files too large | Lower `-cq` (higher number = smaller), reduce resolution, or lower `-maxrate` |

---

## License

See [LICENSE.txt](LICENSE.txt) (GNU GPL v3).

---

## Contributing

Forks and pull requests are welcome — especially:

- Parameterised scripts (`-InputFolder` / `-OutputFolder` instead of hardcoded paths)
- Linux / macOS shell equivalents
- CPU-only variants documented per script
- Plex `.nfo` generation without requiring AI

If this helped you rescue old camcorder footage, consider starring the repo so others can find it.
