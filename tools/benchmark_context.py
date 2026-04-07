#!/usr/bin/env python3
"""E-4: max-context-words の応答時間ベンチマーク

skk-smart-max-context-words を増やすとコーパスルックアップの応答時間はどう変化するか。
10 語がレイテンシと精度のバランス点として適切かを確認する。

注意: Python での計測。実際の Emacs Lisp 環境とは絶対値が異なるが、
相対的な傾向（コンテキスト語数とレイテンシの比例関係）は参考になる。

使用例:
    python tools/benchmark_context.py \\
        --sqlite corpus/skk-cooccurrence.sqlite \\
        --candidates 効果,高価,降下 \\
        --context-sizes 5,10,15,20,30,50 \\
        --iterations 10000

出力（stdout、TSV):
    context_words<TAB>median_ms<TAB>p95_ms<TAB>p99_ms<TAB>mean_ms
"""

from __future__ import annotations

import argparse
import random
import sqlite3
import statistics
import sys
import time
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

    def score_candidate(self, word: str, context_words: list[str]) -> int:
        """N 個の文脈語に対して単語をスコアリングする。"""
        total = 0
        for ctx in context_words:
            total += self.get(word, ctx)
        return total

    def score_all_candidates(
        self,
        candidates: list[str],
        context_words: list[str],
    ) -> dict[str, int]:
        """全候補語をスコアリングする（実際の変換時の処理に相当）。"""
        return {c: self.score_candidate(c, context_words) for c in candidates}


# ============================================================
# ベンチマーク用コンテキスト語生成
# ============================================================

CONTEXT_WORD_POOL = [
    "研究", "大学", "技術", "社会", "経済", "政治", "文化", "教育",
    "医療", "環境", "産業", "情報", "地域", "国際", "歴史", "科学",
    "問題", "方法", "結果", "影響", "発展", "活動", "組織", "制度",
    "報告", "調査", "分析", "評価", "実施", "管理", "支援", "利用",
    "治療", "患者", "病院", "薬", "症状", "診断", "手術", "検査",
    "法律", "裁判", "条約", "政府", "議会", "選挙", "政策", "行政",
    "工場", "生産", "製品", "品質", "効率", "コスト", "設備", "材料",
    "農業", "食品", "土地", "水", "森林", "資源", "気候", "自然",
    "計画", "目標", "戦略", "事業", "企業", "投資", "市場", "競争",
    "学校", "学生", "授業", "試験", "成績", "課題", "知識", "技能",
]


def sample_context_words(pool: list[str], n: int, seed: int | None = None) -> list[str]:
    """プールから n 語をランダムサンプリングする。"""
    rng = random.Random(seed)
    if n > len(pool):
        words = pool * (n // len(pool) + 1)
        return rng.sample(words, n)
    return rng.sample(pool, n)


# ============================================================
# ベンチマーク実行
# ============================================================

def benchmark(
    db: SqliteLookup,
    candidates: list[str],
    context_size: int,
    iterations: int,
    seed: int = 42,
) -> dict:
    """指定コンテキストサイズで変換スコアリングをベンチマークする。"""
    contexts = [
        sample_context_words(CONTEXT_WORD_POOL, context_size, seed=seed + i)
        for i in range(iterations)
    ]

    warmup = min(100, iterations // 10)
    for i in range(warmup):
        db.score_all_candidates(candidates, contexts[i % len(contexts)])

    times_ms: list[float] = []
    for i in range(iterations):
        ctx = contexts[i]
        t0 = time.perf_counter()
        db.score_all_candidates(candidates, ctx)
        t1 = time.perf_counter()
        times_ms.append((t1 - t0) * 1000)

    times_ms.sort()
    p95_idx = int(len(times_ms) * 0.95)
    p99_idx = int(len(times_ms) * 0.99)

    return {
        "context_size": context_size,
        "median_ms": statistics.median(times_ms),
        "p95_ms": times_ms[p95_idx],
        "p99_ms": times_ms[p99_idx],
        "mean_ms": statistics.mean(times_ms),
        "iterations": iterations,
    }


# ============================================================
# メイン
# ============================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="E-4: max-context-words の応答時間ベンチマーク",
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
        "--candidates",
        default="効果,高価,降下",
        help="カンマ区切りの候補語 (デフォルト: 効果,高価,降下)",
    )
    parser.add_argument(
        "--context-sizes",
        default="5,10,15,20,30,50",
        help="カンマ区切りのコンテキスト語数 (デフォルト: 5,10,15,20,30,50)",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=10000,
        help="各コンテキストサイズでの反復回数 (デフォルト: 10000)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="乱数シード (デフォルト: 42)",
    )
    args = parser.parse_args()

    candidates = [c.strip() for c in args.candidates.split(",") if c.strip()]
    context_sizes = [int(x.strip()) for x in args.context_sizes.split(",")]

    print(f"SQLite: {args.sqlite}", file=sys.stderr)
    print(f"候補語: {candidates}", file=sys.stderr)
    print(f"コンテキストサイズ: {context_sizes}", file=sys.stderr)
    print(f"反復回数: {args.iterations:,}", file=sys.stderr)

    print("context_words\tmedian_ms\tp95_ms\tp99_ms\tmean_ms")

    with SqliteLookup(args.sqlite) as db:
        for ctx_size in context_sizes:
            print(f"コンテキストサイズ {ctx_size} ベンチマーク中...", file=sys.stderr)
            result = benchmark(db, candidates, ctx_size, args.iterations, args.seed)
            print(
                f"{result['context_size']}"
                f"\t{result['median_ms']:.4f}"
                f"\t{result['p95_ms']:.4f}"
                f"\t{result['p99_ms']:.4f}"
                f"\t{result['mean_ms']:.4f}"
            )

    print("完了", file=sys.stderr)


if __name__ == "__main__":
    main()
