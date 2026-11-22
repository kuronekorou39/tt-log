"""受け取った記録を、まとめにしてドライブへ置く。

1. make_share で動画をつなぎ、小さい動画と字幕を作る
2. faces で顔の位置を探す
3. make_share で顔の位置をページのデータに入れる
4. rclone でドライブへ置く（local/receiver.json の rclone_remote があるとき）

無料のドライブに収めるため、元の動画は新しい keep_full 回分だけ置く。古い回の元動画はドライブから
完全に消す（ゴミ箱も容量に数えられるため）。PC の share/ には残す。
"""

import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHARE = ROOT / "share"
TOOLS = ROOT / "tools" / "share"
APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
JST = dt.timezone(dt.timedelta(hours=9))
FULL_VIDEO = "videos/game[0-9][0-9].mp4"
SESSION_NAME = re.compile(r"\d{4}-\d{2}-\d{2}(?:-\d+)?")


class StepError(Exception):
    """アプリに見せる短い失敗の理由。"""


def run(cmd: list[str], log: Path, failure: str):
    env = dict(os.environ, PYTHONUTF8="1")
    with open(log, "a", encoding="utf-8") as f:
        f.write(f"\n$ {' '.join(cmd)}\n")
        f.flush()
        code = subprocess.run(cmd, cwd=ROOT, env=env, stdout=f, stderr=subprocess.STDOUT).returncode
    if code:
        raise StepError(failure)


def output(cmd: list[str], failure: str) -> str:
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
    if r.returncode:
        raise StepError(failure)
    return r.stdout


def out_folder(session: dict, sid: str) -> Path:
    """日付のフォルダ。同じ日に別の記録があれば -2, -3 と続ける。"""
    started = (APPLE_EPOCH + dt.timedelta(seconds=session["log"]["startedAt"])).astimezone(JST)
    base, n = f"{started:%Y-%m-%d}", 1
    while True:
        out = SHARE / (base if n == 1 else f"{base}-{n}")
        index = out / "data" / "camera-index.json"
        if not out.exists():
            return out
        if index.exists() and json.loads(index.read_text(encoding="utf-8")).get("id", "").upper() == sid:
            return out
        n += 1


def upload(out: Path, remote: str, keep_full: int, stage):
    rclone = shutil.which("rclone")
    if not rclone:
        raise StepError("rclone がありません")
    remote = remote.rstrip("/")
    output([rclone, "mkdir", f"{remote}/"], "ドライブを読めません")
    listed = output([rclone, "lsf", f"{remote}/", "--dirs-only"], "ドライブを読めません")
    names = {n.rstrip("/") for n in listed.splitlines() if SESSION_NAME.fullmatch(n.rstrip("/"))} | {out.name}
    newest = sorted(names, reverse=True)[:keep_full]

    # 先に古い回の元動画を消して、空きを作る。PC に元があり、ドライブに小さい版がそろっている回だけ
    for name in names - set(newest) - {out.name}:
        local = {p.name for p in (SHARE / name / "videos").glob("game[0-9][0-9].mp4")}
        small = set(output([rclone, "lsf", f"{remote}/{name}/videos-small/", "--files-only"], "ドライブを読めません").split())\
            if local else set()
        full = set(output([rclone, "lsf", f"{remote}/{name}/videos/", "--files-only", "--include", "game[0-9][0-9].mp4"],
                          "ドライブを読めません").split()) if local else set()
        if full and full <= local and full <= small:
            output([rclone, "delete", f"{remote}/{name}", "--include", f"/{FULL_VIDEO}", "--drive-use-trash=false"],
                   "古い動画を消せません")

    files = [p for p in out.rglob("*") if p.is_file()]
    wanted = [p for p in files if p.parent.name == "videos-small" or p.name.endswith("-voice.m4a")]
    if out.name in newest:
        wanted += list((out / "videos").glob("game[0-9][0-9].mp4"))
    page = out / "data" / "page.json"
    about = json.loads(output([rclone, "about", f"{remote}/", "--json"], "ドライブの空きを確認できません"))
    if "free" in about and about["free"] < sum(p.stat().st_size for p in wanted) + page.stat().st_size:
        raise StepError("ドライブの空きが足りません")

    stage("ドライブへ配置中")
    rels = "\n".join(p.relative_to(out).as_posix() for p in wanted)
    listing = out.parent / f".upload-{out.name}.txt"
    listing.write_text(rels + "\n", encoding="utf-8")
    try:
        output([rclone, "copy", str(out), f"{remote}/{out.name}", "--files-from", str(listing)], "ドライブに置けません")
    finally:
        listing.unlink(missing_ok=True)
    # ページは page.json を見て回を見つけるので、動画がそろってから最後に置く
    output([rclone, "copyto", str(page), f"{remote}/{out.name}/data/page.json"], "ドライブに置けません")


def process(folder: Path, camera_same_side: bool, config: dict, stage):
    session = json.loads((folder / "scoreboard" / "session.json").read_text(encoding="utf-8"))
    out = out_folder(session, folder.name)
    log = folder / "pipeline.log"
    base = [sys.executable, str(TOOLS / "make_share.py"), "--session-json", str(folder / "scoreboard" / "session.json"),
            "--camera", str(folder / "camera"), "--out", str(out)]
    if (folder / "scoreboard" / "voice" / "log.tsv").exists():
        base += ["--voice", str(folder / "scoreboard" / "voice")]
    if camera_same_side:
        base.append("--camera-same-side")

    stage("動画を作成中")
    run([*base, "--small"], log, "動画を作れませんでした")
    stage("顔の位置を検出中")
    run([sys.executable, str(TOOLS / "faces.py"), str(out)], log, "顔の検出に失敗しました")
    stage("まとめを作成中")
    run([*base, "--no-video"], log, "まとめを作れませんでした")
    if config.get("rclone_remote"):
        upload(out, config["rclone_remote"], max(1, int(config.get("keep_full", 1))), stage)
