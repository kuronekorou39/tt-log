"""練習の記録を、友人に渡せるフォルダにまとめる。

iPad のスコアボードの記録（SwiftData の default.store）と、iPhone のカメラの記録
（Sessions/<フォルダ>/index.json と動画）から、次を作る。

    <出力>/
      index.html        結果のまとめ（ブラウザで開く。動画もここから見られる）
      videos/gameNN.mp4 ゲームごとの動画（途中で分かれた録画は1本につなぐ。再エンコードしない）
      data/points.csv   1点ずつの記録
      data/session.json スコアボードの記録そのもの

使い方:
    python tools/share/make_share.py --store <default.store> --camera <Sessions/フォルダ> --out share/2026-11-20

動画をつなぐのに ffmpeg / ffprobe を使う（PATH にあること）。
ラリーを探すのに numpy / scipy を使う（rallies.py）。見どころは highlights.py で選ぶ。
"""

import argparse
import csv
import datetime as dt
import html
import json
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
import uuid

import highlights
from pathlib import Path

# SwiftData（Core Data）の日時は 2001-01-01 からの秒
APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)
JST = dt.timezone(dt.timedelta(hours=9))
POINTS_TO_WIN = 11


def apple_time(sec: float) -> dt.datetime:
    return APPLE_EPOCH + dt.timedelta(seconds=sec)


def iso_time(s: str) -> dt.datetime:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def load_session(store: Path, session_id: str):
    con = sqlite3.connect(f"file:{store}?mode=ro", uri=True)
    for zid, names_blob, log_blob in con.execute("select ZID, ZPLAYERNAMES, ZLOGDATA from ZSESSIONRECORD"):
        if str(uuid.UUID(bytes=zid)).upper() == session_id.upper():
            return player_names(names_blob), json.loads(log_blob)
    raise SystemExit(f"記録が見つかりません: {session_id}")


def player_names(blob: bytes) -> list[str]:
    """NSKeyedArchiver に包まれた JSON の配列から名前を取り出す。"""
    objects = plistlib.loads(blob).get("$objects", [])
    for o in objects:
        if isinstance(o, bytes) and o.startswith(b"["):
            return json.loads(o)
    return ["A", "B"]


def server_of(game_index: int, scores: list[int], first_server: int) -> int:
    """サーブは2本ごとに交代、10-10 以降は1本ごと。ゲームごとに最初のサーバーが入れ替わる。"""
    first = first_server if game_index % 2 == 0 else 1 - first_server
    played = scores[0] + scores[1]
    deuce = (POINTS_TO_WIN - 1) * 2
    changes = played // 2 if played < deuce else deuce // 2 + (played - deuce)
    return first if changes % 2 == 0 else 1 - first


def build_games(log: dict) -> list[dict]:
    """スコアボードの操作を順に反映して、ゲームごとの得点の並びを作る（アプリの RuleEngine と同じ規則）。"""
    first_server = log["config"]["firstServer"]
    games = [{"index": 0, "start": apple_time(log["startedAt"]), "end": None, "winner": None, "points": []}]
    scores = [0, 0]
    over = False
    for e in log["events"]:
        ev, at = e["event"], apple_time(e["at"])
        g = games[-1]
        if "point" in ev:
            if over:
                continue
            w = ev["point"]["winner"]
            server = server_of(g["index"], scores, first_server)
            scores[w] += 1
            g["points"].append({"at": at, "winner": w, "scores": list(scores), "server": server, "source": e["source"]})
            if scores[w] >= POINTS_TO_WIN and scores[w] - scores[1 - w] >= 2:
                g["end"], g["winner"], over = at, w, True
        elif "startNextGame" in ev:
            if not over and scores == [0, 0]:
                continue
            if g["end"] is None:
                g["end"] = at
            games.append({"index": g["index"] + 1, "start": at, "end": None, "winner": None, "points": []})
            scores, over = [0, 0], False
        elif "resetGame" in ev:
            if scores == [0, 0]:
                continue
            g["points"], g["end"], g["winner"] = [], None, None
            scores, over = [0, 0], False
    return [g for g in games if g["points"]]


def probe_duration(path: Path) -> float:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return float(out)


def join_videos(camera: Path, index: dict, game_index: int, out: Path, make: bool = True) -> list[dict]:
    """そのゲームの録画をつないで1本にする。各部分の（撮り始め, 動画の中での位置, 長さ）を返す。"""
    clips = [c for c in index["clips"] if c.get("gameIndex") == game_index and (camera / c["file"]).exists()]
    # game02-10 が game02-2 より前に来ないよう、番号で並べる
    clips.sort(key=lambda c: int(Path(c["file"]).stem.split("-")[-1]))
    if not clips:
        return []
    parts, offset = [], 0.0
    for c in clips:
        d = probe_duration(camera / c["file"])
        parts.append({"start": iso_time(c["startedAt"]), "offset": offset, "duration": d})
        offset += d
    out.parent.mkdir(parents=True, exist_ok=True)
    if make and not out.exists():
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as f:
            for c in clips:
                f.write(f"file '{(camera / c['file']).resolve().as_posix()}'\n")
            listing = f.name
        subprocess.run(
            # iPhone の録画には映像・音声のほかに時刻などのデータの流れがあり、mp4 に入らないので映像と音声だけ
            ["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing,
             "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy", "-tag:v", "hvc1", "-movflags", "+faststart", str(out)],
            check=True,
        )
        Path(listing).unlink()
    return parts


