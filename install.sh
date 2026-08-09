#!/usr/bin/env bash
set -euo pipefail

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$source_root"
install_root="${SENDERMAN_INSTALL_ROOT:-/opt/senderman-ftp-admin}"
install_marker_file="$install_root/.senderman-installed"
cd "$repo_root"

service_name="senderman-ftp-admin"
service_user="mr-robot"
sftp_group="senderman-sftp"
sftp_root_dir="/srv/senderman-sftp"
sftp_upload_dirname="upload"
sftp_dropin_dir="/etc/ssh/sshd_config.d"
sftp_dropin_file="$sftp_dropin_dir/99-senderman-sftp.conf"
install_service=false
force_overwrite=false
release_mode="latest"
release_selector=""
install_profile=""
uninstall_keep_config=false
reset_secrets=false

usage() {
  cat <<'EOF'
Uso: bash install.sh [--service] [--force] [--latest-release] [--release <release>] [--choose-release] [--server|--uninstall]
Usage: bash install.sh [--service] [--force] [--latest-release] [--release <release>] [--choose-release] [--server|--uninstall] [--reset-secrets]

  --service         Instala y habilita el servicio systemd
  --force           Sobrescribe .env si ya existe
  --latest-release  Instala la release publicada más reciente (por defecto)
  --release <release> Instala una release publicada concreta
  --choose-release  Muestra una lista de releases publicadas y deja elegir una
  --server          Instala el panel/servidor FTP
  --uninstall       Desinstala la aplicación y limpia accesos directos, venv y servicio
  --keep-config     Con --uninstall, conserva .env y el registro local
  --reset-secrets   Con --server, vuelve a pedir ADMIN_PASS aunque ya exista
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service)
      install_service=true
      shift
      ;;
    --force)
      force_overwrite=true
      shift
      ;;
    --latest-release)
      release_mode="latest"
      release_selector=""
      shift
      ;;
    --release)
      if [[ $# -lt 2 ]]; then
        echo "error: falta la release para --release"
        usage
        exit 1
      fi
      release_mode="exact"
      release_selector="$2"
      shift 2
      ;;
    --release=*)
      release_mode="exact"
      release_selector="${1#*=}"
      shift
      ;;
    --choose-release)
      release_mode="choose"
      release_selector=""
      shift
      ;;
    --server|--servidor)
      install_profile="server"
      shift
      ;;
    --uninstall|--desinstalar)
      install_profile="uninstall"
      shift
      ;;
    --keep-config|--preserve-config)
      uninstall_keep_config=true
      shift
      ;;
    --reset-secrets)
      reset_secrets=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: argumento desconocido: $1"
      usage
      exit 1
      ;;
  esac
done

prompt_confirm() {
  local message="$1"
  local reply
  read -r -p "$message [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

sync_install_root() {
  if [ ! -d "$install_root" ] || [ ! -w "$install_root" ]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "error: sudo es necesario para instalar en $install_root"
      exit 1
    fi
    sudo install -d -m 0755 -o "$service_user" -g "$service_user" "$install_root"
    sudo chown -R "$service_user:$service_user" "$install_root"
  fi

  if [ "$source_root" != "$install_root" ]; then
    python3 - "$source_root" "$install_root" <<'PY'
from pathlib import Path
import shutil
import sys

source_root = Path(sys.argv[1])
install_root = Path(sys.argv[2])
keep = {".git", ".venv", ".env", "panel.log", "users.json", "senderman_registry.sqlite3", "backups", "local-tools", ".senderman-release"}

for path in source_root.rglob("*"):
    relative_path = path.relative_to(source_root)
    if relative_path.parts and relative_path.parts[0] in keep:
      continue

    destination = install_root / relative_path
    if path.is_dir():
      destination.mkdir(parents=True, exist_ok=True)
    else:
      destination.parent.mkdir(parents=True, exist_ok=True)
      shutil.copy2(path, destination)

files_source = source_root / "files"
files_destination = install_root / "files"
if files_source.exists() and not files_destination.exists():
  shutil.copytree(files_source, files_destination)
PY
  fi
  repo_root="$install_root"
  cd "$repo_root"
}

detect_ssh_service_name() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
      echo "ssh"
      return 0
    fi
    if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
      echo "sshd"
      return 0
    fi
  fi
  echo "ssh"
}

sync_sftp_group_membership() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Aviso: sudo no está disponible; no se pudo sincronizar el grupo SFTP."
    return 0
  fi

  python3 - "$repo_root" "$sftp_group" <<'PY'
from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
group_name = sys.argv[2]
users: set[str] = set()

db_path = repo_root / "senderman_registry.sqlite3"
if db_path.exists():
    try:
        conn = sqlite3.connect(db_path)
        try:
            rows = conn.execute("SELECT username FROM user_registry").fetchall()
            users.update(str(row[0]).strip() for row in rows if str(row[0]).strip())
        finally:
            conn.close()
    except Exception:
        pass

legacy_json = repo_root / "users.json"
if legacy_json.exists():
    try:
        raw = json.loads(legacy_json.read_text())
        if isinstance(raw, list):
            for item in raw:
                if isinstance(item, dict):
                    username = str(item.get("username", "")).strip()
                    if username:
                        users.add(username)
    except Exception:
        pass

for username in sorted(users):
    if subprocess.run(["id", "-u", username], capture_output=True, text=True).returncode != 0:
        continue
    subprocess.run(["sudo", "usermod", "-g", group_name, username], check=False)
