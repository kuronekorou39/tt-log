"""iPad / iPhone のアプリから記録を受け取り、2台分そろったら処理する窓口（同じ Wi-Fi の中だけ）。

使い方:
    python tools/receiver/receiver.py

画面に出る6桁のコードを、アプリの「PCへ送る」で最初に1度だけ入れる。
受け取ったものは local/inbox/<記録のID>/ に置く（git 管理外）。設定は local/receiver.json。
"""

import hashlib
import hmac
import json
import queue
import re
import secrets
import shutil
import socket
import sys
import threading
import traceback

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).parent))
import pipeline  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "local" / "receiver.json"
INBOX = ROOT / "local" / "inbox"

PORT = 52741
SERVICE = "_ttlog-recv._tcp.local."
CHUNK_MAX = 16 * 1024 * 1024
JSON_MAX = 1024 * 1024
FILE_MAX = 64 * 1024 ** 3
DISK_MARGIN = 5 * 1024 ** 3     # 処理で増える分の余裕
PAIR_TRIES = 5                  # これだけ間違えたらコードを変える

ROLES = ("camera", "scoreboard")
# 受け取ってよいファイル。これ以外の場所には書かない
ALLOWED = {
    "camera": re.compile(r"index\.json|[A-Za-z0-9_-]+\.(?:mov|mp4)"),
    "scoreboard": re.compile(r"session\.json|voice/log\.tsv|voice/audio/[A-Za-z0-9_-]+\.wav"),
}
ROUTE = re.compile(r"/v1/sessions/([0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12})(?:/(camera|scoreboard))?/(manifest|file|complete|status)")

lock = threading.RLock()
jobs: queue.Queue[str] = queue.Queue()


def load_config() -> dict:
    cfg = {"tokens": {}, "rclone_remote": "", "keep_full": 1}
    if CONFIG.exists():
        cfg.update(json.loads(CONFIG.read_text(encoding="utf-8")))
    return cfg


def write_json(path: Path, data: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    work = path.with_suffix(".tmp")
    work.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
    work.replace(path)


config = load_config()


class Pairing:
    def __init__(self):
        self.renew()

    def renew(self):
        self.code = f"{secrets.randbelow(10 ** 6):06d}"
        self.misses = 0
        print(f"\nペアリングのコード: {self.code}\n", flush=True)

    def attempt(self, code: str, device: str) -> str | None:
        with lock:
            if not hmac.compare_digest(code.encode(), self.code.encode()):
                self.misses += 1
                if self.misses >= PAIR_TRIES:
                    self.renew()
                return None
            token = secrets.token_urlsafe(32)
            config["tokens"][hashlib.sha256(token.encode()).hexdigest()] = device[:80]
            write_json(CONFIG, config)
            print(f"つなぎました: {device[:80]}", flush=True)
            self.renew()
            return token


pairing = Pairing()


def session_dir(sid: str) -> Path:
    return INBOX / sid


def read_state(sid: str) -> dict:
    path = session_dir(sid) / "state.json"
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"state": "receiving", "message": "", "camera": False, "scoreboard": False, "dirty": True, "cameraSameSide": False}


def save_state(sid: str, state: dict):
    write_json(session_dir(sid) / "state.json", state)


def public(state: dict) -> dict:
    return {k: state.get(k) for k in ("state", "message", "camera", "scoreboard")}


def target(sid: str, role: str, rel: str) -> Path:
    if not ALLOWED[role].fullmatch(rel):
        raise ValueError(rel)
    return session_dir(sid) / role / rel


