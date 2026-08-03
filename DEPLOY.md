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
bash install.sh --service
```

`install.sh` instala por defecto la release publicada más reciente. Si necesitas otra versión publicada, usa `bash install.sh --release <release-publicada>` o `bash install.sh --choose-release`.

Si prefieres instalar sin habilitar el servicio aún:

```bash
bash install.sh
```

## Configuración

`install.sh` crea `.env` con permisos 600 si no existe y te pide revisar `ADMIN_PASS` antes de continuar.
Si cambias rutas o usuario, revisa también el archivo `/etc/sudoers.d/ftp-admin`.

El registro de usuarios se guarda en `senderman_registry.sqlite3`; si vienes de una versión anterior, el instalador migra `users.json` automáticamente al arrancar el panel.

## Actualización

Cuando publiques cambios nuevos en GitHub, ejecuta:

```bash
bash tools/update.sh
```

Ese script hace `git pull --ff-only`, reinstala dependencias y reinicia el servicio systemd si está disponible.

Si quieres una actualización más segura, usa:

```bash
bash tools/maintenance.sh
```

Ese helper crea un respaldo del registro SQLite antes de actualizar y te deja una pista de restauración si algo falla.

## Publicación

Antes de crear un tag o una GitHub Release, ejecuta:

tu comprobación privada de release.

Si quieres forzar una revisión con cambios locales sin commit, usa la opción equivalente de tu comprobación privada.

## Respaldo del registro

Si necesitas guardar o restaurar el estado de usuarios, usa:

```bash
bash tools/registry_db.sh backup
bash tools/registry_db.sh restore backups/senderman_registry-YYYYMMDD-HHMMSS.sqlite3
bash tools/registry_db.sh status
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