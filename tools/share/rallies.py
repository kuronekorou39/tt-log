"""動画の音から、ボールを打つ音（と台に弾む音）を拾ってラリーに分け、得点に結びつける。

得点の時刻は「声で言った・画面を押した」時刻なので、ラリーより少し後になる。
声が通らずにあとで続けて押した点は、何点ぶんも同じ時刻になる。
そこで、前の点からその点までの間に起きたラリーのうち最後のもの（続けて押した n 点なら最後の n 本）を、その点のラリーとみなす。
0-0 でネット（レット）が続いても、最後のラリーが点になったものなので、それを選ぶ。
"""

import subprocess
from pathlib import Path

import numpy as np
from scipy.ndimage import median_filter
from scipy.signal import butter, find_peaks, sosfilt

SAMPLE_RATE = 24000
# 打球音は高い音が鋭く立ち上がる。声や足音の低い音を落とす
HIGHPASS_HZ = 2500
FRAME = 0.005
# 周りの音（1秒の中央値）より、これだけ大きければ打球音とみなす（dB）
HIT_MARGIN_DB = 15
MIN_HIT_GAP = 0.12
# 打球音の間がこれより空いたら別のラリー（秒）
RALLY_GAP = 1.6
# ラリーとみなす打球音の数（サーブ＋台で2つ、返球で3つ目）
MIN_HITS = 3
# 前の点を言った直後の音（拾う・弾ませる）を避ける（秒）
AFTER_PREVIOUS = 1.0
# サーブのトスは最初の打球音より少し前
TOSS = 1.2


def load_audio(video: Path) -> np.ndarray:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(video), "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "-"],
        capture_output=True, check=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32)


def hit_times(audio: np.ndarray) -> np.ndarray:
    y = sosfilt(butter(4, HIGHPASS_HZ, "hp", fs=SAMPLE_RATE, output="sos"), audio)
    hop = int(SAMPLE_RATE * FRAME)
    n = len(y) // hop
    env = np.sqrt((y[: n * hop].reshape(n, hop) ** 2).mean(axis=1))
    db = 20 * np.log10(env + 1e-9)
    onset = db - median_filter(db, size=int(1 / FRAME))
    peaks, _ = find_peaks(onset, height=HIT_MARGIN_DB, distance=int(MIN_HIT_GAP / FRAME))
    return peaks * FRAME


def clusters(hits: np.ndarray, lo: float, hi: float) -> list[list[float]]:
    out: list[list[float]] = []
    for t in hits[(hits > lo) & (hits <= hi)]:
        if out and t - out[-1][-1] < RALLY_GAP:
            out[-1].append(float(t))
        else:
            out.append([float(t)])
    return [c for c in out if len(c) >= MIN_HITS]


def attach_rallies(video: Path, points: list[dict]) -> None:
    """points（vt = 動画の中で点が入った秒）に rally = {start, end, hits} を付ける。見つからなければ付けない。"""
    hits = hit_times(load_audio(video))
    i = 0
    prev = 0.0
    while i < len(points):
        if points[i]["vt"] is None:
            i += 1
            continue
        # 同じ時刻（1秒以内）に続けて入れた点をまとめる
        j = i
        while j + 1 < len(points) and points[j + 1]["vt"] is not None and points[j + 1]["vt"] - points[i]["vt"] < 1.0:
            j += 1
        end = points[j]["vt"]
        found = clusters(hits, prev + AFTER_PREVIOUS if i else 0.0, end)
        group = points[i : j + 1]
        for p, c in zip(group[::-1], found[::-1]):
            p["rally"] = {"start": max(0.0, c[0] - TOSS), "end": c[-1], "hits": len(c)}
        prev = end
        i = j + 1
