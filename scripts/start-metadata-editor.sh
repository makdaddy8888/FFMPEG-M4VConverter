#!/usr/bin/env bash
# start-metadata-editor.sh — launch the local thumbnail + metadata web UI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER="$REPO_DIR/web/metadata-editor/server.py"

usage() {
  cat <<'EOF'
Usage: start-metadata-editor.sh [options]

Opens a local web UI to review thumbnails and edit clip metadata
(JSON sidecars + MP4 tags, no re-encode).

Options:
  --dir DIR         Batch folder (or name under iPhone root)
  --iphone-root DIR Parent of batch folders
                    (default: ~/Videos/CamcorderIngest/iPhone)
  --port N          Port (default: 8765)
  --host ADDR       Bind address (default: 127.0.0.1)
  --no-open         Do not open a browser
  -h, --help        Show help

Examples:
  ./scripts/start-metadata-editor.sh
  ./scripts/start-metadata-editor.sh --dir 2026-07-23_104722_7BDA-675E
  ./scripts/start-metadata-editor.sh --dir ~/Videos/CamcorderIngest/iPhone/2026-07-23_104722_7BDA-675E
EOF
}

DIR_ARG=""
IPHONE_ROOT="${HOME}/Videos/CamcorderIngest/iPhone"
PORT=8765
HOST="127.0.0.1"
OPEN=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR_ARG="$2"; shift 2 ;;
    --iphone-root) IPHONE_ROOT="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --no-open) OPEN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ ! -f "$SERVER" ]]; then
  echo "Missing server: $SERVER" >&2
  exit 1
fi
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }

args=(--iphone-root "$IPHONE_ROOT" --host "$HOST" --port "$PORT")
[[ -n "$DIR_ARG" ]] && args+=(--dir "$DIR_ARG")
[[ "$OPEN" -eq 1 ]] && args+=(--open)

exec python3 "$SERVER" "${args[@]}"
