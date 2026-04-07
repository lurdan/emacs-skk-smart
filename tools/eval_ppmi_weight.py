#!/usr/bin/env python3
"""E-2: PPMI freq_weight 正規化の効果を実験するスクリプト

スコア = PPMI × sqrt(word_freq / max_freq) の正規化が変換精度に与える影響を評価する。
専門用語ドメインでの逆効果（低頻度専門語の割引）に特に注意する。

使用例:
    python tools/eval_ppmi_weight.py \\
        --counts corpus/counts_wikipedia.tsv \\
        --eval-set test/fixtures/eval-set.tsv \\
        --mode both

    # 特定のモードのみ
    python tools/eval_ppmi_weight.py \\
        --counts corpus/counts_wikipedia.tsv \\
        --eval-set test/fixtures/eval-set.tsv \\
        --mode baseline

出力（stdout、TSV):
    word<TAB>ctx<TAB>score_baseline<TAB>score_normalized<TAB>word_freq<TAB>max_freq

    --mode both でない場合は各スコア列のみを出力:
    word<TAB>ctx<TAB>score

    精度サマリーも stderr に出力:
    [baseline] top1=X/Y (Z%)
    [normalized] top1=X/Y (Z%)
"""

from __future__ import annotations

import argparse
import math
import sys
from collections import defaultdict
from pathlib import Path


# ============================================================
# 共起カウント TSV 読み込み
# ============================================================

def load_counts(path: str, words_filter: set[str] | None = None) -> dict[tuple[str, str], int]:
    """共起カウント TSV を読み込む。

    words_filter が指定された場合、その語を含むペアのみ読み込む（高速化）。
    ただし PPMI の周辺確率計算が不正確になるため、精度評価には全データが必要。
    """
    cooc: dict[tuple[str, str], int] = defaultdict(int)
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            try:
                w, c, cnt = parts[0], parts[1], int(parts[2])
            except ValueError:
                continue
            if words_filter is None or w in words_filter:
                cooc[(w, c)] += cnt
    return cooc


# ============================================================
# スコア計算
# ============================================================

def compute_scores(
    cooc: dict[tuple[str, str], int],
    min_count: int,
    normalize: bool,
) -> dict[tuple[str, str], float]:
    """PPMI スコアを計算する。

    normalize=True のとき: score = PPMI × sqrt(word_freq / max_freq)
    normalize=False のとき: score = PPMI（従来の計算）

    戻り値のスコアは float（比較のため正規化前後で同一スケールにしない）。
    """
    cooc = {k: v for k, v in cooc.items() if v >= min_count}
    if not cooc:
        return {}

    word_freq: dict[str, int] = defaultdict(int)
    ctx_freq: dict[str, int] = defaultdict(int)
    total = 0
    for (w, c), cnt in cooc.items():
        word_freq[w] += cnt
        ctx_freq[c] += cnt
        total += cnt

    if total == 0:
        return {}

    max_freq = max(word_freq.values()) if word_freq else 1

    scores: dict[tuple[str, str], float] = {}
    for (w, c), cnt in cooc.items():
        p_wc = cnt / total
        p_w = word_freq[w] / total
        p_c = ctx_freq[c] / total
        if p_w <= 0 or p_c <= 0:
            continue
        pmi = math.log2(p_wc / (p_w * p_c))
        ppmi = max(0.0, pmi)
        if ppmi == 0:
            continue
        if normalize:
            freq_weight = math.sqrt(word_freq[w] / max_freq)
            score = ppmi * freq_weight
        else:
            score = ppmi
        scores[(w, c)] = score

    return scores


def score_candidate(
    scores: dict[tuple[str, str], float],
    word: str,
    context_words: list[str],
) -> float:
    """単語と文脈語リストのオーバーラップスコアを返す。"""
    total = 0.0
    for ctx in context_words:
        s = scores.get((word, ctx), 0.0)
        total += s
    return total


# ============================================================
# 評価セット読み込み
# ============================================================

def load_eval_set(path: str) -> list[dict]:
    entries = []
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            entries.append(
                {
                    "midasi": parts[0],
                    "correct": parts[1],
                    "candidates": [c.strip() for c in parts[2].split(",") if c.strip()],
                    "current_words": parts[3].split() if parts[3].strip() else [],
                    "prev_words": parts[4].split() if len(parts) > 4 and parts[4].strip() else [],
                    "note": parts[5] if len(parts) > 5 else "",
                }
            )
    return entries


