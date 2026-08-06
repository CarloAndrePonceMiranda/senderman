#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
service_name="senderman-ftp-admin"
cd "$repo_root"

normalize_choice() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

read_choice() {
  local prompt="$1"
  local reply
  read -r -p "$prompt" reply
  normalize_choice "$reply"
}

service_is_installed() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}\.service"
}

start_service() {
  if systemctl is-active --quiet "$service_name"; then
    echo "El servicio ya está activo."
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
    echo "El servicio ya está detenido."
    return 0
  fi

  if command -v pkexec >/dev/null 2>&1; then
    pkexec /usr/bin/systemctl stop "$service_name"
  else
    sudo /usr/bin/systemctl stop "$service_name"
  fi
}

restart_service() {
  if command -v pkexec >/dev/null 2>&1; then
    pkexec /usr/bin/systemctl restart "$service_name"
  else
    sudo /usr/bin/systemctl restart "$service_name"
  fi
}

status_service() {
  systemctl status "$service_name" --no-pager
}

enable_service() {
  if command -v pkexec >/dev/null 2>&1; then
    pkexec /usr/bin/systemctl enable "$service_name"
  else
    sudo /usr/bin/systemctl enable "$service_name"
  fi
}

disable_service() {
  if command -v pkexec >/dev/null 2>&1; then
    pkexec /usr/bin/systemctl disable "$service_name"
  else
    sudo /usr/bin/systemctl disable "$service_name"
  fi
}

shutdown_machine() {
  if command -v pkexec >/dev/null 2>&1; then
    pkexec /usr/bin/bash -lc "/usr/bin/systemctl stop $service_name && /usr/bin/systemctl poweroff"
  else
    sudo /usr/bin/systemctl stop "$service_name"
    sudo /usr/bin/systemctl poweroff
  fi
}

pause_shell() {
  echo
  read -r -p "Pulsa Enter para continuar..." _
}

shell_menu() {
  while true; do
    echo
    echo "== Senderman Shell =="
    echo "1) Iniciar servicio"
    echo "2) Detener servicio"
    echo "3) Reiniciar servicio"
    echo "4) Ver estado"
    echo "5) Habilitar al arranque"
    echo "6) Deshabilitar al arranque"
    echo "7) Apagar equipo"
    echo "0) Salir"
    choice="$(read_choice "Escribe iniciar, detener, reiniciar, estado, habilitar, deshabilitar, apagar o salir: ")"

    case "$choice" in
      1|iniciar|start)
        if service_is_installed; then
          start_service
        else
          echo "El servicio no está instalado."
        fi
        pause_shell
        ;;
      2|detener|stop)
        if service_is_installed; then
          stop_service
        else
          echo "El servicio no está instalado."
        fi
        pause_shell
        ;;
      3|reiniciar|restart)
        if service_is_installed; then
          restart_service
        else
          echo "El servicio no está instalado."
        fi
        pause_shell
        ;;
      4|estado|status)
        if service_is_installed; then
          status_service
        else
          echo "El servicio no está instalado."
        fi
        pause_shell
        ;;
      5|habilitar|enable)
        if service_is_installed; then
          enable_service
        else
          echo "El servicio no está instalado."
        fi
        pause_shell
        ;;
      6|deshabilitar|disable)
        if service_is_installed; then
          disable_service
        else
          echo "El servicio no está instalado."
        fi
        pause_shell
        ;;
      7|apagar|shutdown)
        if service_is_installed; then
          shutdown_machine
        else
          echo "El servicio no está instalado."
        fi
        pause_shell
        ;;
      0|salir|exit|volver)
        exit 0
        ;;
      *)
        echo "Opción inválida."
        ;;
    esac
  done
}

shell_menu
