import asyncio
import mimetypes
import json
import os
import re
import secrets
import subprocess
import sqlite3
import shutil
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, File, HTTPException, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from starlette.background import BackgroundTask


def load_local_env() -> None:
    env_path = Path(__file__).parent / ".env"
    if not env_path.exists():
        return
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


load_local_env()

# ── Configuración ──────────────────────────────────────────────────────────────
ADMIN_USER = os.getenv("ADMIN_USER", "admin")
ADMIN_PASS = os.getenv("ADMIN_PASS", "ChangeMe123!")
FTP_LOG    = os.getenv("FTP_LOG", "/var/log/vsftpd.log")
VSFTPD_CONF = os.getenv("VSFTPD_CONF", "/etc/vsftpd.conf")
INSTALL_ROOT = Path(os.getenv("SENDERMAN_INSTALL_ROOT", "/opt/senderman-ftp-admin"))
FILES_DIR  = os.getenv("FILES_DIR", str(INSTALL_ROOT / "files"))
FTP_USER   = os.getenv("FTP_USER", "jesus12jimmy13")   # Usuario FTP principal
USER_REGISTRY_DB = Path(__file__).parent / "senderman_registry.sqlite3"
LEGACY_USER_REGISTRY_FILE = Path(__file__).parent / "users.json"
USERADD_BIN = "/usr/sbin/useradd"
CHPASSWD_BIN = "/usr/sbin/chpasswd"
APP_ROOT = Path(__file__).parent
SFTP_GROUP = "senderman-sftp"
SFTP_ROOT_DIR = Path(os.getenv("SFTP_ROOT_DIR", "/srv/senderman-sftp"))
SFTP_UPLOAD_DIRNAME = "upload"

# ── App ────────────────────────────────────────────────────────────────────────
app = FastAPI(title="Senderman FTP Admin")
security = HTTPBasic()
HTML_FILE = Path(__file__).parent / "templates" / "index.html"
STATIC_DIR = Path(__file__).parent / "static"
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

# ── Utilidades ─────────────────────────────────────────────────────────────────
def verify(credentials: HTTPBasicCredentials = Depends(security)) -> str:
    ok_user = secrets.compare_digest(credentials.username.encode(), ADMIN_USER.encode())
    ok_pass = secrets.compare_digest(credentials.password.encode(), ADMIN_PASS.encode())
    if not (ok_user and ok_pass):
        raise HTTPException(status_code=401, headers={"WWW-Authenticate": "Basic"})
    return credentials.username


def run(cmd: list[str]) -> tuple[int, str, str]:
    r = subprocess.run(cmd, capture_output=True, text=True,
                       stdin=subprocess.DEVNULL)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def run_sudo(cmd: list[str], sudo_password: str) -> tuple[int, str, str]:
    r = subprocess.run(
        ["sudo", "-S", "-p", ""] + cmd,
        input=f"{sudo_password}\n",
        capture_output=True,
        text=True,
    )
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def format_bytes(size: int) -> str:
    for unit in ["B", "KB", "MB", "GB"]:
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


def _safe_files_path(relative_path: str) -> Path:
    base = Path(FILES_DIR).resolve()
    safe_relative = relative_path.strip().replace("\\", "/")
    if Path(safe_relative).is_absolute():
        raise HTTPException(status_code=400, detail="Ruta de archivo inválida")

    candidate = (base / safe_relative).resolve()
    if candidate == base or base in candidate.parents:
        return candidate
    raise HTTPException(status_code=400, detail="Ruta de archivo inválida")


def _normalize_upload_relative_path(filename: str) -> Path:
    parts = [part for part in filename.replace("\\", "/").split("/") if part and part != "."]
    if not parts or any(part == ".." for part in parts):
        raise HTTPException(status_code=400, detail="Nombre de archivo inválido")
    return Path(*parts)


def _user_home_dir(username: str) -> str:
    rc, out, _ = run(["getent", "passwd", username])
    if rc != 0 or not out:
        raise HTTPException(status_code=404, detail="No se encontró el directorio del usuario")
    fields = out.split(":")
    if len(fields) < 6:
        raise HTTPException(status_code=500, detail="No se pudo leer el directorio del usuario")
    return fields[5]


def _normalize_public_key_text(public_key_text: str) -> str:
    allowed_prefixes = (
        "ssh-ed25519 ",
        "ssh-rsa ",
        "ssh-dss ",
        "ssh-ecdsa ",
        "ecdsa-sha2-nistp256 ",
        "ecdsa-sha2-nistp384 ",
        "ecdsa-sha2-nistp521 ",
        "sk-ssh-ed25519@openssh.com ",
        "sk-ecdsa-sha2-nistp256@openssh.com ",
    )
    keys: list[str] = []
    for line in public_key_text.splitlines():
        candidate = line.strip()
        if not candidate or candidate.startswith("#"):
            continue
        if not candidate.startswith(allowed_prefixes):
            raise HTTPException(status_code=400, detail="La clave SSH pública no tiene un formato válido")
        parts = candidate.split()
        if len(parts) < 2:
            raise HTTPException(status_code=400, detail="La clave SSH pública no tiene un formato válido")
        keys.append(candidate)

    if not keys:
        raise HTTPException(status_code=400, detail="Debes proporcionar una clave SSH pública")

    deduped: list[str] = []
    seen: set[str] = set()
    for key in keys:
        if key in seen:
            continue
        seen.add(key)
        deduped.append(key)
    return "\n".join(deduped)


