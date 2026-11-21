"""動画から頭の位置を追い、ページで顔を隠すためのデータにする。

顔だけを探すと、後ろや横を向いたときに見失う。人の骨格（鼻・目・耳・肩）を見つけて、
向きに関係なく頭の位置と大きさを決める。PyTorch（torchvision）の Keypoint R-CNN を使う。

出力は data/faces-gameNN.js（file:// で開いても読めるよう、JSON ではなくスクリプト）。
  window.FACES[n] = {fps, frames: [[[x, y, r], ...], ...]}
x, y は頭の中心、r は半径。動画の幅・高さを 1 とした割合。
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


def _track(per_frame: list[list[list[float]]]) -> list[list[list[float]]]:
    """コマごとの頭をつなぎ、少し見失ったところは前の位置で埋める。"""
    tracks: list[dict] = []  # {pos, missed}
    out = []
    for heads in per_frame:
        used = set()
        for tr in tracks:
            best, dist = None, MATCH_DIST * WIDTH
            for k, h in enumerate(heads):
                d = np.hypot(h[0] - tr["pos"][0], h[1] - tr["pos"][1])
                if k not in used and d < dist:
                    best, dist = k, d
            if best is None:
                tr["missed"] += 1
            else:
                used.add(best)
                tr["pos"], tr["missed"] = heads[best], 0
        tracks = [tr for tr in tracks if tr["missed"] <= HOLD_FRAMES]
        tracks += [{"pos": h, "missed": 0} for k, h in enumerate(heads) if k not in used]
        out.append([
            [round(tr["pos"][0] / WIDTH, 4), round(tr["pos"][1] / HEIGHT, 4),
             # 見失っている間は少しずつ大きくして、動いても外れにくく
             round(tr["pos"][2] * (1 + 0.08 * tr["missed"]) / WIDTH, 4)]
            for tr in tracks
        ])
    return out


def find_heads(video: Path) -> dict:
    import torch

    model, device = _model()
    per_frame = []
    with torch.no_grad():
        for rgb in _frames(video):
            x = torch.from_numpy(rgb.copy()).to(device).permute(2, 0, 1).float() / 255
            per_frame.append(_heads(model([x])[0]))
    return {"fps": FPS, "frames": _track(per_frame)}


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
        data = find_heads(v)
        write_script(data, n, args.out / "data" / f"faces-game{n:02d}.js")
        print(f"第{n}ゲーム: {len(data['frames'])}コマ", flush=True)