PY
}

ensure_sftp_user_jail() {
  local username="$1"
  local jail_root="$sftp_root_dir/$username"
  local upload_dir="$jail_root/$sftp_upload_dirname"
  local ssh_dir="$jail_root/.ssh"

  if ! id -u "$username" >/dev/null 2>&1; then
    return 0
  fi

  sudo install -d -m 0755 -o root -g root "$sftp_root_dir"
  sudo install -d -m 0755 -o root -g root "$jail_root"
  sudo install -d -m 0750 -o "$username" -g "$sftp_group" "$upload_dir"
  sudo install -d -m 0700 -o root -g root "$ssh_dir"
}

sync_sftp_jails() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "Aviso: sudo no está disponible; no se pudieron sincronizar los jails SFTP."
    return 0
  fi

  python3 - "$repo_root" <<'PY' | while IFS= read -r username; do
from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

repo_root = Path(sys.argv[1])
users: set[str] = set()

db_path = repo_root / "senderman_registry.sqlite3"
if db_path.exists():
    try:
        conn = sqlite3.connect(db_path)
        try:
            rows = conn.execute("SELECT username FROM user_registry").fetchall()
            users.update(str(row[0]).strip() for row in rows if str(row[0]).strip())
        finally:
            conn.close()
    except Exception:
        pass

legacy_json = repo_root / "users.json"
if legacy_json.exists():
    try:
        raw = json.loads(legacy_json.read_text())
        if isinstance(raw, list):
            for item in raw:
                if isinstance(item, dict):
                    username = str(item.get("username", "")).strip()
                    if username:
                        users.add(username)
    except Exception:
        pass

for username in sorted(users):
    print(username)
PY
    ensure_sftp_user_jail "$username"
  done
}

install_sftp_daemon_config() {
  local ssh_service

  if ! command -v sudo >/dev/null 2>&1; then
    echo "Aviso: sudo no está disponible; no se pudo configurar sshd para SFTP."
    return 0
  fi

  ssh_service="$(detect_ssh_service_name)"
  sudo groupadd -f "$sftp_group"
  sudo install -d -m 0755 "$sftp_dropin_dir"

  cat <<EOF | sudo tee "$sftp_dropin_file" >/dev/null
# Managed by Senderman
Match Group $sftp_group
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    PermitTTY no
    AllowTcpForwarding no
    X11Forwarding no
    ChrootDirectory $sftp_root_dir/%u
    ForceCommand internal-sftp -d /$sftp_upload_dirname
EOF

  sudo chmod 644 "$sftp_dropin_file"

  if command -v sshd >/dev/null 2>&1; then
    if ! sudo sshd -t; then
      echo "error: la configuración de sshd no pasó la validación"
      exit 1
    fi
  fi

  sudo systemctl try-restart "$ssh_service" >/dev/null 2>&1 || true
  sync_sftp_group_membership
  sync_sftp_jails
  echo "Se configuró sshd para SFTP por clave en $sftp_dropin_file."
}

remove_sftp_daemon_config() {
  if ! command -v sudo >/dev/null 2>&1; then
    return 0
  fi

  sudo rm -f "$sftp_dropin_file"
  sudo rm -rf "$sftp_root_dir"
  if command -v sshd >/dev/null 2>&1; then
    sudo sshd -t >/dev/null 2>&1 || true
  fi
  sudo systemctl try-restart "$(detect_ssh_service_name)" >/dev/null 2>&1 || true
}

is_installed() {
  if [ -f "$install_marker_file" ]; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}\.service"; then
      return 0
    fi
  fi

  return 1
}

service_is_installed() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^${service_name}\.service"; then
      return 0
    fi
  fi

  return 1
}

current_release_tag() {
  if [ -f "$install_root/.senderman-release" ]; then
    tr -d '\n' < "$install_root/.senderman-release"
  fi
}

menu_header() {
  local title="$1"
  local subtitle="${2:-}"

  printf '\033[36m====================================================================\033[0m\n'
  printf '\033[1;32m%s\033[0m\n' "$title"
  if [ -n "$subtitle" ]; then
    printf '\033[0;37m%s\033[0m\n' "$subtitle"
  fi
  printf '\033[36m====================================================================\033[0m\n'
}

menu_prompt() {
  local prompt="$1"
  local reply
  read -r -p "$prompt" reply
  printf '%s' "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
}

invalid_menu_feedback() {
  printf '\033[41m\033[97m\033[2J\033[H'
  printf '\n  Ingresa un comando válido\n\n'
  printf '  Presiona Enter para continuar...'
  read -r _
  printf '\033[0m'
}

run_installer_command() {
  env SENDERMAN_INSTALLER_NO_MENU=1 bash "$repo_root/install.sh" "$@"
}

installer_logs() {
  menu_header "Senderman installer" "Logs"

  if service_is_installed && command -v journalctl >/dev/null 2>&1; then
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
      journalctl -u "$service_name" --no-pager -n 80
    elif command -v sudo >/dev/null 2>&1; then
      sudo journalctl -u "$service_name" --no-pager -n 80
    else
      echo "No hay permisos para consultar journalctl."
    fi
  elif [ -f panel.log ]; then
    tail -n 80 panel.log
  else
    echo "No hay logs disponibles todavía."
  fi

  echo
  read -r -p "Pulsa Enter para volver..." _
}

