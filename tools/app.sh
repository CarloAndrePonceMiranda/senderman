#!/usr/bin/env bash
set -euo pipefail

panel_url="http://localhost:8080"

open_browser() {
  local browser

  for browser in firefox chromium chromium-browser google-chrome google-chrome-stable brave-browser; do
    if command -v "$browser" >/dev/null 2>&1; then
      case "$browser" in
        firefox)
          exec "$browser" --new-window --kiosk "$panel_url"
          ;;
        chromium|chromium-browser|google-chrome|google-chrome-stable|brave-browser)
          exec "$browser" --new-window --start-fullscreen "$panel_url"
          ;;
      esac
    fi
  done

  if command -v xdg-open >/dev/null 2>&1; then
    exec xdg-open "$panel_url"
  fi

  echo "error: no se encontró un navegador compatible" >&2
  exit 1
}

open_browser
