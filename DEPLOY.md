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

`install.sh` instala por defecto el tag más reciente y copia la app a `/opt/senderman-ftp-admin`. Si necesitas otra versión, usa `bash install.sh --release <tag>` o `bash install.sh --choose-release`.
Durante la instalación también crea el grupo SFTP dedicado y deja `sshd` configurado para aceptar solo claves públicas en ese grupo.

Si prefieres instalar sin habilitar el servicio aún:

```bash
bash install.sh
```

Al final de la instalación queda un acceso en el menú de aplicaciones:

- `Senderman`: abre la web.

La actualización, la desinstalación y el monitor ya se gestionan desde la pestaña **Mantenimiento** del panel web.

La carpeta compartida por defecto vive dentro de la instalación, en `/opt/senderman-ftp-admin/files`, y puedes cambiarla luego en `FILES_DIR` si lo necesitas.

Si vas a usar cuotas por cliente, activa cuotas en el filesystem que contiene `SFTP_ROOT_DIR` y verifica que `setquota` esté instalado; si no, el panel seguirá guardando el límite pero no podrá imponerlo en el sistema.

## Configuración

`install.sh` crea `.env` con permisos 600 si no existe y te pide revisar `ADMIN_PASS` antes de continuar.
Si cambias rutas o usuario, revisa también el archivo `/etc/sudoers.d/ftp-admin`.

El registro de usuarios se guarda en `senderman_registry.sqlite3`; si vienes de una versión anterior, el instalador migra `users.json` automáticamente al arrancar el panel.
Los usuarios SFTP nuevos y existentes quedan ligados al grupo `senderman-sftp` para que `sshd` aplique la política de clave-only.

## Actualización

Cuando publiques cambios nuevos en GitHub, ejecuta:

```bash
bash tools/update.sh
```

Ese script instala el tag más reciente, o el tag que elijas, reinstala dependencias y reinicia el servicio systemd si está disponible.

## Flujo de ramas

- `feature/*` y `bugfix/*` van a `develop`.
- `hotfix/*` va a `master`.
- `hotfix/*` publica patch tags.
- `master` vuelve a `develop` después de un hotfix.
- Las ramas `feature/*` y `bugfix/*` se eliminan después del merge.

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

Si prefieres un acceso gráfico, instala el acceso [Senderman](senderman.desktop) en el escritorio o en el menú de aplicaciones.

## Checklist final

- `master` es la rama principal.
- El repo tiene el commit inicial y la etiqueta `v1.0.0`.
- `.env` no se sube al repositorio.
- `users.json` y `panel.log` siguen ignorados.
- El panel abre en `http://localhost:8080`.