launch_installer_menu() {
  while true; do
    clear || true
    if is_installed; then
      menu_header "Senderman installer" "Estado: instalado"
      echo "reinstall - Reinstalar"
      echo "update - Actualizar"
      echo "logs - Ver logs"
      echo "uninstall - Desinstalar"
      echo "exit - Salir"
      choice="$(menu_prompt "Escribe un comando: ")"

      case "$choice" in
        reinstall)
          local release_tag
          local args=()
          release_tag="$(current_release_tag || true)"

          if [ -n "$release_tag" ]; then
            args=(--release "$release_tag")
          else
            args=(--latest-release)
          fi

          if service_is_installed; then
            args=(--service "${args[@]}")
          fi

          env SENDERMAN_INSTALLER_NO_MENU=1 bash "$repo_root/install.sh" "${args[@]}" --server --reset-secrets
          read -r -p "Pulsa Enter para continuar..." _
          ;;
        update)
          local args=(--latest-release)
          if service_is_installed; then
            args=(--service "${args[@]}")
          fi

          read -r -p "Elige release manualmente? [y/N]: " reply
          if [[ "$reply" =~ ^[Yy]$ ]]; then
            args=(--choose-release)
          fi

          run_installer_command "${args[@]}" --server
          read -r -p "Pulsa Enter para continuar..." _
          ;;
        logs)
          installer_logs
          ;;
        uninstall)
          read -r -p "¿Conservar configuración? [y/N]: " reply
          if [[ "$reply" =~ ^[Yy]$ ]]; then
            run_installer_command --uninstall --keep-config
          else
            run_installer_command --uninstall
          fi
          read -r -p "Pulsa Enter para continuar..." _
          ;;
        exit)
          exit 0
          ;;
        *)
          invalid_menu_feedback
          ;;
      esac
    else
      menu_header "Senderman installer" "Estado: no instalado"
      echo "install - Instalar"
      echo "exit - Salir"
      choice="$(menu_prompt "Escribe un comando: ")"

      case "$choice" in
        install)
          run_installer_command --latest-release --server
          read -r -p "Pulsa Enter para continuar..." _
          ;;
        exit)
          exit 0
          ;;
        *)
          invalid_menu_feedback
          ;;
      esac
    fi
  done
}

open_config_review() {
  local files=(".env.example" ".env")

  if command -v code >/dev/null 2>&1; then
    code --reuse-window "${files[@]}" >/dev/null 2>&1 &
    return 0
  fi

  if [ -n "${VISUAL:-${EDITOR:-}}" ] && command -v "${VISUAL:-${EDITOR:-}}" >/dev/null 2>&1; then
    "${VISUAL:-${EDITOR:-}}" "${files[@]}"
    return 0
  fi

  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open ".env.example" >/dev/null 2>&1 || true
    xdg-open ".env" >/dev/null 2>&1 || true
    return 0
  fi

  echo
  echo "No se encontró un editor gráfico. Mostrando archivos en terminal:"
  for file in "${files[@]}"; do
    echo
    echo "== $file =="
    sed -n '1,120p' "$file"
  done
}

generate_password() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
}

set_env_value() {
  local key="$1"
  local value="$2"
  python3 - "$key" "$value" <<'PY'
from pathlib import Path
import sys

key = sys.argv[1]
value = sys.argv[2]
path = Path('.env')
lines = []
replaced = False

for line in path.read_text().splitlines():
    if line.startswith(f'{key}='):
        lines.append(f'{key}={value}')
        replaced = True
    else:
        lines.append(line)

if not replaced:
    lines.append(f'{key}={value}')

path.write_text('\n'.join(lines) + '\n')
PY
}

normalize_profile() {
  case "${1:-}" in
    server|servidor|"")
      echo "server"
      ;;
    uninstall|desinstalar)
      echo "uninstall"
      ;;
    *)
      echo ""
      ;;
  esac
}

prompt_install_profile() {
  if [ "$install_profile" = "uninstall" ]; then
    return
  fi

  if [ -z "$install_profile" ] && [ ! -t 0 ]; then
    install_profile="server"
    return
  fi

  if [ -n "$install_profile" ] && [ "$install_profile" != "server" ]; then
    echo "error: modo de instalación inválido"
    exit 1
  fi
}

