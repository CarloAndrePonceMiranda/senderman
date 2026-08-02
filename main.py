import asyncio
import json
import os
import re
import secrets
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import Depends, FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.security import HTTPBasic, HTTPBasicCredentials


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
FILES_DIR  = os.getenv("FILES_DIR", "/home/mr-robot/senderman/files")
FTP_USER   = os.getenv("FTP_USER", "jesus12jimmy13")   # Usuario FTP principal
USER_REGISTRY_FILE = Path(__file__).parent / "users.json"

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


def format_bytes(size: int) -> str:
    for unit in ["B", "KB", "MB", "GB"]:
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


def get_service_status() -> dict:
    _, out, _ = run(["systemctl", "is-active", "vsftpd"])
    return {"active": out == "active", "status": out}


def get_write_enabled() -> bool:
    try:
        conf = Path(VSFTPD_CONF).read_text()
        return "write_enable=YES" in conf
    except:
        return False


def _default_user_record(username: str) -> dict:
    return {
        "username": username,
        "locked": get_user_locked(username),
        "write_enabled": get_write_enabled(),
        "protocol": "SFTP",
    }


def _save_user_registry(users: list[dict]) -> None:
    USER_REGISTRY_FILE.write_text(json.dumps(users, indent=2, ensure_ascii=False))


def get_user_registry() -> list[dict]:
    try:
        if USER_REGISTRY_FILE.exists():
            raw = json.loads(USER_REGISTRY_FILE.read_text())
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
            "protocol": item.get("protocol", "SFTP"),
        })

    if FTP_USER not in seen:
        normalized.insert(0, _default_user_record(FTP_USER))
        _save_user_registry(normalized)
    elif normalized != users:
        _save_user_registry(normalized)

    return normalized


def _user_exists(username: str) -> bool:
    code, _, _ = run(["id", "-u", username])
    return code == 0


def _update_user_registry(username: str, updater) -> list[dict]:
    users = get_user_registry()
    updated: list[dict] = []
    found = False
    for item in users:
        if item["username"] == username:
            item = updater(item)
            found = True
        updated.append(item)
    if not found:
        updated.append(updater(_default_user_record(username)))
    _save_user_registry(updated)
    return updated


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
        _, shadow_out, _ = run(["sudo", "getent", "shadow", username])
        if shadow_out:
            fields = shadow_out.split(":", 2)
            if len(fields) >= 2:
                password_field = fields[1]
                return password_field.startswith("!") or password_field.startswith("*")
    except Exception:
        pass

    _, out, _ = run(["passwd", "-S", username])
    parts = out.split()
    return len(parts) >= 2 and parts[1].startswith("L")


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
    }


@app.get("/api/users")
async def api_users(_: str = Depends(verify)):
    return {"users": get_user_registry()}


@app.post("/api/users/create")
async def api_create_user(request: Request, _: str = Depends(verify)):
    try:
        payload = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="JSON inválido")

    username = str(payload.get("username", "")).strip()
    password = str(payload.get("password", "")).strip()

    if not username or not re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", username):
        raise HTTPException(status_code=400, detail="Nombre de usuario inválido")
    if len(password) < 8:
        raise HTTPException(status_code=400, detail="La contraseña debe tener al menos 8 caracteres")

    users = get_user_registry()
    if any(user["username"] == username for user in users):
        raise HTTPException(status_code=409, detail="El usuario ya está registrado en el panel")
    if _user_exists(username):
        raise HTTPException(status_code=409, detail="El usuario ya existe en el sistema")

    code, _, err = run([
        "sudo", "useradd",
        "-m",
        "-s", "/usr/sbin/nologin",
        username,
    ])
    if code != 0:
        raise HTTPException(status_code=500, detail=err)

    proc = subprocess.run(
        ["sudo", "chpasswd"],
        input=f"{username}:{password}\n",
        text=True,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise HTTPException(status_code=500, detail=proc.stderr.strip() or "No se pudo establecer la contraseña")

    users.append(_default_user_record(username))
    _save_user_registry(users)
    return {"ok": True, "user": username}


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

    users.append(_default_user_record(username))
    _save_user_registry(users)
    return {"ok": True, "user": username}


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
    code, _, err = run(["sudo", "usermod", flag, username])
    if code != 0:
        raise HTTPException(status_code=500, detail=err)

    desired = action == "lock"

    def updater(item: dict) -> dict:
        item["locked"] = desired
        return item

    _update_user_registry(username, updater)
    return {"ok": True, "username": username, "locked": desired}


@app.get("/api/files")
async def api_files(_: str = Depends(verify)):
    try:
        base = Path(FILES_DIR)
        files = []
        for f in sorted(base.rglob("*"), key=lambda p: (p.is_file(), str(p).lower())):
            st = f.stat()
            rel = str(f.relative_to(base))
            files.append({
                "name":     rel,
                "size":     format_bytes(st.st_size) if f.is_file() else "—",
                "raw_size": st.st_size if f.is_file() else 0,
                "is_dir":   f.is_dir(),
                "modified": datetime.fromtimestamp(st.st_mtime).strftime("%d/%m/%Y %H:%M"),
            })
        return files
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


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
