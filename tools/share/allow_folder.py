"""まとめのページで開いてよいドライブのフォルダを登録する。

フォルダ ID そのものは公開ページに載せず、ハッシュだけを書く。

使い方:
    python tools/share/allow_folder.py <共有リンク または フォルダ ID>
"""

import hashlib
import re
import sys

from pathlib import Path

from make_share import TEMPLATE, write_viewer

VIEWER = Path(__file__).resolve().parents[2] / "docs" / "viewer" / "index.html"
LINE = re.compile(r"const ALLOWED_FOLDERS = \[.*?\];")


def folder_id(text: str) -> str:
    m = re.search(r"[#&]d=([A-Za-z0-9_-]+)", text) or re.search(r"/folders/([A-Za-z0-9_-]+)", text)
    value = m[1] if m else text.strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]{10,200}", value):
        raise SystemExit("フォルダ ID を読み取れません")
    return value


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    digest = hashlib.sha256(f"tt-log:{folder_id(sys.argv[1])}".encode()).hexdigest()
    page = TEMPLATE.read_text(encoding="utf-8")
    m = LINE.search(page)
    if not m:
        raise SystemExit("template.html に ALLOWED_FOLDERS がありません")
    known = re.findall(r"[0-9a-f]{64}", m[0])
    if digest not in known:
        known.append(digest)
    line = "const ALLOWED_FOLDERS = [" + ", ".join(f"'{d}'" for d in known) + "];"
    TEMPLATE.write_text(page[:m.start()] + line + page[m.end():], encoding="utf-8", newline="\n")
    write_viewer(VIEWER)
    print(f"登録しました（{len(known)} 件）")


if __name__ == "__main__":
    main()