install_app_icon() {
  local icons_root
  local scalable_icons_dir
  local raster_icons_dir

  icons_root="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor"
  scalable_icons_dir="$icons_root/scalable/apps"
  raster_icons_dir="$icons_root/256x256/apps"

  mkdir -p "$scalable_icons_dir" "$raster_icons_dir"
  rm -f "$scalable_icons_dir/senderman-app.svg" "$scalable_icons_dir/senderman-monitor.svg" "$scalable_icons_dir/senderman-configuration.svg" "$scalable_icons_dir/senderman-ftp-admin.png" "$scalable_icons_dir/senderman-ftp-admin.svg"
  rm -f "$raster_icons_dir/senderman-app.svg" "$raster_icons_dir/senderman-monitor.svg" "$raster_icons_dir/senderman-configuration.svg" "$raster_icons_dir/senderman-ftp-admin.png" "$raster_icons_dir/senderman-ftp-admin.svg"

  cat > "$scalable_icons_dir/senderman-app.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256" role="img" aria-label="Senderman APP">
  <defs>
    <linearGradient id="appGlow" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#00ff66" stop-opacity="0.95"/>
      <stop offset="100%" stop-color="#00d9ff" stop-opacity="0.95"/>
    </linearGradient>
  </defs>
  <rect width="256" height="256" rx="44" fill="#04110d"/>
  <rect x="24" y="28" width="208" height="176" rx="28" fill="#071814" stroke="#00ff66" stroke-width="8"/>
  <rect x="44" y="50" width="168" height="132" rx="14" fill="#06130f" stroke="#123b2f" stroke-width="4"/>
  <path d="M58 66h140" fill="none" stroke="#0b3d2b" stroke-width="4" stroke-linecap="round"/>
  <path d="M72 64v108M94 58v114M116 70v102M138 60v112M160 66v106M182 60v112" fill="none" stroke="url(#appGlow)" stroke-width="8" stroke-linecap="round" opacity="0.92"/>
  <path d="M54 142h148" fill="none" stroke="#00ff66" stroke-width="6" stroke-linecap="round" opacity="0.7"/>
  <path d="M66 118h124" fill="none" stroke="#00d9ff" stroke-width="6" stroke-linecap="round" opacity="0.7"/>
  <rect x="86" y="208" width="84" height="14" rx="7" fill="#00ff66" opacity="0.85"/>
</svg>
EOF

  cat > "$scalable_icons_dir/senderman-tools.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256" role="img" aria-label="Senderman Tools">
  <defs>
    <linearGradient id="toolsGlow" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#00ff66" stop-opacity="0.95"/>
      <stop offset="100%" stop-color="#00d9ff" stop-opacity="0.95"/>
    </linearGradient>
  </defs>
  <rect width="256" height="256" rx="44" fill="#04110d"/>
  <rect x="24" y="28" width="208" height="176" rx="28" fill="#071814" stroke="#00ff66" stroke-width="8"/>
  <circle cx="128" cy="116" r="36" fill="#00ff66" opacity="0.16"/>
  <circle cx="128" cy="116" r="30" fill="none" stroke="url(#toolsGlow)" stroke-width="12"/>
  <circle cx="128" cy="116" r="14" fill="#05110e" stroke="#00d9ff" stroke-width="6"/>
  <path d="M128 66v18M128 148v18M78 116h18M160 116h18M92 80l12 12M152 140l12 12M164 80l-12 12M104 140l-12 12" stroke="#00d9ff" stroke-width="10" stroke-linecap="round"/>
  <path d="M58 70h140" fill="none" stroke="#0b3d2b" stroke-width="4" stroke-linecap="round"/>
  <rect x="88" y="208" width="80" height="14" rx="7" fill="#00ff66" opacity="0.85"/>
</svg>
EOF

  cp "$scalable_icons_dir/senderman-app.svg" "$raster_icons_dir/senderman-app.svg"
}

install_desktop_shortcuts() {
  local applications_dir
  local icons_root
  local app_icon_path
  applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  icons_root="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
  app_icon_path="$icons_root/senderman-app.svg"

  mkdir -p "$applications_dir"
  install_app_icon

  rm -f "$applications_dir/senderman-ftp-admin.desktop" "$applications_dir/senderman-ftp-admin-menu.desktop" "$applications_dir/senderman-ftp-admin-shell.desktop" "$applications_dir/senderman.desktop" "$applications_dir/senderman-app.desktop" "$applications_dir/senderman-tools.desktop" "$applications_dir/senderman-menu.desktop" "$applications_dir/sftp-menu.desktop"

  cat > "$applications_dir/senderman.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Senderman
Comment=Abre la aplicación web de Senderman
Exec=/usr/bin/bash "$repo_root/tools/app.sh"
TryExec=/usr/bin/bash
Icon=$app_icon_path
Terminal=false
Categories=Network;System;
StartupNotify=true
StartupWMClass=SendermanAPP
EOF

  chmod 644 "$applications_dir/senderman.desktop"
  echo "Se instaló el acceso directo principal en $applications_dir."
}

install_console_launchers() {
  local bin_dir="/usr/local/bin"
  local senderman_sftp_launcher="$bin_dir/senderman-sftp"

  if ! command -v sudo >/dev/null 2>&1; then
    echo "Aviso: sudo no está disponible; no se pudieron instalar los launchers de consola."
    return 0
  fi

  cat <<EOF | sudo tee "$senderman_sftp_launcher" >/dev/null
#!/usr/bin/env bash
exec bash "$repo_root/tools/shell.sh"
EOF
  sudo chmod 755 "$senderman_sftp_launcher"
  echo "Se instaló el launcher de consola en $bin_dir/senderman-sftp."
}

remove_console_launchers() {
  if ! command -v sudo >/dev/null 2>&1; then
    return 0
  fi

  sudo rm -f /usr/local/bin/senderman-sftp
}

