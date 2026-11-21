"""スコアボード（iPad）が残した声の録音と聞き取った言葉を、ゲームの動画に合わせる。

iPad は発話ごとに直前数秒の音声を audio/*.wav に残している（VoiceLogs/log.tsv の「音声」列）。
録画の撮り始めの時刻は秒までしかないので、時刻だけで並べると少しずれる。
そこで、録音の声と動画の音（同じ声が小さく入っている）を照らし合わせて位置を決める。
決めた位置から、動画に重ねる音声（m4a）と字幕（聞き取った言葉）を作る。
"""

import csv
import datetime as dt
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import butter, fftconvolve, resample_poly, sosfiltfilt

JST = dt.timezone(dt.timedelta(hours=9))
SAMPLE_RATE = 24000
# 照らし合わせは声の帯域だけ、軽いサンプリングで
MATCH_RATE = 8000
VOICE_BAND = (300, 3400)
# 時刻から決めた位置の前後どこまで探すか（秒）
SEARCH = 2.5
# これより似ていなければ、その録音の照らし合わせは使わない（胸元とカメラでは音がかなり違うので低め）
MIN_MATCH = 0.06
# 字幕を、声が終わってから残す長さ（秒）
CAPTION_HOLD = 1.5


def load_log(voice_dir: Path) -> list[dict]:
    """発話ごとに {at: 録音の終わりの時刻, path: 音声, text: 聞き取った言葉} 。"""
    out = []
    with open(voice_dir / "log.tsv", encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            audio = row.get("音声") or ""
            if not audio or not (voice_dir / audio).exists():
                continue
            at = dt.datetime.strptime(row["時刻"], "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=JST)
            out.append({"at": at, "path": voice_dir / audio, "text": (row.get("第1候補") or "").strip()})
    return out


def _read_mono(path: Path, rate: int) -> np.ndarray:
    x, sr = sf.read(path, dtype="float32", always_2d=True)
    mono = x[:, 0]
    if sr != rate:
        g = np.gcd(sr, rate)
        mono = resample_poly(mono, rate // g, sr // g).astype(np.float32)
    return mono


def _video_audio(video: Path) -> np.ndarray:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(video), "-vn", "-ac", "1", "-ar", str(MATCH_RATE), "-f", "f32le", "-"],
        capture_output=True, check=True,
    ).stdout
    return np.frombuffer(raw, dtype=np.float32)


_BAND = butter(4, VOICE_BAND, btype="band", fs=MATCH_RATE, output="sos")


def _match(snippet: np.ndarray, ref: np.ndarray) -> tuple[int, float]:
    """ref の中で snippet が一番よく重なる位置と、その似ている度合い（0〜1）。"""
    n = len(snippet)
    if len(ref) < n or n == 0:
        return 0, 0.0
    a = snippet - snippet.mean()
    corr = fftconvolve(ref, a[::-1], mode="valid")
    # ref 側の各位置の大きさでならす
    c2 = np.concatenate([[0.0], np.cumsum(ref.astype(np.float64) ** 2)])
    energy = np.sqrt(np.maximum(c2[n:] - c2[:-n], 1e-12)) * np.sqrt((a ** 2).sum() + 1e-12)
    score = corr / energy
    i = int(np.argmax(score))
    return i, float(score[i])


def _speech_start(mono: np.ndarray, rate: int) -> float:
    """録音の中で声が始まる秒（大きい音の 1/10 を超えたところ）。"""
    hop = rate // 50
    frames = len(mono) // hop
    if frames == 0:
        return 0.0
    level = np.sqrt((mono[: frames * hop].reshape(frames, hop) ** 2).mean(axis=1))
    above = np.nonzero(level > level.max() * 0.1)[0]
    return float(above[0] * hop / rate) if len(above) else 0.0


def _place(at: dt.datetime, parts: list[dict]) -> tuple[int, float] | None:
    """時刻が、つないだ動画のどの部分の何秒目か。"""
    for k, p in enumerate(parts):
        t = (at - p["start"]).total_seconds()
        if 0 <= t <= p["duration"]:
            return k, p["offset"] + t
    return None


def build(log: list[dict], parts: list[dict], video: Path, out: Path | None) -> dict | None:
    """動画に合わせて録音を並べる。out があれば音声（m4a）を書く。

    返り値は {captions: [[始め, 終わり, 言葉]], shift: [部分ごとのずれ（秒）]}。
    shift は「時刻から決めた位置」に足すと実際の位置になる値。
    """
    if not parts:
        return None
    first, last = parts[0]["start"], parts[-1]["start"] + dt.timedelta(seconds=parts[-1]["duration"])
    items = [e for e in log if first <= e["at"] <= last]
    if not items:
        return None

    ref = sosfiltfilt(_BAND, _video_audio(video)).astype(np.float32)
    placed = []
    for e in items:
        where = _place(e["at"], parts)
        if where is None:
            continue
        k, end = where
        mono = _read_mono(e["path"], SAMPLE_RATE)
        small = sosfiltfilt(_BAND, _read_mono(e["path"], MATCH_RATE)).astype(np.float32)
        start = end - len(small) / MATCH_RATE
        lo = max(0, int((start - SEARCH) * MATCH_RATE))
        hi = min(len(ref), int((end + SEARCH) * MATCH_RATE))
        i, score = _match(small, ref[lo:hi])
        lag = (lo + i) / MATCH_RATE - start if score >= MIN_MATCH else None
        placed.append({**e, "part": k, "end": end, "mono": mono, "lag": lag})

    # 部分ごとのずれ（撮り始めの時刻の誤差）は一定なので、よく合った録音の中央値をとる
    shift = []
    for k in range(len(parts)):
        lags = [p["lag"] for p in placed if p["part"] == k and p["lag"] is not None]
        shift.append(float(np.median(lags)) if lags else None)
    known = [s for s in shift if s is not None]
    fallback = float(np.median(known)) if known else 0.0
    shift = [fallback if s is None else s for s in shift]

    total = parts[-1]["offset"] + parts[-1]["duration"]
    track = np.zeros(int(total * SAMPLE_RATE) + 1, dtype=np.float32)
    captions = []
    for p in placed:
        # 中央値から大きく外れた照らし合わせは、似た別の音を拾ったとみなす
        lag = p["lag"] if p["lag"] is not None and abs(p["lag"] - shift[p["part"]]) < 0.5 else shift[p["part"]]
        end = p["end"] + lag
        i1 = int(end * SAMPLE_RATE)
        i0 = i1 - len(p["mono"])
        a, b = max(i0, 0), min(i1, len(track))
        if a < b:
            # 前後の録音が重なるところは同じ音なので、上書きでよい
            track[a:b] = p["mono"][a - i0 : b - i0]
        if p["text"]:
            begin = end - len(p["mono"]) / SAMPLE_RATE + _speech_start(p["mono"], SAMPLE_RATE)
            captions.append([round(max(begin, 0), 2), round(end + CAPTION_HOLD, 2), p["text"]])

    # 次の字幕が出たら前の字幕は消す
    for c, nxt in zip(captions, captions[1:]):
        c[1] = min(c[1], nxt[0])

    if out is not None:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            wav = Path(f.name)
        sf.write(wav, track, SAMPLE_RATE)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-c:a", "aac", "-b:a", "64k", str(out)], check=True)
        wav.unlink()
    return {"captions": captions, "shift": shift}
