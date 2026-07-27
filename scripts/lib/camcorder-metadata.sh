#!/usr/bin/env bash
# Shared helpers for camcorder ingest: dates, filenames, fps, metadata I/O.
# Source this file from convert scripts (do not execute directly).

cam_meta_date_suffix() {
  # DDMMYYYY from ISO creation_time or file mtime
  local iso="${1:-}"
  if [[ -n "$iso" ]]; then
    date -u -d "$iso" +"%d%m%Y" 2>/dev/null && return 0
  fi
  date +"%d%m%Y"
}

cam_meta_output_basename() {
  # e.g. 00018-10072026
  local stem="$1" iso="$2"
  echo "${stem}-$(cam_meta_date_suffix "$iso")"
}

cam_meta_get_creation_iso() {
  local f="$1" ct
  ct="$(ffprobe -v quiet -show_entries format_tags=creation_time -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | head -n1 || true)"
  if [[ -z "$ct" ]]; then
    ct="$(ffprobe -v quiet -show_entries stream_tags=creation_time -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null | head -n1 || true)"
  fi
  if [[ -n "$ct" ]]; then
    echo "$ct"
  else
    date -u -r "$f" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "@$(stat -c%Y "$f")" +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

cam_meta_parse_fps() {
  # Convert ffprobe rate like "50/1" or "30000/1001" to a float
  local rate="$1" num den
  if [[ "$rate" == */* ]]; then
    num="${rate%/*}"; den="${rate#*/}"
    awk -v n="$num" -v d="$den" 'BEGIN { if (d > 0) printf "%.4f", n/d; else print "0" }'
  else
    echo "$rate"
  fi
}

cam_meta_target_fps() {
  # PAL 50i AVCHD often reports 50fps before deinterlace → output 25fps progressive.
  # NTSC 60i → 30fps (or 29.97). Already-progressive sources keep native rate.
  local f="$1"
  local json
  json="$(ffprobe -v quiet -select_streams v:0 -show_entries stream=avg_frame_rate,r_frame_rate,field_order -of json "$f" 2>/dev/null || echo '{}')"
  python3 - "$json" <<'PY'
import json, sys
data = json.loads(sys.argv[1] or "{}")
streams = data.get("streams") or [{}]
s = streams[0]
def parse_rate(r):
    if not r or r in ("0/0", "N/A"):
        return None
    if "/" in r:
        n, d = r.split("/", 1)
        d = float(d)
        return float(n) / d if d else None
    try:
        return float(r)
    except ValueError:
        return None

avg = parse_rate(s.get("avg_frame_rate"))
rfr = parse_rate(s.get("r_frame_rate"))
rate = avg or rfr or 25.0
field = (s.get("field_order") or "").lower()

# Interlaced high field-rate → half for progressive output
if field in ("tt", "bb", "tb", "bt") or rate >= 48:
    if rate >= 59:
        out = 30000 / 1001  # ~29.97 NTSC
    elif rate >= 48:
        out = 25.0          # PAL
    else:
        out = round(rate / 2, 3)
elif 29.4 <= rate <= 30.1:
    out = 30000 / 1001
elif 23.9 <= rate <= 24.1:
    out = 24.0
elif 24.9 <= rate <= 25.1:
    out = 25.0
else:
    out = round(rate, 3)

# Sensible integer-ish output for ffmpeg -r
if abs(out - 30000/1001) < 0.05:
    print("30000/1001")
elif abs(out - round(out)) < 0.01:
    print(int(round(out)))
else:
    print(f"{out:.3f}")
PY
}

cam_meta_iso6709() {
  # +lat+lon/  (degrees, no spaces)
  local lat="$1" lon="$2"
  [[ -n "$lat" && -n "$lon" ]] || return 1
  python3 - "$lat" "$lon" <<'PY'
import sys
lat = float(sys.argv[1])
lon = float(sys.argv[2])
def fmt(v, pos, neg):
    sign = pos if v >= 0 else neg
    return f"{sign}{abs(v):.4f}"
print(f"{fmt(lat, '+', '-')}{fmt(lon, '+', '-')}/")
PY
}

cam_meta_touch_file_time() {
  local file="$1" iso="$2"
  local ts
  ts="$(date -u -d "$iso" +%Y%m%d%H%M.%S 2>/dev/null || true)"
  [[ -n "$ts" ]] && touch -t "$ts" "$file" 2>/dev/null || true
}

cam_meta_write_json_sidecar() {
  local json_path="$1"
  shift
  python3 - "$json_path" "$@" <<'PY'
import json, sys
path = sys.argv[1]
keys = ["source_file", "output_file", "creation_time", "title", "description", "location_name", "latitude", "longitude", "iso6709", "source_fps", "output_fps", "notes"]
data = {}
for i, k in enumerate(keys):
    if i + 2 < len(sys.argv):
        data[k] = sys.argv[i + 2]
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
}

cam_meta_append_csv_log() {
  local csv="$1"
  shift
  local header="source_file,output_file,creation_time,title,description,location_name,latitude,longitude,iso6709,source_fps,output_fps,notes"
  if [[ ! -f "$csv" ]]; then
    echo "$header" > "$csv"
  fi
  python3 - "$csv" "$@" <<'PY'
import csv, sys
path = sys.argv[1]
row = sys.argv[2:]
with open(path, "a", newline="", encoding="utf-8") as f:
    csv.writer(f).writerow(row)
PY
}

cam_meta_apply_to_mp4() {
  # Remux with metadata (no re-encode). Args: in out creation_iso title desc location_name lat lon iso6709
  local in="$1" out="$2" creation="$3" title="$4" desc="$5" loc="$6" lat="$7" lon="$8" iso6709="$9"
  local -a meta=(
    -metadata "creation_time=${creation}"
    -metadata "title=${title}"
    -metadata "date=${creation}"
  )
  [[ -n "$desc" ]] && meta+=(-metadata "description=${desc}" -metadata "comment=${desc}")
  [[ -n "$loc" ]] && meta+=(-metadata "location=${loc}")
  if [[ -n "$iso6709" ]]; then
    meta+=(-metadata "com.apple.quicktime.location.ISO6709=${iso6709}")
    meta+=(-metadata "location-eng=${iso6709}")
  fi
  ffmpeg -y -hide_banner -loglevel error -i "$in" -map 0 -c copy \
    -movflags +faststart+use_metadata_tags \
    "${meta[@]}" "$out"
}

cam_meta_open_player() {
  local file="$1"
  if [[ -n "${CAM_META_PLAYER:-}" ]]; then
    "$CAM_META_PLAYER" "$file" &>/dev/null &
    return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$file" &>/dev/null &
    return 0
  fi
  if command -v vlc >/dev/null 2>&1; then
    vlc --play-and-exit "$file" &>/dev/null &
    return 0
  fi
  echo "  (Install VLC or set CAM_META_PLAYER to preview clips.)"
}

cam_meta_is_back_cmd() {
  # True if the user asked to go to the previous field
  local s
  s="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$s" in
    back|b|up|'<'|'^'|prev|previous) return 0 ;;
    *) return 1 ;;
  esac
}