def received(path: Path, size: int) -> int:
    """届いているバイト数。大きさが違う古いものは捨てる（作り直された log.tsv など）。"""
    part = path.with_name(path.name + ".part")
    if path.exists():
        if path.stat().st_size == size:
            return size
        path.unlink()
    if part.exists():
        if part.stat().st_size <= size:
            return part.stat().st_size
        part.unlink()
    return 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ttlog-receiver"
    sys_version = ""

    def log_message(self, *args):
        pass

    def reply(self, code: int, data: dict):
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def refuse(self, code: int, message: str):
        # 本文を読まずに返すときは、次のリクエストとずれないよう接続を切る
        self.close_connection = True
        self.reply(code, {"error": message})

    def length(self, limit: int) -> int | None:
        try:
            n = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return None
        return n if 0 <= n <= limit else None

    def read_json(self) -> dict | None:
        n = self.length(JSON_MAX)
        if n is None:
            return None
        try:
            data = json.loads(self.rfile.read(n))
        except ValueError:
            return None
        return data if isinstance(data, dict) else None

    def authorized(self) -> bool:
        head = self.headers.get("Authorization", "")
        if not head.startswith("Bearer "):
            return False
        digest = hashlib.sha256(head[7:].encode()).hexdigest()
        return any(hmac.compare_digest(digest, t) for t in config["tokens"])

    def do_GET(self):
        url = urlsplit(self.path)
        if not self.authorized():
            return self.refuse(401, "unauthorized")
        if url.path == "/v1/ping":
            return self.reply(200, {"ok": True})
        m = ROUTE.fullmatch(url.path)
        if not m or m[2] or m[3] != "status":
            return self.refuse(404, "not found")
        with lock:
            return self.reply(200, public(read_state(m[1])))

    def do_POST(self):
        url = urlsplit(self.path)
        if url.path == "/v1/pair":
            data = self.read_json()
            if not data or not isinstance(data.get("code"), str):
                return self.refuse(400, "bad request")
            token = pairing.attempt(data["code"], str(data.get("device", "")))
            return self.reply(200, {"token": token}) if token else self.reply(403, {"error": "コードが違います"})
        if not self.authorized():
            return self.refuse(401, "unauthorized")
        m = ROUTE.fullmatch(url.path)
        if not m or not m[2]:
            return self.refuse(404, "not found")
        if m[3] == "manifest":
            return self.manifest(m[1], m[2])
        if m[3] == "complete":
            self.length(JSON_MAX) is not None and self.rfile.read(int(self.headers["Content-Length"]))
            return self.complete(m[1], m[2])
        return self.refuse(404, "not found")

    def do_PUT(self):
        url = urlsplit(self.path)
        if not self.authorized():
            return self.refuse(401, "unauthorized")
        m = ROUTE.fullmatch(url.path)
        if not m or not m[2] or m[3] != "file":
            return self.refuse(404, "not found")
        q = parse_qs(url.query)
        n = self.length(CHUNK_MAX)
        if n is None or not n:
            return self.refuse(413, "chunk too large")
        try:
            path = target(m[1], m[2], q["path"][0])
            offset, size = int(q["offset"][0]), int(q["size"][0])
        except (KeyError, ValueError):
            return self.refuse(400, "bad request")
        if not 0 <= offset < size <= FILE_MAX or offset + n > size:
            return self.refuse(400, "bad range")
        body = self.rfile.read(n)
        if len(body) != n:
            return self.refuse(400, "short body")
        if not hmac.compare_digest(hashlib.sha256(body).hexdigest(), self.headers.get("X-SHA256", "").lower()):
            return self.reply(422, {"error": "checksum"})
        with lock:
            state = read_state(m[1])
            if state["state"] in ("queued", "processing"):
                return self.reply(409, {"error": "処理中です"})
            have = received(path, size)
            if have != offset:
                return self.reply(409, {"received": have})
            path.parent.mkdir(parents=True, exist_ok=True)
            part = path.with_name(path.name + ".part")
            with open(part, "ab") as f:
                f.write(body)
            if offset + n == size:
                part.replace(path)
            if not state.get("dirty"):
                state["dirty"] = True
                save_state(m[1], state)
        return self.reply(200, {"received": offset + n})

    def manifest(self, sid: str, role: str):
        data = self.read_json()
        files = data.get("files") if data else None
        if not isinstance(files, list) or not files:
            return self.refuse(400, "bad manifest")
        offsets, total, clean = {}, 0, []
        with lock:
            state = read_state(sid)
            if state["state"] in ("queued", "processing"):
                return self.reply(409, {"error": "処理中です"})
            try:
                for f in files:
                    rel, size = f["path"], f["size"]
                    if not isinstance(size, int) or not 0 < size <= FILE_MAX:
                        raise ValueError(rel)
                    path = target(sid, role, rel)
                    # 記録は直されても大きさが同じことがあるので、中身で比べる
                    digest = f.get("sha256")
                    if digest and path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                        path.unlink()
                        state["dirty"] = True
                    offsets[rel] = received(path, size)
                    total += size - offsets[rel]
                    clean.append({"path": rel, "size": size})
            except (KeyError, TypeError, ValueError):
                return self.reply(400, {"error": "bad manifest"})
            required = "index.json" if role == "camera" else "session.json"
            if required not in offsets:
                return self.reply(400, {"error": "bad manifest"})
            INBOX.mkdir(parents=True, exist_ok=True)
            if shutil.disk_usage(INBOX).free < total + DISK_MARGIN:
                return self.reply(507, {"error": "PCの空きが足りません"})
            if role == "camera":
                same = bool(data.get("cameraSameSide"))
                if same != state.get("cameraSameSide"):
                    state["cameraSameSide"] = same
                    state["dirty"] = True
            state[role] = False
            save_state(sid, state)
            write_json(session_dir(sid) / f"manifest-{role}.json", {"files": clean})
        return self.reply(200, {"offsets": offsets})

    def complete(self, sid: str, role: str):
        with lock:
            state = read_state(sid)
            if state["state"] in ("queued", "processing"):
                return self.reply(200, public(state))
            listing = session_dir(sid) / f"manifest-{role}.json"
            if not listing.exists():
                return self.reply(409, {"error": "manifest がありません"})
            for f in json.loads(listing.read_text(encoding="utf-8"))["files"]:
                path = target(sid, role, f["path"])
                if not path.exists() or path.stat().st_size != f["size"]:
                    return self.reply(409, {"error": f"未着: {f['path']}"})
            state[role] = True
            if all(state[r] for r in ROLES) and (state.get("dirty") or state["state"] != "done"):
                state.update(state="queued", message="")
                jobs.put(sid)
            save_state(sid, state)
            return self.reply(200, public(state))


