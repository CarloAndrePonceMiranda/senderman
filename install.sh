#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

service_name="senderman-ftp-admin"
install_service=false
force_overwrite=false
release_mode="latest"
release_selector=""

usage() {
  cat <<'EOF'
Uso: bash install.sh [--service] [--force] [--latest-release] [--release <release>] [--choose-release]

  --service         Instala y habilita el servicio systemd
  --force           Sobrescribe .env si ya existe
  --latest-release  Instala la release publicada más reciente (por defecto)
  --release <release> Instala una release publicada concreta
  --choose-release  Muestra una lista de releases publicadas y deja elegir una
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
    for prefix, _ in prefixes.items():
      if remote_url.startswith(prefix):
        slug = remote_url[len(prefix) :]
        return slug[:-4] if slug.endswith(".git") else slug
    raise SystemExit(f"error: no se pudo resolver el repositorio GitHub desde origin: {remote_url}")


  def fetch_json(url: str):
    request = urllib.request.Request(
      url,
      headers={"Accept": "application/vnd.github+json", "User-Agent": "senderman-installer"},
    )
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

  select_tag_info() {
    local repo_slug="$1"
    local mode="$2"
    local selector="$3"

    python3 - "$repo_slug" "$mode" "$selector" <<'PY'
  from __future__ import annotations

  import subprocess
  import sys

  repo_slug, mode, selector = sys.argv[1:4]


  def git_tags() -> list[str]:
    result = subprocess.run(["git", "tag", "--sort=-creatordate"], check=True, text=True, capture_output=True)
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


  def tag_line(tag: str) -> str:
    return f"{tag}|https://github.com/{repo_slug}/archive/refs/tags/{tag}.tar.gz|{tag}"


  tags = git_tags()
  if not tags:
    print("error: no hay tags locales disponibles para compatibilidad", file=sys.stderr)
    raise SystemExit(1)

  if mode == "latest":
    print(tag_line(tags[0]))
  elif mode == "exact":
    if selector not in tags:
      print(f"error: no se encontró un tag local para {selector}", file=sys.stderr)
      raise SystemExit(1)
    print(tag_line(selector))
  elif mode == "choose":
    print("Tags locales disponibles:")
    for index, tag in enumerate(tags, start=1):
      print(f"{index}) {tag}")

    if not sys.stdin.isatty():
      print("error: --choose-release requiere una terminal interactiva", file=sys.stderr)
      raise SystemExit(1)

    while True:
      choice = input("Elige un tag por número o nombre: ").strip()
      if not choice:
        continue
      if choice.isdigit():
        selected_index = int(choice) - 1
        if 0 <= selected_index < len(tags):
          print(tag_line(tags[selected_index]))
          break
        print("Opción fuera de rango. Intenta otra vez.")
        continue

      if choice in tags:
        print(tag_line(choice))
        break

      print("No encontré ese tag. Intenta otra vez.")
  else:
    print(f"error: modo de tag desconocido: {mode}", file=sys.stderr)
    raise SystemExit(1)
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

if ! python3 -c 'import venv' >/dev/null 2>&1; then
  echo "error: python3-venv no está instalado"
  exit 1
fi

if ! command -v pip3 >/dev/null 2>&1; then
  echo "error: pip3 no está instalado"
  exit 1
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
prompt_confirm "¿Quieres abrir una pausa para revisar .env ahora?" || true

if $install_service; then
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