# ============================================================
# 評価
# ============================================================

def evaluate_accuracy(
    scores: dict[tuple[str, str], float],
    entries: list[dict],
    label: str,
) -> tuple[int, int]:
    """top-1 精度を計算して stderr に出力する。"""
    top1 = 0
    total = 0
    for e in entries:
        if not e["current_words"]:
            continue
        cand_scores = {
            c: score_candidate(scores, c, e["current_words"])
            for c in e["candidates"]
        }
        if all(s == 0 for s in cand_scores.values()):
            continue
        ranked = sorted(e["candidates"], key=lambda c: -cand_scores[c])
        total += 1
        if ranked[0] == e["correct"]:
            top1 += 1

    pct = top1 / total * 100 if total > 0 else 0
    print(f"[{label}] top1={top1}/{total} ({pct:.1f}%)", file=sys.stderr)
    return top1, total


# ============================================================
# メイン
# ============================================================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="E-2: PPMI freq_weight 正規化の効果実験",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--counts",
        required=True,
        metavar="TSV",
        help="共起カウント TSV ファイル",
    )
    parser.add_argument(
        "--eval-set",
        default="test/fixtures/eval-set.tsv",
        help="評価セット TSV (デフォルト: test/fixtures/eval-set.tsv)",
    )
    parser.add_argument(
        "--mode",
        choices=["baseline", "normalized", "both"],
        default="both",
        help="出力モード: baseline / normalized / both (デフォルト: both)",
    )
    parser.add_argument(
        "--min-count",
        type=int,
        default=10,
        help="min-count フィルタ (デフォルト: 10)",
    )
    parser.add_argument(
        "--top-n",
        type=int,
        default=50,
        help="各候補語の上位 N ペアを出力 (--mode both 時のみ, デフォルト: 50)",
    )
    args = parser.parse_args()

    # 評価セット読み込み
    print(f"評価セット読み込み: {args.eval_set}", file=sys.stderr)
    entries = load_eval_set(args.eval_set)
    candidate_words = set(c for e in entries for c in e["candidates"])
    print(f"  {len(entries)} エントリ, {len(candidate_words)} 候補語", file=sys.stderr)

    # カウント読み込み（候補語のみフィルタ）
    print(f"カウント読み込み中: {args.counts}", file=sys.stderr)
    print("  注意: 候補語フィルタ適用（PPMI の周辺確率は候補語視点のみ）", file=sys.stderr)
    cooc = load_counts(args.counts, words_filter=candidate_words)
    print(f"  {len(cooc):,} ペア読み込み完了", file=sys.stderr)

    if args.mode in ("baseline", "both"):
        print("ベースラインスコア計算中...", file=sys.stderr)
        scores_base = compute_scores(cooc, args.min_count, normalize=False)
        evaluate_accuracy(scores_base, entries, "baseline")

    if args.mode in ("normalized", "both"):
        print("正規化スコア計算中...", file=sys.stderr)
        scores_norm = compute_scores(cooc, args.min_count, normalize=True)
        evaluate_accuracy(scores_norm, entries, "normalized")

    # 詳細出力
    if args.mode == "both":
        # 各候補語について上位ペアを比較出力
        print("word\tctx\tscore_baseline\tscore_normalized")
        for word in sorted(candidate_words):
            pairs = [
                (w, c, scores_base.get((w, c), 0.0), scores_norm.get((w, c), 0.0))
                for (w, c) in scores_base
                if w == word
            ]
            # ベースラインスコア降順で上位 N ペア
            pairs.sort(key=lambda x: -x[2])
            for _, ctx, s_base, s_norm in pairs[: args.top_n]:
                print(f"{word}\t{ctx}\t{s_base:.4f}\t{s_norm:.4f}")
    elif args.mode == "baseline":
        print("word\tctx\tscore_baseline")
        for (word, ctx), score in sorted(scores_base.items(), key=lambda x: -x[1]):
            if word in candidate_words:
                print(f"{word}\t{ctx}\t{score:.4f}")
    else:
        print("word\tctx\tscore_normalized")
        for (word, ctx), score in sorted(scores_norm.items(), key=lambda x: -x[1]):
            if word in candidate_words:
                print(f"{word}\t{ctx}\t{score:.4f}")


if __name__ == "__main__":
    main()
