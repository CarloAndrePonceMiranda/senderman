# Senderman FTP Admin

Panel web de administración para el servidor FTPS/SFTP **vsftpd** en `senderman`.  
Construido con **FastAPI + WebSockets + Bootstrap 5 Dark**.

## Despliegue rápido

Si solo quieres dejarlo funcionando en Ubuntu, usa la guía corta en [DEPLOY.md](DEPLOY.md).

Resumen rápido:

1. Clona el repositorio y entra al directorio.
2. Ejecuta `bash setup_ubuntu.sh`.
3. Copia `.env.example` a `.env` y ajusta `ADMIN_PASS`.
4. Arranca el panel con `sudo systemctl enable --now senderman-ftp-admin`.
5. Abre `http://localhost:8080` y verifica el estado del servicio.

Si después publicas cambios, usa `bash update_ubuntu.sh` para traerlos y reinstalar dependencias.

## Checklist de entrega

- `master` es la rama principal.
- Existe el commit inicial y la etiqueta `v1.0.0`.
- `.env` no se sube al repositorio.
- `users.json` y `panel.log` siguen fuera de Git.
- El panel puede arrancar manualmente o como servicio systemd.

## Qué incluye

- Estado del servicio y control de `vsftpd`.
- Registro de usuarios del sistema desde la UI.
- Bloqueo/desbloqueo y escritura por usuario.
- Usuarios conectados y actividad en vivo.
- Explorador de archivos de la carpeta compartida.

## Estructura del repositorio

```text
ftp-admin/
├── main.py
├── requirements.txt
├── .env.example
├── .gitignore
├── README.md
└── templates/
    └── index.html
```

---

## Requisitos

- Ubuntu 24.04 o similar
- Python 3.12+
- Git
- `vsftpd` instalado y configurado
- Dependencias del sistema: `fail2ban`, `ufw`
- Acceso `sudo` para los comandos que el panel ejecuta

---

## Instalación

Si quieres hacerlo en un solo paso, ejecuta:

```bash
bash setup_ubuntu.sh
```

Si prefieres hacerlo manualmente:

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip git

git clone <URL_DE_TU_REPO>
cd ftp-admin

python3 -m venv .venv
source .venv/bin/activate

