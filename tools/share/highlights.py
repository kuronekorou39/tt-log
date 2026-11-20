"""見どころの点を選ぶ。

点ごとに「どれだけ見ごたえがありそうか」を足し上げ、上から選ぶ。
- ラリーの長さ（秒）
- 相手のゲームポイントをしのいだ
- デュース（10-10 以降）
- 逆転（3点以上離されてから前に出た）
- 連続得点（5点目から）
- ゲームを決めた
"""

GAME_POINT_SAVE = 6
DEUCE = 3
COMEBACK = 5
COMEBACK_GAP = 3
STREAK_FROM = 5
STREAK = 2
GAME_WINNER = 3
# ラリーの長さは1秒あたりこれだけ
PER_SECOND = 1.0
# これ以上のラリーは「長いラリー」と書く（秒）
LONG_RALLY = 7
PICK = 12
POINTS_TO_WIN = 11


def pick(games: list[dict]) -> list[dict]:
    """[{"g": ゲームの並び順, "k": 点の並び順, "tags": [...]}]（時間の順）。"""
    found = []
    for gi, g in enumerate(games):
        before = [0, 0]
        worst = [0, 0]  # その選手がいちばん離されていた点差
        run, runner = 0, None
        n = len(g["points"])
        for k, p in enumerate(g["points"]):
            w, l = p["winner"], 1 - p["winner"]
            after = p["scores"]
            score, tags = 0.0, []
            r = p.get("rally")
            if r:
                length = r["end"] - r["start"]
                score += length * PER_SECOND
                if length >= LONG_RALLY:
                    tags.append(f"ラリー {round(length)}秒")
            if before[l] >= POINTS_TO_WIN - 1 and before[l] > before[w]:
                score += GAME_POINT_SAVE
                tags.append("ゲームポイントをしのぐ")
            if min(before) >= POINTS_TO_WIN - 1:
                score += DEUCE
                tags.append("デュース")
            if worst[w] >= COMEBACK_GAP and before[w] <= before[l] < after[w]:
                score += COMEBACK
                tags.append("逆転")
                worst[w] = 0  # 逆転は一度だけ数える（デュースの取り合いで何度も出さない）
            run = run + 1 if w == runner else 1
            runner = w
            if run >= STREAK_FROM:
                score += STREAK
                tags.append(f"{run}連続")
            if k == n - 1 and g["winner"] is not None:
                score += GAME_WINNER
                tags.append("ゲームを決めた")
            worst[l] = max(worst[l], after[w] - after[l])
            before = list(after)
            if tags:
                found.append({"g": gi, "k": k, "score": score, "tags": tags, "at": p["at"]})
    top = sorted(found, key=lambda h: -h["score"])[:PICK]
    return [{"g": h["g"], "k": h["k"], "tags": h["tags"]} for h in sorted(top, key=lambda h: h["at"])]