install_sudoers_rules() {
  local sudoers_file="/etc/sudoers.d/ftp-admin"
  local ftp_user="jesus12jimmy13"

  if ! command -v sudo >/dev/null 2>&1; then
    echo "Aviso: sudo no está disponible; no se pudieron instalar las reglas sudoers."
    return 0
  fi

  cat <<EOF | sudo tee "$sudoers_file" >/dev/null
$service_user ALL=(ALL) NOPASSWD: /usr/bin/systemctl start vsftpd
$service_user ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop vsftpd
$service_user ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart vsftpd
$service_user ALL=(ALL) NOPASSWD: /usr/bin/usermod -L $ftp_user
$service_user ALL=(ALL) NOPASSWD: /usr/bin/usermod -U $ftp_user
$service_user ALL=(ALL) NOPASSWD: /usr/bin/getent shadow $ftp_user
$service_user ALL=(ALL) NOPASSWD: /usr/sbin/useradd -m -s /usr/sbin/nologin *
$service_user ALL=(ALL) /usr/sbin/chpasswd
$service_user ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/vsftpd.conf
$service_user ALL=(ALL) NOPASSWD: /usr/bin/tail -n 50 -f /var/log/vsftpd.log
$service_user ALL=(ALL) NOPASSWD: /usr/bin/tail -n 500 /var/log/vsftpd.log
EOF
  sudo chmod 440 "$sudoers_file"

  if command -v visudo >/dev/null 2>&1; then
    sudo visudo -cf "$sudoers_file" >/dev/null
  fi

  echo "Se instalaron las reglas sudoers en $sudoers_file."
}

remove_desktop_shortcuts() {
  local applications_dir
  local icons_dir
  local scalable_icons_dir
  applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
  scalable_icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"

  rm -f "$applications_dir/senderman-menu.desktop" "$applications_dir/senderman.desktop" "$applications_dir/senderman-app.desktop" "$applications_dir/senderman-tools.desktop" "$applications_dir/senderman-ftp-admin-monitor.desktop" "$applications_dir/senderman-ftp-admin-shell.desktop" "$applications_dir/senderman-ftp-admin-configuration.desktop" "$applications_dir/senderman-ftp-admin.desktop" "$applications_dir/senderman-ftp-admin-menu.desktop" "$applications_dir/sftp-menu.desktop"
  rm -f "$icons_dir/senderman-app.svg" "$icons_dir/senderman-tools.svg" "$icons_dir/senderman-monitor.svg" "$icons_dir/senderman-configuration.svg" "$icons_dir/senderman-ftp-admin.svg" "$icons_dir/senderman-ftp-admin.png" "$icons_dir/sftp-matrix.svg"
  rm -f "$scalable_icons_dir/senderman-app.svg" "$scalable_icons_dir/senderman-tools.svg" "$scalable_icons_dir/senderman-monitor.svg" "$scalable_icons_dir/senderman-configuration.svg" "$scalable_icons_dir/senderman-ftp-admin.svg" "$scalable_icons_dir/senderman-ftp-admin.png" "$scalable_icons_dir/sftp-matrix.svg"
}

uninstall_application() {
  echo "== Desinstalación de Senderman FTP Admin =="

  remove_console_launchers
  remove_desktop_shortcuts
  if ! $uninstall_keep_config; then
    remove_sftp_daemon_config
  fi

  if command -v sudo >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q '^senderman-ftp-admin\.service'; then
      sudo systemctl stop senderman-ftp-admin || true
      sudo systemctl disable senderman-ftp-admin || true
      sudo rm -f "/etc/systemd/system/$service_name.service"
      sudo systemctl daemon-reload || true
    fi
  fi

  rm -f "$install_marker_file"

  if command -v sudo >/dev/null 2>&1; then
    if $uninstall_keep_config; then
      sudo rm -rf "$install_root/.venv" "$install_root/panel.log" "$install_root/.senderman-release"
    else
      sudo rm -rf "$install_root"
    fi
  else
    rm -rf "$install_root"
  fi

  if $uninstall_keep_config; then
    rm -rf .venv .senderman-release panel.log
    echo "Se conservaron .env, senderman_registry.sqlite3 y backups."
  else
    rm -rf .venv .env .senderman-release panel.log senderman_registry.sqlite3 backups
  fi

  echo "Se eliminaron la aplicación, el servicio y los accesos directos."
}

get_repo_slug() {
  local remote_url
  remote_url="$(git remote get-url origin 2>/dev/null || true)"

  case "$remote_url" in
    https://github.com/*)
      printf '%s' "${remote_url#https://github.com/}" | sed 's/\.git$//'
      ;;
    http://github.com/*)
      printf '%s' "${remote_url#http://github.com/}" | sed 's/\.git$//'
      ;;
    git@github.com:*)
      printf '%s' "${remote_url#git@github.com:}" | sed 's/\.git$//'
      ;;
    *)
      echo "error: no se pudo resolver el repositorio GitHub desde origin: $remote_url"
      exit 1
      ;;
  esac
}

resolve_tag_info() {
  local mode="$1"
  local selector="$2"

  python3 - "$mode" "$selector" <<'PY'
from __future__ import annotations

import subprocess
import sys

mode, selector = sys.argv[1:3]


def repo_slug() -> str:
  remote_url = subprocess.run(
    ["git", "remote", "get-url", "origin"],
    check=True,
    text=True,
    capture_output=True,
  ).stdout.strip()

  prefixes = {
    "https://github.com/": "",
    "http://github.com/": "",
    "git@github.com:": "",
  }
  for prefix in prefixes:
    if remote_url.startswith(prefix):
      slug = remote_url[len(prefix) :]
      return slug[:-4] if slug.endswith(".git") else slug
  raise SystemExit(f"error: no se pudo resolver el repositorio GitHub desde origin: {remote_url}")


def git_tags() -> list[str]:
  result = subprocess.run(["git", "tag", "--sort=-creatordate"], check=True, text=True, capture_output=True)
  return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def tag_line(tag: str) -> str:
  return f"{tag}|https://github.com/{repo_slug()}/archive/refs/tags/{tag}.tar.gz|{tag}"


tags = git_tags()
if not tags:
  raise SystemExit(1)

if mode == "latest":
  print(tag_line(tags[0]))
elif mode == "exact":
  if selector not in tags:
    raise SystemExit(1)
  print(tag_line(selector))
elif mode == "choose":
  print("Tags locales disponibles:")
  for index, tag in enumerate(tags, start=1):
    print(f"{index}) {tag}")

  if not sys.stdin.isatty():
    raise SystemExit(1)

  while True:
    choice = input("Elige un tag por número o nombre: ").strip()
    if not choice:
      continue
    if choice.isdigit():
      selected_index = int(choice) - 1
      if 0 <= selected_index < len(tags):
        print(tag_line(tags[selected_index]))
        raise SystemExit(0)
      continue

    if choice in tags:
      print(tag_line(choice))
      raise SystemExit(0)
else:
  raise SystemExit(1)
PY
}

