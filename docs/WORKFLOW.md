# Workflow & Forking Guide

This document explains the full conversion pipeline behind [FFMPEG-M4VConverter](../README.md), why each step exists, and how to fork the project for your own source format, quality goals, and media server setup.

---

## The Problem in Detail

### HDCAM / AVCHD camcorder files are not "normal" video files

When you plug an SD card from a Sony (or similar AVCHD) camcorder into a PC, you see a `PRIVATE` folder — not a simple list of `.mp4` files. Inside `BDMV/STREAM/` are `.MTS` files:

- **Container:** MPEG Transport Stream (`.MTS` / `.m2ts`)
- **Video:** Often H.264 or MPEG-2, frequently **interlaced** at 50i (PAL) or 60i (NTSC)
- **Audio:** AC-3 or LPCM
- **Metadata:** Recording date may live in stream tags, not the filename

Phones, browsers, and Plex expect **progressive** H.264 or HEVC in an MP4/M4V container with `moov` atom at the front (`faststart`). Raw `.MTS` fails on most of these without remuxing or re-encoding.

### Why a two-step pipeline?

| Step | Purpose | Keep? |
|------|---------|-------|
| **Archive** | One high-quality deinterlaced copy per clip | Yes — master for re-edits and TV playback |
| **iPhone / share** | Small HEVC copy for phones, messaging, cloud | Optional — regenerate from archive anytime |

Re-encoding once to a good archive, then downsampling for mobile, avoids running expensive deinterlacing twice.

---

## Recommended Pipeline

```
 SD card .MTS files
        │
        ▼
 ┌──────────────────┐
 │ 1. INVENTORY     │  video_inventory_to_csv.ps1 (optional)
 │    ffprobe audit │
 └────────┬─────────┘
          ▼
 ┌──────────────────┐
 │ 2. ARCHIVE       │  convertMTS2VOB.ps1
 │    1080p HEVC    │  deinterlace + NVENC + AAC
 └────────┬─────────┘
          ▼
 ┌──────────────────┐
 │ 3. iPhone COPY   │  convert_MTStoIphone.ps1
 │    480p HEVC     │  scale down + preserve creation_time
 └────────┬─────────┘
          ▼
 ┌──────────────────┐
 │ 4. METADATA      │  (optional) Plex .nfo, ExifTool tags
 │    for Plex      │  see "Metadata & Plex" below
 └────────┬─────────┘
          ▼
    Plex / iCloud / share
```

---

## Step-by-Step

### Step 0 — Inspect before you encode

Always probe one representative file first:

```powershell
ffprobe -hide_banner -i "D:\Camcorder\STREAM\00000.MTS"
```

Note:

- **Resolution** (e.g. 1920×1080)
- **Frame rate** (e.g. 50 fps interlaced → needs `yadif`)
- **Video codec** (`h264`, `mpeg2video`)
- **Audio codec** (`ac3`, `pcm_s16le`)
- **Duration** (sanity check — corrupt files show wrong duration)

For a full library audit:

```powershell
.\video_inventory_to_csv.ps1 -RootPath "D:\Camcorder" -OutputFile ".\inventory.csv"
```

Edit the default paths inside the script or pass parameters as shown.

---

### Step 1 — Archive conversion

**Script:** `convertMTS2VOB.ps1`

**What it does:**

- Deinterlaces with `yadif=mode=1` (field-aware, good for PAL 50i)
- Encodes to HEVC with NVIDIA NVENC (`hevc_nvenc`)
- Uses VBR with `cq 27` and a `maxrate` cap to control size
- Remuxes audio to AAC 192k
- Adds `+faststart` for streaming/seeking

**Before running**, edit at the top of the script:

```powershell
$inputFolder  = "D:\YourPath\STREAM"
$outputFolder = "D:\YourPath\Archive_1080p"
```

**FFmpeg flags explained:**

