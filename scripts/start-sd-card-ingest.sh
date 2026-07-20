#!/usr/bin/env bash
# start-sd-card-ingest.sh — watch for SD card, copy .MTS, convert for iPhone
# Designed for Linux (no NVIDIA required). CPU libx265 by default.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONVERT_SCRIPT="$SCRIPT_DIR/convert-mts-to-compact.sh"

usage() {
  cat <<'EOF'
Usage: start-sd-card-ingest.sh [options]

Watches for an AVCHD / HDCAM SD card, copies .MTS files to disk, then
converts them to compact iPhone HEVC (~8:1 size, e.g. 8 GB -> ~1 GB).

Options:
  --dest-root DIR       Inbox / iPhone / Logs root
                        (default: $HOME/Videos/CamcorderIngest)
  --poll-seconds N      Watch poll interval (default: 2)
  --once                Process an already-mounted card, then exit
  --source-path DIR     Use this folder directly (skip auto-detect)
  --target-ratio N      Size ratio goal (default: 8)
  --max-output-bytes N  Output ceiling in bytes (default: 1 GiB)
  --width N             Output width (default: 854)
  --height N            Output height (default: 480)
  --keep-watching       After one card, wait for the next
  --prefer-nvenc        Pass through to converter (otherwise CPU)
  -h, --help            Show this help

Examples:
  ./scripts/start-sd-card-ingest.sh
  ./scripts/start-sd-card-ingest.sh --once
  ./scripts/start-sd-card-ingest.sh --once --source-path /media/$USER/SDCARD
  ./scripts/start-sd-card-ingest.sh --dest-root "$HOME/Videos/Camcorder"
EOF
}

DEST_ROOT="${HOME}/Videos/CamcorderIngest"
POLL_SECONDS=2
ONCE=0
SOURCE_PATH=""
TARGET_RATIO=8
MAX_OUTPUT_BYTES=1073741824
WIDTH=854
HEIGHT=480
KEEP_WATCHING=0
PREFER_NVENC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-root) DEST_ROOT="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --source-path) SOURCE_PATH="$2"; shift 2 ;;
    --target-ratio) TARGET_RATIO="$2"; shift 2 ;;
    --max-output-bytes) MAX_OUTPUT_BYTES="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --height) HEIGHT="$2"; shift 2 ;;
    --keep-watching) KEEP_WATCHING=1; shift ;;
    --prefer-nvenc) PREFER_NVENC=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ ! -x "$CONVERT_SCRIPT" && -f "$CONVERT_SCRIPT" ]]; then
  chmod +x "$CONVERT_SCRIPT"
fi
if [[ ! -f "$CONVERT_SCRIPT" ]]; then
  echo "Missing conversion script: $CONVERT_SCRIPT" >&2
  exit 1
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg not found on PATH" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not found on PATH" >&2; exit 1; }

INBOX_ROOT="$DEST_ROOT/Inbox"
IPHONE_ROOT="$DEST_ROOT/iPhone"
LOG_ROOT="$DEST_ROOT/Logs"
mkdir -p "$INBOX_ROOT" "$IPHONE_ROOT" "$LOG_ROOT"

LOG_FILE=""
log() {
  local level="${2:-INFO}"
  local line="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $1"
  # stderr so command substitutions can capture clean stdout (copy stats)
  echo "$line" >&2
  if [[ -n "$LOG_FILE" ]]; then
    echo "$line" >> "$LOG_FILE"
  fi
}

mb_str() {
  awk -v b="$1" 'BEGIN { printf "%.2f", b / 1048576 }'
}

