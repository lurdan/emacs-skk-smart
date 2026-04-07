#!/usr/bin/env python3
"""既存の SQLite corpus を最適化する（SQLite → SQLite 変換）。

既存 SQLite からの再構築のため高速。以下の最適化を組み合わせて適用する:
  - WITHOUT ROWID テーブル（S-1c）: rowid + PRIMARY KEY 二重格納を解消
  - スコア下限フィルタ  （S-1a）: 低スコアノイズを除去
  - ページサイズ最適化 （S-1b）: B-tree 深さを最小化

使用例:
  # 推奨（全最適化）
  python3 tools/optimize_sqlite.py corpus/skk-cooccurrence-wikipedia.sqlite

  # 出力先を明示
  python3 tools/optimize_sqlite.py input.sqlite output.sqlite

  # オプションのカスタマイズ
  python3 tools/optimize_sqlite.py --min-score 200 --page-size 8192 input.sqlite
"""

import argparse
import os
import sqlite3
import sys


DEFAULT_MIN_SCORE = 300
DEFAULT_PAGE_SIZE = 16384
DEFAULT_BATCH_SIZE = 200_000

SCHEMA_WITHOUT_ROWID = """
CREATE TABLE IF NOT EXISTS cooccurrence (
    candidate    TEXT NOT NULL,
    context_word TEXT NOT NULL,
    score        INTEGER NOT NULL,
    PRIMARY KEY (candidate, context_word)
) WITHOUT ROWID;
"""


def optimize(
    src_path: str,
    dst_path: str,
    min_score: int = DEFAULT_MIN_SCORE,
    page_size: int = DEFAULT_PAGE_SIZE,
    batch_size: int = DEFAULT_BATCH_SIZE,
) -> tuple[int, int]:
    """src_path を読み込んで最適化済みの dst_path を生成する。

    Returns:
        (total_written, total_skipped) のタプル
    """
    src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
    src.execute("PRAGMA query_only = ON;")

    dst = sqlite3.connect(dst_path)
    dst.execute(f"PRAGMA page_size = {page_size};")
    dst.execute("PRAGMA journal_mode=WAL;")
    dst.execute("PRAGMA synchronous=NORMAL;")
    dst.execute("PRAGMA cache_size = -65536;")  # 64 MB キャッシュ
    dst.execute(SCHEMA_WITHOUT_ROWID)

    total_written = 0
    total_skipped = 0
    batch = []

    cursor = src.execute(
        "SELECT candidate, context_word, score FROM cooccurrence ORDER BY candidate, context_word"
    )

    for row in cursor:
        candidate, context_word, score = row
        if score < min_score:
            total_skipped += 1
            continue
        batch.append((candidate, context_word, score))
        if len(batch) >= batch_size:
            dst.executemany("INSERT OR REPLACE INTO cooccurrence VALUES (?, ?, ?)", batch)
            dst.commit()
            total_written += len(batch)
            batch = []
            print(
                f"  {total_written:,} 行書き込み済み（スキップ: {total_skipped:,}）...",
                file=sys.stderr,
            )

    if batch:
        dst.executemany("INSERT OR REPLACE INTO cooccurrence VALUES (?, ?, ?)", batch)
        dst.commit()
        total_written += len(batch)

    src.close()
    dst.close()
    return total_written, total_skipped


def human_size(n_bytes: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if n_bytes < 1024:
            return f"{n_bytes:.1f} {unit}"
        n_bytes /= 1024
    return f"{n_bytes:.1f} TB"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="既存 SQLite corpus を WITHOUT ROWID + スコアフィルタ + ページサイズ最適化で再構築する"
    )
    parser.add_argument("src_path", help="入力 SQLite ファイルパス")
    parser.add_argument(
        "dst_path",
        nargs="?",
        help="出力 SQLite ファイルパス（省略時: 入力と同じ名前に .opt.sqlite を付ける）",
    )
    parser.add_argument(
        "--min-score",
        type=int,
        default=DEFAULT_MIN_SCORE,
        metavar="N",
        help=f"この値未満のエントリを除外する（デフォルト: {DEFAULT_MIN_SCORE}）",
    )
    parser.add_argument(
        "--page-size",
        type=int,
        default=DEFAULT_PAGE_SIZE,
        choices=[512, 1024, 2048, 4096, 8192, 16384, 32768, 65536],
        help=f"SQLite ページサイズ（デフォルト: {DEFAULT_PAGE_SIZE}）",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f"一括 INSERT のバッチサイズ（デフォルト: {DEFAULT_BATCH_SIZE}）",
    )
    parser.add_argument(
        "--inplace",
        action="store_true",
        help="変換完了後に入力ファイルを出力で上書きする",
    )

    args = parser.parse_args()

    src_path = args.src_path
    if not os.path.isfile(src_path):
        print(f"エラー: ファイルが見つかりません: {src_path}", file=sys.stderr)
        sys.exit(1)

    if args.dst_path:
        dst_path = args.dst_path
    elif args.inplace:
        base = os.path.splitext(src_path)[0]
        dst_path = base + ".tmp.sqlite"
    else:
        base = os.path.splitext(src_path)[0]
        dst_path = base + ".opt.sqlite"

    if os.path.exists(dst_path):
        print(f"エラー: 出力ファイルが既に存在します: {dst_path}", file=sys.stderr)
        print("削除するか別のパスを指定してください。", file=sys.stderr)
        sys.exit(1)

    src_size = os.path.getsize(src_path)
    print(f"最適化開始: {src_path} ({human_size(src_size)})", file=sys.stderr)
    print(
        f"  min_score={args.min_score}  page_size={args.page_size}  without_rowid=True",
        file=sys.stderr,
    )
    print(f"  → {dst_path}", file=sys.stderr)

    written, skipped = optimize(
        src_path,
        dst_path,
        min_score=args.min_score,
        page_size=args.page_size,
        batch_size=args.batch_size,
    )

    dst_size = os.path.getsize(dst_path)
    ratio = dst_size / src_size * 100
    print(
        f"\n完了: {written:,} 行書き込み  {skipped:,} 行スキップ",
        file=sys.stderr,
    )
    print(
        f"サイズ: {human_size(src_size)} → {human_size(dst_size)} ({ratio:.1f}%  削減: {100-ratio:.1f}%)",
        file=sys.stderr,
    )

    if args.inplace:
        os.replace(dst_path, src_path)
        print(f"上書き完了: {src_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