def _parse_quota_bytes(quota_value: object) -> int:
    if quota_value in (None, "", 0, "0"):
        return 0
    try:
        parsed = int(quota_value)
    except (TypeError, ValueError):
        raise HTTPException(status_code=400, detail="La cuota debe ser un número entero de bytes")
    if parsed < 0:
        raise HTTPException(status_code=400, detail="La cuota no puede ser negativa")
    return parsed


def _quota_blocks(quota_bytes: int) -> int:
    if quota_bytes <= 0:
        return 0
    return (quota_bytes + 1023) // 1024


def _sftp_quota_mountpoint() -> str | None:
    rc, out, _ = run(["findmnt", "-no", "TARGET", "--target", str(SFTP_ROOT_DIR)])
    if rc != 0 or not out:
        return None
    return out.strip()


def _apply_user_quota(username: str, quota_bytes: int) -> bool:
    quota_tool = shutil.which("setquota")
    mountpoint = _sftp_quota_mountpoint()
    if not quota_tool or not mountpoint:
        return False

    blocks = _quota_blocks(quota_bytes)
    if blocks <= 0:
        code, _, err = run_sudo(["setquota", "-u", username, "0", "0", "0", "0", mountpoint], ADMIN_PASS)
    else:
        code, _, err = run_sudo(["setquota", "-u", username, str(blocks), str(blocks), "0", "0", mountpoint], ADMIN_PASS)

    if code != 0:
        return False
    return True


def _normalize_sftp_home_dir(username: str, home_dir: str | None = None) -> str:
    base_dir = SFTP_ROOT_DIR.resolve()
    desired = Path(home_dir.strip()) if home_dir else base_dir / username
    if not desired.is_absolute():
        raise HTTPException(status_code=400, detail="El directorio de inicio debe ser una ruta absoluta")

    resolved = desired.resolve() if desired.exists() else Path(str(desired))
    try:
        resolved_relative = resolved.resolve().relative_to(base_dir)
    except Exception:
        raise HTTPException(status_code=400, detail=f"El directorio de inicio debe estar dentro de {base_dir}")

    if len(resolved_relative.parts) != 1 or resolved_relative.parts[0] != username:
        raise HTTPException(status_code=400, detail=f"El directorio de inicio debe ser {base_dir / username}")

    return str(base_dir / username)


def _default_sftp_jail(username: str) -> str:
    return str(SFTP_ROOT_DIR / username)


def _prepare_sftp_jail(username: str, jail_root: str | None = None) -> str:
    jail_path = Path(_normalize_sftp_home_dir(username, jail_root))
    upload_dir = jail_path / SFTP_UPLOAD_DIRNAME
    ssh_dir = jail_path / ".ssh"

    run_sudo(["install", "-d", "-m", "755", "-o", "root", "-g", "root", str(SFTP_ROOT_DIR)], ADMIN_PASS)
    run_sudo(["install", "-d", "-m", "755", "-o", "root", "-g", "root", str(jail_path)], ADMIN_PASS)
    run_sudo(["install", "-d", "-m", "750", "-o", username, "-g", SFTP_GROUP, str(upload_dir)], ADMIN_PASS)
    run_sudo(["install", "-d", "-m", "700", "-o", "root", "-g", "root", str(ssh_dir)], ADMIN_PASS)
    return str(jail_path)


def _install_public_key(username: str, public_key_text: str) -> None:
    home_dir = Path(_user_home_dir(username))
    ssh_dir = home_dir / ".ssh"
    authorized_keys = ssh_dir / "authorized_keys"
    normalized = _normalize_public_key_text(public_key_text)

    run_sudo(["install", "-d", "-m", "700", "-o", "root", "-g", "root", str(ssh_dir)], ADMIN_PASS)
    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(normalized + "\n")
        temp_path = handle.name

    try:
        run_sudo(["install", "-m", "600", "-o", "root", "-g", "root", temp_path, str(authorized_keys)], ADMIN_PASS)
    finally:
        Path(temp_path).unlink(missing_ok=True)


def _ensure_sftp_group_membership(username: str) -> None:
    code, _, err = run_sudo(["usermod", "-aG", SFTP_GROUP, username], ADMIN_PASS)
    if code != 0:
        raise HTTPException(status_code=500, detail=err or "No se pudo asignar el grupo SFTP")


def _move_sftp_jail(old_username: str, new_username: str) -> str:
    old_jail = Path(SFTP_ROOT_DIR) / old_username
    new_jail = Path(SFTP_ROOT_DIR) / new_username
    if old_jail.exists() and old_jail != new_jail:
        code, _, err = run_sudo(["mv", str(old_jail), str(new_jail)], ADMIN_PASS)
        if code != 0:
            raise HTTPException(status_code=500, detail=err or "No se pudo mover el jail SFTP")
    return _prepare_sftp_jail(new_username, str(new_jail))


