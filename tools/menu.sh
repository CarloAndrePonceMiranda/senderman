#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
service_name="senderman-ftp-admin"
cd "$repo_root"

selected_release_args=()
selected_service_args=()

normalize_choice() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

read_choice() {
  local prompt="$1"
  local reply
  read -r -p "$prompt" reply
  normalize_choice "$reply"
}

pause_menu() {
  echo
  read -r -p "Pulsa Enter para volver al menú..." _
}

is_installed() {
  if [ -f .senderman-release ] || [ -d .venv ]; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}\.service"; then
      return 0
    fi
  fi

  return 1
}

current_profile() {
  if [ -f client.env ] && [ -f .env ]; then
    echo "both"
  elif [ -f client.env ]; then
    echo "client"
  elif [ -f .env ] || [ -d .venv ]; then
    echo "server"
  else
    echo "server"
  fi
}

service_installed() {
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi

  systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}\.service"
}

current_release_tag() {
  if [ -f .senderman-release ]; then
    tr -d '\n' < .senderman-release
  fi
}

run_installer() {
  echo
  echo "Ejecutando: bash install.sh $*"
  bash "$repo_root/install.sh" "$@"
}

choose_release_args() {
  selected_release_args=()

  while true; do
    echo
    echo "Selección de release:"
    echo "1) Release publicada más reciente"
    echo "2) Elegir entre releases publicadas"
    echo "3) Escribir un tag concreto"
    echo "0) Volver"
    choice="$(read_choice "Escribe latest, choose, tag o volver: ")"

    case "$choice" in
      1|latest|latest-release|recent|reciente)
        selected_release_args=(--latest-release)
        return 0
        ;;
      2|choose|selector|elegir)
        selected_release_args=(--choose-release)
        return 0
        ;;
      3|tag|release)
        read -r -p "Tag de la release: " tag
        if [ -z "$tag" ]; then
          echo "No se indicó ningún tag."
          continue
        fi
        selected_release_args=(--release "$tag")
        return 0
        ;;
      0|volver|salir|exit)
        return 1
        ;;
      *)
        echo "Opción inválida."
        ;;
    esac
  done
}

choose_service_args_for_install() {
  selected_service_args=()

  if [ "$1" = "client" ]; then
    return 0
  fi

  choice="$(read_choice "¿Instalar como servicio systemd? [si/no]: ")"
  if [[ "$choice" =~ ^(si|s|y|yes)$ ]]; then
    selected_service_args=(--service)
  fi
}

choose_service_args_for_update() {
  selected_service_args=()

  if [ "$1" = "client" ]; then
    return 0
  fi

  if service_installed; then
    selected_service_args=(--service)
  fi
}

install_flow() {
  local profile=""

  while true; do
    echo
    echo "Instalación:"
    echo "1) Servidor"
    echo "2) Cliente"
    echo "3) Ambos"
    echo "0) Volver"
    choice="$(read_choice "Escribe servidor, cliente, ambos o volver: ")"

    case "$choice" in
      1|server|servidor)
        profile="server"
        ;;
      2|client|cliente)
        profile="client"
        ;;
      3|both|ambos)
        profile="both"
        ;;
      0|volver|salir|exit)
        return 0
        ;;
      *)
        echo "Opción inválida."
        continue
        ;;
    esac

    if ! choose_release_args; then
      continue
    fi

    choose_service_args_for_install "$profile"

    if run_installer "${selected_service_args[@]}" "${selected_release_args[@]}" "--${profile}"; then
      echo
      echo "Instalación completada."
    else
      echo
      echo "La instalación falló."
    fi
    pause_menu
    exit 0
  done
}

update_flow() {
  local profile
  profile="$(current_profile)"

  while true; do
    echo
    echo "Actualización:"
    echo "1) Release publicada más reciente"
    echo "2) Elegir entre releases publicadas"
    echo "3) Escribir un tag concreto"
    echo "0) Volver"
    choice="$(read_choice "Escribe actualizar, latest, choose, tag o volver: ")"

    case "$choice" in
      1|latest|actualizar|update)
        selected_release_args=(--latest-release)
        ;;
      2|choose|elegir)
        selected_release_args=(--choose-release)
        ;;
      3|tag)
        read -r -p "Tag de la release: " tag
        if [ -z "$tag" ]; then
          echo "No se indicó ningún tag."
          continue
        fi
        selected_release_args=(--release "$tag")
        ;;
      0|volver|salir|exit)
        return 0
        ;;
      *)
        echo "Opción inválida."
        continue
        ;;
    esac

    choose_service_args_for_update "$profile"

    if run_installer "${selected_service_args[@]}" "${selected_release_args[@]}" "--${profile}"; then
      echo
      echo "Actualización completada."
    else
      echo
      echo "La actualización falló."
    fi
    pause_menu
    exit 0
  done
}

