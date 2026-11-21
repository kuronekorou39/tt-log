"""練習の記録を、友人に渡せるフォルダにまとめる。

iPad のスコアボードの記録（SwiftData の default.store）と、iPhone のカメラの記録
（Sessions/<フォルダ>/index.json と動画）から、次を作る。

    <出力>/
      index.html        結果のまとめ（ブラウザで開く。動画もここから見られる）
      videos/gameNN.mp4 ゲームごとの動画（途中で分かれた録画は1本につなぐ。再エンコードしない）
      data/points.csv   1点ずつの記録
      data/session.json スコアボードの記録そのもの

使い方:
    python tools/share/make_share.py --store <default.store> --camera <Sessions/フォルダ> --voice <VoiceLogs> --out share/2026-11-20

動画をつなぐのに ffmpeg / ffprobe を使う（PATH にあること）。
ラリーを探すのに numpy / scipy を使う（rallies.py）。見どころの候補（☆）は highlights.py で選ぶ。ページで付けた印（★）は見た人のブラウザにだけ残る。
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


# H.264 の書き出し（NVIDIA の GPU を使う。画質は cq、ビットレートの上限は maxrate）
H264 = ["-c:v", "h264_nvenc", "-preset", "p5", "-rc", "vbr", "-cq", "23", "-b:v", "0", "-maxrate", "16M",
        "-bufsize", "32M", "-profile:v", "high", "-pix_fmt", "yuv420p"]


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
            # iPhone の録画には映像・音声のほかに時刻などのデータの流れがあり、mp4 に入らないので映像と音声だけ。
            # 映像は HEVC のままだと Firefox などで再生できないので H.264 にする
            ["ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", listing,
             "-map", "0:v:0", "-map", "0:a:0?", *H264, "-c:a", "copy", "-movflags", "+faststart", str(out)],
            check=True,
        )
        Path(listing).unlink()
    return parts


def video_time(parts: list[dict], at: dt.datetime, shift: list[float] | None = None) -> float | None:
    """その時刻が、つないだ動画の何秒目か。録画の切れ目に落ちたら次の部分の頭。

    shift は部分ごとの撮り始めの時刻の誤差（声の録音と照らし合わせて求めたもの）。
    """
    for k, p in enumerate(parts):
        t = (at - p["start"]).total_seconds()
        if t < 0:
            return p["offset"]
        if t <= p["duration"]:
            return p["offset"] + min(max(t + (shift[k] if shift else 0.0), 0.0), p["duration"])
    return None


# 「競り合い」とみなす点数（両方がこれ以上）
CLOSE_FROM = 9


def stats(games: list[dict]) -> list[dict]:
    s = [{"points": 0, "srvWon": 0, "srvAll": 0, "rcvWon": 0, "rcvAll": 0, "run": 0, "games": 0,
          "closeWon": 0, "lead": 0} for _ in range(2)]
    run, runner = 0, None
    for g in games:
        run, runner = 0, None
        if g["winner"] is not None:
            s[g["winner"]]["games"] += 1
        before = [0, 0]
        for p in g["points"]:
            w, sv = p["winner"], p["server"]
            # 終盤の競り合い（両方 9 点以上）で取った点
            if min(before) >= CLOSE_FROM:
                s[w]["closeWon"] += 1
            before = p["scores"]
            s[w]["lead"] = max(s[w]["lead"], before[w] - before[1 - w])
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
    ap.add_argument("--camera-same-side", action="store_true",
                    help="カメラがスコアボードと同じ向きから撮っている（動画の左にいる人＝スコアボードの左の人）")
    ap.add_argument("--voice", type=Path, help="iPad の VoiceLogs（log.tsv と audio/）。あれば声の音声と字幕を動画に重ねられる")
    ap.add_argument("--viewer", type=Path, help="Web に置く、データの入っていないページの書き出し先（例：docs/viewer/index.html）")
    args = ap.parse_args()

    index = json.loads((args.camera / "index.json").read_text(encoding="utf-8"))
    names, log = load_session(args.store, index["id"])
    games = build_games(log)
    voice_log = None
    if args.voice:
        import voice
        voice_log = voice.load_log(args.voice)

    out = args.out
    (out / "data").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.camera / "index.json", out / "data" / "camera-index.json")
    (out / "data" / "session.json").write_text(json.dumps(log, ensure_ascii=False, indent=1), encoding="utf-8")

    for g in games:
        name = f"game{g['index'] + 1:02d}.mp4"
        parts = join_videos(args.camera, index, g["index"], out / "videos" / name, make=not args.no_video)
        g["video"] = f"videos/{name}" if parts or (out / "videos" / name).exists() else None
        g["parts"] = len(parts)
        g["voice"], g["captions"], shift = None, [], None
        if voice_log and g["video"] and (out / g["video"]).exists():
            import voice
            name_v = f"game{g['index'] + 1:02d}-voice.m4a"
            matched = voice.build(voice_log, parts, out / g["video"], out / "videos" / name_v)
            if matched:
                g["voice"], g["captions"], shift = f"videos/{name_v}", matched["captions"], matched["shift"]
        for p in g["points"]:
            p["vt"] = video_time(parts, p["at"], shift) if parts else None
        if g["video"] and not args.no_rally:
            from rallies import attach_rallies
            attach_rallies(out / g["video"], g["points"])
        if g["video"] and not args.no_rally:
            for p in g["points"]:
                if "fixed_vt" in p:
                    # 続けて押した点の時刻を、ラリーが終わった時刻に直す
                    p["tapped_at"] = p["at"]
                    p["at"] = p["at"] + dt.timedelta(seconds=p["fixed_vt"] - p["vt"])
                    p["vt"] = p["fixed_vt"]
        from rallies import play_spans, point_ranges
        for p, r in zip(g["points"], point_ranges(g["points"])):
            p["range"] = r
        g["spans"] = play_spans([p["range"] for p in g["points"]])

    with open(out / "data" / "points.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["ゲーム", "点", "時刻", "取った人", names[0], names[1], "サーブ", "動画の秒", "ラリーの始まり", "ラリーの秒数",
                    "押した時刻（直す前）"])
        for g in games:
            for k, p in enumerate(g["points"], 1):
                w.writerow([g["index"] + 1, k, p["at"].astimezone(JST).strftime("%H:%M:%S"), names[p["winner"]],
                            p["scores"][0], p["scores"][1], names[p["server"]],
                            "" if p["vt"] is None else f"{p['vt']:.1f}",
                            f"{p['rally']['start']:.1f}" if p.get("rally") else "",
                            f"{p['rally']['end'] - p['rally']['start']:.1f}" if p.get("rally") else "",
                            p["tapped_at"].astimezone(JST).strftime("%H:%M:%S") if "tapped_at" in p else ""])

    for g in games:
        # スコアボードの左にいる人。ゲームごとにエンドを替える（連続形式。最終ゲームの途中の交代はない）
        first_left = log["config"]["firstLeft"]
        board_left = first_left if g["index"] % 2 == 0 else 1 - first_left
        # 2026-11-20 はカメラがスコアボードと向かい合う側にあり、左右が逆だった
        g["video_left"] = board_left if args.camera_same_side else 1 - board_left
    write_html(out / "index.html", index["id"], names, log, games)
    if args.viewer:
        write_viewer(args.viewer)
    print(f"できました: {out.resolve()}")


TEMPLATE = Path(__file__).with_name("template.html")


def write_html(path: Path, session_id: str, names: list[str], log: dict, games: list[dict]):
    started = apple_time(log["startedAt"]).astimezone(JST)
    won = [sum(1 for g in games if g["winner"] == p) for p in range(2)]
    st = stats(games)
    data = [{
        "n": g["index"] + 1,
        "video": g["video"],
        "voice": g["voice"],
        "vl": g["video_left"],
        "captions": g.get("captions", []),
        "spans": [[round(a, 2), round(b, 2)] for a, b in g["spans"]],
        "winner": g["winner"],
        "final": g["points"][-1]["scores"],
        "minutes": round(((g["end"] or g["points"][-1]["at"]) - g["points"][0]["at"]).total_seconds() / 60),
        "points": [{"w": p["winner"], "s": p["scores"], "sv": p["server"], "vt": p["vt"],
                    "r": [round(p["range"][0], 2), round(p["range"][1], 2)] if p["range"] else None,
                    "fx": "tapped_at" in p,
                    "t": p["at"].astimezone(JST).strftime("%H:%M:%S")} for p in g["points"]],
    } for g in games]

    def pct(a, b):
        return f"{round(100 * a / b)}%" if b else "—"

    def row(label, f):
        return f"<tr><th>{label}</th>" + "".join(f"<td>{f(i)}</td>" for i in range(2)) + "</tr>"

    first, last = games[0]["points"][0]["at"], games[-1]["points"][-1]["at"]
    rally_lengths = [p["rally"]["length"] for g in games for p in g["points"] if p.get("rally")]
    rows = (
        f"<p class='muted'>{len(games)}ゲーム・{sum(len(g['points']) for g in games)}点・"
        f"{round((last - first).total_seconds() / 60)}分</p>"
        f"<table class='stats'><thead><tr><th></th><th class='a'>{html.escape(names[0])}</th>"
        f"<th class='b'>{html.escape(names[1])}</th></tr></thead><tbody>"
        + row("ゲーム", lambda i: st[i]["games"])
        + row("得点", lambda i: st[i]["points"])
        + row("サーブで取った", lambda i: f"{pct(st[i]['srvWon'], st[i]['srvAll'])} <small>{st[i]['srvWon']}/{st[i]['srvAll']}</small>")
        + row("レシーブで取った", lambda i: f"{pct(st[i]['rcvWon'], st[i]['rcvAll'])} <small>{st[i]['rcvWon']}/{st[i]['rcvAll']}</small>")
        + row("最長連続", lambda i: st[i]["run"])
        + row("最大リード", lambda i: st[i]["lead"])
        + row(f"{CLOSE_FROM}-{CLOSE_FROM}以降", lambda i: st[i]["closeWon"])
        + "</tbody></table>"
        + "<table class='stats'><thead><tr><th></th><th>スコア</th><th>時間</th></tr></thead><tbody>"
        + "".join(
            f"<tr><th>第{g['index'] + 1}ゲーム</th>"
            f"<td class='{'' if g['winner'] is None else 'ab'[g['winner']]}'>{g['points'][-1]['scores'][0]} - {g['points'][-1]['scores'][1]}</td>"
            f"<td>{round(((g['end'] or g['points'][-1]['at']) - g['points'][0]['at']).total_seconds() / 60)}分</td></tr>"
            for g in games)
        + "</tbody></table>"
        + (f"<p class='muted'>ラリー（推定）：平均 {sum(rally_lengths) / len(rally_lengths):.1f}秒・最長 {max(rally_lengths):.1f}秒</p>"
           if rally_lengths else "")
    )
    content = {
        "title": f"{started:%Y-%m-%d} 卓球",
        "date": f"{started.year}年{started.month}月{started.day}日",
        "won": won,
        "stats": rows,
        "data": {"id": session_id, "names": names, "games": data, "candidates": highlights.candidates(games)},
    }
    # 顔を隠すための頭の位置（faces.py で作る）。file:// でも読めるようスクリプトで読む
    faces = sorted(path.parent.glob("data/faces-game*.js"))
    # Web に置いたページ（write_viewer）がドライブから読む。ドライブは一度に多く読むと弾くので、顔の位置も1つにまとめる
    web = dict(content, faces={})
    for f in faces:
        text = f.read_text(encoding="utf-8")
        web["faces"][int(f.stem[len("faces-game"):])] = json.loads(text[text.index("] = ") + 4 : text.rindex(";")])
    (path.parent / "data" / "page.json").write_text(json.dumps(web, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    page = TEMPLATE.read_text(encoding="utf-8")
    page = page.replace("{{FACES}}", "\n".join(f'<script src="data/{f.name}"></script>' for f in faces))
    page = page.replace("{{PAGE}}", json.dumps(content, ensure_ascii=False).replace("</", "<\\/"))
    path.write_text(page, encoding="utf-8")


def write_viewer(path: Path):
    """データの入っていないページ。Web に置き、#d=ドライブのフォルダID&k=APIキー で開く。"""
    page = TEMPLATE.read_text(encoding="utf-8").replace("{{FACES}}", "").replace("{{PAGE}}", "null")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(page, encoding="utf-8")


if __name__ == "__main__":
    main()