def _remove_sftp_jail(username: str) -> None:
    jail_root = Path(SFTP_ROOT_DIR) / username
    if jail_root.exists():
        code, _, err = run_sudo(["rm", "-rf", str(jail_root)], ADMIN_PASS)
        if code != 0:
            raise HTTPException(status_code=500, detail=err or "No se pudo eliminar el jail SFTP")


def _generate_keypair(username: str) -> tuple[str, str]:
    with tempfile.TemporaryDirectory(prefix=f"senderman-{username}-") as temp_dir:
        key_path = Path(temp_dir) / f"{username}-sftp"
        proc = subprocess.run(
            [
                "ssh-keygen",
                "-q",
                "-t",
                "ed25519",
                "-N",
                "",
                "-C",
                f"{username}@senderman",
                "-f",
                str(key_path),
            ],
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise HTTPException(status_code=500, detail=proc.stderr.strip() or "No se pudo generar la clave SSH")

        private_key = key_path.read_text()
        public_key = key_path.with_suffix(".pub").read_text().strip()
        return private_key, public_key


def get_current_release_tag() -> str:
    release_file = APP_ROOT / ".senderman-release"
    if not release_file.exists():
        return ""
    return release_file.read_text().strip()


def get_maintenance_state() -> dict:
    return {
        "installed": (APP_ROOT / ".senderman-installed").exists(),
        "release": get_current_release_tag(),
        "install_root": str(INSTALL_ROOT),
        "files_dir": str(FILES_DIR),
        "panel_log_exists": (APP_ROOT / "panel.log").exists(),
        "service": get_service_status(),
    }


async def run_maintenance_command(args: list[str]) -> dict:
    proc = await asyncio.create_subprocess_exec(
        *args,
        cwd=str(APP_ROOT),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    return {
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
        "stdout": stdout.decode("utf-8", errors="replace").strip(),
        "stderr": stderr.decode("utf-8", errors="replace").strip(),
    }


def get_service_status() -> dict:
    _, out, _ = run(["systemctl", "is-active", "vsftpd"])
    return {"active": out == "active", "status": out}


def get_write_enabled() -> bool:
    try:
        conf = Path(VSFTPD_CONF).read_text()
        return "write_enable=YES" in conf
    except:
        return False


def _default_user_record(
    username: str,
    *,
    locked: bool | None = None,
    write_enabled: bool | None = None,
    home_dir: str | None = None,
    public_key: str = "",
    quota_bytes: int | None = None,
    protocol: str = "SFTP",
) -> dict:
    return {
        "username": username,
        "locked": get_user_locked(username) if locked is None else locked,
        "write_enabled": get_write_enabled() if write_enabled is None else write_enabled,
        "home_dir": _user_home_dir(username) if home_dir is None and _user_exists(username) else (home_dir or ""),
        "public_key": public_key,
        "quota_bytes": 0 if quota_bytes is None else quota_bytes,
        "protocol": protocol,
    }


def _open_registry_db() -> sqlite3.Connection:
    conn = sqlite3.connect(USER_REGISTRY_DB)
    conn.row_factory = sqlite3.Row
    return conn


def _row_to_user(row: sqlite3.Row) -> dict:
    return {
        "username": row["username"],
        "locked": bool(row["locked"]),
        "write_enabled": bool(row["write_enabled"]),
        "home_dir": row["home_dir"],
        "public_key": row["public_key"],
        "quota_bytes": int(row["quota_bytes"] or 0),
        "protocol": row["protocol"],
    }


def _legacy_user_registry_records() -> list[dict]:
    try:
        if LEGACY_USER_REGISTRY_FILE.exists():
            raw = json.loads(LEGACY_USER_REGISTRY_FILE.read_text())
            users = raw if isinstance(raw, list) else []
        else:
            users = []
    except Exception:
        users = []

    normalized: list[dict] = []
    seen: set[str] = set()
    for item in users:
        if not isinstance(item, dict):
            continue
        username = str(item.get("username", "")).strip()
        if not username or username in seen:
            continue
        seen.add(username)
        normalized.append({
            "username": username,
            "locked": bool(item.get("locked", get_user_locked(username))),
            "write_enabled": bool(item.get("write_enabled", get_write_enabled() if username == FTP_USER else False)),
            "home_dir": str(item.get("home_dir", _user_home_dir(username) if _user_exists(username) else "")),
            "public_key": str(item.get("public_key", "")),
            "quota_bytes": _parse_quota_bytes(item.get("quota_bytes", 0)),
            "protocol": item.get("protocol", "SFTP"),
        })
    return normalized


def _ensure_registry_db(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS user_registry (
            username TEXT PRIMARY KEY,
            locked INTEGER NOT NULL,
            write_enabled INTEGER NOT NULL,
            home_dir TEXT NOT NULL DEFAULT '',
            public_key TEXT NOT NULL DEFAULT '',
            quota_bytes INTEGER NOT NULL DEFAULT 0,
            protocol TEXT NOT NULL
        )
        """
    )
    columns = {row[1] for row in conn.execute("PRAGMA table_info(user_registry)").fetchall()}
    if "home_dir" not in columns:
        conn.execute("ALTER TABLE user_registry ADD COLUMN home_dir TEXT NOT NULL DEFAULT ''")
    if "public_key" not in columns:
        conn.execute("ALTER TABLE user_registry ADD COLUMN public_key TEXT NOT NULL DEFAULT ''")
    if "quota_bytes" not in columns:
        conn.execute("ALTER TABLE user_registry ADD COLUMN quota_bytes INTEGER NOT NULL DEFAULT 0")
    count = conn.execute("SELECT COUNT(*) FROM user_registry").fetchone()[0]
    if count == 0:
        for record in _legacy_user_registry_records():
            conn.execute(
                """
                INSERT INTO user_registry (username, locked, write_enabled, home_dir, public_key, quota_bytes, protocol)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(username) DO UPDATE SET
                    locked = excluded.locked,
                    write_enabled = excluded.write_enabled,
                    home_dir = excluded.home_dir,
                    public_key = excluded.public_key,
                    quota_bytes = excluded.quota_bytes,
                    protocol = excluded.protocol
                """,
                (
                    record["username"],
                    int(bool(record["locked"])),
                    int(bool(record["write_enabled"])),
                    record["home_dir"],
                    record["public_key"],
                    int(record.get("quota_bytes", 0) or 0),
                    record["protocol"],
                ),
            )
    ftp_exists = conn.execute(
        "SELECT 1 FROM user_registry WHERE username = ?",
        (FTP_USER,),
    ).fetchone()
    if ftp_exists is None:
        default_record = _default_user_record(FTP_USER)
        conn.execute(
            """
            INSERT INTO user_registry (username, locked, write_enabled, home_dir, public_key, quota_bytes, protocol)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                default_record["username"],
                int(bool(default_record["locked"])),
                int(bool(default_record["write_enabled"])),
                default_record["home_dir"],
                default_record["public_key"],
                int(default_record.get("quota_bytes", 0) or 0),
                default_record["protocol"],
            ),
        )
    conn.commit()


def _upsert_user_record(conn: sqlite3.Connection, user: dict) -> None:
    conn.execute(
        """
        INSERT INTO user_registry (username, locked, write_enabled, home_dir, public_key, quota_bytes, protocol)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(username) DO UPDATE SET
            locked = excluded.locked,
            write_enabled = excluded.write_enabled,
            home_dir = excluded.home_dir,
            public_key = excluded.public_key,
            quota_bytes = excluded.quota_bytes,
            protocol = excluded.protocol
        """,
        (
            user["username"],
            int(bool(user["locked"])),
            int(bool(user["write_enabled"])),
            user.get("home_dir", ""),
            user.get("public_key", ""),
            int(user.get("quota_bytes", 0) or 0),
            user.get("protocol", "SFTP"),
        ),
    )


def get_user_registry() -> list[dict]:
    with _open_registry_db() as conn:
        _ensure_registry_db(conn)
        rows = conn.execute(
            """
            SELECT username, locked, write_enabled, home_dir, public_key, quota_bytes, protocol
            FROM user_registry
            ORDER BY CASE WHEN username = ? THEN 0 ELSE 1 END, username
            """,
            (FTP_USER,),
        ).fetchall()
    return [_row_to_user(row) for row in rows]


def _user_exists(username: str) -> bool:
    code, _, _ = run(["id", "-u", username])
    return code == 0


def _update_user_registry(username: str, updater) -> list[dict]:
    with _open_registry_db() as conn:
        _ensure_registry_db(conn)
        row = conn.execute(
            "SELECT username, locked, write_enabled, home_dir, public_key, quota_bytes, protocol FROM user_registry WHERE username = ?",
            (username,),
        ).fetchone()
        current = _row_to_user(row) if row is not None else _default_user_record(username, write_enabled=False)
        updated = updater(current)
        _upsert_user_record(conn, updated)
        conn.commit()
    return get_user_registry()


def _delete_user_registry(username: str) -> None:
    with _open_registry_db() as conn:
        _ensure_registry_db(conn)
        conn.execute("DELETE FROM user_registry WHERE username = ?", (username,))
        conn.commit()


def _active_peer_ips(port: int) -> set[str]:
    """Devuelve las IPs remotas con conexiones TCP establecidas al puerto indicado."""
    _, ss_out, _ = run(["ss", "-tnH", "state", "established", "sport", "=", f":{port}"])
    peers: set[str] = set()
    for line in ss_out.splitlines():
        match = re.search(r'\s(\d+\.\d+\.\d+\.\d+):\d+\s+(\d+\.\d+\.\d+\.\d+):\d+', line)
        if match:
            peers.add(match.group(2))
    return peers


def _tail_log(path: str, lines: int = 500) -> list[str]:
    """Lee las últimas líneas de un log protegido con sudo."""
    _, out, _ = run(["sudo", "tail", "-n", str(lines), path])
    return out.splitlines()


def get_connected_users() -> list[dict]:
    """Detecta sesiones FTP (vsftpd) y SFTP (sshd) activas."""
    results: list[dict] = []

    # ── FTP (puerto 21) ────────────────────────────────────────────────────────
    try:
        ftp_ips = _active_peer_ips(21)

        if ftp_ips:
            sessions: dict[str, dict] = {}
            for line in _tail_log(FTP_LOG, 500):
                pid_m = re.search(r'\[pid (\d+)\]', line)
                if not pid_m:
                    continue
                pid = pid_m.group(1)
                if "OK LOGIN" in line:
                    ip_m  = re.search(r'Client "([^"]+)"', line)
                    usr_m = re.search(r'\[([^\]]+)\] OK LOGIN', line)
                    time_m = re.match(r'(\w+ +\w+ +\d+ +\d+:\d+:\d+ \d+)', line)
                    if ip_m and usr_m:
                        sessions[pid] = {
                            "pid":      pid,
                            "user":     usr_m.group(1),
                            "ip":       ip_m.group(1),
                            "since":    time_m.group(1) if time_m else "—",
                            "protocol": "FTP",
                        }
                elif "421 Timeout" in line or "DISCONNECT" in line:
                    sessions.pop(pid, None)
            results += [v for v in sessions.values() if v["ip"] in ftp_ips]
    except Exception:
        pass

    # ── SFTP (puerto 2222) ─────────────────────────────────────────────────────
    try:
        sftp_ips = _active_peer_ips(22) | _active_peer_ips(2222)
        if sftp_ips:
            sessions: dict[str, dict] = {}
            for line in _tail_log("/var/log/auth.log", 500):
                if "Accepted" not in line or " for " not in line or " from " not in line:
                    continue
                ip_m = re.search(r' from (\d+\.\d+\.\d+\.\d+) port ', line)
                usr_m = re.search(r'Accepted \w+ for (\S+)', line)
                time_m = re.match(r'([A-Z][a-z]{2} +\d+ +\d+:\d+:\d+)', line)
                pid_m = re.search(r'sshd\[(\d+)\]', line)
                if not ip_m or not usr_m:
                    continue
                ip = ip_m.group(1)
                if ip not in sftp_ips:
                    continue
                sessions[ip] = {
                    "pid": pid_m.group(1) if pid_m else "—",
                    "user": usr_m.group(1),
                    "ip": ip,
                    "since": time_m.group(1) if time_m else "—",
                    "protocol": "SFTP",
                }
            results += list(sessions.values())
    except Exception:
        pass

    return results


def get_user_locked(username: str) -> bool:
    try:
        rc, shadow_out, _ = run(["sudo", "getent", "shadow", username])
        if rc != 0:
            return True
        if shadow_out:
            fields = shadow_out.split(":", 2)
            if len(fields) >= 2:
                password_field = fields[1]
                return password_field.startswith("!") or password_field.startswith("*")
    except Exception:
        return True

    return True


# ── Rutas HTTP ─────────────────────────────────────────────────────────────────
@app.get("/", response_class=HTMLResponse)
async def dashboard(_: str = Depends(verify)):
    return HTMLResponse(content=HTML_FILE.read_text())


@app.get("/api/status")
async def api_status(_: str = Depends(verify)):
    return {
        **get_service_status(),
        "write_enabled": get_write_enabled(),
        "connected_users": get_connected_users(),
        "user_locked": get_user_locked(FTP_USER),
        "users": get_user_registry(),
        "maintenance": get_maintenance_state(),
    }


@app.get("/api/users")
async def api_users(_: str = Depends(verify)):
    return {"users": get_user_registry()}


@app.get("/api/users/{username}")
async def api_user_detail(username: str, _: str = Depends(verify)):
    users = get_user_registry()
    user = next((item for item in users if item["username"] == username), None)
    if user is None and not _user_exists(username):
        raise HTTPException(status_code=404, detail="El usuario no existe")

    if user is None:
        user = _default_user_record(username, locked=get_user_locked(username), write_enabled=False)

    return {
        **user,
        "home_dir": user.get("home_dir") or (_user_home_dir(username) if _user_exists(username) else ""),
    }


@app.post("/api/users/create")
async def api_create_user(request: Request, _: str = Depends(verify)):
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="JSON inválido")

    username = str(payload.get("username", "")).strip()
    public_key = str(payload.get("public_key", "")).strip()
    generate_keypair = bool(payload.get("generate_keypair", True))
    home_dir = str(payload.get("home_dir", "")).strip()
    quota_bytes = _parse_quota_bytes(payload.get("quota_bytes", 0))

    if not username or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", username):
        raise HTTPException(status_code=400, detail="Nombre de usuario inválido")

    if home_dir and not Path(home_dir).is_absolute():
        raise HTTPException(status_code=400, detail="El directorio de inicio debe ser una ruta absoluta")

    users = get_user_registry()
    if any(user["username"] == username for user in users):
        raise HTTPException(status_code=409, detail="El usuario ya está registrado en el panel")
    if _user_exists(username):
        raise HTTPException(status_code=409, detail="El usuario ya existe en el sistema")

    jail_root = _normalize_sftp_home_dir(username, home_dir)
    useradd_command = [USERADD_BIN, "-M", "-d", jail_root, "-s", "/usr/sbin/nologin", username]

    code, _, err = run_sudo(useradd_command, ADMIN_PASS)
    if code != 0:
        raise HTTPException(status_code=500, detail=err or "No se pudo crear el usuario en el sistema")

    _ensure_sftp_group_membership(username)
    jail_root = _prepare_sftp_jail(username, jail_root)

    private_key = ""
    normalized_public_key = ""
    if public_key:
        normalized_public_key = _normalize_public_key_text(public_key)
        _install_public_key(username, normalized_public_key)
    elif generate_keypair:
        private_key, normalized_public_key = _generate_keypair(username)
        _install_public_key(username, normalized_public_key)
    else:
        raise HTTPException(status_code=400, detail="Debes proporcionar una clave pública o pedir que el panel genere una")

    quota_applied = _apply_user_quota(username, quota_bytes)

    users.append(_default_user_record(username, write_enabled=False, home_dir=jail_root, public_key=normalized_public_key, quota_bytes=quota_bytes))
    _save_user_registry(users)
    return {"ok": True, "user": username, "private_key": private_key, "public_key": normalized_public_key, "quota_bytes": quota_bytes, "quota_applied": quota_applied}


