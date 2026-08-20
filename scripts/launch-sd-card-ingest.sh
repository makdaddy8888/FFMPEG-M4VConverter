#!/usr/bin/env bash
# launch-sd-card-ingest.sh — open a terminal and run the SD card ingest workflow.
# Used by the double-click .desktop launcher.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INGEST="$SCRIPT_DIR/start-sd-card-ingest.sh"

run_ingest() {
  echo
  echo "  Camcorder SD Card Ingest"
  echo "  ========================"
  echo "  Plug in the card (optional), then the script will:"
  echo "    • copy .MTS files to ~/Videos/CamcorderIngest/Inbox/"
  echo "    • convert them to phone-ready MP4 in iPhone/"
  echo
  echo "  Press Ctrl+C to cancel at any time."
  echo

  if [[ ! -x "$INGEST" ]]; then
    chmod +x "$INGEST" 2>/dev/null || true
  fi
  if [[ ! -f "$INGEST" ]]; then
    echo "Missing ingest script: $INGEST" >&2
    return 1
  fi

  # Interactive by default when launched from a real terminal window
  "$INGEST" "$@"
  local rc=$?
  echo
  if [[ $rc -eq 0 ]]; then
    echo "  Done. You can close this window."
  else
    echo "  Finished with errors (exit $rc). Scroll up for details."
  fi
  return "$rc"
}

# If already inside a terminal with a TTY, run directly.
# If double-clicked from the desktop/file manager, open a terminal with --hold.
if [[ -t 0 && -t 1 ]]; then
  run_ingest "$@"
  exit $?
fi

if command -v xdg-terminal-exec >/dev/null 2>&1; then
  exec xdg-terminal-exec --title="Camcorder SD Ingest" --hold -- \
    "$SCRIPT_DIR/launch-sd-card-ingest.sh" "$@"
fi

if command -v x-terminal-emulator >/dev/null 2>&1; then
  exec x-terminal-emulator -e bash -lc \
    "$(printf '%q ' "$SCRIPT_DIR/launch-sd-card-ingest.sh" "$@"); echo; read -r -p 'Press Enter to close… '"
fi

# Last resort: run without a new terminal (logs only)
run_ingest "$@"
exit $?
