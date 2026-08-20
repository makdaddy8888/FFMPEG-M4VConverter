#!/usr/bin/env bash
# convert-mts-to-compact.sh — MTS → compact iPhone HEVC (~8:1 size budget)
# CPU-first (libx265). Optional NVENC. Interactive metadata review per clip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/camcorder-metadata.sh
source "$SCRIPT_DIR/lib/camcorder-metadata.sh"

usage() {
  cat <<'EOF'
Usage: convert-mts-to-compact.sh -i INPUT_FOLDER -o OUTPUT_FOLDER [options]

Converts .MTS camcorder files to compact 480p HEVC MP4 for iPhone.
Fixes PAL/NTSC interlaced framerate (50i→25fps, 60i→30fps).
Names outputs like 00018-10072026.mp4 (clip + recording date DDMMYYYY).

Required:
  -i, --input DIR       Folder containing .MTS files (searched recursively)
  -o, --output DIR      Folder for .mp4 output

Options:
  --target-ratio N      Source:output size ratio (default: 8)
  --max-output-bytes N  Hard ceiling for total output (default: 1073741824 = 1 GiB)
  --width N             Output width (default: 854)
  --height N            Output height (default: 480)
  --audio-kbps N        AAC bitrate kbps (default: 96)
  --min-video-kbps N    Video bitrate floor (default: 600)
  --max-video-kbps N    Video bitrate ceiling (default: 1800)
  --prefer-nvenc        Use NVIDIA NVENC when available (default: CPU libx265)
  --interactive         After each clip: open player, prompt for metadata (default if TTY)
  --no-interactive      Batch mode, no prompts
  -h, --help            Show this help

Sidecars written per clip: <name>.json metadata + metadata-log.csv in output folder.
EOF
}

INPUT_FOLDER=""
OUTPUT_FOLDER=""
TARGET_RATIO=8
MAX_OUTPUT_BYTES=1073741824
WIDTH=854
HEIGHT=480
AUDIO_KBPS=96
MIN_VIDEO_KBPS=600
MAX_VIDEO_KBPS=1800
PREFER_NVENC=0
INTERACTIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input) INPUT_FOLDER="$2"; shift 2 ;;
    -o|--output) OUTPUT_FOLDER="$2"; shift 2 ;;
    --target-ratio) TARGET_RATIO="$2"; shift 2 ;;
    --max-output-bytes) MAX_OUTPUT_BYTES="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --height) HEIGHT="$2"; shift 2 ;;
    --audio-kbps) AUDIO_KBPS="$2"; shift 2 ;;
    --min-video-kbps) MIN_VIDEO_KBPS="$2"; shift 2 ;;
    --max-video-kbps) MAX_VIDEO_KBPS="$2"; shift 2 ;;
    --prefer-nvenc) PREFER_NVENC=1; shift ;;
    --interactive) INTERACTIVE=1; shift ;;
    --no-interactive) INTERACTIVE=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$INTERACTIVE" ]]; then
  if [[ -t 0 ]]; then INTERACTIVE=1; else INTERACTIVE=0; fi
fi

if [[ -z "$INPUT_FOLDER" || -z "$OUTPUT_FOLDER" ]]; then
  usage >&2
  exit 1
fi
if [[ ! -d "$INPUT_FOLDER" ]]; then
  echo "Input folder not found: $INPUT_FOLDER" >&2
  exit 1
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg not found on PATH" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not found on PATH" >&2; exit 1; }

mkdir -p "$OUTPUT_FOLDER"
METADATA_CSV="$OUTPUT_FOLDER/metadata-log.csv"

mapfile -d '' FILES < <(find "$INPUT_FOLDER" -type f \( -iname '*.mts' \) -print0 | sort -z)
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No .MTS files found under $INPUT_FOLDER"
  exit 0
fi

nvenc_available() {
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -q hevc_nvenc || return 1
  ffmpeg -hide_banner -loglevel error -f lavfi -i color=c=black:s=64x64:d=0.1 \
    -c:v hevc_nvenc -f null - >/dev/null 2>&1
}

USE_NVENC=0
if [[ "$PREFER_NVENC" -eq 1 ]] && nvenc_available; then
  USE_NVENC=1
fi

get_duration() {
  local f="$1" raw dur
  raw="$(ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null || true)"
  if [[ -n "$raw" ]]; then
    dur="$(awk -v d="$raw" 'BEGIN { if (d+0 > 0) print d; else print 0 }')"
    if awk -v d="$dur" 'BEGIN { exit !(d > 0) }'; then
      echo "$dur"
      return
    fi
  fi
  local bytes
  bytes="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")"
  awk -v b="$bytes" 'BEGIN { printf "%.3f", (b * 8) / 17000000 }'
}

