#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

echo "== Senderman FTP Admin update =="
echo "Repo: $repo_root"

if ! command -v git >/dev/null 2>&1; then
  echo "error: git no está instalado"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: hay cambios locales sin guardar. Haz commit, stash o limpia el árbol antes de actualizar."
  exit 1
fi

current_branch="$(git branch --show-current)"
if [ -z "$current_branch" ]; then
  echo "error: no se pudo detectar la rama actual"
  exit 1
fi

echo "Actualizando desde origin/$current_branch..."
git pull --ff-only origin "$current_branch"

if [ ! -d .venv ]; then
  echo "error: no existe .venv. Ejecuta primero install.sh"
  exit 1
fi

# shellcheck disable=SC1091
source .venv/bin/activate

pip install --upgrade pip >/dev/null
pip install -r requirements.txt

if systemctl list-unit-files | grep -q '^senderman-ftp-admin\.service'; then
  echo "Reiniciando servicio systemd..."
  sudo systemctl restart senderman-ftp-admin
else
  echo "Servicio systemd no detectado. Reinicia el panel manualmente si hace falta."
fi

echo
echo "Actualización completada."