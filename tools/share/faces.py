"""動画から頭の位置を追い、ページで顔を隠すためのデータにする。

顔だけを探すと、後ろや横を向いたときに見失う。人の骨格（鼻・目・耳・肩）を見つけて、
向きに関係なく頭の位置と大きさを決める。PyTorch（torchvision）の Keypoint R-CNN を使う。

出力は data/faces-gameNN.js（file:// で開いても読めるよう、JSON ではなくスクリプト）。
  window.FACES[n] = {fps, frames: [[[x, y, r, 番号], ...], ...], tracks: {番号: {side, t0, t1, n, img}}}
x, y は頭の中心、r は半径。動画の幅・高さを 1 とした割合。
番号は同じ人として続いている頭（トラック）。side は台の左の人（L）・右の人（R）・それ以外（X）の見立て。
"""

import json
import subprocess
from pathlib import Path

import numpy as np

# 1秒に何コマ調べるか（ページでは間をなめらかにつなぐ）
FPS = 10
# 調べるときの大きさ（奥の人の顔が小さいので、縮めすぎない）
WIDTH, HEIGHT = 1280, 720
# 人とみなす確からしさ
MIN_PERSON = 0.7
# 見失っても、これだけのコマは前の位置で隠し続ける
HOLD_FRAMES = 8
# 前のコマの頭と同じ人とみなす距離（画面の幅に対する割合）
MATCH_DIST = 0.08
# 隠す円を、見つけた頭より少し大きく
MARGIN = 1.3

# COCO の骨格の番号
HEAD = [0, 1, 2, 3, 4]  # 鼻・目・耳
SHOULDERS = [5, 6]


def _model():
    import torch
    from torchvision.models.detection import KeypointRCNN_ResNet50_FPN_Weights, keypointrcnn_resnet50_fpn

    device = "cuda" if torch.cuda.is_available() else "cpu"
    m = keypointrcnn_resnet50_fpn(weights=KeypointRCNN_ResNet50_FPN_Weights.DEFAULT).to(device).eval()
    return m, device


def _frames(video: Path):
    proc = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", str(video), "-vf", f"fps={FPS},scale={WIDTH}:{HEIGHT}",
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        stdout=subprocess.PIPE,
    )
    size = WIDTH * HEIGHT * 3
    while True:
        buf = proc.stdout.read(size)
        if len(buf) < size:
            break
        yield np.frombuffer(buf, dtype=np.uint8).reshape(HEIGHT, WIDTH, 3)
    proc.wait()


def _heads(out: dict) -> list[list[float]]:
    """1コマの検出結果から、頭ごとの [x, y, r]（ピクセル）。"""
    heads = []
    for box, score, kp in zip(out["boxes"], out["scores"], out["keypoints"]):
        if score < MIN_PERSON:
            continue
        box, kp = box.tolist(), kp.tolist()
        head = np.array([kp[i][:2] for i in HEAD])
        shoulders = np.array([kp[i][:2] for i in SHOULDERS])
        cx, cy = head.mean(axis=0)
        # 頭の大きさ：鼻・目・耳の広がり、肩幅、体の高さのうち大きいものから
        spread = np.ptp(head, axis=0).max()
        shoulder = np.linalg.norm(shoulders[0] - shoulders[1])
        height = box[3] - box[1]
        base = max(shoulder * 0.35, height * 0.07)
        # 体の一部だけが映ると点が散らばるので、広がりは肩幅などの倍までに
        r = min(max(spread * 0.9, base), base * 2) * MARGIN
        # 同じ頭を二重に見つけたら、一つにまとめる
        if any(np.hypot(cx - h[0], cy - h[1]) < max(r, h[2]) * 0.7 for h in heads):
            continue
        heads.append([float(cx), float(cy), float(r)])
    return heads


# 同じ人として、見失ってもこれだけのコマまでは探し続ける（隠すのは HOLD_FRAMES まで）
REID_FRAMES = 30
# これより短いトラックは、誤検知とみなして「その他」にする（コマ数）
MIN_PLAYER_FRAMES = 15
# 一覧に出す切り抜きの大きさ
THUMB = 64


