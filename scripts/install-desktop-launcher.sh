#!/usr/bin/env bash
# install-desktop-launcher.sh — install double-click Desktop + Apps menu launchers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_DIR="${XDG_DESKTOP_DIR:-$HOME/Desktop}"

mkdir -p "$APPS_DIR"
[[ -d "$DESKTOP_DIR" ]] && mkdir -p "$DESKTOP_DIR" || true

chmod +x \
  "$SCRIPT_DIR/launch-sd-card-ingest.sh" \
  "$SCRIPT_DIR/launch-metadata-editor.sh" \
  "$SCRIPT_DIR/start-sd-card-ingest.sh" \
  "$SCRIPT_DIR/start-metadata-editor.sh" \
  "$SCRIPT_DIR/convert-mts-to-compact.sh" \
  2>/dev/null || true

install_one() {
  local template="$1" launch="$2" app_name="$3" label="$4"
  if [[ ! -f "$template" ]]; then
    echo "Missing template: $template" >&2
    return 1
  fi
  if [[ ! -f "$launch" ]]; then
    echo "Missing launcher script: $launch" >&2
    return 1
  fi

  render() {
    local dest="$1"
    sed \
      -e "s|PLACEHOLDER_LAUNCH|$launch|g" \
      -e "s|PLACEHOLDER_REPO|$REPO_DIR|g" \
      "$template" > "$dest"
    chmod +x "$dest"
  }

  render "$APPS_DIR/$app_name"
  echo "Installed Apps menu entry ($label):"
  echo "  $APPS_DIR/$app_name"

  if [[ -d "$DESKTOP_DIR" ]] && [[ -w "$DESKTOP_DIR" ]]; then
    render "$DESKTOP_DIR/$app_name"
    if command -v gio >/dev/null 2>&1; then
      gio set "$DESKTOP_DIR/$app_name" metadata::trusted true 2>/dev/null || true
    fi
    echo "Installed Desktop shortcut ($label):"
    echo "  $DESKTOP_DIR/$app_name"
  fi
}

install_one \
  "$REPO_DIR/launchers/Camcorder-SD-Ingest.desktop" \
  "$SCRIPT_DIR/launch-sd-card-ingest.sh" \
  "Camcorder-SD-Ingest.desktop" \
  "SD Ingest"

install_one \
  "$REPO_DIR/launchers/Camcorder-Metadata-Desk.desktop" \
  "$SCRIPT_DIR/launch-metadata-editor.sh" \
  "Camcorder-Metadata-Desk.desktop" \
  "Metadata Desk"

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APPS_DIR" 2>/dev/null || true
fi

echo
echo "Done. Desktop / Apps menu:"
echo "  • Camcorder SD Ingest"
echo "  • Camcorder Metadata Desk"
echo
echo "First time on Ubuntu: right-click → Allow Launching if prompted."
