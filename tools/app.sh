#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
panel_url="http://127.0.0.1:8080"
browser_profile_dir="$repo_root/.senderman-browser-profile"
window_class="SendermanAPP"

panel_is_ready() {
  python3 - <<'PY' >/dev/null 2>&1
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.5)
try:
    sock.connect(("127.0.0.1", 8080))
except OSError:
    raise SystemExit(1)
finally:
    sock.close()
PY
}

start_panel_if_needed() {
  if panel_is_ready; then
    return 0
  fi

  if [ ! -x "$repo_root/.venv/bin/python" ] || [ ! -f "$repo_root/main.py" ]; then
    return 0
  fi

  nohup "$repo_root/.venv/bin/python" "$repo_root/main.py" > "$repo_root/panel.log" 2>&1 &

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if panel_is_ready; then
      return 0
    fi
    sleep 1
  done
}

start_panel_if_needed

open_browser() {
  local browser

  mkdir -p "$browser_profile_dir"

  for browser in firefox chromium chromium-browser google-chrome google-chrome-stable brave-browser; do
    if command -v "$browser" >/dev/null 2>&1; then
      case "$browser" in
        firefox)
          exec "$browser" --new-instance --profile "$browser_profile_dir" --new-window --kiosk "$panel_url"
          ;;
        chromium|chromium-browser|google-chrome|google-chrome-stable|brave-browser)
          exec "$browser" --user-data-dir="$browser_profile_dir" --new-window --app="$panel_url" --class="$window_class"
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
