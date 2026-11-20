"""スコアボード（iPad）が残した声の録音を、ゲームの動画に合わせた1本の音声にする。

iPad は発話ごとに直前数秒の音声を audio/*.wav に残している（VoiceLogs/log.tsv の「音声」列）。
つないだ受信機のマイク（胸元）の音なので、動画の音より声がはっきり聞こえる。
録音のない時間は無音。ページで動画と一緒に流す（オンとオフを切り替えられる）。
"""

import csv
import datetime as dt
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

JST = dt.timezone(dt.timedelta(hours=9))
SAMPLE_RATE = 24000


def load_log(voice_dir: Path) -> list[tuple[dt.datetime, Path]]:
    """(発話の時刻＝録音の終わり, 音声ファイル) の一覧。"""
    out = []
    with open(voice_dir / "log.tsv", encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            audio = row.get("音声") or ""
            if not audio:
                continue
            path = voice_dir / audio
            if not path.exists():
                continue
            at = dt.datetime.strptime(row["時刻"], "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=JST)
            out.append((at, path))
    return out


def build_track(log: list[tuple[dt.datetime, Path]], parts: list[dict], out: Path) -> bool:
    """parts（つないだ動画の各部分の撮り始め・位置・長さ）に合わせて音声を並べ、out（m4a）に書く。"""
    if not parts:
        return False
    total = parts[-1]["offset"] + parts[-1]["duration"]
    track = np.zeros(int(total * SAMPLE_RATE) + 1, dtype=np.float32)
    placed = 0
    for at, path in log:
        # 録音の終わりが、動画のどの部分の何秒目か
        end = None
        for p in parts:
            t = (at - p["start"]).total_seconds()
            if 0 <= t <= p["duration"]:
                end = p["offset"] + t
                break
        if end is None:
            continue
        x, sr = sf.read(path, dtype="float32", always_2d=True)
        mono = x[:, 0]
        if sr != SAMPLE_RATE:
            g = np.gcd(sr, SAMPLE_RATE)
            mono = resample_poly(mono, SAMPLE_RATE // g, sr // g).astype(np.float32)
        i1 = int(end * SAMPLE_RATE)
        i0 = i1 - len(mono)
        a, b = max(i0, 0), min(i1, len(track))
        if a >= b:
            continue
        # 前後の録音が重なるところは同じ音なので、上書きでよい
        track[a:b] = mono[a - i0 : b - i0]
        placed += 1
    if not placed:
        return False
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        wav = Path(f.name)
    sf.write(wav, track, SAMPLE_RATE)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(wav), "-c:a", "aac", "-b:a", "64k", str(out)], check=True)
    wav.unlink()
    return True