| Flag | Why |
|------|-----|
| `-fflags +genpts` | Regenerate presentation timestamps — fixes many MTS timing issues |
| `-vsync vfr` | Variable frame rate sync after deinterlacing |
| `-af aresample=async=1` | Stretch/compress audio to match video if drift occurs |
| `-map 0:v:0 -map 0:a?` | First video stream; first audio stream if present |
| `-movflags +faststart` | Moves metadata to start of file for web/phone playback |

---

### Step 2 — iPhone / mobile copy

**Script:** `convert_MTStoIphone.ps1`

**What it does:**

- Reads original `creation_time` via ffprobe (`Get-RecordingTime`)
- Downscales to **854×480** (good balance of quality and size for phones)
- Re-encodes to HEVC
- Writes `creation_time` and `title` metadata into the output MP4
- Sets Windows file timestamps to the recording date

**Before running**, point input at your archive folder:

```powershell
$inputFolder  = "D:\YourPath\Archive_1080p"
$outputFolder = "D:\YourPath\iPhone_Converted"
```

For **720p** instead of 480p, use `Convert_to_iphone_size.ps1` and change the scale filter to match your preference.

---

### Step 3 — Alternative paths

| Your situation | Use this |
|----------------|----------|
| Blu-ray `.m2ts` rips, no GPU | `convert2.ps1` (interactive paths, CPU `libx264`) |
| Tight file-size budget | `vob2m4v.ps1` (fixed bitrate cap `2M`) |
| Mixed formats already on disk | `Convert_to_iphone_size.ps1` |
| Early codec comparison | `convert.ps1` (commented FFmpeg one-liners) |

---

## Metadata & Plex

### Why `.nfo` files help

