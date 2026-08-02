#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

echo "== Senderman FTP Admin setup =="
echo "Repo: $repo_root"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 no está instalado"
  exit 1
fi

if ! python3 -c 'import venv' >/dev/null 2>&1; then
  echo "error: python3-venv no está instalado"
  exit 1
fi

if [ ! -d .venv ]; then
  echo "Creando entorno virtual..."
  python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

pip install --upgrade pip >/dev/null
pip install -r requirements.txt

if [ ! -f .env ]; then
  cp .env.example .env
  echo "Se creó .env desde .env.example. Revisa ADMIN_PASS antes de iniciar."
else
  echo ".env ya existe; no se sobrescribió."
fi

echo
echo "Listo. Siguientes pasos:"
echo "1) Revisa .env"
echo "2) Ajusta /etc/sudoers.d/ftp-admin si hace falta"
echo "3) Inicia el panel con: nohup .venv/bin/python main.py > panel.log 2>&1 &"