@app.post("/api/users/register")
async def api_register_user(request: Request, _: str = Depends(verify)):
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="JSON inválido")

    username = str(payload.get("username", "")).strip()
    if not username or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", username):
        raise HTTPException(status_code=400, detail="Nombre de usuario inválido")

    users = get_user_registry()
    if any(user["username"] == username for user in users):
        raise HTTPException(status_code=409, detail="El usuario ya está registrado")

    if not _user_exists(username):
        raise HTTPException(status_code=404, detail="El usuario no existe en el sistema")

    _ensure_sftp_group_membership(username)
    jail_root = _prepare_sftp_jail(username)

    users.append(_default_user_record(username, write_enabled=False, home_dir=jail_root, quota_bytes=0))
    _save_user_registry(users)
    return {"ok": True, "user": username}


@app.put("/api/users/{username}")
async def api_update_user(username: str, request: Request, _: str = Depends(verify)):
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="JSON inválido")

    if username == FTP_USER:
        raise HTTPException(status_code=400, detail="El usuario principal no se puede editar desde este formulario")

    new_username = str(payload.get("new_username", username)).strip() or username
    home_dir = str(payload.get("home_dir", "")).strip()
    public_key = str(payload.get("public_key", "")).strip()
    quota_bytes = _parse_quota_bytes(payload.get("quota_bytes", 0))
    locked = payload.get("locked")
    write_enabled = payload.get("write_enabled")

    if not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", new_username):
        raise HTTPException(status_code=400, detail="Nombre de usuario inválido")
    jail_root = _normalize_sftp_home_dir(new_username, home_dir or None)

    users = get_user_registry()
    current = next((user for user in users if user["username"] == username), None)
    if current is None and not _user_exists(username):
        raise HTTPException(status_code=404, detail="El usuario no existe")
    if new_username != username and any(user["username"] == new_username for user in users):
        raise HTTPException(status_code=409, detail="El nombre de usuario ya existe en el panel")
    if new_username != username and _user_exists(new_username):
        raise HTTPException(status_code=409, detail="El nombre de usuario ya existe en el sistema")

    rename_required = new_username != username
    if rename_required:
        rename_command = ["usermod", "-l", new_username, "-d", jail_root, username]
        code, _, err = run_sudo(rename_command, ADMIN_PASS)
        if code != 0:
            raise HTTPException(status_code=500, detail=err or "No se pudo renombrar el usuario")
        registry_username = new_username
        jail_root = _move_sftp_jail(username, new_username)
    else:
        registry_username = username
        code, _, err = run_sudo(["usermod", "-d", jail_root, username], ADMIN_PASS)
        if code != 0:
            raise HTTPException(status_code=500, detail=err or "No se pudo cambiar el directorio de inicio")
        jail_root = _prepare_sftp_jail(registry_username, jail_root)

    _ensure_sftp_group_membership(registry_username)

    if public_key:
        normalized_public_key = _normalize_public_key_text(public_key)
        _install_public_key(registry_username, normalized_public_key)
    else:
        normalized_public_key = current["public_key"] if current is not None else ""

    if locked is not None:
        desired_locked = bool(locked)
        lock_command = ["usermod", "-L" if desired_locked else "-U", registry_username]
        code, _, err = run_sudo(lock_command, ADMIN_PASS)
        if code != 0:
            raise HTTPException(status_code=500, detail=err or "No se pudo cambiar el estado del usuario")

    if write_enabled is not None:
        desired_write = bool(write_enabled)
        def updater(item: dict) -> dict:
            item["write_enabled"] = desired_write
            item["home_dir"] = jail_root
            item["public_key"] = normalized_public_key
            item["quota_bytes"] = quota_bytes
            return item

        _update_user_registry(registry_username, updater)
    else:
        def updater(item: dict) -> dict:
            item["home_dir"] = jail_root
            item["public_key"] = normalized_public_key
            item["quota_bytes"] = quota_bytes
            return item

        _update_user_registry(registry_username, updater)

    quota_applied = _apply_user_quota(registry_username, quota_bytes)

    if rename_required and registry_username != username:
        _delete_user_registry(username)

    return {"ok": True, "username": registry_username, "quota_bytes": quota_bytes, "quota_applied": quota_applied}