def video_time(parts: list[dict], at: dt.datetime) -> float | None:
    """その時刻が、つないだ動画の何秒目か。録画の切れ目に落ちたら次の部分の頭。"""
    for p in parts:
        t = (at - p["start"]).total_seconds()
        if t < 0:
            return p["offset"]
        if t <= p["duration"]:
            return p["offset"] + t
    return None


def stats(games: list[dict]) -> list[dict]:
    s = [{"points": 0, "srvWon": 0, "srvAll": 0, "rcvWon": 0, "rcvAll": 0, "run": 0} for _ in range(2)]
    run, runner = 0, None
    for g in games:
        run, runner = 0, None
        for p in g["points"]:
            w, sv = p["winner"], p["server"]
            s[w]["points"] += 1
            s[sv]["srvAll"] += 1
            s[1 - sv]["rcvAll"] += 1
            if w == sv:
                s[w]["srvWon"] += 1
            else:
                s[w]["rcvWon"] += 1
            run = run + 1 if w == runner else 1
            runner = w
            s[w]["run"] = max(s[w]["run"], run)
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--store", required=True, type=Path, help="iPad の default.store")
    ap.add_argument("--camera", required=True, type=Path, help="iPhone の Sessions/<フォルダ>")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--no-video", action="store_true", help="動画を新しく作らない（まとめだけ作り直す）")
    ap.add_argument("--no-rally", action="store_true", help="動画の音からラリーを探さない")
    args = ap.parse_args()

    index = json.loads((args.camera / "index.json").read_text(encoding="utf-8"))
    names, log = load_session(args.store, index["id"])
    games = build_games(log)

    out = args.out
    (out / "data").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.camera / "index.json", out / "data" / "camera-index.json")
    (out / "data" / "session.json").write_text(json.dumps(log, ensure_ascii=False, indent=1), encoding="utf-8")

    for g in games:
        name = f"game{g['index'] + 1:02d}.mp4"
        parts = join_videos(args.camera, index, g["index"], out / "videos" / name, make=not args.no_video)
        g["video"] = f"videos/{name}" if parts or (out / "videos" / name).exists() else None
        g["parts"] = len(parts)
        for p in g["points"]:
            p["vt"] = video_time(parts, p["at"]) if parts else None
        if g["video"] and not args.no_rally:
            from rallies import attach_rallies
            attach_rallies(out / g["video"], g["points"])

    with open(out / "data" / "points.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["ゲーム", "点", "時刻", "取った人", names[0], names[1], "サーブ", "動画の秒", "ラリーの始まり", "ラリーの秒数"])
        for g in games:
            for k, p in enumerate(g["points"], 1):
                w.writerow([g["index"] + 1, k, p["at"].astimezone(JST).strftime("%H:%M:%S"), names[p["winner"]],
                            p["scores"][0], p["scores"][1], names[p["server"]],
                            "" if p["vt"] is None else f"{p['vt']:.1f}",
                            f"{p['rally']['start']:.1f}" if p.get("rally") else "",
                            f"{p['rally']['end'] - p['rally']['start']:.1f}" if p.get("rally") else ""])

    write_html(out / "index.html", names, log, games)
    print(f"できました: {out.resolve()}")


def write_html(path: Path, names: list[str], log: dict, games: list[dict]):
    started = apple_time(log["startedAt"]).astimezone(JST)
    won = [sum(1 for g in games if g["winner"] == p) for p in range(2)]
    st = stats(games)
    data = [{
        "n": g["index"] + 1,
        "video": g["video"],
        "winner": g["winner"],
        "final": g["points"][-1]["scores"],
        "minutes": round(((g["end"] or g["points"][-1]["at"]) - g["points"][0]["at"]).total_seconds() / 60),
        "points": [{"w": p["winner"], "s": p["scores"], "sv": p["server"], "vt": p["vt"],
                    "r": [round(p["rally"]["start"], 2), round(p["rally"]["end"], 2)] if p.get("rally") else None,
                    "t": p["at"].astimezone(JST).strftime("%H:%M:%S")} for p in g["points"]],
    } for g in games]

    def pct(a, b):
        return f"{round(100 * a / b)}%" if b else "—"

    rows = "".join(
        f"<tr><th>{html.escape(names[i])}</th><td>{st[i]['points']}</td>"
        f"<td>{pct(st[i]['srvWon'], st[i]['srvAll'])} <small>({st[i]['srvWon']}/{st[i]['srvAll']})</small></td>"
        f"<td>{pct(st[i]['rcvWon'], st[i]['rcvAll'])} <small>({st[i]['rcvWon']}/{st[i]['rcvAll']})</small></td>"
        f"<td>{st[i]['run']}</td></tr>"
        for i in range(2)
    )
    page = (Path(__file__).with_name("template.html")).read_text(encoding="utf-8").replace("{{TITLE}}", f"{started:%Y-%m-%d} 卓球")
    page = page.replace("{{DATE}}", f"{started:%Y年%m月%d日 %H:%M}")
    page = page.replace("{{A}}", html.escape(names[0])).replace("{{B}}", html.escape(names[1]))
    page = page.replace("{{WA}}", str(won[0])).replace("{{WB}}", str(won[1]))
    page = page.replace("{{STATS}}", rows)
    page = page.replace("{{DATA}}", json.dumps({"names": names, "games": data, "highlights": highlights.pick(games)}, ensure_ascii=False))
    path.write_text(page, encoding="utf-8")


if __name__ == "__main__":
    main()
