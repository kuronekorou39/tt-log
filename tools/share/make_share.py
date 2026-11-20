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


def join_videos(camera: Path, index: dict, game_index: int, out: Path) -> list[dict]:
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
    if not out.exists():
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
    ap.add_argument("--no-video", action="store_true", help="動画をつながない（まとめだけ作り直す）")
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
        parts = [] if args.no_video else join_videos(args.camera, index, g["index"], out / "videos" / name)
        g["video"] = f"videos/{name}" if parts or (out / "videos" / name).exists() else None
        g["parts"] = len(parts)
        for p in g["points"]:
            p["vt"] = video_time(parts, p["at"]) if parts else None

    with open(out / "data" / "points.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["ゲーム", "点", "時刻", "取った人", names[0], names[1], "サーブ", "動画の秒"])
        for g in games:
            for k, p in enumerate(g["points"], 1):
                w.writerow([g["index"] + 1, k, p["at"].astimezone(JST).strftime("%H:%M:%S"), names[p["winner"]],
                            p["scores"][0], p["scores"][1], names[p["server"]],
                            "" if p["vt"] is None else f"{p['vt']:.1f}"])

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
    page = TEMPLATE.replace("{{TITLE}}", f"{started:%Y-%m-%d} 卓球")
    page = page.replace("{{DATE}}", f"{started:%Y年%m月%d日 %H:%M}")
    page = page.replace("{{A}}", html.escape(names[0])).replace("{{B}}", html.escape(names[1]))
    page = page.replace("{{WA}}", str(won[0])).replace("{{WB}}", str(won[1]))
    page = page.replace("{{STATS}}", rows)
    page = page.replace("{{DATA}}", json.dumps({"names": names, "games": data}, ensure_ascii=False))
    path.write_text(page, encoding="utf-8")


TEMPLATE = """<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{TITLE}}</title>
<style>
:root { --bg:#f6f7f9; --card:#fff; --fg:#1d2330; --muted:#6b7280; --line:#e5e7eb; --a:#d1495b; --b:#2e86ab; --hl:#fff4d6; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#111418; --card:#1a1f26; --fg:#e7e9ee; --muted:#9aa3af; --line:#2b323c; --a:#ef6f7f; --b:#5bb3d6; --hl:#3a3320; }
}
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font-family: system-ui, -apple-system, "Hiragino Sans", "Yu Gothic UI", sans-serif; }
main { max-width: 1100px; margin: 0 auto; padding: 20px 16px 60px; }
header { display:flex; flex-wrap:wrap; align-items:baseline; justify-content:space-between; gap:8px; }
h1 { font-size: 1.1rem; font-weight:600; color:var(--muted); margin:0; }
.total { font-size: 2.2rem; font-weight: 800; letter-spacing: .02em; }
.total .a { color: var(--a); } .total .b { color: var(--b); }
.card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:14px; margin-top:16px; }
table { width:100%; border-collapse: collapse; }
th, td { padding:8px 6px; border-bottom:1px solid var(--line); text-align:center; font-variant-numeric: tabular-nums; }
th:first-child, td:first-child { text-align:left; }
small { color: var(--muted); }
.games tr { cursor:pointer; }
.games tr.sel { background: var(--hl); }
.win-a { color: var(--a); font-weight:700; } .win-b { color: var(--b); font-weight:700; }
.layout { display:grid; grid-template-columns: minmax(0, 2fr) minmax(0, 1fr); gap:16px; }
@media (max-width: 800px) { .layout { grid-template-columns: 1fr; } }
video { width:100%; border-radius:8px; background:#000; aspect-ratio:16/9; }
.novideo { padding:40px; text-align:center; color:var(--muted); }
.plist { max-height: 460px; overflow:auto; }
.plist button { display:flex; width:100%; gap:10px; align-items:center; border:0; background:none; color:inherit;
  padding:6px 8px; border-bottom:1px solid var(--line); font: inherit; text-align:left; cursor:pointer; }
.plist button:hover { background: var(--hl); }
.plist button:disabled { cursor: default; opacity:.6; }
.dot { width:10px; height:10px; border-radius:50%; flex: none; }
.sc { font-weight:700; font-variant-numeric: tabular-nums; min-width: 3.5em; }
.flow { width:100%; height:70px; display:block; }
.legend { display:flex; gap:14px; font-size:.85rem; color:var(--muted); margin-top:6px; }
</style>
</head>
<body>
<main>
<header>
  <h1>{{DATE}}</h1>
  <div class="total"><span class="a">{{A}} {{WA}}</span> - <span class="b">{{WB}} {{B}}</span></div>
</header>

<div class="card">
  <table class="games" id="games"><thead><tr><th>ゲーム</th><th>スコア</th><th>時間</th><th>流れ</th></tr></thead><tbody></tbody></table>
  <div class="legend"><span>流れ：上が {{A}}、下が {{B}} のリード</span></div>
</div>

<div class="layout">
  <div class="card">
    <div id="player"></div>
  </div>
  <div class="card">
    <div class="plist" id="plist"></div>
  </div>
</div>

<div class="card">
  <table>
    <thead><tr><th></th><th>得点</th><th>サーブで取った</th><th>レシーブで取った</th><th>最長連続</th></tr></thead>
    <tbody>{{STATS}}</tbody>
  </table>
</div>
</main>

<script>
const DATA = {{DATA}};
const COLORS = ['var(--a)', 'var(--b)'];
// 点を取ったのはラリーの終わり。少し前から見せる
const LEAD = 8;
let current = 0;

function flow(g) {
  const w = 220, h = 70, n = g.points.length;
  let max = 3;
  const ds = g.points.map(p => p.s[0] - p.s[1]);
  ds.forEach(d => max = Math.max(max, Math.abs(d)));
  const x = i => (i + 1) / n * (w - 4) + 2, y = d => h / 2 - d / max * (h / 2 - 4);
  let path = `M2 ${h / 2}`;
  ds.forEach((d, i) => path += ` L${x(i).toFixed(1)} ${y(d).toFixed(1)}`);
  return `<svg class="flow" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none"><line x1="0" x2="${w}" y1="${h/2}" y2="${h/2}" stroke="currentColor" opacity=".2"/><path d="${path}" fill="none" stroke="currentColor" stroke-width="2" vector-effect="non-scaling-stroke"/></svg>`;
}

function renderGames() {
  const tb = document.querySelector('#games tbody');
  tb.innerHTML = DATA.games.map((g, i) => {
    const cls = g.winner === null ? '' : (g.winner === 0 ? 'win-a' : 'win-b');
    const note = g.winner === null ? ' <small>途中</small>' : '';
    return `<tr data-i="${i}" class="${i === current ? 'sel' : ''}"><td>第${g.n}ゲーム</td>`
      + `<td class="${cls}">${g.final[0]} - ${g.final[1]}${note}</td><td>${g.minutes}分</td><td style="width:40%">${flow(g)}</td></tr>`;
  }).join('');
  tb.querySelectorAll('tr').forEach(tr => tr.onclick = () => select(+tr.dataset.i));
}

function select(i) {
  current = i;
  renderGames();
  const g = DATA.games[i];
  const pl = document.getElementById('player');
  pl.innerHTML = g.video
    ? `<video id="v" controls preload="metadata" src="${g.video}"></video>`
    : `<div class="novideo">このゲームの動画はありません</div>`;
  const list = document.getElementById('plist');
  list.innerHTML = g.points.map((p, k) =>
    `<button data-k="${k}" ${p.vt === null || !g.video ? 'disabled' : ''}>`
    + `<span class="dot" style="background:${COLORS[p.w]}"></span>`
    + `<span class="sc">${p.s[0]} - ${p.s[1]}</span>`
    + `<span>${DATA.names[p.w]}</span><small style="margin-left:auto">${p.t}</small></button>`).join('');
  list.querySelectorAll('button').forEach(b => b.onclick = () => {
    const p = g.points[+b.dataset.k];
    const v = document.getElementById('v');
    if (!v || p.vt === null) return;
    v.currentTime = Math.max(0, p.vt - LEAD);
    v.play();
  });
}

renderGames();
select(0);
</script>
</body>
</html>
"""

if __name__ == "__main__":
    main()