def _track(per_frame: list[list[list[float]]]) -> tuple[list[list[list]], dict]:
    """コマごとの頭をつないで番号を付ける。少し見失ったところは前の位置で埋める。

    返り値は（コマごとの [x, y, r, 番号]、番号ごとの {コマ数, 始め, 終わり, 一番大きく映ったコマと位置}）。"""
    tracks: list[dict] = []
    info: dict[int, dict] = {}
    out = []
    next_id = 1
    for k, heads in enumerate(per_frame):
        used = set()
        # 最近まで見えていたものから先に割り当てる
        for tr in sorted(tracks, key=lambda t: t["missed"]):
            best, dist = None, MATCH_DIST * WIDTH * (1 + 0.1 * tr["missed"])
            for j, h in enumerate(heads):
                d = np.hypot(h[0] - tr["pos"][0], h[1] - tr["pos"][1])
                if j not in used and d < dist:
                    best, dist = j, d
            if best is None:
                tr["missed"] += 1
            else:
                used.add(best)
                tr["pos"], tr["missed"] = heads[best], 0
                i = info[tr["id"]]
                i["n"] += 1
                i["t1"] = k
                if heads[best][2] > i["best"][3]:
                    i["best"] = [k, *heads[best]]
        tracks = [tr for tr in tracks if tr["missed"] <= REID_FRAMES]
        for j, h in enumerate(heads):
            if j not in used:
                tracks.append({"id": next_id, "pos": h, "missed": 0})
                info[next_id] = {"n": 1, "t0": k, "t1": k, "best": [k, *h], "xs": []}
                next_id += 1
        frame = []
        for tr in tracks:
            if tr["missed"] > HOLD_FRAMES:
                continue
            x, y, r = tr["pos"]
            if tr["missed"] == 0:
                info[tr["id"]]["xs"].append(x / WIDTH)
            # 見失っている間は少しずつ大きくして、動いても外れにくく
            frame.append([round(x / WIDTH, 4), round(y / HEIGHT, 4), round(r * (1 + 0.08 * tr["missed"]) / WIDTH, 4), tr["id"]])
        out.append(frame)
    return out, info


def _side(info: dict) -> str:
    """トラックが、台の左の人（L）か右の人（R）か、それ以外（X）か。"""
    if info["n"] < MIN_PLAYER_FRAMES:
        return "X"
    return "L" if np.median(info["xs"]) < 0.5 else "R"


def _thumbs(video: Path, info: dict) -> dict[int, str]:
    """トラックごとに、一番大きく映ったコマの頭を切り抜いた小さな画像（data URL）。"""
    import base64

    import cv2

    out = {}
    for tid, i in info.items():
        k, x, y, r = i["best"]
        raw = subprocess.run(
            ["ffmpeg", "-v", "error", "-ss", f"{k / FPS:.2f}", "-i", str(video), "-frames:v", "1",
             "-vf", f"scale={WIDTH}:{HEIGHT}", "-f", "rawvideo", "-pix_fmt", "bgr24", "-"],
            capture_output=True,
        ).stdout
        if len(raw) < WIDTH * HEIGHT * 3:
            continue
        img = np.frombuffer(raw[: WIDTH * HEIGHT * 3], np.uint8).reshape(HEIGHT, WIDTH, 3)
        a = max(int(r * 1.1), 8)
        x0, y0 = max(int(x) - a, 0), max(int(y) - a, 0)
        crop = img[y0 : int(y) + a, x0 : int(x) + a]
        if crop.size == 0:
            continue
        ok, jpg = cv2.imencode(".jpg", cv2.resize(crop, (THUMB, THUMB)), [cv2.IMWRITE_JPEG_QUALITY, 70])
        if ok:
            out[tid] = "data:image/jpeg;base64," + base64.b64encode(jpg.tobytes()).decode()
    return out


def detect(video: Path, cache: Path) -> list[list[list[float]]]:
    """コマごとの頭（ピクセル）。時間がかかるので cache に残し、あれば使う。"""
    if cache.exists():
        return json.loads(cache.read_text(encoding="utf-8"))
    import torch

    model, device = _model()
    per_frame = []
    with torch.no_grad():
        for rgb in _frames(video):
            x = torch.from_numpy(rgb.copy()).to(device).permute(2, 0, 1).float() / 255
            per_frame.append([[round(v, 1) for v in h] for h in _heads(model([x])[0])])
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(per_frame, separators=(",", ":")), encoding="utf-8")
    return per_frame


def find_heads(video: Path, cache: Path) -> dict:
    frames, info = _track(detect(video, cache))
    thumbs = _thumbs(video, info)
    tracks = {
        tid: {"side": _side(i), "t0": round(i["t0"] / FPS, 1), "t1": round(i["t1"] / FPS, 1), "n": i["n"],
              "img": thumbs.get(tid)}
        for tid, i in info.items()
    }
    return {"fps": FPS, "frames": frames, "tracks": tracks}


def write_script(data: dict, game: int, path: Path) -> None:
    path.write_text(
        f"(window.FACES = window.FACES || {{}})[{game}] = {json.dumps(data, separators=(',', ':'))};\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    import argparse

    ap = argparse.ArgumentParser(description="まとめの動画から頭の位置を探して data/faces-gameNN.js に書く")
    ap.add_argument("out", type=Path, help="まとめのフォルダ（videos/ と data/ がある）")
    ap.add_argument("--games", type=int, nargs="*", help="ゲームの番号（なければ全部）")
    args = ap.parse_args()
    videos = sorted((args.out / "videos").glob("game[0-9][0-9].mp4"))
    for v in videos:
        n = int(v.stem[4:])
        if args.games and n not in args.games:
            continue
        # 見つけた頭は、共有するフォルダの外（隣）に残す
        cache = args.out.parent / ".faces-cache" / args.out.name / f"game{n:02d}.json"
        data = find_heads(v, cache)
        write_script(data, n, args.out / "data" / f"faces-game{n:02d}.js")
        sides = [t["side"] for t in data["tracks"].values()]
        print(f"game{n}: frames={len(data['frames'])} tracks={len(sides)} L={sides.count('L')} R={sides.count('R')}", flush=True)
