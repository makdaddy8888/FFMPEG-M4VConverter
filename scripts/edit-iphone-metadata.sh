#!/usr/bin/env bash
# edit-iphone-metadata.sh — re-review / fix metadata on already-converted iPhone MP4s
# Does NOT re-encode video. Edits JSON sidecars + remuxes metadata into MP4s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/camcorder-metadata.sh
source "$SCRIPT_DIR/lib/camcorder-metadata.sh"

usage() {
  cat <<'EOF'
Usage: edit-iphone-metadata.sh -d IPHONE_BATCH_DIR [options]

Interactively fix titles/descriptions/locations on an existing iPhone batch.
Opens each clip, lets you edit metadata (←→ / back), then remuxes tags into
the MP4 without re-encoding.

Options:
  -d, --dir DIR       iPhone batch folder (contains .mp4 + .json)
  --only STEM         Only edit one clip (e.g. 00011-24122017 or 00011)
  --from STEM         Start at this clip (skip earlier ones)
  --issues-only       Only clips with empty/default/suspicious metadata
  --no-player         Do not open a video player
  -h, --help          Show help

Examples:
  ./scripts/edit-iphone-metadata.sh -d ~/Videos/CamcorderIngest/iPhone/2026-07-23_104722_7BDA-675E
  ./scripts/edit-iphone-metadata.sh -d ... --issues-only
  ./scripts/edit-iphone-metadata.sh -d ... --only 00011
EOF
}

BATCH_DIR=""
ONLY=""
FROM=""
ISSUES_ONLY=0
OPEN_PLAYER=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir) BATCH_DIR="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --issues-only) ISSUES_ONLY=1; shift ;;
    --no-player) OPEN_PLAYER=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "$BATCH_DIR" ]]; then
  usage >&2
  exit 1
fi
if [[ ! -d "$BATCH_DIR" ]]; then
  echo "Folder not found: $BATCH_DIR" >&2
  exit 1
fi
command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not found" >&2; exit 1; }

looks_suspicious() {
  # Flag real problems — not "title left as CLIP-DDMMYYYY" (common / OK).
  local title="$1" desc="$2" loc="$3"
  [[ -z "$desc" ]] && return 0
  local low
  low="$(echo "$title $desc $loc" | tr '[:upper:]' '[:lower:]')"
  if [[ "$low" == *christman* || "$low" == *chlesea* || "$low" == *"jervis bau"* \
     || "$low" == *"sought coogee"* || "$low" == *allowe* \
     || "$low" == *"jervis bay act"* ]]; then
    return 0
  fi
  [[ "$loc" == *NSw ]] && return 0
  return 1
}

mapfile -d '' JSONS < <(find "$BATCH_DIR" -maxdepth 1 -type f -name '*.json' ! -name 'metadata-log.csv' -print0 | sort -z)
# filter to sidecars that have matching mp4
CLIPS=()
for j in "${JSONS[@]}"; do
  [[ -f "$j" ]] || continue
  stem="$(basename "$j" .json)"
  mp4="$BATCH_DIR/${stem}.mp4"
  [[ -f "$mp4" ]] || continue
  if [[ -n "$ONLY" ]]; then
    case "$stem" in
      "$ONLY"|"$ONLY"-*|${ONLY}-*) ;;
      *) continue ;;
    esac
  fi
  CLIPS+=("$j")
done