@app.delete("/api/users/{username}")
async def api_delete_user(username: str, remove_home: bool = True, _: str = Depends(verify)):
    if username == FTP_USER:
        raise HTTPException(status_code=400, detail="El usuario principal no se puede eliminar desde el panel")
    if not _user_exists(username):
        raise HTTPException(status_code=404, detail="El usuario no existe en el sistema")

    command = ["sudo", "userdel"]
    if remove_home:
        command.append("-r")
    command.append(username)
    code, _, err = run_sudo(command[1:], ADMIN_PASS)
    if code != 0:
        raise HTTPException(status_code=500, detail=err or "No se pudo eliminar el usuario")

    _remove_sftp_jail(username)

    _delete_user_registry(username)
    return {"ok": True, "username": username}


@app.get("/api/users/{username}/keys")
async def api_user_keys(username: str, _: str = Depends(verify)):
    users = get_user_registry()
    user = next((item for item in users if item["username"] == username), None)
    if user is None and not _user_exists(username):
        raise HTTPException(status_code=404, detail="El usuario no existe")
    if user is None:
        user = _default_user_record(username, locked=get_user_locked(username), write_enabled=False)
    return {"username": username, "public_key": user.get("public_key", "")}


@app.post("/api/users/{username}/keys")
async def api_set_user_key(username: str, request: Request, _: str = Depends(verify)):
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="JSON inválido")

    public_key = str(payload.get("public_key", "")).strip()
    if not _user_exists(username):
        raise HTTPException(status_code=404, detail="El usuario no existe")

    normalized_public_key = _normalize_public_key_text(public_key)
    _install_public_key(username, normalized_public_key)
    _update_user_registry(username, lambda item: {**item, "public_key": normalized_public_key})
    return {"ok": True, "username": username, "public_key": normalized_public_key}