cam_meta_read_field() {
  # Read one editable field with readline (←→ move cursor, edit typos).
  # Usage: cam_meta_read_field PROMPT DEFAULT_VALUE → prints answer on stdout
  # Exit 2 if user typed a "back" command.
  # Prefills DEFAULT so you can arrow left and fix mistakes in place.
  local prompt="$1" default="${2:-}" ans
  # -e = readline (arrow keys work); -i = initial text to edit
  if [[ -n "$default" ]]; then
    read -e -i "$default" -r -p "$prompt" ans || true
  else
    read -e -r -p "$prompt" ans || true
  fi
  if cam_meta_is_back_cmd "$ans"; then
    return 2
  fi
  printf '%s' "$ans"
}

cam_meta_parse_date_override() {
  # DDMMYYYY → ISO, or empty on failure
  local date_override="$1" creation_fallback="$2"
  [[ -n "$date_override" ]] || { printf '%s' "$creation_fallback"; return 0; }
  local parsed
  parsed="$(python3 - "$date_override" <<'PY'
import sys
from datetime import datetime
d = sys.argv[1].strip()
try:
    dt = datetime.strptime(d, "%d%m%Y")
    print(dt.strftime("%Y-%m-%dT%H:%M:%SZ"))
except ValueError:
    print("")
PY
)"
  if [[ -z "$parsed" ]]; then
    echo "  Invalid date format; keeping original creation time." >&2
    printf '%s' "$creation_fallback"
  else
    printf '%s' "$parsed"
  fi
}

