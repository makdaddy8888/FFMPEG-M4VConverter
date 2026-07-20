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

cam_meta_interactive_review() {
  # Sets globals: META_TITLE META_DESC META_LOC META_LAT META_LON META_ISO6709 META_CREATION META_NOTES
  local file="$1" stem="$2" creation="$3" source_fps="$4" out_fps="$5"
  META_TITLE="$stem"
  META_DESC=""
  META_LOC=""
  META_LAT=""
  META_LON=""
  META_ISO6709=""
  META_CREATION="$creation"
  META_NOTES=""

  echo ""
  echo "  ┌─────────────────────────────────────────────────────────"
  echo "  │ Review clip: $(basename "$file")"
  echo "  │ Recorded:     $creation"
  echo "  │ Source fps:   $source_fps  →  output: ${out_fps} fps progressive"
  echo "  └─────────────────────────────────────────────────────────"
  cam_meta_open_player "$file"
  echo ""
  echo "  Watch the clip, then enter metadata (Enter = keep default / skip)."
  echo ""

  read -r -p "  Title [$META_TITLE]: " ans
  [[ -n "$ans" ]] && META_TITLE="$ans"

  read -r -p "  Description / what happens in this clip: " META_DESC

  read -r -p "  Location name (e.g. Beach holiday): " META_LOC

  read -r -p "  Latitude (decimal, e.g. -27.47): " META_LAT
  read -r -p "  Longitude (decimal, e.g. 153.03): " META_LON
  if [[ -n "$META_LAT" && -n "$META_LON" ]]; then
    META_ISO6709="$(cam_meta_iso6709 "$META_LAT" "$META_LON" || true)"
  fi

  read -r -p "  Recording date override (DDMMYYYY, blank = use $creation): " date_override
  if [[ -n "$date_override" ]]; then
    # Parse DDMMYYYY to ISO
    META_CREATION="$(python3 - "$date_override" <<'PY'
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
    if [[ -z "$META_CREATION" ]]; then
      echo "  Invalid date format; keeping original creation time."
      META_CREATION="$creation"
    fi
  fi

  read -r -p "  Notes (private log): " META_NOTES
  echo ""
}
