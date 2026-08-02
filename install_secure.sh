#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

service_name="senderman-ftp-admin"
install_service=false
force_overwrite=false

usage() {
  cat <<'EOF'
Uso: bash install_secure.sh [--service] [--force]

  --service   Instala y habilita el servicio systemd
  --force     Sobrescribe .env si ya existe
EOF
}

for arg in "$@"; do
  case "$arg" in
    --service)
      install_service=true
      ;;
    --force)
      force_overwrite=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: argumento desconocido: $arg"
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

echo "== Senderman FTP Admin secure install =="
echo "Repo: $repo_root"

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

echo
echo "Abre .env y ajusta al menos ADMIN_PASS antes de continuar."
echo "También revisa FTP_LOG, VSFTPD_CONF y FILES_DIR si tu equipo usa rutas distintas."
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