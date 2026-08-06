#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

service_name="senderman-ftp-admin"
install_service=false
force_overwrite=false
release_mode="latest"
release_selector=""
install_profile=""
uninstall_keep_config=false
client_config_file="client.env"

usage() {
  cat <<'EOF'
Uso: bash install.sh [--service] [--force] [--latest-release] [--release <release>] [--choose-release] [--server|--client|--both|--uninstall]

  --service         Instala y habilita el servicio systemd
  --force           Sobrescribe .env si ya existe
  --latest-release  Instala la release publicada más reciente (por defecto)
  --release <release> Instala una release publicada concreta
  --choose-release  Muestra una lista de releases publicadas y deja elegir una
  --server          Instala el panel/servidor FTP
  --client          Instala herramientas seguras de cliente
  --both            Instala servidor y cliente
  --uninstall       Desinstala la aplicación y limpia accesos directos, venv y servicio
  --keep-config     Con --uninstall, conserva .env, client.env y el registro local
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
    --client|--cliente)
      install_profile="client"
      shift
      ;;
    --both|--ambos)
      install_profile="both"
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
    server|servidor)
      echo "server"
      ;;
    client|cliente)
      echo "client"
      ;;
    both|ambos)
      echo "both"
      ;;
    *)
      echo ""
      ;;
  esac
}

prompt_install_profile() {
  local reply

  if [ -n "$install_profile" ]; then
    if [ "$install_profile" = "uninstall" ]; then
      return
    fi
    install_profile="$(normalize_profile "$install_profile")"
    if [ -z "$install_profile" ]; then
      echo "error: modo de instalación inválido"
      exit 1
    fi
    return
  fi

  if [ ! -t 0 ]; then
    install_profile="server"
    return
  fi

  echo
  read -r -p "¿Qué deseas instalar? [servidor/cliente/ambos] (servidor): " reply
  install_profile="$(normalize_profile "${reply:-server}")"
  if [ -z "$install_profile" ]; then
    echo "error: modo de instalación inválido"
    exit 1
  fi
}

install_client_tools() {
  if ! command -v sudo >/dev/null 2>&1; then
    echo "aviso: no hay sudo disponible; instala manualmente lftp, openssh-client y ca-certificates"
    return 0
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "aviso: apt-get no está disponible; instala manualmente lftp, openssh-client y ca-certificates"
    return 0
  fi

  echo "Instalando herramientas de cliente seguro..."
  sudo apt-get update
  sudo apt-get install -y lftp openssh-client ca-certificates

  if sudo apt-get -s autoremove --purge 2>/dev/null | grep -q '^Remv\|^The following packages will be REMOVED:'; then
    echo
    if prompt_confirm "¿Quieres eliminar dependencias ya no necesarias con autoremove?"; then
      sudo apt-get autoremove --purge -y
    fi
  fi
}

write_client_config() {
  if [ -f "$client_config_file" ] && ! $force_overwrite; then
    echo "$client_config_file ya existe; no se sobrescribió."
    return 0
  fi

  cat > "$client_config_file" <<'EOF'
# Cliente seguro Senderman
SENDERMAN_CLIENT_PROTOCOL=ftps
SENDERMAN_CLIENT_HOST=
SENDERMAN_CLIENT_PORT=21
SENDERMAN_CLIENT_USER=

# Opcionales:
# SENDERMAN_CLIENT_VERIFY=yes
# SENDERMAN_CLIENT_CA_FILE=/ruta/a/ca.crt
EOF
  chmod 600 "$client_config_file"
  echo "Se creó $client_config_file con permisos 600."
}

install_app_icon() {
  local icons_dir
  icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"

  mkdir -p "$icons_dir"
  rm -f "$icons_dir/senderman-ftp-admin.png" "$icons_dir/senderman-ftp-admin.svg"

  cat > "$icons_dir/senderman-ftp-admin.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256" role="img" aria-label="Senderman FTP Admin">
  <rect width="256" height="256" rx="44" fill="#0f172a"/>
  <rect x="28" y="28" width="200" height="200" rx="36" fill="#111827" stroke="#38bdf8" stroke-width="6"/>
  <circle cx="92" cy="98" r="18" fill="#38bdf8"/>
  <circle cx="164" cy="98" r="18" fill="#f59e0b"/>
  <path d="M72 160c14-26 37-39 56-39s42 13 56 39" fill="none" stroke="#e5e7eb" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M72 160h112" fill="none" stroke="#e5e7eb" stroke-width="12" stroke-linecap="round"/>
  <text x="128" y="214" fill="#e5e7eb" font-family="sans-serif" font-size="28" text-anchor="middle">FTP Admin</text>
</svg>
EOF
}

