#!/usr/bin/env bash
# start-sd-card-ingest.sh — copy from SD card if present, else convert existing Inbox
# Designed for Linux (no NVIDIA required). CPU libx265 by default.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONVERT_SCRIPT="$SCRIPT_DIR/convert-mts-to-compact.sh"

usage() {
  cat <<'EOF'
Usage: start-sd-card-ingest.sh [options]

Smart ingest:
  1. If an SD card with .MTS is present → copy to Inbox, then convert
  2. If no SD card → convert existing .MTS already saved under Inbox/

Options:
  --dest-root DIR       Inbox / iPhone / Logs root
                        (default: $HOME/Videos/CamcorderIngest)
  --poll-seconds N      Watch poll interval (default: 2)
  --once                Run once (detect card or fall back to Inbox), then exit
                        (this is the default behaviour)
  --watch               Wait for a new SD card instead of using Inbox fallback
  --source-path DIR     Use this folder/card path directly (skip auto-detect)
  --inbox-batch DIR     Convert this Inbox batch folder (name or full path)
  --inbox-only          Skip SD detection; only convert existing Inbox copies
  --target-ratio N      Size ratio goal (default: 8)
  --max-output-bytes N  Output ceiling in bytes (default: 1 GiB)
  --width N             Output width (default: 854)
  --height N            Output height (default: 480)
  --keep-watching       After one card, wait for the next
  --prefer-nvenc        Pass through to converter (otherwise CPU)
  --interactive         Prompt for metadata after each clip (default if TTY)
  --no-interactive      Batch convert without prompts
  -h, --help            Show this help

Examples:
  # Usual: card in → copy+convert; card out → convert saved Inbox
  ./scripts/start-sd-card-ingest.sh

  ./scripts/start-sd-card-ingest.sh --source-path /run/media/$USER/23F0-4F26
  ./scripts/start-sd-card-ingest.sh --inbox-only
  ./scripts/start-sd-card-ingest.sh --inbox-batch 2026-07-20_020638_fake-sd
EOF
}

DEST_ROOT="${HOME}/Videos/CamcorderIngest"
POLL_SECONDS=2
MODE="auto"          # auto | watch | inbox-only
SOURCE_PATH=""
INBOX_BATCH=""
TARGET_RATIO=8
MAX_OUTPUT_BYTES=1073741824
WIDTH=854
HEIGHT=480
KEEP_WATCHING=0
PREFER_NVENC=0
INTERACTIVE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest-root) DEST_ROOT="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --once) MODE="auto"; shift ;;
    --watch) MODE="watch"; shift ;;
    --source-path) SOURCE_PATH="$2"; shift 2 ;;
    --inbox-batch) INBOX_BATCH="$2"; shift 2 ;;
    --inbox-only) MODE="inbox-only"; shift ;;
    --target-ratio) TARGET_RATIO="$2"; shift 2 ;;
    --max-output-bytes) MAX_OUTPUT_BYTES="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --height) HEIGHT="$2"; shift 2 ;;
    --keep-watching) KEEP_WATCHING=1; MODE="watch"; shift ;;
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
  echo "$line" >&2
  if [[ -n "$LOG_FILE" ]]; then
    echo "$line" >> "$LOG_FILE"
  fi
}

mb_str() {
  awk -v b="$1" 'BEGIN { printf "%.2f", b / 1048576 }'
}