# Candidate mount roots where desktop environments usually mount removable media
candidate_mounts() {
  local roots=()
  local d
  for d in "/media/${USER}" "/run/media/${USER}" /media /mnt; do
    [[ -d "$d" ]] || continue
    if [[ "$d" == /media || "$d" == /mnt ]]; then
      # only immediate subdirs
      local child
      for child in "$d"/*; do
        [[ -d "$child" ]] || continue
        # skip empty placeholders
        roots+=("$child")
      done
    else
      local child
      for child in "$d"/*; do
        [[ -d "$child" ]] || continue
        roots+=("$child")
      done
    fi
  done

  # Also include currently mounted removable/hotplug filesystems via findmnt
  if command -v findmnt >/dev/null; then
    while IFS= read -r mp; do
      [[ -n "$mp" && -d "$mp" ]] || continue
      roots+=("$mp")
    done < <(findmnt -rno TARGET,FSTYPE,SOURCE | awk '
      $2 ~ /^(vfat|exfat|fuseblk|ntfs|msdos)$/ && $1 !~ /^\/(boot|sys|proc|run\/credentials)/ { print $1 }
    ')
  fi

  printf '%s\n' "${roots[@]}" | awk 'NF' | sort -u
}

find_mts_source() {
  local root="$1"
  local stream
  for stream in \
    "$root/PRIVATE/AVCHD/BDMV/STREAM" \
    "$root/private/AVCHD/BDMV/STREAM" \
    "$root/AVCHD/BDMV/STREAM"; do
    if [[ -d "$stream" ]] && find "$stream" -maxdepth 1 -type f \( -iname '*.mts' \) -print -quit | grep -q .; then
      echo "$stream"
      return 0
    fi
  done

  # Loose .MTS anywhere on this mount (small removable volumes only)
  if find "$root" -type f \( -iname '*.mts' \) -print -quit 2>/dev/null | grep -q .; then
    echo "$root"
    return 0
  fi
  return 1
}

discover_sources() {
  local root src
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    if src="$(find_mts_source "$root")"; then
      printf '%s\t%s\n' "$root" "$src"
    fi
  done < <(candidate_mounts)
}

fingerprint_root() {
  local root="$1"
  local src id size label
  src="$(findmnt -n -o SOURCE --target "$root" 2>/dev/null || echo unknown)"
  size="$(df -B1 --output=size "$root" 2>/dev/null | tail -n1 | tr -d ' ' || echo 0)"
  label="$(basename "$root")"
  id="$(lsblk -no UUID "$src" 2>/dev/null | head -n1 || true)"
  echo "${id}|${src}|${size}|${label}"
}

copy_mts_files() {
  local source_path="$1"
  local dest_path="$2"
  mkdir -p "$dest_path"

  mapfile -d '' files < <(find "$source_path" -type f \( -iname '*.mts' \) -print0 | sort -z)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No .MTS files found under $source_path" >&2
    return 1
  fi

  local copied=0 skipped=0 bytes=0 f base dest
  for f in "${files[@]}"; do
    base="$(basename "$f")"
    dest="$dest_path/$base"
    local src_size
    src_size="$(stat -c%s "$f")"
    if [[ -f "$dest" ]] && [[ "$(stat -c%s "$dest")" -eq "$src_size" ]]; then
      log "Skip (already copied): $base" INFO
      skipped=$((skipped + 1))
      bytes=$((bytes + src_size))
      continue
    fi
    log "Copying $base ($(mb_str "$src_size") MB)..."
    cp -p "$f" "$dest"
    bytes=$((bytes + src_size))
    copied=$((copied + 1))
  done

  # stdout: stats only (captured by caller)
  echo "$copied $skipped ${#files[@]} $bytes"
}

ingest_one() {
  local mount_root="$1"
  local source_path="$2"
  local stamp label safe batch inbox iphone
  stamp="$(date '+%Y-%m-%d_%H%M%S')"
  label="$(basename "$mount_root")"
  safe="$(echo "$label" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_//;s/_$//')"
  [[ -n "$safe" ]] || safe="SDCARD"
  batch="${stamp}_${safe}"
  inbox="$INBOX_ROOT/$batch"
  iphone="$IPHONE_ROOT/$batch"
  LOG_FILE="$LOG_ROOT/${batch}.log"

  mkdir -p "$inbox" "$iphone"
  log "========================================"
  log "SD card detected: $mount_root"
  log "Source clips: $source_path"
  log "Inbox:  $inbox"
  log "iPhone: $iphone"
  log "Log:    $LOG_FILE"

  log "=== Stage 1/2: Copy .MTS off the SD card ==="
  local copy_stats copied skipped total bytes
  copy_stats="$(copy_mts_files "$source_path" "$inbox")"
  read -r copied skipped total bytes <<< "$copy_stats"
  log "Copy complete: $copied copied, $skipped skipped, $total total, $(mb_str "$bytes") MB"

  echo
  echo "  **********************************************"
  echo "  *  COPY DONE — safe to eject the SD card now *"
  echo "  **********************************************"
  echo
  log "Safe to eject the SD card. Conversion continues from the hard drive."

  log "=== Stage 2/2: Convert to compact iPhone MP4 (CPU unless --prefer-nvenc) ==="
  log "Target ~${TARGET_RATIO}:1, max output $(awk -v b="$MAX_OUTPUT_BYTES" 'BEGIN { printf "%d", b/1048576 }') MB, ${WIDTH}x${HEIGHT}"

  local convert_args=(
    -i "$inbox" -o "$iphone"
    --target-ratio "$TARGET_RATIO"
    --max-output-bytes "$MAX_OUTPUT_BYTES"
    --width "$WIDTH"
    --height "$HEIGHT"
  )
  if [[ "$PREFER_NVENC" -eq 1 ]]; then
    convert_args+=(--prefer-nvenc)
  fi

  set +e
  "$CONVERT_SCRIPT" "${convert_args[@]}"
  local rc=$?
  set -e

  if [[ $rc -eq 0 ]]; then
    local out_size
    out_size="$(find "$iphone" -type f -name '*.mp4' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')"
    log "Conversion succeeded. iPhone folder: $iphone ($(mb_str "$out_size") MB)"
  else
    log "Conversion finished with errors (exit $rc)." ERROR
  fi
  log "Batch complete: $batch"
  return "$rc"
}

echo
echo "  SD Card Auto-Ingest (Linux / CPU-first)"
echo "  DestRoot: $DEST_ROOT"
echo "  Target:   ~${TARGET_RATIO}:1  (max $(awk -v b="$MAX_OUTPUT_BYTES" 'BEGIN { printf "%d", b/1048576 }') MB total output)"
echo "  Output:   ${WIDTH}x${HEIGHT} HEVC for iPhone"
echo "  Encoder:  libx265 CPU$([[ "$PREFER_NVENC" -eq 1 ]] && echo ' (NVENC preferred if present)')"
if [[ "$ONCE" -eq 1 || -n "$SOURCE_PATH" ]]; then
  echo "  Mode:     once"
elif [[ "$KEEP_WATCHING" -eq 1 ]]; then
  echo "  Mode:     watch (every new card)"
else
  echo "  Mode:     watch until first card, then exit"
fi
echo

if [[ -n "$SOURCE_PATH" ]]; then
  if [[ ! -d "$SOURCE_PATH" ]]; then
    echo "Source path not found: $SOURCE_PATH" >&2
    exit 1
  fi
  src="$(find_mts_source "$SOURCE_PATH" || true)"
  if [[ -z "$src" ]]; then
    # allow pointing directly at a STREAM folder
    if find "$SOURCE_PATH" -maxdepth 1 -type f \( -iname '*.mts' \) -print -quit | grep -q .; then
      src="$SOURCE_PATH"
    else
      echo "No .MTS files found under $SOURCE_PATH" >&2
      exit 1
    fi
  fi
  ingest_one "$SOURCE_PATH" "$src"
  exit $?
fi

if [[ "$ONCE" -eq 1 ]]; then
  mapfile -t found < <(discover_sources)
  if [[ ${#found[@]} -eq 0 ]]; then
    echo "No SD card with .MTS files detected." >&2
    echo "Mount the card, or pass --source-path /path/to/STREAM" >&2
    exit 1
  fi
  IFS=$'\t' read -r root src <<< "${found[0]}"
  if [[ ${#found[@]} -gt 1 ]]; then
    echo "Multiple cards found; using the first: $root"
  fi
  ingest_one "$root" "$src"
  exit $?
fi

echo "Waiting for an SD card with .MTS files..."
echo "Insert the card into the reader and wait for it to mount. Press Ctrl+C to cancel."
echo

declare -A SEEN=()
while true; do
  while IFS=$'\t' read -r root src; do
    [[ -n "$root" ]] || continue
    fp="$(fingerprint_root "$root")"
    if [[ -n "${SEEN[$fp]+x}" ]]; then
      continue
    fi
    SEEN[$fp]=1
    set +e
    ingest_one "$root" "$src"
    rc=$?
    set -e
    if [[ "$KEEP_WATCHING" -eq 0 ]]; then
      exit "$rc"
    fi
    echo
    echo "Ready for the next SD card..."
  done < <(discover_sources)
  sleep "$POLL_SECONDS"
done