if [[ ${#CLIPS[@]} -eq 0 ]]; then
  echo "No .json+.mp4 pairs found in $BATCH_DIR" >&2
  exit 1
fi

STARTED=0
if [[ -z "$FROM" ]]; then STARTED=1; fi

echo
echo "  Edit iPhone metadata (no re-encode)"
echo "  Folder: $BATCH_DIR"
echo "  Clips:  ${#CLIPS[@]}"
echo "  Tips:   ← → edit text  |  type back = previous field"
echo "          At summary: Enter=save  |  s / skip = leave unchanged"
echo

UPDATED=0
SKIPPED=0
i=0
for json_path in "${CLIPS[@]}"; do
  i=$((i + 1))
  stem="$(basename "$json_path" .json)"
  mp4="$BATCH_DIR/${stem}.mp4"

  if [[ $STARTED -eq 0 ]]; then
    case "$stem" in
      "$FROM"|"$FROM"-*|${FROM}-*) STARTED=1 ;;
      *) continue ;;
    esac
  fi

  # Load existing sidecar
  eval "$(python3 - "$json_path" <<'PY'
import json, sys, shlex
d = json.load(open(sys.argv[1], encoding="utf-8"))
keys = [
  ("META_TITLE", "title"),
  ("META_DESC", "description"),
  ("META_LOC", "location_name"),
  ("META_LAT", "latitude"),
  ("META_LON", "longitude"),
  ("META_ISO6709", "iso6709"),
  ("META_CREATION", "creation_time"),
  ("META_NOTES", "notes"),
  ("SOURCE_FILE", "source_file"),
  ("SOURCE_FPS", "source_fps"),
  ("OUTPUT_FPS", "output_fps"),
]
for var, key in keys:
    print(f'{var}={shlex.quote(str(d.get(key) or ""))}')
PY
)"

  if [[ "$ISSUES_ONLY" -eq 1 ]] && ! looks_suspicious "$META_TITLE" "$META_DESC" "$META_LOC"; then
    continue
  fi

  echo
  echo "  ══════════════════════════════════════════════════════"
  echo "  [$i/${#CLIPS[@]}] $stem"
  echo "  Current title: $META_TITLE"
  echo "  Description:   ${META_DESC:-—}"
  echo "  Location:      ${META_LOC:-—}"
  echo "  Date:          $META_CREATION"
  echo "  ══════════════════════════════════════════════════════"

  if [[ "$OPEN_PLAYER" -eq 1 ]]; then
    cam_meta_open_player "$mp4"
  fi

  # Quick action before full form
  action="$(cam_meta_read_field "  Action [Enter=edit / s=skip / q=quit]: " "")"
  status=$?
  choice="$(echo "${action:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$choice" in
    s|skip)
      SKIPPED=$((SKIPPED + 1))
      continue
      ;;
    q|quit|exit)
      echo "  Stopped. Updated=$UPDATED skipped=$SKIPPED"
      exit 0
      ;;
  esac

  # Reuse interactive form with current sidecar values prefilled
  export CAM_META_PREFILL=1
  cam_meta_interactive_review \
    "$mp4" "$META_TITLE" "$META_CREATION" "${SOURCE_FPS:-?}" "${OUTPUT_FPS:-?}"
  unset CAM_META_PREFILL

  # Remux metadata into MP4 (temp then replace)
  tmp="${mp4}.meta.tmp.mp4"
  cam_meta_apply_to_mp4 "$mp4" "$tmp" "$META_CREATION" "$META_TITLE" "$META_DESC" \
    "$META_LOC" "$META_LAT" "$META_LON" "$META_ISO6709"
  mv -f "$tmp" "$mp4"
  cam_meta_touch_file_time "$mp4" "$META_CREATION"

  # If title/date changed, rename files to match CLIP-DDMMYYYY convention when possible
  clip_id="${stem%%-*}"
  new_base="$(cam_meta_output_basename "$clip_id" "$META_CREATION")"
  # Prefer keeping human title in metadata only; filename stays date-based
  # unless the stem was already date-based — then refresh date suffix only.
  if [[ "$stem" != "$new_base" && "$stem" =~ ^[0-9]{5}-[0-9]{8}$ ]]; then
    new_mp4="$BATCH_DIR/${new_base}.mp4"
    new_json="$BATCH_DIR/${new_base}.json"
    if [[ ! -e "$new_mp4" ]]; then
      mv -f "$mp4" "$new_mp4"
      mp4="$new_mp4"
      json_path_out="$new_json"
      rm -f "$json_path"
    else
      json_path_out="$json_path"
    fi
  else
    json_path_out="$json_path"
    new_base="$stem"
  fi

  cam_meta_write_json_sidecar "$json_path_out" \
    "${SOURCE_FILE:-}" "$mp4" "$META_CREATION" "$META_TITLE" "$META_DESC" \
    "$META_LOC" "$META_LAT" "$META_LON" "$META_ISO6709" \
    "${SOURCE_FPS:-}" "${OUTPUT_FPS:-}" "$META_NOTES"

  # Append to a fix log (do not rewrite whole CSV mid-session)
  fix_log="$BATCH_DIR/metadata-fixes.csv"
  cam_meta_append_csv_log "$fix_log" \
    "${SOURCE_FILE:-}" "$mp4" "$META_CREATION" "$META_TITLE" "$META_DESC" \
    "$META_LOC" "$META_LAT" "$META_LON" "$META_ISO6709" \
    "${SOURCE_FPS:-}" "${OUTPUT_FPS:-}" "$META_NOTES"

  echo "  Saved: $(basename "$mp4")  title=$META_TITLE"
  UPDATED=$((UPDATED + 1))
done

echo
echo "  Done. Updated=$UPDATED  skipped=$SKIPPED"
echo "  Sidecars + MP4 tags updated. Fix log: $BATCH_DIR/metadata-fixes.csv"
echo