get_source_fps_label() {
  ffprobe -v quiet -select_streams v:0 -show_entries stream=avg_frame_rate,field_order \
    -of default=noprint_wrappers=1 "$1" 2>/dev/null | tr '\n' ' '
}

echo "Probing durations for bitrate budget..."
TOTAL_SOURCE_BYTES=0
TOTAL_DURATION=0
DURATIONS=()
for f in "${FILES[@]}"; do
  bytes="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")"
  dur="$(get_duration "$f")"
  DURATIONS+=("$dur")
  TOTAL_SOURCE_BYTES=$((TOTAL_SOURCE_BYTES + bytes))
  TOTAL_DURATION="$(awk -v a="$TOTAL_DURATION" -v b="$dur" 'BEGIN { printf "%.6f", a + b }')"
done

read -r TARGET_TOTAL_BYTES AVG_VIDEO_KBPS MAXRATE_KBPS BUFSIZE_KBPS < <(python3 - "$TOTAL_SOURCE_BYTES" "$TARGET_RATIO" "$MAX_OUTPUT_BYTES" "$TOTAL_DURATION" "$AUDIO_KBPS" "$MIN_VIDEO_KBPS" "$MAX_VIDEO_KBPS" <<'PY'
import sys
src = int(sys.argv[1])
ratio = max(float(sys.argv[2]), 1.0)
max_out = int(sys.argv[3])
duration = float(sys.argv[4])
audio_kbps = int(sys.argv[5])
min_v = int(sys.argv[6])
max_v = int(sys.argv[7])
budget = min(max_out, max(int(src / ratio), 1))
usable_bits = budget * 8 * 0.95
audio_bps = audio_kbps * 1000
video_bits = usable_bits - (audio_bps * duration)
if duration <= 0:
    avg = min_v
else:
    avg = int(round((video_bits / duration) / 1000.0))
avg = max(min_v, min(max_v, avg))
maxrate = int(round(avg * 1.35))
bufsize = int(round(avg * 2.0))
print(budget, avg, maxrate, bufsize)
PY
)

if [[ "$USE_NVENC" -eq 1 ]]; then
  ENCODER_LABEL="hevc_nvenc"
else
  ENCODER_LABEL="libx265 (CPU)"
fi

echo "Compact iPhone conversion (~${TARGET_RATIO}:1 budget)"
echo "  Input:       $INPUT_FOLDER"
echo "  Output:      $OUTPUT_FOLDER"
echo "  Clips:       ${#FILES[@]}"
echo "  Interactive: $([[ "$INTERACTIVE" -eq 1 ]] && echo yes || echo no)"
python3 - "$TOTAL_SOURCE_BYTES" "$TARGET_TOTAL_BYTES" "$MAX_OUTPUT_BYTES" "$TOTAL_DURATION" "$AVG_VIDEO_KBPS" "$MAXRATE_KBPS" "$WIDTH" "$HEIGHT" "$AUDIO_KBPS" "$ENCODER_LABEL" <<'PY'
import sys
src, budget, cap, dur, avg, mx, w, h, a, enc = sys.argv[1:]
print(f"  Source:      {int(src)/1048576:.2f} MB")
print(f"  Budget:      {int(budget)/1048576:.2f} MB (cap {int(cap)/1048576:.0f} MB)")
print(f"  Duration:    {float(dur):.1f} s")
print(f"  Video:       ~{avg} kbps avg, max {mx} kbps, {w}x{h}")
print(f"  Audio:       AAC {a} kbps")
print(f"  Encoder:     {enc}")
print(f"  Framerate:   50i→25fps / 60i→30fps after deinterlace")
print(f"  Naming:      CLIP-DDMMYYYY.mp4")
PY
echo

OK=0
FAILED=0
OUTPUT_BYTES=0

