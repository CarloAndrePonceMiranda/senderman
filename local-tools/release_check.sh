#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

allow_dirty=false
release_tag="${1:-v1.3.0}"

if [[ "${1:-}" == "--allow-dirty" ]]; then
  allow_dirty=true
  release_tag="${2:-v1.3.0}"
fi

echo "== Senderman FTP Admin release check =="
echo "Repo: $repo_root"
echo "Tag: $release_tag"

if ! command -v git >/dev/null 2>&1; then
  echo "error: git no está instalado"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 no está instalado"
  exit 1
fi

if ! python3 -c 'import py_compile' >/dev/null 2>&1; then
  echo "error: python3 no puede importar py_compile"
  exit 1
fi

if ! $allow_dirty; then
  if [ -n "$(git status --porcelain)" ]; then
    echo "error: hay cambios locales sin guardar"
    exit 1
  fi
fi

current_branch="$(git branch --show-current)"
if [ "$current_branch" != "master" ]; then
  echo "error: la rama actual debe ser master"
  exit 1
fi

if git show-ref --verify --quiet "refs/tags/$release_tag"; then
  echo "error: el tag $release_tag ya existe"
  exit 1
fi

python3 -m py_compile main.py

if command -v node >/dev/null 2>&1; then
  node --check static/js/app.js
else
  echo "warning: node no está instalado; no se pudo validar static/js/app.js"
fi

for path in .env users.json senderman_registry.sqlite3 panel.log; do
  if [ -e "$path" ] && ! git check-ignore -q "$path"; then
    echo "error: $path existe pero no está ignorado por git"
    exit 1
  fi
done

echo
echo "OK: el repo está listo para crear la release $release_tag"