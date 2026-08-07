#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

normalize_choice() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

read_choice() {
  local prompt="$1"
  local reply
  read -r -p "$prompt" reply
  normalize_choice "$reply"
}

open_installer_menu() {
  exec bash "$repo_root/install.sh" "$@"
}

open_sftp_admin_menu() {
  exec bash "$repo_root/tools/shell.sh" "$@"
}

if [ $# -gt 0 ]; then
  case "$(normalize_choice "$1")" in
    installer)
      open_installer_menu "${@:2}"
      ;;
    sftpadmin|sftp-admin|sftp)
      open_sftp_admin_menu "${@:2}"
      ;;
    *)
      exec bash "$repo_root/install.sh" "$@"
      ;;
  esac
fi

while true; do
  clear || true
  printf '\033[36m====================================================================\033[0m\n'
  printf '\033[1;32mSenderman Desktop\033[0m\n'
  printf '\033[0;37mSelecciona el menú que quieres abrir\033[0m\n'
  printf '\033[36m====================================================================\033[0m\n'
  echo "installer - Instalador de programa"
  echo "sftpadmin - Administrador de servicio SFTP"
  echo "salir - Cerrar"
  choice="$(read_choice "Escribe un comando: ")"

  case "$choice" in
    installer)
      open_installer_menu
      ;;
    sftpadmin)
      open_sftp_admin_menu
      ;;
    salir|exit)
      exit 0
      ;;
    *)
      echo "Comando inválido."
      read -r -p "Pulsa Enter para continuar..." _
      ;;
  esac
done
