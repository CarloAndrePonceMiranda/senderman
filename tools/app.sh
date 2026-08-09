#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
panel_url="http://127.0.0.1:8080/?v=20260809"
window_class="SendermanAPP"

python_bin() {
  if [ -x "$repo_root/.venv/bin/python" ]; then
    printf '%s' "$repo_root/.venv/bin/python"
    return 0
  fi

  if [ -x "/home/mr-robot/ftp-admin/.venv/bin/python" ]; then
    printf '%s' "/home/mr-robot/ftp-admin/.venv/bin/python"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi

  return 1
}

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

  local python_path
  python_path="$(python_bin || true)"

  if [ -z "$python_path" ] || [ ! -f "$repo_root/main.py" ]; then
    return 0
  fi

  nohup "$python_path" "$repo_root/main.py" > "$repo_root/panel.log" 2>&1 &

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

  for browser in chromium chromium-browser google-chrome google-chrome-stable brave-browser; do
    if command -v "$browser" >/dev/null 2>&1; then
      exec "$browser" --new-window --app="$panel_url" --class="$window_class"
    fi
  done

  if command -v xdg-open >/dev/null 2>&1; then
    exec xdg-open "$panel_url"
  fi

  echo "error: no se encontró un navegador compatible" >&2
  exit 1
}

open_browser
