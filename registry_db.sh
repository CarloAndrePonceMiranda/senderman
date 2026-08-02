#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Uso:
  bash registry_db.sh backup [ruta-destino]
  bash registry_db.sh restore <archivo-respaldo>
  bash registry_db.sh status

Comandos:
  backup   Crea una copia del registro SQLite en backups/
  restore  Restaura el archivo SQLite desde un respaldo existente
  status   Muestra la ubicación actual del registro y si existe
EOF
}

registry_db="senderman_registry.sqlite3"
backup_dir="backups"
timestamp="$(date +%Y%m%d-%H%M%S)"

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

command="$1"
shift || true

ensure_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 no está instalado"
    exit 1
  fi
}

backup_registry() {
  local destination="${1:-$backup_dir/${registry_db%.sqlite3}-$timestamp.sqlite3}"
  ensure_python

  if [ ! -f "$registry_db" ]; then
    echo "error: no existe $registry_db"
    exit 1
  fi

  mkdir -p "$(dirname "$destination")"
  python3 - "$registry_db" "$destination" <<'PY'
from pathlib import Path
import sqlite3
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
backup = sqlite3.connect(destination)
with sqlite3.connect(source) as conn:
    conn.backup(backup)
backup.close()
print(f"Respaldo creado en {destination}")
PY
}

restore_registry() {
  local source="${1:-}"
  ensure_python

  if [ -z "$source" ]; then
    echo "error: falta la ruta del respaldo"
    usage
    exit 1
  fi

  if [ ! -f "$source" ]; then
    echo "error: no existe el respaldo $source"
    exit 1
  fi

  python3 - "$source" "$registry_db" <<'PY'
from pathlib import Path
import shutil
import sqlite3
import sys

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
temp = destination.with_suffix(destination.suffix + '.tmp')

with sqlite3.connect(source) as conn:
    conn.execute('SELECT name FROM sqlite_master LIMIT 1')

shutil.copy2(source, temp)
temp.replace(destination)
print(f"Registro restaurado en {destination}")
PY
}

show_status() {
  if [ -f "$registry_db" ]; then
    echo "Registro SQLite: $repo_root/$registry_db"
    echo "Estado: presente"
  else
    echo "Registro SQLite: $repo_root/$registry_db"
    echo "Estado: no existe"
  fi
}

case "$command" in
  backup)
    backup_registry "${1:-}"
    ;;
  restore)
    restore_registry "${1:-}"
    ;;
  status)
    show_status
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "error: comando desconocido: $command"
    usage
    exit 1
    ;;
esac