@app.post("/api/users/{username}/keys/generate")
async def api_generate_user_key(username: str, _: str = Depends(verify)):
    if not _user_exists(username):
        raise HTTPException(status_code=404, detail="El usuario no existe")

    private_key, public_key = _generate_keypair(username)
    _install_public_key(username, public_key)
    _update_user_registry(username, lambda item: {**item, "public_key": public_key})
    return {"ok": True, "username": username, "private_key": private_key, "public_key": public_key}


@app.post("/api/service/{action}")
async def api_service(action: str, _: str = Depends(verify)):
    if action not in ("start", "stop", "restart"):
        raise HTTPException(status_code=400, detail="Acción inválida")
    code, _, err = run(["sudo", "systemctl", action, "vsftpd"])
    if code != 0:
        raise HTTPException(status_code=500, detail=err)
    return {"ok": True, "action": action}


@app.post("/api/write/{state}")
async def api_write(state: str, _: str = Depends(verify)):
    return await api_user_write(FTP_USER, state, _)


@app.post("/api/users/{username}/write/{state}")
async def api_user_write(username: str, state: str, _: str = Depends(verify)):
    if state not in ("on", "off"):
        raise HTTPException(status_code=400)
    try:
        desired = state == "on"

        def updater(item: dict) -> dict:
            item["write_enabled"] = desired
            return item

        _update_user_registry(username, updater)

        if username == FTP_USER:
            conf = Path(VSFTPD_CONF).read_text()
            if desired:
                new_conf = re.sub(r'write_enable=\w+', 'write_enable=YES', conf)
            else:
                new_conf = re.sub(r'write_enable=\w+', 'write_enable=NO', conf)
            proc = subprocess.run(["sudo", "tee", VSFTPD_CONF],
                                  input=new_conf.encode(), capture_output=True)
            if proc.returncode != 0:
                raise Exception(proc.stderr.decode())
            run(["sudo", "systemctl", "restart", "vsftpd"])

        return {"ok": True, "username": username, "write_enabled": desired}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/user/{action}")
