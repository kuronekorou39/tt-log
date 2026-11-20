"""見どころの候補（☆）を選ぶ。

2026-11-20 の練習で、ゲームポイントやデュースなどの状況から選んだものは「いらない」、
長いラリーは「いい感じ」だった。なので候補は長いラリーだけにする。
最後に決めるのは見た人（ページで ★ を付ける）。
"""

# これ以上続いたラリーを候補にする（秒。サーブのトスから最後の打球音まで）
LONG_RALLY = 9.0


def candidates(games: list[dict]) -> list[str]:
    """候補の点の名前（"ゲーム番号-何点目"。ページの印と同じ形）。"""
    out = []
    for g in games:
        for k, p in enumerate(g["points"]):
            r = p.get("rally")
            if r and r["end"] - r["start"] >= LONG_RALLY:
                out.append(f"{g['index'] + 1}-{k + 1}")
    return out
