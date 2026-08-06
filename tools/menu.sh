#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
service_name="senderman-ftp-admin"
cd "$repo_root"

selected_release_args=()
selected_service_args=()

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
    read -r -p "Opción: " choice

    case "$choice" in
      1)
        selected_release_args=(--latest-release)
        return 0
        ;;
      2)
        selected_release_args=(--choose-release)
        return 0
        ;;
      3)
        read -r -p "Tag de la release: " tag
        if [ -z "$tag" ]; then
          echo "No se indicó ningún tag."
          continue
        fi
        selected_release_args=(--release "$tag")
        return 0
        ;;
      0)
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

  read -r -p "¿Instalar como servicio systemd? [y/N]: " reply
  if [[ "$reply" =~ ^[Yy]$ ]]; then
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
    read -r -p "Opción: " choice

    case "$choice" in
      1)
        profile="server"
        ;;
      2)
        profile="client"
        ;;
      3)
        profile="both"
        ;;
      0)
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
    return 0
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
    read -r -p "Opción: " choice

    case "$choice" in
      1)
        selected_release_args=(--latest-release)
        ;;
      2)
        selected_release_args=(--choose-release)
        ;;
      3)
        read -r -p "Tag de la release: " tag
        if [ -z "$tag" ]; then
          echo "No se indicó ningún tag."
          continue
        fi
        selected_release_args=(--release "$tag")
        ;;
      0)
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
    return 0
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
    read -r -p "Opción: " choice

    case "$choice" in
      1)
        if [ -z "$release_tag" ]; then
          echo "No hay una release marcada en .senderman-release."
          continue
        fi
        selected_release_args=(--release "$release_tag")
        ;;
      2)
        selected_release_args=(--latest-release)
        ;;
      3)
        selected_release_args=(--choose-release)
        ;;
      4)
        read -r -p "Tag de la release: " tag
        if [ -z "$tag" ]; then
          echo "No se indicó ningún tag."
          continue
        fi
        selected_release_args=(--release "$tag")
        ;;
      0)
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
    return 0
  done
}

uninstall_flow() {
  while true; do
    echo
    echo "Desinstalación:"
    echo "1) Desinstalación completa"
    echo "2) Desinstalar pero mantener configuración"
    echo "0) Volver"
    read -r -p "Opción: " choice

    case "$choice" in
      1)
        if run_installer --uninstall; then
          echo
          echo "Desinstalación completada."
        else
          echo
          echo "La desinstalación falló."
        fi
        pause_menu
        return 0
        ;;
      2)
        if run_installer --uninstall --keep-config; then
          echo
          echo "Desinstalación completada y configuración conservada."
        else
          echo
          echo "La desinstalación falló."
        fi
        pause_menu
        return 0
        ;;
      0)
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
    read -r -p "Opción: " choice

    case "$choice" in
      1)
        update_flow
        ;;
      2)
        reinstall_flow
        ;;
      3)
        uninstall_flow
        ;;
      0)
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
    read -r -p "Opción: " choice

    case "$choice" in
      1)
        install_flow
        ;;
      0)
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