async def api_user(action: str, _: str = Depends(verify)):
    return await api_user_action(FTP_USER, action, _)


@app.post("/api/users/{username}/{action}")
async def api_user_action(username: str, action: str, _: str = Depends(verify)):
    if action not in ("lock", "unlock"):
        raise HTTPException(status_code=400)
    flag = "-L" if action == "lock" else "-U"
    code, _, err = run_sudo(["usermod", flag, username], ADMIN_PASS)
    if code != 0:
        raise HTTPException(status_code=500, detail=err)

    desired = action == "lock"

    def updater(item: dict) -> dict:
        item["locked"] = desired
        return item

    _update_user_registry(username, updater)
    return {"ok": True, "username": username, "locked": desired}


@app.get("/api/files")
async def api_files(path: str = "", _: str = Depends(verify)):
    try:
        base = Path(FILES_DIR).resolve()
        base.mkdir(parents=True, exist_ok=True)
        current_dir = _safe_files_path(path)
        if not current_dir.exists() or not current_dir.is_dir():
            raise HTTPException(status_code=404, detail="La carpeta no existe")

        entries = []
        for item in sorted(current_dir.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower())):
            st = item.stat()
            rel = str(item.relative_to(base))
            entries.append({
                "path": rel,
                "name": item.name,
                "size": format_bytes(st.st_size) if item.is_file() else "—",
                "raw_size": st.st_size if item.is_file() else 0,
                "is_dir": item.is_dir(),
                "modified": datetime.fromtimestamp(st.st_mtime).strftime("%d/%m/%Y %H:%M"),
            })

        current_rel = "" if current_dir == base else str(current_dir.relative_to(base))
        parent_rel = "" if current_dir == base else ("" if current_dir.parent == base else str(current_dir.parent.relative_to(base)))

        return {
            "current_path": current_rel,
            "parent_path": parent_rel,
            "entries": entries,
        }
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/files/download")
async def api_files_download(path: str, _: str = Depends(verify)):
    try:
        target = _safe_files_path(path)
        if not target.exists():
            raise HTTPException(status_code=404, detail="El archivo no existe")

        if target.is_dir():
            temp_zip = Path(tempfile.NamedTemporaryFile(prefix="senderman-files-", suffix=".zip", delete=False).name)
            temp_zip.unlink(missing_ok=True)
            zip_path = shutil.make_archive(str(temp_zip.with_suffix("")), "zip", root_dir=str(target.parent), base_dir=target.name)
            return FileResponse(
                zip_path,
                filename=f"{target.name}.zip",
                media_type="application/zip",
                background=BackgroundTask(Path(zip_path).unlink, missing_ok=True),
            )

        media_type = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
        return FileResponse(target, filename=target.name, media_type=media_type)
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/files/upload")
async def api_files_upload(path: str = "", files: list[UploadFile] = File(...), _: str = Depends(verify)):
    try:
        base = Path(FILES_DIR).resolve()
        base.mkdir(parents=True, exist_ok=True)
        target_dir = _safe_files_path(path)
        target_dir.mkdir(parents=True, exist_ok=True)
        uploaded: list[str] = []

        for file in files:
            relative_path = _normalize_upload_relative_path(file.filename)
            destination = (target_dir / relative_path).resolve()
            if base not in destination.parents and destination != base:
                raise HTTPException(status_code=400, detail="Nombre de archivo inválido")
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open("wb") as handle:
                handle.write(await file.read())
            uploaded.append(str(destination.relative_to(base)))

        return {"ok": True, "uploaded": uploaded}
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/maintenance")
async def api_maintenance(_: str = Depends(verify)):
    return get_maintenance_state()