[Plex](https://www.plex.tv/) can read sidecar `.nfo` files next to your videos. For home movies, a minimal `.nfo` gives Plex a **title**, **plot** (description), **premiered** date, and **genre/tag** — turning `00012.MTS` into something searchable.

Example:

```xml
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<movie>
  <title>Beach holiday 2016</title>
  <premiered>2016-07-04</premiered>
  <year>2016</year>
  <plot>Family afternoon at the beach, kids building sandcastles.</plot>
  <tag>beach</tag>
  <genre>Home Video</genre>
</movie>
```

Save as `00012.nfo` next to `00012.mp4`.

### Getting the date into `.nfo`

Priority order:

1. **ffprobe `creation_time`** — most reliable when the camcorder wrote it
2. **Filename patterns** — e.g. `2016-07-04_00012.mp4` or `04072016`
3. **Filesystem date** — last resort

The `Get-RecordingTime` function in `convert_MTStoIphone.ps1` implements (1) and (3). You can pipe that date into a `.nfo` `<premiered>` field in your own fork.

### Optional: AI-generated descriptions

If you want to experiment with **CUDA + PyTorch**, a vision model (e.g. LLaVA) can sample frames from each video and write a text summary into the `<plot>` field. This is heavier (~14 GB model download, NVIDIA GPU recommended) and is **not required** for the core conversion workflow — but it is a powerful add-on for large family libraries in Plex.

A cleaned optional tool for this may live under `tools/ai-analyzer/` in future releases. For now, the concept is:

```
MP4 → ffmpeg extracts 5 frames → AI describes scenes → .nfo <plot> + ExifTool tags
```

Everything can run locally — no cloud API needed.

---

## How to Fork for Your Specific Challenge

### 1. Fork on GitHub

Click **Fork** on [makdaddy8888/FFMPEG-M4VConverter](https://github.com/makdaddy8888/FFMPEG-M4VConverter), then clone your copy:

```powershell
git clone https://github.com/YOUR_USERNAME/FFMPEG-M4VConverter.git
cd FFMPEG-M4VConverter
```

### 2. Create a branch for your camcorder

```powershell
git checkout -b panasonic-sd900-ntsc
```

### 3. Identify what is different about your footage

| Question | Affects |
|----------|---------|
| PAL (25/50i) or NTSC (30/60i)? | `yadif` mode, frame rate |
| 720p or 1080p source? | scale filter, `maxrate` |
| H.264 or MPEG-2 video? | decode compatibility (both work with FFmpeg) |
| Single or multiple audio tracks? | `-map` options |
| Need `.m4v` extension specifically? | rename output; same codec settings apply |

### 4. Customise one script — not all at once

Minimal edit checklist:

```powershell
# 1. Paths
$inputFolder  = "YOUR_INPUT"
$outputFolder = "YOUR_OUTPUT"

# 2. Input glob (if not .MTS)
Get-ChildItem -Path $inputFolder -Filter *.MTS   # change extension

# 3. Deinterlace (if progressive source, remove yadif)
-vf "yadif=mode=1"

# 4. Quality (higher CQ number = smaller file, lower quality)
-cq 27

# 5. Resolution (iPhone step)
-vf "yadif=mode=1,scale=854:480"
```

### 5. Test matrix

Before batch processing, convert **one** file and check:

- [ ] Plays on target device (iPhone, Plex, VLC)
- [ ] No combing artifacts (interlacing gone)
- [ ] Audio in sync end-to-end
- [ ] `creation_time` correct (`ffprobe -show_entries format_tags=creation_time -i output.mp4`)
- [ ] File size acceptable

### 6. Batch safely

- Keep originals on the SD card or a backup drive until verified
- Log failures — redirect stderr: `2>> errors.log`
- Use `Convert_to_iphone_size.ps1` skip logic (`if (Test-Path $outputFile)`) as a model for resume support

### 7. Share improvements back

If you solve a new codec, camcorder brand, or CPU-only variant, a pull request helps the next person.

---

## Common Fork Scenarios

### "I have Panasonic AVCHD, not Sony"

Same `.MTS` in `STREAM` — pipeline is identical. Probe first; adjust `yadif` if NTSC.

### "I want .m4v not .mp4"

Change the output extension. For HEVC/H.264 + AAC in an MPEG-4 container, `.m4v` and `.mp4` are largely interchangeable for Apple devices.

### "I have no NVIDIA GPU"

Use `convert2.ps1` as a template (`libx264`, `-crf 20`, `-preset slow`). Expect longer encode times.

### "I want one script, not two steps"

Merge archive and iPhone filters into a single FFmpeg call — trade-off: you cannot re-generate phone copies from a master later without re-deinterlacing.

### "I use Plex and want dates + descriptions"

1. Run the iPhone/archive script (preserves `creation_time`)
2. Add a `.nfo` per file with `<premiered>` from ffprobe
3. In Plex: Library → Refresh Metadata

### "Files are already MP4 but huge"

Skip step 1; run `Convert_to_iphone_size.ps1` or only the scale/CQ section from `convert_MTStoIphone.ps1`.

---

## FFmpeg Command Cheat Sheet

**Probe:**

```powershell
ffprobe -v quiet -print_format json -show_format -show_streams -i input.MTS
```

**Single-file manual encode (archive quality):**

```powershell
ffmpeg -y -fflags +genpts -i input.MTS `
  -vf "yadif=mode=1" `
  -map 0:v:0 -map 0:a? `
  -c:v hevc_nvenc -preset p5 -rc vbr -cq 27 -pix_fmt yuv420p `
  -c:a aac -b:a 192k `
  -movflags +faststart `
  output.mp4
```

**Preserve date on a single file:**

```powershell
ffmpeg -i input.mp4 -c copy `
  -metadata creation_time="2016-07-04T10:30:00Z" `
  -movflags +use_metadata_tags `
  output.mp4
```

---

## What Not to Commit in Your Fork

Keep secrets and personal data out of git:

- OAuth tokens (YouTube, Google Cloud)
- Plex tokens
- Personal drive paths are fine in local commits but consider parameterising before publishing
- Generated CSV inventories with full file paths you do not want public

This repo's `.gitignore` excludes `yt_token.json`, `.env`, and credential scripts.

---

## Further Reading

- [FFmpeg documentation](https://ffmpeg.org/documentation.html)
- [FFmpeg HEVC encoding guide](https://trac.ffmpeg.org/wiki/Encode/H.265)
- [Plex local media assets / .nfo files](https://support.plex.tv/articles/local-files-for-tv-show-metadata/)
- [ExifTool](https://exiftool.org/) — embedded metadata in video files