resolve_release_info() {
	local mode="$1"
	local selector="$2"

	python3 - "$mode" "$selector" <<'PY'
from __future__ import annotations

import json
import subprocess
import sys
import urllib.error
import urllib.request

mode, selector = sys.argv[1:3]


def repo_slug() -> str:
	remote_url = subprocess.run(
		["git", "remote", "get-url", "origin"],
		check=True,
		text=True,
		capture_output=True,
	).stdout.strip()

	prefixes = {
		"https://github.com/": "",
		"http://github.com/": "",
		"git@github.com:": "",
	}
	for prefix in prefixes:
		if remote_url.startswith(prefix):
			slug = remote_url[len(prefix) :]
			return slug[:-4] if slug.endswith(".git") else slug
	raise SystemExit(f"error: no se pudo resolver el repositorio GitHub desde origin: {remote_url}")


def fetch_json(url: str):
	request = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "senderman-installer"})
	with urllib.request.urlopen(request) as response:
		return json.load(response)


def git_tags() -> list[str]:
	result = subprocess.run(["git", "tag", "--sort=-creatordate"], check=True, text=True, capture_output=True)
	return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def release_line(tag: str, tarball_url: str, name: str) -> str:
	return f"{tag}|{tarball_url}|{name}"


slug = repo_slug()

try:
	if mode == "latest":
		latest = fetch_json(f"https://api.github.com/repos/{slug}/releases/latest")
		print(release_line(latest["tag_name"], latest["tarball_url"], latest.get("name") or latest["tag_name"]))
		raise SystemExit(0)

	releases = [release for release in fetch_json(f"https://api.github.com/repos/{slug}/releases?per_page=100") if not release.get("draft") and not release.get("prerelease")]

	if mode == "exact":
		for release in releases:
			if release.get("tag_name") == selector:
				print(release_line(release["tag_name"], release["tarball_url"], release.get("name") or release["tag_name"]))
				raise SystemExit(0)
		raise SystemExit(f"error: no se encontró una release publicada para {selector}")

	if mode == "choose":
		if releases:
			print("Releases publicadas disponibles:")
			for index, release in enumerate(releases, start=1):
				published_at = (release.get("published_at") or "")[:10]
				title = release.get("name") or release["tag_name"]
				print(f"{index}) {release['tag_name']} - {title} ({published_at})")

			if not sys.stdin.isatty():
				raise SystemExit("error: --choose-release requiere una terminal interactiva")

			while True:
				choice = input("Elige una release por número o tag: ").strip()
				if not choice:
					continue
				if choice.isdigit():
					selected_index = int(choice) - 1
					if 0 <= selected_index < len(releases):
						release = releases[selected_index]
						print(release_line(release["tag_name"], release["tarball_url"], release.get("name") or release["tag_name"]))
						raise SystemExit(0)
					print("Opción fuera de rango. Intenta otra vez.")
					continue

				for release in releases:
					if release.get("tag_name") == choice:
						print(release_line(release["tag_name"], release["tarball_url"], release.get("name") or release["tag_name"]))
						raise SystemExit(0)

				print("No encontré esa release. Intenta otra vez.")

		    # fall back to tags if no releases are published
		tags = git_tags()
		if not tags:
			raise SystemExit("error: no hay tags locales disponibles para compatibilidad")

		print("Tags locales disponibles:")
		for index, tag in enumerate(tags, start=1):
			print(f"{index}) {tag}")

		if not sys.stdin.isatty():
			raise SystemExit("error: --choose-release requiere una terminal interactiva")

		while True:
			choice = input("Elige un tag por número o nombre: ").strip()
			if not choice:
				continue
			if choice.isdigit():
				selected_index = int(choice) - 1
				if 0 <= selected_index < len(tags):
					tag = tags[selected_index]
					print(release_line(tag, f"https://github.com/{slug}/archive/refs/tags/{tag}.tar.gz", tag))
					raise SystemExit(0)
				print("Opción fuera de rango. Intenta otra vez.")
				continue

			if choice in tags:
				print(release_line(choice, f"https://github.com/{slug}/archive/refs/tags/{choice}.tar.gz", choice))
				raise SystemExit(0)

			print("No encontré ese tag. Intenta otra vez.")

		raise SystemExit(f"error: modo de release desconocido: {mode}")