@app.post("/api/maintenance/install")
async def api_maintenance_install(_: str = Depends(verify)):
    result = await run_maintenance_command(["bash", "install.sh", "--service", "--latest-release", "--server"])
    if not result["ok"]:
        raise HTTPException(status_code=500, detail=result["stderr"] or result["stdout"] or "No se pudo completar la instalación")
    return result


@app.post("/api/maintenance/update")
async def api_maintenance_update(_: str = Depends(verify)):
    result = await run_maintenance_command(["bash", "tools/update.sh", "--latest-release"])
    if not result["ok"]:
        raise HTTPException(status_code=500, detail=result["stderr"] or result["stdout"] or "No se pudo completar la actualización")
    return result


@app.post("/api/maintenance/uninstall")
async def api_maintenance_uninstall(keep_config: bool = True, _: str = Depends(verify)):
    command = ["bash", "install.sh", "--uninstall"]
    if keep_config:
        command.append("--keep-config")
    result = await run_maintenance_command(command)
    if not result["ok"]:
        raise HTTPException(status_code=500, detail=result["stderr"] or result["stdout"] or "No se pudo completar la desinstalación")
    return result


# ── WebSocket — log en tiempo real ─────────────────────────────────────────────
@app.websocket("/ws/logs")
async def ws_logs(ws: WebSocket):
    await ws.accept()
    try:
        proc = await asyncio.create_subprocess_exec(
            "sudo", "/usr/local/bin/senderman-log-stream",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            while True:
                try:
                    line = await asyncio.wait_for(proc.stdout.readline(), timeout=20)
                    if line:
                        await ws.send_text(line.decode("utf-8", errors="replace").strip())
                    else:
                        break
                except asyncio.TimeoutError:
                    await ws.send_text("__ping__")
        finally:
            proc.terminate()
    except WebSocketDisconnect:
        pass
    except Exception:
        pass


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8080, reload=False)
