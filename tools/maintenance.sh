#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Uso:
  bash tools/maintenance.sh

Qué hace:
  1) Crea un respaldo de senderman_registry.sqlite3
  2) Ejecuta tools/update_ubuntu.sh
  3) Si falla la actualización, muestra el comando de restauración
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_path="backups/senderman_registry-${timestamp}.sqlite3"
restore_hint="bash tools/registry_db.sh restore $backup_path"

mkdir -p backups

echo "== Senderman FTP Admin maintenance =="
echo "Repo: $repo_root"
echo "Backup: $backup_path"

if [ -f senderman_registry.sqlite3 ]; then
  bash "$script_dir/registry_db.sh" backup "$backup_path"
else
  echo "Aviso: no existe senderman_registry.sqlite3; se omite el respaldo del registro."
fi

if bash "$script_dir/update_ubuntu.sh"; then
  echo
  echo "Mantenimiento completado con éxito."
else
  code=$?
  echo
  echo "error: la actualización falló con código $code"
  echo "Si necesitas volver atrás en el registro, usa:"
  echo "$restore_hint"
  exit "$code"
fi