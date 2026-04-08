#!/usr/bin/env python3
"""共起カウント TSV から SQLite ファイルを生成するスクリプト。

入力: build_cooccurrence.py の出力 TSV（word TAB context_word TAB count）
出力: SQLite ファイル（cooccurrence テーブル）

使用例:
  python make_sqlite.py --output cooccurrence.sqlite --input counts.tsv
  python make_sqlite.py --test-fixture
"""

import argparse
import math
import os
import sqlite3
import sys
from collections import defaultdict


# ============================================================
# SQLite 書き出し
# ============================================================

def create_sqlite(path: str) -> sqlite3.Connection:
    """最適化済み SQLite データベースを作成する。"""
    conn = sqlite3.connect(path)
    # page_size は最初の書き込み前（journal_mode 設定より前）に指定する必要がある
    conn.execute("PRAGMA page_size=16384;")
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("""
        CREATE TABLE IF NOT EXISTS cooccurrence (
            candidate   TEXT NOT NULL,
            context_word TEXT NOT NULL,
            score        INTEGER NOT NULL,
            PRIMARY KEY (candidate, context_word)
        ) WITHOUT ROWID
    """)
    return conn


# ============================================================
# PPMI スコア計算
# ============================================================

def compute_ppmi_scores(
    cooc: dict[tuple[str, str], int],
    min_count: int,
) -> dict[tuple[str, str], int]:
    """共起カウントから PPMI スコアを計算する。

    スコア = min(999, int(PPMI × 100))
    PPMI = max(0, PMI)
    PMI = log2(P(w,c) × N / (P(w) × P(c)))
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

    scores: dict[tuple[str, str], int] = {}
    for (w, c), cnt in cooc.items():
        p_wc = cnt / total
        p_w = word_freq[w] / total
        p_c = ctx_freq[c] / total

        if p_w > 0 and p_c > 0:
            pmi = math.log2(p_wc / (p_w * p_c))
            ppmi = max(0.0, pmi)
            score = min(999, int(ppmi * 100))
            if score > 0:
                scores[(w, c)] = score

    return scores


# ============================================================
# テスト用フィクスチャ生成
# ============================================================

def build_test_fixture(output_path: str) -> None:
    """テスト用の既知エントリを含む小さな SQLite を生成する。"""
    conn = create_sqlite(output_path)

    fixtures = [
        ("効果", "薬", 800),
        ("効果", "治療", 600),
        ("高価", "購入", 750),
    ]

    conn.executemany(
        "INSERT OR REPLACE INTO cooccurrence (candidate, context_word, score) VALUES (?, ?, ?)",
        fixtures,
    )
    conn.commit()
    conn.close()
    print(f"テスト用フィクスチャを生成しました: {output_path}", file=sys.stderr)


# ============================================================
# メイン処理（二段パス省メモリ）
# ============================================================

def read_tsv(stream) -> dict[tuple[str, str], int]:
    """TSV ストリームから共起カウントを読み込む。"""
    cooc: dict[tuple[str, str], int] = defaultdict(int)
    for line in stream:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        try:
            count = int(parts[2])
        except ValueError:
            continue
        cooc[(parts[0], parts[1])] += count
    return cooc


def build_sqlite_streaming(input_path: str, output_path: str, min_count: int,
                            score_threshold: int = 0) -> None:
    """二段パスで大規模 TSV から SQLite を生成する（省メモリ）。

    一段目: 周辺頻度（word_freq, ctx_freq, total）を集計する。
    二段目: min_count フィルタを適用しながら PPMI を計算し SQLite に書き出す。
    """
    # --- 一段目: 周辺頻度の集計 ---
    print("一段目: 周辺頻度集計中...", file=sys.stderr)
    word_freq: dict[str, int] = defaultdict(int)
    ctx_freq: dict[str, int] = defaultdict(int)
    total = 0
    with open(input_path, encoding="utf-8") as f:
        for i, line in enumerate(f):
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            try:
                cnt = int(parts[2])
            except ValueError:
                continue
            word_freq[parts[0]] += cnt
            ctx_freq[parts[1]] += cnt
            total += cnt
            if i % 10_000_000 == 0 and i > 0:
                print(f"  一段目: {i:,} 行処理済み", file=sys.stderr)

    print(f"一段目完了: 語彙 {len(word_freq):,} 語, 文脈語 {len(ctx_freq):,} 語, 共起総数 {total:,}", file=sys.stderr)

    if total == 0:
        print("警告: 入力データが空です。", file=sys.stderr)
        conn = create_sqlite(output_path)
        conn.close()
        return

    # --- 二段目: PPMI 計算 & SQLite 書き出し ---
    print("二段目: PPMI 計算 & SQLite 書き出し中...", file=sys.stderr)
    conn = create_sqlite(output_path)
    written = 0
    batch: list[tuple[str, str, int]] = []
    BATCH_SIZE = 100_000

    with open(input_path, encoding="utf-8") as f:
        for i, line in enumerate(f):
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            try:
                cnt = int(parts[2])
            except ValueError:
                continue
            if cnt < min_count:
                continue
            w, c = parts[0], parts[1]
            p_wc = cnt / total
            p_w = word_freq[w] / total
            p_c = ctx_freq[c] / total
            if p_w <= 0 or p_c <= 0:
                continue
            pmi = math.log2(p_wc / (p_w * p_c))
            ppmi = max(0.0, pmi)
            score = min(999, int(ppmi * 100))
            if score <= score_threshold:
                continue
            batch.append((w, c, score))
            written += 1
            if len(batch) >= BATCH_SIZE:
                conn.executemany(
                    "INSERT OR REPLACE INTO cooccurrence (candidate, context_word, score) VALUES (?, ?, ?)",
                    batch,
                )
                conn.commit()
                batch.clear()
            if i % 10_000_000 == 0 and i > 0:
                print(f"  二段目: {i:,} 行処理済み, {written:,} エントリ追加", file=sys.stderr)

    if batch:
        conn.executemany(
            "INSERT OR REPLACE INTO cooccurrence (candidate, context_word, score) VALUES (?, ?, ?)",
            batch,
        )
        conn.commit()

    conn.execute("ANALYZE;")
    conn.close()
    print(f"二段目完了: {written:,} エントリ", file=sys.stderr)
    print(f"SQLite 生成完了: {output_path}", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="共起カウント TSV から SQLite ファイルを生成する"
    )
    parser.add_argument(
        "--output", "-o",
        default="cooccurrence.sqlite",
        help="出力 SQLite ファイルパス（デフォルト: cooccurrence.sqlite）",
    )
    parser.add_argument(
        "--min-count",
        type=int,
        default=10,
        help="最低共起回数（デフォルト: 10）",
    )
    parser.add_argument(
        "--score-threshold",
        type=int,
        default=300,
        help="この値以下の PPMI スコアのエントリを除外する（デフォルト: 300）",
    )
    parser.add_argument(
        "--input", "-i",
        default=None,
        help="入力 TSV ファイルパス（省略時は stdin）。大規模ファイルには --streaming と組み合わせること",
    )
    parser.add_argument(
        "--streaming",
        action="store_true",
        help="二段パス省メモリモード（大規模 TSV 向け、--input が必要）",
    )
    parser.add_argument(
        "--test-fixture",
        action="store_true",
        help="テスト用フィクスチャを test/fixtures/test-cooccurrence.sqlite に生成する",
    )

    args = parser.parse_args()

    if args.test_fixture:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        workspace_dir = os.path.dirname(script_dir)
        fixture_dir = os.path.join(workspace_dir, "test", "fixtures")
        os.makedirs(fixture_dir, exist_ok=True)
        fixture_path = os.path.join(fixture_dir, "test-cooccurrence.sqlite")
        build_test_fixture(fixture_path)
        return

    if args.streaming:
        if not args.input:
            print("エラー: --streaming モードは --input ファイルパスが必要です。", file=sys.stderr)
            sys.exit(1)
        build_sqlite_streaming(args.input, args.output, args.min_count, args.score_threshold)
        return

    # stdin から TSV を読み込む（後方互換）
    stream = open(args.input, encoding="utf-8") if args.input else sys.stdin
    try:
        cooc = read_tsv(stream)
    finally:
        if args.input:
            stream.close()

    if not cooc:
        print("警告: 入力データが空です。", file=sys.stderr)
        conn = create_sqlite(args.output)
        conn.close()
        return

    scores = compute_ppmi_scores(cooc, args.min_count)
    if args.score_threshold > 0:
        scores = {k: v for k, v in scores.items() if v > args.score_threshold}
    print(f"スコア計算完了: {len(scores)} エントリ", file=sys.stderr)

    conn = create_sqlite(args.output)
    conn.executemany(
        "INSERT OR REPLACE INTO cooccurrence (candidate, context_word, score) VALUES (?, ?, ?)",
        [(w, c, score) for (w, c), score in scores.items()],
    )
    conn.commit()
    conn.execute("ANALYZE;")
    conn.close()
    print(f"SQLite を生成しました: {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
