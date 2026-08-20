#!/usr/bin/env bash
# start-youtube-upload.sh — upload an iPhone batch to YouTube (OAuth)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOADER="$SCRIPT_DIR/upload-to-youtube.py"
REQS="$SCRIPT_DIR/requirements-youtube.txt"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/camcorder-ingest"
CLIENT_SECRET="$CONFIG_DIR/client_secret.json"
VENV_DIR="$CONFIG_DIR/venv"

usage() {
  cat <<'EOF'
Usage: start-youtube-upload.sh --dir BATCH_DIR [options]

Uploads .mp4 clips from an iPhone batch folder to your YouTube channel,
using titles/descriptions from the .json sidecars.

One-time setup (Google account = your YouTube login):
  1. Open https://console.cloud.google.com/
  2. Create (or pick) a project
  3. APIs & Services → Library → enable "YouTube Data API v3"
  4. OAuth consent screen → External → add yourself as a Test user
  5. Credentials → Create credentials → OAuth client ID → Desktop app
  6. Download the JSON and save it as:
       ~/.config/camcorder-ingest/client_secret.json

Options:
  --dir DIR           Batch folder (required)
  --privacy STATUS    private | unlisted | public  (default: private)
  --limit N           Upload at most N new clips this run
  --dry-run           Show what would upload
  --only LIST         Comma-separated stems, e.g. 00011,00014
  --playlist-prefix S Year playlist prefix (default: Camcorder → "Camcorder 2016")
  --create-playlists-only  Create year playlists only (no uploads)
  --no-playlists      Do not use year playlists
  --install-deps      Create venv + install YouTube libraries
  -h, --help          Show help

Examples:
  ./scripts/start-youtube-upload.sh --install-deps
  ./scripts/start-youtube-upload.sh --dir ~/Videos/CamcorderIngest/iPhone/2026-07-23_104722_7BDA-675E --dry-run
  ./scripts/start-youtube-upload.sh --dir ~/Videos/CamcorderIngest/iPhone/2026-07-23_104722_7BDA-675E --privacy private --limit 5
EOF
}

ensure_venv() {
  mkdir -p "$CONFIG_DIR"
  if [[ ! -x "$VENV_DIR/bin/python" ]]; then
    echo "Creating Python venv at $VENV_DIR ..."
    python3 -m venv "$VENV_DIR"
  fi
  "$VENV_DIR/bin/python" -m pip install -q --upgrade pip
  "$VENV_DIR/bin/python" -m pip install -q -r "$REQS"
  echo "YouTube libraries ready in $VENV_DIR"
}

DIR=""
PRIVACY="private"
LIMIT=""
DRY_RUN=0
ONLY=""
INSTALL=0
PLAYLIST_PREFIX="Camcorder"
CREATE_PLAYLISTS_ONLY=0
NO_PLAYLISTS=0
EXTRA=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --privacy) PRIVACY="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    --playlist-prefix) PLAYLIST_PREFIX="$2"; shift 2 ;;
    --create-playlists-only) CREATE_PLAYLISTS_ONLY=1; shift ;;
    --no-playlists) NO_PLAYLISTS=1; shift ;;
    --install-deps) INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

if [[ "$INSTALL" -eq 1 ]]; then
  ensure_venv
  [[ -z "$DIR" ]] && exit 0
fi

if [[ -z "$DIR" ]]; then
  usage >&2
  exit 1
fi

mkdir -p "$CONFIG_DIR"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  ensure_venv
elif ! "$VENV_DIR/bin/python" -c "import googleapiclient, google_auth_oauthlib" 2>/dev/null; then
  ensure_venv
fi

if [[ ! -f "$CLIENT_SECRET" && "$DRY_RUN" -eq 0 ]]; then
  echo "Missing OAuth client file:"
  echo "  $CLIENT_SECRET"
  echo
  echo "Follow the one-time setup in --help, then re-run."
  echo "Your normal YouTube login is used in the browser after that file exists."
  exit 1
fi

args=(--dir "$DIR" --privacy "$PRIVACY" --client-secret "$CLIENT_SECRET" --playlist-prefix "$PLAYLIST_PREFIX")
[[ -n "$LIMIT" ]] && args+=(--limit "$LIMIT")
[[ "$DRY_RUN" -eq 1 ]] && args+=(--dry-run)
[[ -n "$ONLY" ]] && args+=(--only "$ONLY")
[[ "$CREATE_PLAYLISTS_ONLY" -eq 1 ]] && args+=(--create-playlists-only)
[[ "$NO_PLAYLISTS" -eq 1 ]] && args+=(--no-playlists)
args+=("${EXTRA[@]}")

exec "$VENV_DIR/bin/python" "$UPLOADER" "${args[@]}"
