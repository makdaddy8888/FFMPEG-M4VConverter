#!/usr/bin/env bash
# launch-metadata-editor.sh — open terminal + local metadata web UI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START="$SCRIPT_DIR/start-metadata-editor.sh"

run() {
  echo
  echo "  Camcorder Metadata Desk"
  echo "  ======================="
  echo "  Browser UI for thumbnails + metadata edits."
  echo "  Saves JSON sidecars and MP4 tags (no re-encode)."
  echo
  chmod +x "$START" 2>/dev/null || true
  "$START" "$@"
}

if [[ -t 0 && -t 1 ]]; then
  run "$@"
  exit $?
fi

if command -v xdg-terminal-exec >/dev/null 2>&1; then
  exec xdg-terminal-exec --title="Camcorder Metadata Desk" --hold -- \
    "$SCRIPT_DIR/launch-metadata-editor.sh" "$@"
fi

if command -v x-terminal-emulator >/dev/null 2>&1; then
  exec x-terminal-emulator -e bash -lc \
    "$(printf '%q ' "$SCRIPT_DIR/launch-metadata-editor.sh" "$@"); echo; read -r -p 'Press Enter to close… '"
fi

run "$@"
