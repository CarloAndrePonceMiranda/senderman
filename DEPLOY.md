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

Al final de la instalación quedan tres accesos en el menú de aplicaciones:

- `Senderman APP`: abre la web.
- `Senderman Shell`: abre el terminal de administración del servicio.
- `Senderman Tools`: abre `./install.sh` para el menú de actualización, reinstalación y desinstalación.

## Configuración

`install.sh` crea `.env` con permisos 600 si no existe y te pide revisar `ADMIN_PASS` antes de continuar.
Si cambias rutas o usuario, revisa también el archivo `/etc/sudoers.d/ftp-admin`.

El registro de usuarios se guarda en `senderman_registry.sqlite3`; si vienes de una versión anterior, el instalador migra `users.json` automáticamente al arrancar el panel.

## Actualización

Cuando publiques cambios nuevos en GitHub, ejecuta:

```bash
bash tools/update.sh
```

Ese script instala la release publicada más reciente, o la release publicada que elijas, reinstala dependencias y reinicia el servicio systemd si está disponible.

## Publicación

Antes de crear un tag o una GitHub Release, ejecuta:

tu comprobación privada de release.

Si quieres forzar una revisión con cambios locales sin commit, usa la opción equivalente de tu comprobación privada.

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

### Detener vsftpd antes de apagar Ubuntu

Si quieres que `vsftpd` se detenga automáticamente al apagar este equipo, instala el servicio [vsftpd-stop-on-shutdown.service](vsftpd-stop-on-shutdown.service):

```bash
sudo cp vsftpd-stop-on-shutdown.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable vsftpd-stop-on-shutdown
```

Con ese servicio habilitado, `vsftpd` se detendrá como parte del apagado normal de Ubuntu.

## Arranque bajo demanda con autenticación

Si quieres que el panel se inicie solo cuando lo pidas y que Ubuntu te solicite la contraseña del sistema, usa el launcher local:

```bash
bash tools/app.sh
```

Ese comando intenta abrir el navegador en pantalla completa con un navegador compatible y, si no lo encuentra, usa el navegador por defecto.

Si prefieres un acceso gráfico, puedes instalar [Senderman APP](senderman-app.desktop), [Senderman Shell](senderman-shell.desktop) o [Senderman Tools](senderman-tools.desktop) en el escritorio o en el menú de aplicaciones.

## Checklist final

- `master` es la rama principal.
- El repo tiene el commit inicial y la etiqueta `v1.0.0`.
- `.env` no se sube al repositorio.
- `users.json` y `panel.log` siguen ignorados.
- El panel abre en `http://localhost:8080`.