except urllib.error.HTTPError as exc:
	if exc.code != 404:
		raise SystemExit(f"error: no se pudo consultar GitHub Releases: {exc}")

	tags = git_tags()
	if not tags:
		raise SystemExit("error: no hay tags locales disponibles para compatibilidad")

	if mode == "latest":
		tag = tags[0]
		print(release_line(tag, f"https://github.com/{slug}/archive/refs/tags/{tag}.tar.gz", tag))
	elif mode == "exact":
		if selector not in tags:
			raise SystemExit(f"error: no se encontró un tag local para {selector}")
		print(release_line(selector, f"https://github.com/{slug}/archive/refs/tags/{selector}.tar.gz", selector))
	elif mode == "choose":
		print("Tags locales disponibles:")
		for index, tag in enumerate(tags, start=1):
			print(f"{index}) {tag}")

		if not sys.stdin.isatty():
			raise SystemExit("error: --choose-release requiere una terminal interactiva")

		while True:
			choice = input("Elige un tag por número o nombre: ").strip()
			if not choice:
				continue
			if choice.isdigit():
				selected_index = int(choice) - 1
				if 0 <= selected_index < len(tags):
					tag = tags[selected_index]
					print(release_line(tag, f"https://github.com/{slug}/archive/refs/tags/{tag}.tar.gz", tag))
					raise SystemExit(0)
				print("Opción fuera de rango. Intenta otra vez.")
				continue

			if choice in tags:
				print(release_line(choice, f"https://github.com/{slug}/archive/refs/tags/{choice}.tar.gz", choice))
				raise SystemExit(0)

			print("No encontré ese tag. Intenta otra vez.")
	else:
		raise SystemExit(f"error: modo de release desconocido: {mode}")

except urllib.error.URLError as exc:
	raise SystemExit(f"error: no se pudo consultar GitHub Releases: {exc}")
PY
}

select_release_info() {
  local repo_slug="$1"
  local mode="$2"
  local selector="$3"

  python3 - "$repo_slug" "$mode" "$selector" <<'PY'
from __future__ import annotations

import json
import sys
import urllib.request

repo_slug, mode, selector = sys.argv[1:4]
headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "senderman-installer",
}


def fetch_json(url: str):
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request) as response:
        return json.load(response)


def release_line(release: dict) -> str:
    return f"{release['tag_name']}|{release['tarball_url']}|{release.get('name') or release['tag_name']}"


try:
    if mode == "latest":
        print(release_line(fetch_json(f"https://api.github.com/repos/{repo_slug}/releases/latest")))
    elif mode == "exact":
        releases = fetch_json(f"https://api.github.com/repos/{repo_slug}/releases?per_page=100")
        for release in releases:
            if release.get("draft"):
                continue

        destination = repo_root / relative_path
        if path.is_dir():
            destination.mkdir(parents=True, exist_ok=True)
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)

    for path in sorted(repo_root.rglob("*"), reverse=True):
        relative_path = path.relative_to(repo_root)
        if relative_path.parts and relative_path.parts[0] in keep:
            continue

        source_equivalent = source_root / relative_path
        if source_equivalent.exists():
            continue

        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()
PY
}

write_release_marker() {
  local release_tag="$1"
  printf '%s\n' "$release_tag" > .senderman-release
}

sync_release_tree() {
  local tarball_url="$1"

  python3 - "$tarball_url" "$repo_root" <<'PY'
from __future__ import annotations

import shutil
import subprocess
import sys
import tarfile
import tempfile
import re
import urllib.request
from pathlib import Path

tarball_url = sys.argv[1]
repo_root = Path(sys.argv[2]).resolve()
keep = {".git", ".venv", ".env", "panel.log", "users.json", "senderman_registry.sqlite3", "backups", "files", "local-tools", ".senderman-release"}

with tempfile.TemporaryDirectory() as temp_dir:
  temp_path = Path(temp_dir)
  archive_path = temp_path / "release.tar.gz"

  try:
    request = urllib.request.Request(tarball_url, headers={"User-Agent": "senderman-installer"})
    with urllib.request.urlopen(request) as response, open(archive_path, "wb") as archive_file:
      shutil.copyfileobj(response, archive_file)
  except Exception:
    match = (
      re.search(r"/tarball/([^/?#]+)$", tarball_url)
      or re.search(r"/archive/refs/tags/([^/]+)\.tar\.gz$", tarball_url)
      or re.search(r"/tags/([^/]+)\.tar\.gz$", tarball_url)
    )
    if not match:
      raise

    tag = match.group(1)
    subprocess.run(["git", "archive", "--format=tar.gz", f"--output={archive_path}", tag], check=True, cwd=repo_root)

  with tarfile.open(archive_path, "r:gz") as archive:
    archive.extractall(temp_path)

  extracted_roots = [entry for entry in temp_path.iterdir() if entry.name != archive_path.name]
  source_root = extracted_roots[0] if len(extracted_roots) == 1 and extracted_roots[0].is_dir() else temp_path

  for path in source_root.rglob("*"):
    relative_path = path.relative_to(source_root)
    if path == archive_path:
      continue
    if relative_path.parts and relative_path.parts[0] in keep:
      continue

    destination = repo_root / relative_path
    if path.is_dir():
      destination.mkdir(parents=True, exist_ok=True)
    else:
      destination.parent.mkdir(parents=True, exist_ok=True)
      shutil.copy2(path, destination)

  for path in sorted(repo_root.rglob("*"), reverse=True):
    relative_path = path.relative_to(repo_root)
    if relative_path.parts and relative_path.parts[0] in keep:
      continue

    source_equivalent = source_root / relative_path
    if source_equivalent.exists():
      continue

    if path.is_dir():
      shutil.rmtree(path)
    else:
      path.unlink()

  files_source = source_root / "files"
  files_destination = repo_root / "files"
  if files_source.exists() and not files_destination.exists():
    shutil.copytree(files_source, files_destination)
PY
}

