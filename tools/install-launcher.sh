#!/usr/bin/env bash
set -u

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_root="$(cd "$script_dir/.." && pwd)"

echo "Senderman: iniciando instalación del servicio..."
echo
bash "$install_root/install.sh" --service --latest-release --server
exit_code=$?

echo
if [ "$exit_code" -eq 0 ]; then
  echo "Instalación finalizada correctamente."
else
  echo "La instalación terminó con errores (código $exit_code)."
fi
echo
read -r -p "Pulsa Enter para cerrar esta terminal..." _
exit "$exit_code"