reinstall_flow() {
  local profile
  local release_tag
  profile="$(current_profile)"
  release_tag="$(current_release_tag || true)"

  while true; do
    echo
    echo "Reinstalación:"
    if [ -n "$release_tag" ]; then
      echo "1) Reinstalar la release actual ($release_tag)"
    else
      echo "1) Reinstalar la release actual"
    fi
    echo "2) Reinstalar la release publicada más reciente"
    echo "3) Elegir entre releases publicadas"
    echo "4) Escribir un tag concreto"
    echo "0) Volver"
    choice="$(read_choice "Escribe actual, latest, choose, tag o volver: ")"

    case "$choice" in
      1|actual|actualizar|current|current-release)
        if [ -z "$release_tag" ]; then
          echo "No hay una release marcada en .senderman-release."
          continue
        fi
        selected_release_args=(--release "$release_tag")
        ;;
      2|latest|reciente)
        selected_release_args=(--latest-release)
        ;;
      3|choose|elegir)
        selected_release_args=(--choose-release)
        ;;
      4|tag)
        read -r -p "Tag de la release: " tag
        if [ -z "$tag" ]; then
          echo "No se indicó ningún tag."
          continue
        fi
        selected_release_args=(--release "$tag")
        ;;
      0|volver|salir|exit)
        return 0
        ;;
      *)
        echo "Opción inválida."
        continue
        ;;
    esac

    choose_service_args_for_update "$profile"

    if run_installer "${selected_service_args[@]}" "${selected_release_args[@]}" "--${profile}"; then
      echo
      echo "Reinstalación completada."
    else
      echo
      echo "La reinstalación falló."
    fi
    pause_menu
    exit 0
  done
}

uninstall_flow() {
  while true; do
    echo
    echo "Desinstalación:"
    echo "1) Desinstalación completa"
    echo "2) Desinstalar pero mantener configuración"
    echo "0) Volver"
    choice="$(read_choice "Escribe completa, conservar o volver: ")"

    case "$choice" in
      1|completa|full|total)
        if run_installer --uninstall; then
          echo
          echo "Desinstalación completada."
        else
          echo
          echo "La desinstalación falló."
        fi
        pause_menu
        exit 0
        ;;
      2|conservar|keep|config)
        if run_installer --uninstall --keep-config; then
          echo
          echo "Desinstalación completada y configuración conservada."
        else
          echo
          echo "La desinstalación falló."
        fi
        pause_menu
        exit 0
        ;;
      0|volver|salir|exit)
        return 0
        ;;
      *)
        echo "Opción inválida."
        ;;
    esac
  done
}

installed_menu() {
  while true; do
    echo
    echo "== Senderman FTP Admin =="
    echo "Estado: instalado"
    echo "1) Actualizar"
    echo "2) Reinstalar"
    echo "3) Desinstalar"
    echo "0) Salir"
    choice="$(read_choice "Escribe actualizar, reinstalar, desinstalar o salir: ")"

    case "$choice" in
      1|actualizar|update)
        update_flow
        ;;
      2|reinstalar|install|reinstall)
        reinstall_flow
        ;;
      3|desinstalar|uninstall|remove)
        uninstall_flow
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

not_installed_menu() {
  while true; do
    echo
    echo "== Senderman FTP Admin =="
    echo "Estado: no instalado"
    echo "1) Instalar"
    echo "0) Salir"
    choice="$(read_choice "Escribe instalar o salir: ")"

    case "$choice" in
      1|instalar|install)
        install_flow
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

main() {
  echo "== Menú interactivo de Senderman FTP Admin =="

  if is_installed; then
    installed_menu
  else
    not_installed_menu
  fi
}

main
