#!/usr/bin/env bash
set -euo pipefail

service_name="senderman-ftp-admin"
panel_url="http://localhost:8080"

start_service() {
  if systemctl is-active --quiet "$service_name"; then
    return 0
  fi

  if command -v pkexec >/dev/null 2>&1; then
    pkexec /usr/bin/systemctl start "$service_name"
  else
    sudo /usr/bin/systemctl start "$service_name"
  fi
}

stop_service() {
  if ! systemctl is-active --quiet "$service_name"; then
    return 0
  fi

  if command -v pkexec >/dev/null 2>&1; then
    pkexec /usr/bin/systemctl stop "$service_name"
  else
    sudo /usr/bin/systemctl stop "$service_name"
  fi
}

shutdown_machine() {
  if command -v pkexec >/dev/null 2>&1; then
    pkexec /usr/bin/bash -lc "/usr/bin/systemctl stop senderman-ftp-admin && /usr/bin/systemctl poweroff"
  else
    sudo /usr/bin/systemctl stop "$service_name"
    sudo /usr/bin/systemctl poweroff
  fi
}

open_panel() {
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$panel_url" >/dev/null 2>&1 || true
  fi
}

case "${1:-start}" in
  start)
    start_service
    open_panel
    ;;
  stop)
    stop_service
    ;;
  restart)
    if command -v pkexec >/dev/null 2>&1; then
      pkexec /usr/bin/systemctl restart "$service_name"
    else
      sudo /usr/bin/systemctl restart "$service_name"
    fi
    ;;
  status)
    systemctl status "$service_name" --no-pager
    ;;
  shutdown)
    shutdown_machine
    ;;
  *)
    echo "Uso: $0 [start|stop|restart|status|shutdown]" >&2
    exit 1
    ;;
esac