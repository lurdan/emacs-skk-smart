#!/usr/bin/env python3
"""E-1: min-count 最適値の実験スクリプト

変換精度（正解候補が 1 位になる率）が最大になる min-count 値を調べる。

使用例:
    # SQLite ファイルをその場で生成して評価（--counts で TSV を指定）
    python tools/eval_mincount.py \\
        --eval-set test/fixtures/eval-set.tsv \\
        --counts corpus/counts_wikipedia.tsv \\
        --min-counts 5,8,10,15,20

    # 既存の SQLite ファイルを使って評価（--sqlite-dir で格納ディレクトリを指定）
    # ファイル名の規則: <prefix>-<N>.sqlite  例: cooccurrence-10.sqlite
    python tools/eval_mincount.py \\
        --eval-set test/fixtures/eval-set.tsv \\
        --sqlite-dir /path/to/dbs \\
        --min-counts 5,8,10,15,20

出力（stdout、TSV):
    min_count<TAB>top1_accuracy<TAB>top1_count<TAB>total<TAB>entry_count
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
import tempfile
from pathlib import Path


# ============================================================
# SQLite ルックアップ
# ============================================================

class SqliteLookup:
    """SQLite コーパスへの O(1) ルックアップ。"""

    def __init__(self, path: str) -> None:
        self._conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        self._conn.execute("PRAGMA mmap_size=268435456;")  # 256 MB

    def close(self) -> None:
        self._conn.close()

    def __enter__(self) -> "SqliteLookup":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def get(self, word: str, ctx: str) -> int:
        """(word, ctx) ペアの PPMI スコアを返す。なければ 0。"""
        row = self._conn.execute(
            "SELECT score FROM cooccurrence WHERE candidate=? AND context_word=?",
            (word, ctx),
        ).fetchone()
        return row[0] if row else 0

    def score(self, word: str, context_words: list[str]) -> int:
        """単語と文脈語リストのオーバーラップスコアを返す。"""
        total = 0
        for ctx in context_words:
            total += self.get(word, ctx)
        return total

    def entry_count(self) -> int:
        row = self._conn.execute("SELECT COUNT(*) FROM cooccurrence").fetchone()
        return row[0] if row else 0


# ============================================================
# SQLite 生成（make_sqlite.py の実装を呼ぶ）
# ============================================================

def build_sqlite_from_tsv(
    counts_path: str,
    output_path: str,
    min_count: int,
) -> None:
    """TSV から指定 min-count で SQLite を生成する（省メモリ二段パス）。"""
    sys.path.insert(0, str(Path(__file__).parent))
    from make_sqlite import build_sqlite_streaming
    build_sqlite_streaming(counts_path, output_path, min_count)


# ============================================================
# 評価セット読み込み
# ============================================================

def load_eval_set(path: str) -> list[dict]:
    """eval-set.tsv を読み込む。コメント行・空行は無視。"""
    entries = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                print(
                    f"  警告: {path}:{lineno}: フィールド数不足 ({len(parts)}), スキップ",
                    file=sys.stderr,
                )
                continue
            midasi = parts[0]
            correct = parts[1]
            candidates = [c.strip() for c in parts[2].split(",") if c.strip()]
            current_words = parts[3].split() if parts[3].strip() else []
            prev_words = parts[4].split() if len(parts) > 4 and parts[4].strip() else []
            note = parts[5] if len(parts) > 5 else ""
            entries.append(
                {
                    "midasi": midasi,
                    "correct": correct,
                    "candidates": candidates,
                    "current_words": current_words,
                    "prev_words": prev_words,
                    "note": note,
                }
            )
    return entries


# ============================================================
# 評価
# ============================================================

def evaluate(db: SqliteLookup, entries: list[dict], prev_weight: float = 0.0) -> dict:
    """eval セットの top-1 精度を計算する。"""
    top1 = 0
    details = []
    for e in entries:
        current_words = e["current_words"]
        prev_words = e["prev_words"]
        correct = e["correct"]
        candidates = e["candidates"]

        if not current_words and not prev_words:
            details.append({**e, "result": "skip", "scores": {}})
            continue

        scores: dict[str, int] = {}
        for cand in candidates:
            s_cur = db.score(cand, current_words)
            s_prev = int(db.score(cand, prev_words) * prev_weight) if prev_words else 0
            scores[cand] = s_cur + s_prev

        ranked = sorted(candidates, key=lambda c: -scores[c])

        if not ranked:
            details.append({**e, "result": "skip", "scores": scores})
            continue

        if all(s == 0 for s in scores.values()):
            details.append({**e, "result": "no_signal", "scores": scores, "ranked": ranked})
            continue

        result = "top1" if ranked[0] == correct else "miss"
        if result == "top1":
            top1 += 1
        details.append({**e, "result": result, "scores": scores, "ranked": ranked})

    scoreable = [d for d in details if d["result"] in ("top1", "miss")]
    total = len(scoreable)
    accuracy = top1 / total if total > 0 else 0.0

    return {
        "top1_count": top1,
        "total": total,
        "top1_accuracy": accuracy,
        "details": details,
    }


# ============================================================
# メイン
# ============================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="E-1: min-count 最適値の実験（変換精度 vs min-count）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--eval-set",
        default="test/fixtures/eval-set.tsv",
        help="評価セット TSV (デフォルト: test/fixtures/eval-set.tsv)",
    )

    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument(
        "--counts",
        metavar="TSV",
        help="共起カウント TSV (指定時は --min-counts で SQLite をその場で生成、省メモリ二段パス)",
    )
    src.add_argument(
        "--sqlite-dir",
        metavar="DIR",
        help="SQLite ファイルのディレクトリ (ファイル名: cooccurrence-<N>.sqlite)",
    )

    parser.add_argument(
        "--min-counts",
        default="5,8,10,15,20",
        help="カンマ区切りの min-count 値 (デフォルト: 5,8,10,15,20)",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="ミスした事例を詳細表示する",
    )
    args = parser.parse_args()

    min_counts = [int(x.strip()) for x in args.min_counts.split(",")]

    print(f"評価セット読み込み: {args.eval_set}", file=sys.stderr)
    entries = load_eval_set(args.eval_set)
    print(f"  {len(entries)} エントリ読み込み完了", file=sys.stderr)

    print("min_count\ttop1_accuracy\ttop1_count\ttotal\tentry_count")

    with tempfile.TemporaryDirectory() as tmpdir:
        for mc in sorted(min_counts):
            if args.counts:
                db_path = str(Path(tmpdir) / f"cooccurrence-{mc}.sqlite")
                print(f"min_count={mc} SQLite 生成中...", file=sys.stderr)
                build_sqlite_from_tsv(args.counts, db_path, mc)
            else:
                db_path = str(Path(args.sqlite_dir) / f"cooccurrence-{mc}.sqlite")
                if not Path(db_path).exists():
                    print(
                        f"  警告: {db_path} が見つかりません, スキップ",
                        file=sys.stderr,
                    )
                    continue

            print(f"min_count={mc} 評価中...", file=sys.stderr)
            with SqliteLookup(db_path) as db:
                result = evaluate(db, entries)
                n_entries = db.entry_count()

            print(
                f"{mc}\t{result['top1_accuracy']:.4f}"
                f"\t{result['top1_count']}\t{result['total']}\t{n_entries}"
            )

            if args.verbose:
                for d in result["details"]:
                    if d["result"] == "miss":
                        scores_str = ", ".join(
                            f"{c}:{d['scores'][c]}"
                            for c in d["candidates"]
                        )
                        print(
                            f"  MISS  {d['midasi']} 正解={d['correct']}"
                            f" 1位={d['ranked'][0]}"
                            f" ctx={d['current_words']}"
                            f" scores=[{scores_str}]",
                            file=sys.stderr,
                        )
                    elif d["result"] == "no_signal":
                        print(
                            f"  ZERO  {d['midasi']} 正解={d['correct']}"
                            f" ctx={d['current_words']}",
                            file=sys.stderr,
                        )


if __name__ == "__main__":
    main()
