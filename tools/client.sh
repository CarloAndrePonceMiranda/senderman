#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
client_env="$script_dir/../client.env"

if [ -f "$client_env" ]; then
  # shellcheck disable=SC1090
  source "$client_env"
fi

usage() {
  cat <<'EOF'
Uso:
  bash tools/client.sh connect

El helper lee client.env si existe y conecta por FTPS o SFTP.
EOF
}

prompt_value() {
  local label="$1"
  local default_value="${2:-}"
  local value

  if [ -t 0 ]; then
    if [ -n "$default_value" ]; then
      read -r -p "$label [$default_value]: " value
      printf '%s' "${value:-$default_value}"
    else
      read -r -p "$label: " value
      printf '%s' "$value"
    fi
  else
    printf '%s' "$default_value"
  fi
}

connect_sftp() {
  local host="${SENDERMAN_CLIENT_HOST:-}"
  local port="${SENDERMAN_CLIENT_PORT:-2222}"
  local user="${SENDERMAN_CLIENT_USER:-}"

  host="${host:-$(prompt_value "Servidor o IP remoto" "")}"
  host="$(printf '%s' "$host" | xargs)"
  user="${user:-$(prompt_value "Usuario remoto" "")}"
  user="$(printf '%s' "$user" | xargs)"

  if [ -z "$host" ] || [ -z "$user" ]; then
    echo "error: faltan datos para SFTP" >&2
    exit 1
  fi

  exec sftp -P "$port" "$user@$host"
}

connect_ftps() {
  local host="${SENDERMAN_CLIENT_HOST:-}"
  local port="${SENDERMAN_CLIENT_PORT:-21}"
  local user="${SENDERMAN_CLIENT_USER:-}"
  local verify="${SENDERMAN_CLIENT_VERIFY:-yes}"
  local ca_file="${SENDERMAN_CLIENT_CA_FILE:-}"
  local lftp_cmds="set cmd:fail-exit yes;"

  host="${host:-$(prompt_value "Servidor o IP remoto" "")}"
  host="$(printf '%s' "$host" | xargs)"
  user="${user:-$(prompt_value "Usuario remoto" "")}"
  user="$(printf '%s' "$user" | xargs)"

  if [ -z "$host" ] || [ -z "$user" ]; then
    echo "error: faltan datos para FTPS" >&2
    exit 1
  fi

  if [[ "$verify" =~ ^[Nn](o)?$ ]]; then
    lftp_cmds+=" set ssl:verify-certificate no;"
  elif [ -n "$ca_file" ]; then
    lftp_cmds+=" set ssl:ca-file \"$ca_file\";"
  fi

  lftp_cmds+=" ls; bye"

  lftp -u "$user" "ftps://$host:$port" -e "$lftp_cmds"
}

main() {
  local command="${1:-connect}"

  case "$command" in
    connect)
      case "${SENDERMAN_CLIENT_PROTOCOL:-ftps}" in
        sftp)
          connect_sftp
          ;;
        ftps|*)
          connect_ftps
          ;;
      esac
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "error: comando inválido: $command" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"