cam_meta_interactive_review() {
  # Sets globals: META_TITLE META_DESC META_LOC META_LAT META_LON META_ISO6709 META_CREATION META_NOTES
  # If CAM_META_PREFILL=1, keep any META_* values already set by the caller (edit mode).
  local file="$1" stem="$2" creation="$3" source_fps="$4" out_fps="$5"
  if [[ "${CAM_META_PREFILL:-0}" == "1" ]]; then
    META_TITLE="${META_TITLE:-$stem}"
    META_DESC="${META_DESC:-}"
    META_LOC="${META_LOC:-}"
    META_LAT="${META_LAT:-}"
    META_LON="${META_LON:-}"
    META_ISO6709="${META_ISO6709:-}"
    META_CREATION="${META_CREATION:-$creation}"
    META_NOTES="${META_NOTES:-}"
  else
    META_TITLE="$stem"
    META_DESC=""
    META_LOC=""
    META_LAT=""
    META_LON=""
    META_ISO6709=""
    META_CREATION="$creation"
    META_NOTES=""
  fi
  local date_override="" ans step=0 status=0 choice=""
  if [[ -n "$META_CREATION" && "$META_CREATION" != "$creation" ]]; then
    date_override="$(cam_meta_date_suffix "$META_CREATION" || true)"
  fi

  echo ""
  echo "  ┌─────────────────────────────────────────────────────────"
  echo "  │ Review clip: $(basename "$file")"
  echo "  │ Recorded:     $creation"
  echo "  │ Source fps:   $source_fps  →  output: ${out_fps} fps progressive"
  echo "  └─────────────────────────────────────────────────────────"
  cam_meta_open_player "$file"
  echo ""
  echo "  Watch the clip, then enter metadata."
  echo "  Tips:  ← → move cursor to fix typos   |   type back  = previous field"
  echo "         Enter keeps the text shown     |   type back on Title = stay"
  echo ""

  # Field order: 0 title, 1 desc, 2 loc, 3 lat, 4 lon, 5 date, 6 notes, 7 confirm
  while true; do
    case "$step" in
      0)
        ans="$(cam_meta_read_field "  Title: " "$META_TITLE")"
        status=$?
        if [[ $status -eq 2 ]]; then
          echo "  (Already at first field.)"
          continue
        fi
        [[ -n "$ans" ]] && META_TITLE="$ans"
        step=1
        ;;
      1)
        ans="$(cam_meta_read_field "  Description / what happens: " "$META_DESC")"
        status=$?
        if [[ $status -eq 2 ]]; then step=0; continue; fi
        META_DESC="$ans"
        step=2
        ;;
      2)
        ans="$(cam_meta_read_field "  Location name (e.g. Beach holiday): " "$META_LOC")"
        status=$?
        if [[ $status -eq 2 ]]; then step=1; continue; fi
        META_LOC="$ans"
        step=3
        ;;
      3)
        ans="$(cam_meta_read_field "  Latitude (decimal, e.g. -27.47): " "$META_LAT")"
        status=$?
        if [[ $status -eq 2 ]]; then step=2; continue; fi
        META_LAT="$ans"
        step=4
        ;;
      4)
        ans="$(cam_meta_read_field "  Longitude (decimal, e.g. 153.03): " "$META_LON")"
        status=$?
        if [[ $status -eq 2 ]]; then step=3; continue; fi
        META_LON="$ans"
        if [[ -n "$META_LAT" && -n "$META_LON" ]]; then
          META_ISO6709="$(cam_meta_iso6709 "$META_LAT" "$META_LON" || true)"
        else
          META_ISO6709=""
        fi
        step=5
        ;;
      5)
        ans="$(cam_meta_read_field "  Recording date override (DDMMYYYY, blank = keep): " "$date_override")"
        status=$?
        if [[ $status -eq 2 ]]; then step=4; continue; fi
        date_override="$ans"
        META_CREATION="$(cam_meta_parse_date_override "$date_override" "$creation")"
        step=6
        ;;
      6)
        ans="$(cam_meta_read_field "  Notes (private log): " "$META_NOTES")"
        status=$?
        if [[ $status -eq 2 ]]; then step=5; continue; fi
        META_NOTES="$ans"
        step=7
        ;;
      7)
        echo ""
        echo "  ── Summary ─────────────────────────────────────────────"
        echo "  Title:       $META_TITLE"
        echo "  Description: ${META_DESC:-—}"
        echo "  Location:    ${META_LOC:-—}"
        echo "  Lat/Lon:     ${META_LAT:-—} / ${META_LON:-—}"
        echo "  Date:        $META_CREATION"
        echo "  Notes:       ${META_NOTES:-—}"
        echo "  ────────────────────────────────────────────────────────"
        ans="$(cam_meta_read_field "  OK? [Enter=yes / back / title / desc / loc / lat / lon / date / notes]: " "")"
        status=$?
        if [[ $status -eq 2 ]]; then step=6; continue; fi
        choice="$(echo "${ans:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        case "$choice" in
          ""|y|yes|ok|done) break ;;
          title|t) step=0 ;;
          desc|description|d) step=1 ;;
          loc|location|l) step=2 ;;
          lat|latitude) step=3 ;;
          lon|longitude|long) step=4 ;;
          date) step=5 ;;
          notes|n) step=6 ;;
          *)
            echo "  Unknown choice. Press Enter to accept, or type title / desc / back."
            ;;
        esac
        ;;
      *) step=0 ;;
    esac
  done
  echo ""
}