candidate_mounts() {
  local roots=()
  local d
  for d in "/media/${USER}" "/run/media/${USER}" /media /mnt; do
    [[ -d "$d" ]] || continue
    local child
    for child in "$d"/*; do
      [[ -d "$child" ]] || continue
      roots+=("$child")
    done
  done

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
    # Never treat our own Inbox / iPhone folders as an SD card
    case "$root" in
      "$DEST_ROOT"|"$INBOX_ROOT"|"$IPHONE_ROOT"|"$DEST_ROOT"/*) continue ;;
    esac
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

  local copied=0 skipped=0 bytes=0 f base dest src_size
  for f in "${files[@]}"; do
    base="$(basename "$f")"
    dest="$dest_path/$base"
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

  echo "$copied $skipped ${#files[@]} $bytes"
}

run_convert() {
  local inbox="$1"
  local iphone="$2"
  mkdir -p "$iphone"

  log "=== Convert to compact iPhone MP4 ==="
  log "Input:  $inbox"
  log "Output: $iphone"
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
  if [[ "$INTERACTIVE" -eq 1 ]]; then
    convert_args+=(--interactive)
  else
    convert_args+=(--no-interactive)
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
  return "$rc"
}

ingest_from_card() {
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

  run_convert "$inbox" "$iphone"
  local rc=$?
  log "Batch complete: $batch"
  return "$rc"
}

# List Inbox batch dirs that still contain .MTS (newest first)
list_inbox_batches() {
  local d count
  if [[ ! -d "$INBOX_ROOT" ]]; then
    return 0
  fi
  # newest directory first
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    count="$(find "$d" -maxdepth 1 -type f \( -iname '*.mts' \) 2>/dev/null | wc -l)"
    count="$(echo "$count" | tr -d ' ')"
    if [[ "$count" -gt 0 ]]; then
      printf '%s\t%s\n' "$count" "$d"
    fi
  done < <(find "$INBOX_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' 2>/dev/null | sort -nr | cut -f2-)
}

pick_inbox_batch() {
  local preferred="$1"
  local path count

  if [[ -n "$preferred" ]]; then
    if [[ -d "$preferred" ]]; then
      path="$preferred"
    elif [[ -d "$INBOX_ROOT/$preferred" ]]; then
      path="$INBOX_ROOT/$preferred"
    else
      echo "Inbox batch not found: $preferred" >&2
      return 1
    fi
    count="$(find "$path" -maxdepth 1 -type f \( -iname '*.mts' \) 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$count" -eq 0 ]]; then
      echo "No .MTS files in Inbox batch: $path" >&2
      return 1
    fi
    echo "$path"
    return 0
  fi

  mapfile -t batches < <(list_inbox_batches)
  if [[ ${#batches[@]} -eq 0 ]]; then
    return 1
  fi

  # Prefer newest; if several, print a short list
  if [[ ${#batches[@]} -gt 1 ]]; then
    echo "Multiple Inbox batches with .MTS found; using the newest:" >&2
    local i=0
    for row in "${batches[@]}"; do
      i=$((i + 1))
      count="${row%%$'\t'*}"
      path="${row#*$'\t'}"
      echo "  $i) $(basename "$path")  ($count clips)" >&2
      [[ $i -ge 5 ]] && break
    done
  fi

  path="${batches[0]#*$'\t'}"
  echo "$path"
  return 0
}

ingest_from_inbox() {
  local inbox iphone batch
  inbox="$(pick_inbox_batch "$INBOX_BATCH")" || {
    echo "No saved .MTS files found under $INBOX_ROOT" >&2
    echo "Insert the SD card, or copy clips into $INBOX_ROOT/<batch>/ first." >&2
    return 1
  }
  batch="$(basename "$inbox")"
  iphone="$IPHONE_ROOT/$batch"
  LOG_FILE="$LOG_ROOT/${batch}-convert.log"

  log "========================================"
  log "No SD card used — converting existing Inbox copies"
  log "Inbox:  $inbox"
  log "iPhone: $iphone"
  log "Log:    $LOG_FILE"

  local n
  n="$(find "$inbox" -maxdepth 1 -type f \( -iname '*.mts' \) | wc -l | tr -d ' ')"
  log "Found $n .MTS file(s) already on the hard drive"

  run_convert "$inbox" "$iphone"
  local rc=$?
  log "Batch complete: $batch"
  return "$rc"
}

resolve_explicit_source() {
  local path="$1"
  local src
  if [[ ! -d "$path" ]]; then
    echo "Source path not found: $path" >&2
    return 1
  fi
  src="$(find_mts_source "$path" || true)"
  if [[ -z "$src" ]]; then
    if find "$path" -maxdepth 1 -type f \( -iname '*.mts' \) -print -quit | grep -q .; then
      src="$path"
    else
      echo "No .MTS files found under $path" >&2
      return 1
    fi
  fi
  echo "$src"
}

echo
echo "  SD Card Auto-Ingest (Linux / CPU-first)"
echo "  DestRoot: $DEST_ROOT"
echo "  Target:   ~${TARGET_RATIO}:1  (max $(awk -v b="$MAX_OUTPUT_BYTES" 'BEGIN { printf "%d", b/1048576 }') MB total output)"
echo "  Output:   ${WIDTH}x${HEIGHT} HEVC for iPhone"
echo "  Encoder:  libx265 CPU$([[ "$PREFER_NVENC" -eq 1 ]] && echo ' (NVENC preferred if present)')"
echo "  Review:   $([[ "$INTERACTIVE" -eq 1 ]] && echo 'interactive (metadata prompt per clip)' || echo 'batch')"
case "$MODE" in
  auto) echo "  Mode:     auto (SD card if present, else existing Inbox)" ;;
  watch) echo "  Mode:     watch for SD card" ;;
  inbox-only) echo "  Mode:     inbox-only (skip SD card)" ;;
esac
echo

# Explicit path always wins
if [[ -n "$SOURCE_PATH" ]]; then
  src="$(resolve_explicit_source "$SOURCE_PATH")" || exit 1
  # If path is already under Inbox, convert in place (no re-copy)
  case "$SOURCE_PATH" in
    "$INBOX_ROOT"|"$INBOX_ROOT"/*)
      INBOX_BATCH="$SOURCE_PATH"
      ingest_from_inbox
      exit $?
      ;;
  esac
  ingest_from_card "$SOURCE_PATH" "$src"
  exit $?
fi

if [[ "$MODE" == "inbox-only" ]]; then
  ingest_from_inbox
  exit $?
fi

if [[ "$MODE" == "auto" ]]; then
  mapfile -t found < <(discover_sources)
  if [[ ${#found[@]} -gt 0 ]]; then
    IFS=$'\t' read -r root src <<< "${found[0]}"
    if [[ ${#found[@]} -gt 1 ]]; then
      echo "Multiple cards found; using the first: $root"
    fi
    ingest_from_card "$root" "$src"
    exit $?
  fi

  echo "No SD card with .MTS detected — looking for saved Inbox copies..."
  ingest_from_inbox
  exit $?
fi

# watch mode
echo "Waiting for an SD card with .MTS files..."
echo "Insert the card into the reader and wait for it to mount. Press Ctrl+C to cancel."
echo "Tip: run without --watch to fall back to existing Inbox copies."
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
    ingest_from_card "$root" "$src"
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