install_desktop_shortcuts() {
  local applications_dir
  applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

  mkdir -p "$applications_dir"
  install_app_icon

  cat > "$applications_dir/senderman-ftp-admin.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SFTP Monitor
Comment=Abre el panel web de administración
Exec=/usr/bin/bash $repo_root/tools/launcher.sh start
TryExec=/usr/bin/bash
Icon=senderman-ftp-admin
Terminal=false
Categories=Network;System;
StartupNotify=true
EOF

  cat > "$applications_dir/senderman-ftp-admin-menu.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SFTP Shell
Comment=Abre el menú interactivo de instalación y mantenimiento
Exec=/usr/bin/bash $repo_root/tools/menu.sh
TryExec=/usr/bin/bash
Icon=senderman-ftp-admin
Terminal=true
Categories=Network;System;Utility;
StartupNotify=true
EOF

  chmod 644 "$applications_dir/senderman-ftp-admin.desktop" "$applications_dir/senderman-ftp-admin-menu.desktop"
  echo "Se instalaron los accesos directos en $applications_dir."
}

remove_desktop_shortcuts() {
  local applications_dir
  local icons_dir
  applications_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  icons_dir="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"

  rm -f "$applications_dir/senderman-ftp-admin.desktop" "$applications_dir/senderman-ftp-admin-menu.desktop"
  rm -f "$icons_dir/senderman-ftp-admin.svg" "$icons_dir/senderman-ftp-admin.png"
}

uninstall_application() {
  echo "== Desinstalación de Senderman FTP Admin =="

  remove_desktop_shortcuts

  if command -v sudo >/dev/null 2>&1; then
    if systemctl list-unit-files | grep -q '^senderman-ftp-admin\.service'; then
      sudo systemctl stop senderman-ftp-admin || true
      sudo systemctl disable senderman-ftp-admin || true
      sudo rm -f "/etc/systemd/system/$service_name.service"
      sudo systemctl daemon-reload || true
    fi
  fi

  if $uninstall_keep_config; then
    rm -rf .venv .senderman-release panel.log
    echo "Se conservaron .env, client.env, senderman_registry.sqlite3 y backups."
  else
    rm -rf .venv .env .senderman-release panel.log client.env senderman_registry.sqlite3 backups
  fi

  echo "Se eliminaron la aplicación, el servicio y los accesos directos."
}