def worker():
    while True:
        sid = jobs.get()

        def stage(message: str):
            with lock:
                state = read_state(sid)
                state.update(state="processing", message=message)
                save_state(sid, state)
            print(f"{sid[:8]}: {message}", flush=True)

        try:
            with lock:
                same = read_state(sid).get("cameraSameSide", False)
            stage("準備中")
            pipeline.process(session_dir(sid), same, load_config(), stage)
            with lock:
                state = read_state(sid)
                state.update(state="done", message="", dirty=False)
                save_state(sid, state)
            print(f"{sid[:8]}: 完了", flush=True)
        except Exception as e:
            traceback.print_exc()
            with lock:
                state = read_state(sid)
                state.update(state="failed", message=e.args[0] if isinstance(e, pipeline.StepError) else "処理に失敗しました")
                save_state(sid, state)


def resume_jobs():
    """処理の途中で止まったものは、起動したときにやり直す。"""
    if not INBOX.exists():
        return
    for d in INBOX.iterdir():
        if (d / "state.json").exists():
            state = read_state(d.name)
            if state["state"] in ("queued", "processing"):
                state["state"] = "queued"
                save_state(d.name, state)
                jobs.put(d.name)


def local_ip() -> str:
    # 実際には送らない。外へ出るときに使う自分のアドレスを調べるだけ
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        try:
            s.connect(("192.0.2.1", 9))
            return s.getsockname()[0]
        except OSError:
            return "127.0.0.1"


def advertise(ip: str):
    """アプリが PC を自動で見つけられるよう、同じ Wi-Fi に知らせる。"""
    try:
        from zeroconf import ServiceInfo, Zeroconf
    except ImportError:
        print("zeroconf がないので自動では見つかりません（アプリに PC のアドレスを入れてください）", flush=True)
        return None
    zc = Zeroconf(interfaces=[ip])
    zc.register_service(ServiceInfo(SERVICE, f"TTLog PC.{SERVICE}", addresses=[socket.inet_aton(ip)], port=PORT,
                                    server=f"ttlog-{socket.gethostname()}.local."))
    return zc


def main():
    resume_jobs()
    threading.Thread(target=worker, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    ip = local_ip()
    zc = advertise(ip)
    print(f"受け取り中: {ip}:{PORT}（止めるときは Ctrl+C）", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if zc:
            zc.unregister_all_services()
            zc.close()


if __name__ == "__main__":
    main()
