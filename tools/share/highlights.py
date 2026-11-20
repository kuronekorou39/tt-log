"""見どころの候補（☆）を選ぶ。

2026-11-20 の練習で、ゲームポイントやデュースなどの状況から選んだものは「いらない」、
長いラリーは「いい感じ」だった。なので候補は長いラリーだけにする（最初の打球音から最後まで）。
最後に決めるのは見た人（ページで ★ を付ける）。
"""

# 長い順にこれだけを候補にする（多すぎると印の意味がなくなる）
PICK = 6


def candidates(games: list[dict]) -> list[str]:
    """候補の点の名前（"ゲーム番号-何点目"。ページの印と同じ形）。ラリーが長い順に PICK 個。"""
    found = []
    for g in games:
        for k, p in enumerate(g["points"]):
            r = p.get("rally")
            if r:
                found.append((r["length"], f"{g['index'] + 1}-{k + 1}"))
    return [key for _, key in sorted(found, reverse=True)[:PICK]]