prompt_client_profile() {
  local host
  local port
  local user
  local protocol
  local verify
  local ca_file

  if [ ! -t 0 ]; then
    return 0
  fi

  echo
  read -r -p "Modo de cliente [ftps/sftp] (ftps): " protocol
  protocol="${protocol:-ftps}"

  read -r -p "Servidor o IP remoto: " host
  read -r -p "Puerto remoto (21 para FTPS, 2222 para SFTP): " port
  read -r -p "Usuario remoto: " user

  if [ -z "$host" ] || [ -z "$user" ]; then
    echo "aviso: faltan datos de cliente; deja $client_config_file para configurarlo después"
    return 0
  fi

  if [ "$protocol" = "sftp" ]; then
    port="${port:-2222}"
  else
    port="${port:-21}"
  fi

  if [ "$protocol" = "ftps" ]; then
    read -r -p "¿Verificar certificado TLS? [Y/n]: " verify
    verify="${verify:-yes}"
    if [[ "$verify" =~ ^[Nn]$ ]]; then
      verify="no"
    else
      verify="yes"
    fi

    ca_file=""
    if [ "$verify" = "yes" ]; then
      read -r -p "Ruta opcional de la CA (.crt) para confiar en el servidor: " ca_file
    fi
  fi

  {
    echo "SENDERMAN_CLIENT_PROTOCOL=$protocol"
    echo "SENDERMAN_CLIENT_HOST=$host"
    echo "SENDERMAN_CLIENT_PORT=$port"
    echo "SENDERMAN_CLIENT_USER=$user"
    if [ "$protocol" = "ftps" ]; then
      echo "SENDERMAN_CLIENT_VERIFY=$verify"
      if [ -n "$ca_file" ]; then
        echo "SENDERMAN_CLIENT_CA_FILE=$ca_file"
      fi
    fi
  } > "$client_config_file"
  chmod 600 "$client_config_file"
  echo "Se guardó la configuración de cliente en $client_config_file."
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
keep = {".git", ".venv", ".env", "client.env", "panel.log", "users.json", "senderman_registry.sqlite3", "backups", "local-tools", ".senderman-release"}

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
  release_info="$(resolve_release_info "$release_mode" "$release_selector")"
  IFS='|' read -r release_tag release_tarball_url release_name <<<"$release_info"

  echo "Instalando desde la release publicada: $release_tag"
  if [ -n "$release_name" ]; then
    echo "Nombre: $release_name"
  fi

  sync_release_tree "$release_tarball_url"
  write_release_marker "$release_tag"

  exec env SENDERMAN_INSTALLER_SKIP_BOOTSTRAP=1 bash "$repo_root/install.sh" "$@"
fi

if [ "$install_profile" != "client" ]; then
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
    echo "Se creó .env desde .env.example con permisos 600."
  fi

  current_admin_pass="$(grep -E '^ADMIN_PASS=' .env | head -n1 | cut -d= -f2- || true)"
  if [ -z "$current_admin_pass" ] || [ "$current_admin_pass" = "ChangeMe123!" ]; then
    echo
    read -r -p "Escribe un ADMIN_PASS nuevo o pulsa Enter para generar uno seguro: " admin_pass
    if [ -z "$admin_pass" ]; then
      admin_pass="$(generate_password)"
      echo "ADMIN_PASS generado automáticamente."
      echo "Guárdalo ahora: $admin_pass"
    fi
    set_env_value "ADMIN_PASS" "$admin_pass"
  fi

  echo
  echo "Revisa .env si quieres ajustar ADMIN_USER, FTP_LOG, VSFTPD_CONF o FILES_DIR."
  if prompt_confirm "¿Quieres abrir una pausa para revisar .env ahora?"; then
    open_config_review
  fi

  if [ "$install_profile" != "client" ] && $install_service; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "error: sudo no está disponible y se pidió instalar el servicio"
      exit 1
    fi

    if [ ! -f senderman-ftp-admin.service ]; then
      echo "error: no se encontró senderman-ftp-admin.service"
      exit 1
    fi

    echo "Instalando servicio systemd..."
    sudo cp senderman-ftp-admin.service "/etc/systemd/system/$service_name.service"
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$service_name"
  fi
fi

if [ "$install_profile" != "server" ]; then
  install_client_tools
  write_client_config
  prompt_client_profile
fi

if [ "$install_profile" != "client" ]; then
  install_desktop_shortcuts
fi

echo
echo "Listo. Siguientes pasos:"
case "$install_profile" in
  server)
    echo "1) Verifica .env"
    if $install_service; then
      echo "2) Revisa el estado con: sudo systemctl status $service_name"
      echo "3) Abre http://localhost:8080"
    else
      echo "2) Arranca el panel con: nohup .venv/bin/python main.py > panel.log 2>&1 &"
      echo "3) Abre http://localhost:8080"
    fi
    ;;
  client)
    echo "1) Ajusta client.env con la IP o dominio remoto"
    echo "2) Usa: bash tools/client.sh connect"
    echo "3) Si es FTPS, instala la CA del servidor para evitar el error de certificado"
    ;;
  both)
    echo "1) Verifica .env y client.env"
    if $install_service; then
      echo "2) Revisa el estado con: sudo systemctl status $service_name"
    else
      echo "2) Arranca el panel con: nohup .venv/bin/python main.py > panel.log 2>&1 &"
    fi
    echo "3) Usa: bash tools/client.sh connect"
    ;;
esac