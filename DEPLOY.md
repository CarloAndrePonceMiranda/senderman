# Despliegue en Ubuntu

Esta guía deja el panel funcionando en una máquina Ubuntu con el mínimo de pasos.

## Requisitos

- Ubuntu 24.04 o similar
- Python 3.12+
- Git
- `vsftpd` instalado y configurado
- Acceso `sudo`

## Instalación rápida

```bash
git clone <URL_DE_TU_REPO>
cd ftp-admin
bash setup_ubuntu.sh
```

## Configuración

```bash
cp .env.example .env
nano .env
```

Ajusta al menos `ADMIN_PASS`. Si cambias rutas o usuario, revisa también el archivo `/etc/sudoers.d/ftp-admin`.

## Arranque manual

```bash
cd /ruta/al/repo/ftp-admin
nohup .venv/bin/python main.py > panel.log 2>&1 &
```

Abre la interfaz en:

```text
http://localhost:8080
```

## Arranque como servicio

```bash
sudo cp senderman-ftp-admin.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now senderman-ftp-admin
```

Comandos útiles:

```bash
sudo systemctl status senderman-ftp-admin
sudo systemctl restart senderman-ftp-admin
sudo systemctl stop senderman-ftp-admin
```

## Checklist final

- `master` es la rama principal.
- El repo tiene el commit inicial y la etiqueta `v1.0.0`.
- `.env` no se sube al repositorio.
- `users.json` y `panel.log` siguen ignorados.
- El panel abre en `http://localhost:8080`.