echo "== Senderman FTP Admin secure install =="
echo "Repo: $repo_root"

if ! command -v git >/dev/null 2>&1; then
  echo "error: git no está instalado"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 no está instalado"
  exit 1
fi

prompt_install_profile

if [ "$install_profile" = "uninstall" ]; then
  uninstall_application
  exit 0
fi

sync_install_root

if [ "$install_profile" != "client" ]; then
  if ! python3 -c 'import venv' >/dev/null 2>&1; then
    echo "error: python3-venv no está instalado"
    exit 1
  fi

  if ! command -v pip3 >/dev/null 2>&1; then
    echo "error: pip3 no está instalado"
    exit 1
  fi
fi

if [ "${SENDERMAN_INSTALLER_SKIP_BOOTSTRAP:-0}" != "1" ]; then
  repo_slug="$(get_repo_slug)"
  if release_info="$(resolve_tag_info "$release_mode" "$release_selector" 2>/dev/null)"; then
    :
  else
    release_info="$(resolve_release_info "$release_mode" "$release_selector")"
  fi
  IFS='|' read -r release_tag release_tarball_url release_name <<<"$release_info"

  sync_install_root

  echo "Instalando desde la release publicada: $release_tag"
  if [ -n "$release_name" ]; then
    echo "Nombre: $release_name"
  fi

  sync_release_tree "$release_tarball_url"
  write_release_marker "$release_tag"

  exec env SENDERMAN_INSTALLER_SKIP_BOOTSTRAP=1 bash "$repo_root/install.sh" "$@"
fi

  if [ -z "$install_profile" ] && [ -t 0 ] && [ "${SENDERMAN_INSTALLER_NO_MENU:-0}" != "1" ]; then
  launch_installer_menu
  exit 0
fi

if [ ! -d .venv ]; then
  echo "Creando entorno virtual..."
  python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

pip install --upgrade pip >/dev/null
pip install -r requirements.txt

if [ -f .env ] && ! $force_overwrite; then
  echo ".env ya existe; no se sobrescribió."
else
  cp .env.example .env
  chmod 600 .env
  set_env_value "FILES_DIR" "$install_root/files"
  set_env_value "SFTP_ROOT_DIR" "$sftp_root_dir"
  echo "Se creó .env desde .env.example con permisos 600."
fi

current_admin_pass="$(grep -E '^ADMIN_PASS=' .env | head -n1 | cut -d= -f2- || true)"
admin_pass="$current_admin_pass"
if $reset_secrets; then
  echo
  read -r -p "Escribe un ADMIN_PASS nuevo o pulsa Enter para generar uno seguro: " admin_pass
  if [ -z "$admin_pass" ]; then
    admin_pass="$(generate_password)"
    echo "ADMIN_PASS generado automáticamente."
    echo "Guárdalo ahora: $admin_pass"
  fi
  set_env_value "ADMIN_PASS" "$admin_pass"
elif [ -z "$current_admin_pass" ] || [ "$current_admin_pass" = "ChangeMe123!" ]; then
  echo
  read -r -p "Escribe un ADMIN_PASS nuevo o pulsa Enter para generar uno seguro: " admin_pass
  if [ -z "$admin_pass" ]; then
    admin_pass="$(generate_password)"
    echo "ADMIN_PASS generado automáticamente."
    echo "Guárdalo ahora: $admin_pass"
  fi
  set_env_value "ADMIN_PASS" "$admin_pass"
fi

if command -v sudo >/dev/null 2>&1; then
  printf '%s:%s\n' "$service_user" "$admin_pass" | sudo chpasswd
fi

echo
echo "Revisa .env si quieres ajustar ADMIN_USER, FTP_LOG, VSFTPD_CONF o FILES_DIR."
if prompt_confirm "¿Quieres abrir una pausa para revisar .env ahora?"; then
  open_config_review
fi

if $install_service; then
  if ! command -v sudo >/dev/null 2>&1; then
    echo "error: sudo no está disponible y se pidió instalar el servicio"
    exit 1
  fi

  echo "Instalando servicio systemd..."
  cat <<EOF | sudo tee "/etc/systemd/system/$service_name.service" >/dev/null
[Unit]
Description=Senderman FTP Admin
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$install_root
EnvironmentFile=$install_root/.env
ExecStart=/usr/bin/env bash -lc 'cd $install_root && exec .venv/bin/python main.py'
Restart=on-failure
RestartSec=5
User=$service_user
Group=$service_user

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now "$service_name"
fi

install_sudoers_rules
install_sftp_daemon_config

install_desktop_shortcuts
install_console_launchers
touch "$install_marker_file"

echo
echo "Listo. Siguientes pasos:"
echo "1) Verifica .env"
if $install_service; then
  echo "2) Revisa el estado con: sudo systemctl status $service_name"
  echo "3) Abre http://localhost:8080"
else
  echo "2) Arranca el panel con: nohup .venv/bin/python main.py > panel.log 2>&1 &"
  echo "3) Abre http://localhost:8080"
fi