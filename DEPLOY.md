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
bash install_secure.sh --service
```

Si prefieres instalar sin habilitar el servicio aún:

```bash
bash install_secure.sh
```

## Configuración

`install_secure.sh` crea `.env` con permisos 600 y te pide revisar `ADMIN_PASS` antes de continuar.
Si cambias rutas o usuario, revisa también el archivo `/etc/sudoers.d/ftp-admin`.

## Actualización

Cuando publiques cambios nuevos en GitHub, ejecuta:

```bash
bash local-tools/update_ubuntu.sh
```

Ese script hace `git pull --ff-only`, reinstala dependencias y reinicia el servicio systemd si está disponible.

## Publicación

Antes de crear un tag o una GitHub Release, ejecuta:

```bash
bash local-tools/release_check.sh
```

Si quieres forzar una revisión con cambios locales sin commit, usa:

```bash
bash local-tools/release_check.sh --allow-dirty v1.1.1
```

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