for idx in "${!FILES[@]}"; do
  f="${FILES[$idx]}"
  dur="${DURATIONS[$idx]}"
  base="$(basename "$f")"
  stem="${base%.*}"
  creation="$(cam_meta_get_creation_iso "$f")"
  out_base="$(cam_meta_output_basename "$stem" "$creation")"
  out="$OUTPUT_FOLDER/${out_base}.mp4"
  json_sidecar="$OUTPUT_FOLDER/${out_base}.json"
  tmp="${out}.tmp.mp4"

  if [[ -f "$out" ]]; then
    echo "Skipping existing: $(basename "$out")"
    OUTPUT_BYTES=$((OUTPUT_BYTES + $(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")))
    OK=$((OK + 1))
    continue
  fi

  target_fps="$(cam_meta_target_fps "$f")"
  source_fps_label="$(get_source_fps_label "$f")"

  echo "Processing $base (${dur}s)..."
  echo "  Recorded:    $creation"
  echo "  Output name: ${out_base}.mp4"
  echo "  Source fps:  $source_fps_label"
  echo "  Target fps:  $target_fps (progressive)"

  # Deinterlace + correct fps + scale. CFR for stable phone playback.
  vf="yadif=mode=1,fps=${target_fps},scale=${WIDTH}:${HEIGHT}:flags=lanczos"
  common=(
    -y -hide_banner -loglevel error -stats
    -fflags +genpts -i "$f"
    -vf "$vf"
    -map 0:v:0 -map 0:a?
    -fps_mode cfr
    -r "$target_fps"
    -af aresample=async=1:first_pts=0
    -c:a aac -b:a "${AUDIO_KBPS}k"
    -pix_fmt yuv420p
  )

  if [[ "$USE_NVENC" -eq 1 ]]; then
    if ! ffmpeg "${common[@]}" \
      -c:v hevc_nvenc -preset p5 -profile:v main -rc vbr \
      -b:v "${AVG_VIDEO_KBPS}k" -maxrate "${MAXRATE_KBPS}k" -bufsize "${BUFSIZE_KBPS}k" \
      -cq 28 \
      "$tmp"; then
      echo "  Failed encode: $base" >&2
      rm -f "$tmp"
      FAILED=$((FAILED + 1))
      echo
      continue
    fi
  else
    if ! ffmpeg "${common[@]}" \
      -c:v libx265 -preset medium \
      -b:v "${AVG_VIDEO_KBPS}k" -maxrate "${MAXRATE_KBPS}k" -bufsize "${BUFSIZE_KBPS}k" \
      -x265-params log-level=error \
      "$tmp"; then
      echo "  Failed encode: $base" >&2
      rm -f "$tmp"
      FAILED=$((FAILED + 1))
      echo
      continue
    fi
  fi

  # Verify output fps
  out_fps="$(ffprobe -v quiet -select_streams v:0 -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 "$tmp" 2>/dev/null || echo "?")"
  echo "  Encoded fps: $out_fps"

  META_TITLE="$out_base"
  META_DESC=""
  META_LOC=""
  META_LAT=""
  META_LON=""
  META_ISO6709=""
  META_CREATION="$creation"
  META_NOTES=""

  if [[ "$INTERACTIVE" -eq 1 ]]; then
    cam_meta_interactive_review "$tmp" "$out_base" "$creation" "$source_fps_label" "$target_fps"
    # Recompute filename if user changed date
    out_base="$(cam_meta_output_basename "$stem" "$META_CREATION")"
    out="$OUTPUT_FOLDER/${out_base}.mp4"
    json_sidecar="$OUTPUT_FOLDER/${out_base}.json"
  fi

  cam_meta_apply_to_mp4 "$tmp" "$out" "$META_CREATION" "$META_TITLE" "$META_DESC" \
    "$META_LOC" "$META_LAT" "$META_LON" "$META_ISO6709"
  rm -f "$tmp"

  cam_meta_touch_file_time "$out" "$META_CREATION"

  cam_meta_write_json_sidecar "$json_sidecar" \
    "$f" "$out" "$META_CREATION" "$META_TITLE" "$META_DESC" \
    "$META_LOC" "$META_LAT" "$META_LON" "$META_ISO6709" \
    "$source_fps_label" "$target_fps" "$META_NOTES"

  cam_meta_append_csv_log "$METADATA_CSV" \
    "$f" "$out" "$META_CREATION" "$META_TITLE" "$META_DESC" \
    "$META_LOC" "$META_LAT" "$META_LON" "$META_ISO6709" \
    "$source_fps_label" "$target_fps" "$META_NOTES"

  out_size="$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")"
  src_size="$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")"
  OUTPUT_BYTES=$((OUTPUT_BYTES + out_size))
  python3 - "$out" "$out_size" "$src_size" "$json_sidecar" <<'PY'
import sys
path, out_s, src_s, sidecar = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
ratio = (src_s / out_s) if out_s else 0
print(f"  Done: {path} ({out_s/1048576:.2f} MB, {ratio:.1f}:1)")
print(f"  Sidecar: {sidecar}")
PY
  echo
  OK=$((OK + 1))
done

echo "Compact conversion complete."
echo "  Succeeded: $OK  Failed: $FAILED"
echo "  Metadata log: $METADATA_CSV"
python3 -c "print(f'  Output total: {$OUTPUT_BYTES/1048576:.2f} MB / budget {$TARGET_TOTAL_BYTES/1048576:.2f} MB')"
if [[ "$OUTPUT_BYTES" -gt "$MAX_OUTPUT_BYTES" ]]; then
  echo "WARNING: Output exceeded max budget. Re-run with lower --max-video-kbps or --height." >&2
fi
[[ "$FAILED" -eq 0 ]] || exit 2
exit 0
