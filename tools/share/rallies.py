"""動画の音から、ボールを打つ音（と台に弾む音）を拾ってラリーに分け、得点に結びつける。

得点の時刻は「声で言った・画面を押した」時刻なので、ラリーより少し後になる。
声が通らずにあとで続けて押した点は、何点ぶんも同じ時刻になる。その時刻は、選んだラリーが終わった時刻に直す（fixed_vt）。
そこで、前の点からその点までの間で、打球音がいちばん多く続いたかたまり（続けて押した n 点なら多い順に n 本）を、
その点のラリーとみなす。最後のかたまりにしないのは、ラリーのあとの球拾いの音を選んでしまうため（2026-11-20 第1ゲーム 2-1）。

見せ始めは、そのラリーを含む「音が続いている区間」の頭にする。サーブの前にボールを弾ませる音から始まるので、
サーブの構えから見られる。区間は、打球音の間が ACTIVE_GAP 秒より空いたところで切る。
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
HIT_MARGIN_DB = 12
MIN_HIT_GAP = 0.12
# ラリーの長さ（見どころの候補）は、はっきりした打球音だけで測る。弱い音まで拾うと、
# 球拾いや声かけの音がつながって長く見える（2026-11-20：良いと言われた長いラリーが候補から外れた）
CLEAR_HIT_MARGIN_DB = 15
# 打球音の間がこれより空いたら別のラリー（秒）
RALLY_GAP = 1.6
# ラリーとみなす打球音の数（サーブ＋台で2つ、返球で3つ目）
MIN_HITS = 3
# 点を入れる何秒前までのラリーを探すか（1点あたり）。ゲームの最初の点で、
# 始まる前の打ち合いを選ばないように（打ち合いは本番のラリーより長く続く）
LOOKBACK = 40.0
# 続けて押した点とみなす、押した間隔（秒）
BATCH_GAP = 3.0
# 続けて押した点の時刻は、そのラリーの最後の打球音のこれだけ後に直す
FIXED_AFTER_LAST_HIT = 0.5
# 前の点を言った直後の音（拾う・弾ませる）を避ける（秒）
AFTER_PREVIOUS = 1.0
# 「音が続いている区間」を切る間（秒）。球拾いや話している時間はこれより長い
ACTIVE_GAP = 6.0
# 区間の頭は、最初の音のこれだけ前（構えてから最初の音まで）
LEAD_IN = 3.0
# ただし見せ始めは、ラリーの最初の打球音からこれより前には戻らない（秒）。
# 練習では球拾いや声かけの音が切れ目なく続き、区間だけだとゲームの頭まで戻ってしまう
MAX_LEAD = 8.0
# ラリーの終わりから、これだけ後まで見せる
TAIL = 2.0


def load_audio(video: Path) -> np.ndarray:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(video), "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "-"],
        capture_output=True, check=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32)


def hit_times(audio: np.ndarray, margin: float = HIT_MARGIN_DB) -> np.ndarray:
    y = sosfilt(butter(4, HIGHPASS_HZ, "hp", fs=SAMPLE_RATE, output="sos"), audio)
    hop = int(SAMPLE_RATE * FRAME)
    n = len(y) // hop
    env = np.sqrt((y[: n * hop].reshape(n, hop) ** 2).mean(axis=1))
    db = 20 * np.log10(env + 1e-9)
    onset = db - median_filter(db, size=int(1 / FRAME))
    peaks, _ = find_peaks(onset, height=margin, distance=int(MIN_HIT_GAP / FRAME))
    return peaks * FRAME


def clusters(hits: np.ndarray, lo: float, hi: float, min_hits: int = MIN_HITS) -> list[list[float]]:
    out: list[list[float]] = []
    for t in hits[(hits > lo) & (hits <= hi)]:
        if out and t - out[-1][-1] < RALLY_GAP:
            out[-1].append(float(t))
        else:
            out.append([float(t)])
    return [c for c in out if len(c) >= min_hits]


def clear_length(clear: np.ndarray, lo: float, hi: float) -> float:
    """lo〜hi の中で、はっきりした打球音が続いたいちばん長いかたまりの長さ（秒）。"""
    cs = clusters(clear, lo - 0.5, hi + 0.5)
    return max((c[-1] - c[0] for c in cs), default=0.0)


def active_start(hits: np.ndarray, t: float) -> float:
    """t の打球音を含む「音が続いている区間」の頭（LEAD_IN 込み）。"""
    before = hits[hits <= t][::-1]
    start = t
    for h in before:
        if start - h > ACTIVE_GAP:
            break
        start = h
    return float(start) - LEAD_IN


def attach_rallies(video: Path, points: list[dict]) -> None:
    """points（vt = 動画の中で点が入った秒）に rally = {start, end, hits} を付ける。見つからなければ付けない。
    start は見せ始め（サーブの構え）、end は見せ終わり。"""
    audio = load_audio(video)
    hits = hit_times(audio)
    clear = hit_times(audio, CLEAR_HIT_MARGIN_DB)
    shown_until = 0.0
    i = 0
    prev = 0.0
    while i < len(points):
        if points[i]["vt"] is None:
            i += 1
            continue
        # 声が通らずに、あとで続けて押した点をまとめる
        j = i
        while j + 1 < len(points) and points[j + 1]["vt"] is not None and points[j + 1]["vt"] - points[j]["vt"] < BATCH_GAP:
            j += 1
        end = points[j]["vt"]
        group = points[i : j + 1]
        lo = max(prev + AFTER_PREVIOUS if i else 0.0, end - LOOKBACK * len(group))
        found = clusters(hits, lo, end) or clusters(hits, prev + AFTER_PREVIOUS if i else 0.0, end)
        if len(found) < len(group):
            # 続けて押した点のぶんラリーが見つからなければ、短いかたまり（サーブミスなど）も数える
            found = clusters(hits, lo, end, min_hits=2) or found
        # 打球音の多い順に点の数だけ選び、時間の順に戻す
        chosen = sorted(sorted(found, key=len)[::-1][: len(group)], key=lambda c: c[0])
        for p, c in zip(group[len(group) - len(chosen):], chosen):
            # 前の点の見せ終わりより前には戻らない（前のラリーと重ねない）
            start = max(active_start(hits, c[0]), c[0] - MAX_LEAD, shown_until, prev + AFTER_PREVIOUS if i else 0.0, 0.0)
            p["rally"] = {"start": start, "end": c[-1] + TAIL, "hits": len(c), "length": clear_length(clear, c[0], c[-1])}
            shown_until = c[-1] + TAIL
            if len(group) > 1:
                # 続けて押した点は、押した時刻ではなくラリーが終わった時刻に直す
                p["fixed_vt"] = c[-1] + FIXED_AFTER_LAST_HIT
        prev = end
        i = j + 1


# 「間を飛ばす」で残す長さ。1点あたり、点を入れた時刻からこれだけ前まで（サーブの構え＋ラリー＋少しの間）
KEEP_PER_POINT = 25.0
# 点を入れた後に残す長さ（秒）
KEEP_AFTER = 1.5


def play_spans(points: list[dict]) -> list[list[float]]:
    """試合をしている区間（動画の秒）。点を入れた時刻だけから決める（打球音は話し声や足音と区別しきれず、
    ラリーを切ってしまうため。2026-11-20 第1ゲーム 7-5、第4ゲーム 3-2）。

    前の点からこの点までを、1点あたり KEEP_PER_POINT 秒まで残す。続けて押した n 点は n 倍まで。
    飛ぶのは、ゲーム前の打ち合い・休憩・長い話など、点と点の間が長く空いたところだけ。"""
    spans: list[list[float]] = []
    prev = None
    i = 0
    vts = [p["vt"] for p in points]
    while i < len(vts):
        if vts[i] is None:
            i += 1
            continue
        j = i
        while j + 1 < len(vts) and vts[j + 1] is not None and vts[j + 1] - vts[j] < BATCH_GAP:
            j += 1
        end = vts[j]
        start = end - KEEP_PER_POINT * (j - i + 1)
        if prev is not None:
            start = max(start, prev)
        span = [max(0.0, start), end + KEEP_AFTER]
        if spans and span[0] <= spans[-1][1]:
            spans[-1][1] = span[1]
        else:
            spans.append(span)
        prev = end
        i = j + 1
    return spans
