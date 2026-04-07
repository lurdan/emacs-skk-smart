#!/usr/bin/env python3
"""E-3: prev_sentence_weight 最適値の実験スクリプト

skk-smart-prev-sentence-weight のデフォルト 0.3 が最適かどうかを評価セットで検証する。
「前文コンテキストが正解に必要なケース」と「現文コンテキストのみで解決できるケース」を
分けて計測する。

使用例:
    python tools/eval_prev_weight.py \\
        --sqlite corpus/skk-cooccurrence.sqlite \\
        --eval-set test/fixtures/eval-set.tsv \\
        --weights 0.0,0.1,0.2,0.3,0.5,1.0

出力（stdout、TSV):
    weight<TAB>top1_current<TAB>accuracy_current<TAB>top1_cross<TAB>accuracy_cross<TAB>top1_total<TAB>accuracy_total
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path


# ============================================================
# SQLite ルックアップ
# ============================================================

class SqliteLookup:
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
        row = self._conn.execute(
            "SELECT score FROM cooccurrence WHERE candidate=? AND context_word=?",
            (word, ctx),
        ).fetchone()
        return row[0] if row else 0

    def score(self, word: str, context_words: list[str]) -> int:
        total = 0
        for ctx in context_words:
            total += self.get(word, ctx)
        return total


# ============================================================
# 評価セット読み込み
# ============================================================

def load_eval_set(path: str) -> tuple[list[dict], list[dict]]:
    """eval-set.tsv を読み込み、(現文解決可能エントリ, 前文必要エントリ) に分類する。"""
    current_entries = []
    cross_entries = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            e = {
                "midasi": parts[0],
                "correct": parts[1],
                "candidates": [c.strip() for c in parts[2].split(",") if c.strip()],
                "current_words": parts[3].split() if parts[3].strip() else [],
                "prev_words": parts[4].split() if len(parts) > 4 and parts[4].strip() else [],
                "note": parts[5] if len(parts) > 5 else "",
            }
            if e["current_words"]:
                current_entries.append(e)
            elif e["prev_words"]:
                cross_entries.append(e)
    return current_entries, cross_entries


# ============================================================
# 評価
# ============================================================

def evaluate_set(
    db: SqliteLookup,
    entries: list[dict],
    prev_weight: float,
) -> tuple[int, int]:
    """top-1 精度を返す。(top1_count, total)"""
    top1 = 0
    total = 0
    for e in entries:
        cand_scores: dict[str, float] = {}
        for cand in e["candidates"]:
            s_cur = db.score(cand, e["current_words"])
            s_prev = db.score(cand, e["prev_words"]) * prev_weight if e["prev_words"] else 0
            cand_scores[cand] = s_cur + s_prev

        if all(s == 0 for s in cand_scores.values()):
            continue

        ranked = sorted(e["candidates"], key=lambda c: -cand_scores[c])
        total += 1
        if ranked[0] == e["correct"]:
            top1 += 1
    return top1, total


# ============================================================
# メイン
# ============================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="E-3: prev_sentence_weight 最適値の実験",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--sqlite",
        required=True,
        metavar="PATH",
        help="SQLite ファイルパス",
    )
    parser.add_argument(
        "--eval-set",
        default="test/fixtures/eval-set.tsv",
        help="評価セット TSV (デフォルト: test/fixtures/eval-set.tsv)",
    )
    parser.add_argument(
        "--weights",
        default="0.0,0.1,0.2,0.3,0.5,1.0",
        help="カンマ区切りの重み値 (デフォルト: 0.0,0.1,0.2,0.3,0.5,1.0)",
    )
    parser.add_argument(
        "--verbose", "-v",
        action="store_true",
        help="各重みでの詳細結果を表示する",
    )
    args = parser.parse_args()

    weights = [float(x.strip()) for x in args.weights.split(",")]

    print(f"評価セット読み込み: {args.eval_set}", file=sys.stderr)
    current_entries, cross_entries = load_eval_set(args.eval_set)
    print(f"  現文解決可能: {len(current_entries)} エントリ", file=sys.stderr)
    print(f"  前文必要: {len(cross_entries)} エントリ", file=sys.stderr)

    if not cross_entries:
        print(
            "警告: 前文必要エントリが 0 件です。eval-set.tsv に prev_words のみのエントリを追加してください。",
            file=sys.stderr,
        )

    print(
        "weight"
        "\ttop1_current\ttotal_current\taccuracy_current"
        "\ttop1_cross\ttotal_cross\taccuracy_cross"
        "\ttop1_total\ttotal_total\taccuracy_total"
    )

    with SqliteLookup(args.sqlite) as db:
        for w in weights:
            c_top1, c_total = evaluate_set(db, current_entries, w)
            x_top1, x_total = evaluate_set(db, cross_entries, w)
            t_top1 = c_top1 + x_top1
            t_total = c_total + x_total

            c_acc = c_top1 / c_total if c_total > 0 else 0.0
            x_acc = x_top1 / x_total if x_total > 0 else 0.0
            t_acc = t_top1 / t_total if t_total > 0 else 0.0

            print(
                f"{w:.2f}"
                f"\t{c_top1}\t{c_total}\t{c_acc:.4f}"
                f"\t{x_top1}\t{x_total}\t{x_acc:.4f}"
                f"\t{t_top1}\t{t_total}\t{t_acc:.4f}"
            )

            if args.verbose:
                print(f"  [w={w:.2f}] 現文: {c_top1}/{c_total} ({c_acc:.1%})", file=sys.stderr)
                if cross_entries:
                    print(f"  [w={w:.2f}] 前文: {x_top1}/{x_total} ({x_acc:.1%})", file=sys.stderr)
                if args.verbose and cross_entries:
                    for e in cross_entries:
                        cand_scores = {}
                        for cand in e["candidates"]:
                            s_cur = db.score(cand, e["current_words"])
                            s_prev = db.score(cand, e["prev_words"]) * w
                            cand_scores[cand] = s_cur + s_prev
                        if all(s == 0 for s in cand_scores.values()):
                            continue
                        ranked = sorted(e["candidates"], key=lambda c: -cand_scores[c])
                        result = "OK" if ranked[0] == e["correct"] else "NG"
                        print(
                            f"    {result} {e['midasi']} 正解={e['correct']} 1位={ranked[0]}"
                            f" prev={e['prev_words']}",
                            file=sys.stderr,
                        )


if __name__ == "__main__":
    main()