pip install -r requirements.txt
```

---

## Configuración

1. Copia el archivo de ejemplo:

```bash
cp .env.example .env
```

2. Edita `.env` y ajusta, como mínimo, `ADMIN_PASS`.

3. Si cambias las rutas por defecto, revisa también el archivo `/etc/sudoers.d/ftp-admin`.

Variables disponibles:

| Variable | Descripción |
|---|---|
| `ADMIN_USER` | Usuario HTTP del panel |
| `ADMIN_PASS` | Contraseña HTTP del panel |
| `FTP_LOG` | Ruta del log de `vsftpd` |
| `VSFTPD_CONF` | Ruta del archivo de configuración de `vsftpd` |
| `FILES_DIR` | Carpeta compartida |
| `FTP_USER` | Usuario principal administrado por el panel |

---

## Uso

1. Abre una terminal solo para arrancar el panel.
2. Ejecuta:

```bash
cd /ruta/al/repo/ftp-admin
nohup .venv/bin/python main.py > panel.log 2>&1 &
```

> Ese comando deja el panel corriendo en segundo plano, así que no mezcles
> comprobaciones en la misma terminal. El log del panel se guarda en `panel.log`.

3. Usa otra terminal o el navegador para verificar que responde.

Abre la interfaz en:

```text
http://localhost:8080
```

Para detenerlo:

```bash
pkill -f "python3 main.py"
```

### Uso en el panel

- La pestaña **Usuarios conectados** contiene el registro de usuarios.
- El botón **Abrir registro de usuarios** abre una modal para crear cuentas.
- Los toggles de **Estado** y **Escritura** se usan directamente desde la tabla.
- El panel guarda el registro local en `users.json`.

---

## Acceso

**Credenciales por defecto del panel:**

| Campo | Valor |
|-------|-------|
| Usuario | `admin` |
| Contraseña | definida en `ADMIN_PASS` dentro de `.env` |

Acceso desde el navegador:

```text
http://localhost:8080
```

Si lo expones en red local, usa la IP del servidor en el mismo puerto.

---

## Funcionalidades

| Función | Descripción |
|---------|-------------|
| **Estado del servidor** | Indicador en tiempo real (activo / detenido) |
| **Control de servicio** | Botones Iniciar / Detener / Reiniciar vsftpd |
| **Alta en el panel** | Crear cuentas del sistema y registrarlas en la UI |
| **Registro de usuarios** | Ver estado, bloqueo y escritura por cada usuario registrado |
| **Bloquear usuario** | Cortar acceso a un usuario registrado con un clic |
| **Actividad en vivo** | Feed del log `/var/log/vsftpd.log` vía WebSocket |
| **Usuarios conectados** | Quién está conectado, desde qué IP y desde cuándo |
| **Explorador de archivos** | Lista recursiva de `senderman/files/` con tamaños y total |

---

## Configuración avanzada

El backend lee estas variables desde `.env` o variables de entorno:

- `ADMIN_USER`
- `ADMIN_PASS`
- `FTP_LOG`
- `VSFTPD_CONF`
- `FILES_DIR`
- `FTP_USER`

Valores por defecto incluidos en `.env.example`.

---

## Permisos sudo requeridos

El archivo `/etc/sudoers.d/ftp-admin` contiene los permisos necesarios:

```
mr-robot ALL=(ALL) NOPASSWD: /usr/bin/systemctl start vsftpd
mr-robot ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop vsftpd
mr-robot ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart vsftpd
mr-robot ALL=(ALL) NOPASSWD: /usr/bin/usermod -L jesus12jimmy13
mr-robot ALL=(ALL) NOPASSWD: /usr/bin/usermod -U jesus12jimmy13
mr-robot ALL=(ALL) NOPASSWD: /usr/bin/getent shadow jesus12jimmy13
mr-robot ALL=(ALL) NOPASSWD: /usr/sbin/useradd -m -s /usr/sbin/nologin
mr-robot ALL=(ALL) NOPASSWD: /usr/sbin/chpasswd
mr-robot ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/vsftpd.conf
mr-robot ALL=(ALL) NOPASSWD: /usr/bin/tail -n 50 -f /var/log/vsftpd.log
mr-robot ALL=(ALL) NOPASSWD: /usr/bin/tail -n 500 /var/log/vsftpd.log
```

Si cambias el usuario principal o las rutas, actualiza este archivo para que el panel siga pudiendo ejecutar los comandos necesarios.

---

## Configuración del servidor FTP (`/etc/vsftpd.conf`)

Aspectos clave de la configuración activa:

| Opción | Valor | Descripción |
|--------|-------|-------------|
| `ssl_enable` | YES | TLS habilitado |
| `force_local_logins_ssl` | NO | FTP plano permitido (compatibilidad GnuTLS) |
| `chroot_local_user` | YES | Usuario enjaulado en su home |
| `local_root` | `/home/mr-robot/senderman` | Raíz del servidor FTP |
| `pasv_min_port` / `pasv_max_port` | 40404 | Puerto pasivo único |
| `pasv_address` | 189.242.89.77 | IP pública |
| `write_enable` | NO | Solo descarga por defecto para el usuario principal |
| `anonymous_enable` | NO | Sin acceso anónimo |

---

## Servicio systemd

Si prefieres que el panel arranque como servicio en Ubuntu, usa el archivo incluido [senderman-ftp-admin.service](senderman-ftp-admin.service).

Pasos de instalación:

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

Si cambias la ruta del repositorio, edita `WorkingDirectory` y `ExecStart` en el archivo del servicio.

---

## Seguridad y archivos ignorados

- **fail2ban** activo: bloquea IPs tras 5 intentos fallidos en 10 minutos (ban 1 hora)
- **UFW** con puertos abiertos: 21 (FTP), 40404 (pasivo), 22 (SSH), 80, 443
- **Chroot jail**: el usuario FTP solo ve `senderman/` y no puede salir
- **Sin shell**: `jesus12jimmy13` usa `/usr/sbin/nologin` — no puede abrir una terminal
- **Certificado TLS**: autofirmado en `/etc/ssl/vsftpd/`, válido 1 año
- **Registro local**: el panel guarda estado de bloqueo y escritura por usuario en `users.json`
- `.env`, `panel.log`, `users.json` y `__pycache__/` no se suben al repositorio.

## Cómo registrar usuarios

1. Abre el panel y ve a la tarjeta **Registro de usuarios**.
2. Escribe el nombre de usuario y una contraseña inicial.
3. Pulsa **Crear**.
4. El panel crea la cuenta del sistema con shell deshabilitada y la añade a `users.json`.
5. Después ya podrás bloquearla o darle escritura desde la tabla.

> La cuenta se crea con `/usr/sbin/nologin` para mantener el acceso restringido.

---

## Para compartir el proyecto en GitHub

1. Verifica que `.env` no tenga secretos que no quieras compartir.
2. Confirma que `users.json` y `panel.log` no se suban.
3. Mantén el repositorio privado si contiene configuración sensible.
4. Si tu compa va a desplegarlo, solo necesita clonar, crear `.env`, instalar dependencias y arrancar `main.py`.

---

## Solución de problemas

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| `GnuTLS -15` en FileZilla Linux | Incompatibilidad GnuTLS/OpenSSL | Usar cifrado **FTP plano** en Gestor de sitios |
| `530 Non-anonymous sessions must use encryption` | `force_local_logins_ssl=YES` | Verificar que está en `NO` |
| Login correcto pero directorio vacío | Permisos de `/home/mr-robot` (750) | `sudo chmod o+x /home/mr-robot` |
| Transferencias fallidas (modo pasivo) | Puerto 40404 no reachable | Verificar port forwarding en router; limitar FileZilla a 1 conexión simultánea |
| Panel no muestra usuarios conectados | Log solo legible por root | Verificar `/etc/sudoers.d/ftp-admin` |

---

## Notas

- El panel escucha en `0.0.0.0:8080` — no lo expongas a internet sin autenticación adicional.
- El log en vivo usa WebSocket; requiere `uvicorn[standard]` o `websockets` instalado.
- Para iniciar automáticamente al arrancar, configurar como servicio systemd.
