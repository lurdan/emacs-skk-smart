#!/usr/bin/env python3
"""Wikipedia と JParaCrawl から共起統計を構築するスクリプト。

使用例:
  # plain テキストファイルから
  python build_cooccurrence.py --format plain input.txt > counts.tsv

  # Wikipedia (wikiextractor JSONL) から
  python build_cooccurrence.py --format wikipedia wiki_00 wiki_01 > counts.tsv

  # JParaCrawl (TSV) から
  python build_cooccurrence.py --format jparacrawl --ja-col 3 corpus.tsv.gz > counts.tsv

  # stdin から
  cat text.txt | python build_cooccurrence.py --format plain > counts.tsv

出力: TSV 形式 (word TAB context_word TAB count) を stdout に出力

メモリ対策:
  内部的にチャンク単位でカウンタをフラッシュし、最終的にマージソートで集計します。
  大規模コーパス（数 GB）でも動作します。
"""

import argparse
import gzip
import heapq
import json
import os
import re
import sys
import tempfile
from collections import Counter
from typing import Iterator


# ============================================================
# 漢字語抽出
# ============================================================

# skk-smart と同じ粒度の漢字正規表現
KANJI_PATTERN = re.compile(r"[\u4e00-\u9fff\u3400-\u4dbf]+")


def extract_kanji_words(text: str) -> list[str]:
    """テキストから漢字語を抽出してリストで返す。"""
    return KANJI_PATTERN.findall(text)


# ============================================================
# 共起カウント
# ============================================================

def count_cooccurrences(
    words: list[str],
    window: int,
    counter: Counter,
) -> None:
    """ウィンドウ内の漢字語の共起をカウントする。

    words の各語について、前後 window 語以内の語との共起を記録する。
    """
    n = len(words)
    for i, word in enumerate(words):
        start = max(0, i - window)
        end = min(n, i + window + 1)
        for j in range(start, end):
            if i != j:
                ctx = words[j]
                counter[(word, ctx)] += 1


def process_sentence(
    sentence: str,
    window: int,
    counter: Counter,
) -> None:
    """1 文を処理して共起をカウントする。"""
    words = extract_kanji_words(sentence)
    if len(words) >= 2:
        count_cooccurrences(words, window, counter)


# ============================================================
# 入力フォーマット別処理
# ============================================================

def open_file(path: str):
    """gzip 対応でファイルを開く。"""
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8", errors="replace")
    else:
        return open(path, encoding="utf-8", errors="replace")


def iter_sentences_plain(stream) -> Iterator[str]:
    """plain フォーマット: 1 行 1 文のテキスト。"""
    for line in stream:
        yield line.rstrip("\n")


def iter_sentences_wikipedia(stream) -> Iterator[str]:
    """wikipedia フォーマット: wikiextractor の JSONL 出力。
    各行が {"text": "..."} の JSON。
    """
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            text = obj.get("text", "")
            # 段落を文に分割（改行区切り）
            for sentence in text.splitlines():
                yield sentence
        except json.JSONDecodeError:
            continue


def iter_sentences_jparacrawl(stream, ja_col: int) -> Iterator[str]:
    """jparacrawl フォーマット: TSV ファイル。
    --ja-col で日本語列のインデックスを指定。
    """
    for line in stream:
        line = line.rstrip("\n")
        cols = line.split("\t")
        if len(cols) > ja_col:
            yield cols[ja_col]


# ============================================================
# チャンクフラッシュとマージ
# ============================================================

# メモリ上の Counter がこの件数を超えたらディスクにフラッシュする
FLUSH_THRESHOLD = 5_000_000


def flush_counter(counter: Counter, tmpdir: str) -> str:
    """Counter をソート済み TSV の一時ファイルに書き出してパスを返す。"""
    fd, path = tempfile.mkstemp(dir=tmpdir, suffix=".tsv")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        for (word, ctx), count in sorted(counter.items()):
            f.write(f"{word}\t{ctx}\t{count}\n")
    return path


def iter_sorted_tsv(path: str) -> Iterator[tuple[str, str, int]]:
    """ソート済み TSV を (word, ctx, count) のタプルで読み込む。"""
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 3:
                yield parts[0], parts[1], int(parts[2])


def merge_sorted_files(tmp_paths: list[str], min_count: int) -> Iterator[tuple[str, str, int]]:
    """複数のソート済み TSV をマージして重複を合算し min_count でフィルタする。"""
    iters = [iter_sorted_tsv(p) for p in tmp_paths]
    # heapq.merge はソート済みイテレータをマージする（メモリ O(N ファイル数)）
    merged = heapq.merge(*iters, key=lambda x: (x[0], x[1]))

    current_key = None
    current_count = 0
    for word, ctx, count in merged:
        key = (word, ctx)
        if key == current_key:
            current_count += count
        else:
            if current_key is not None and current_count >= min_count:
                yield current_key[0], current_key[1], current_count
            current_key = key
            current_count = count
    if current_key is not None and current_count >= min_count:
        yield current_key[0], current_key[1], current_count


# ============================================================
# メイン処理
# ============================================================

def process_files(
    paths: list[str],
    fmt: str,
    ja_col: int,
    window: int,
    min_count: int,
) -> list[str]:
    """ファイルリストを処理してソート済み一時ファイルのリストを返す。"""
    counter: Counter = Counter()
    total_lines = 0
    tmp_paths: list[str] = []
    tmpdir = tempfile.mkdtemp(prefix="skk_cooc_")

    def maybe_flush():
        nonlocal counter
        if len(counter) >= FLUSH_THRESHOLD:
            path = flush_counter(counter, tmpdir)
            tmp_paths.append(path)
            print(
                f"  → フラッシュ: {len(counter):,} ペア → {os.path.basename(path)}",
                file=sys.stderr,
            )
            counter = Counter()

    def process_stream(stream):
        nonlocal total_lines
        if fmt == "plain":
            sentences = iter_sentences_plain(stream)
        elif fmt == "wikipedia":
            sentences = iter_sentences_wikipedia(stream)
        elif fmt == "jparacrawl":
            sentences = iter_sentences_jparacrawl(stream, ja_col)
        else:
            raise ValueError(f"不明なフォーマット: {fmt}")

        for sentence in sentences:
            process_sentence(sentence, window, counter)
            total_lines += 1
            if total_lines % 500_000 == 0:
                print(
                    f"処理済み: {total_lines:,} 行, メモリ内ペア: {len(counter):,}",
                    file=sys.stderr,
                )
            maybe_flush()

    if paths:
        for i, path in enumerate(paths):
            print(f"[{i+1}/{len(paths)}] 処理中: {path}", file=sys.stderr)
            with open_file(path) as f:
                process_stream(f)
    else:
        print("stdin から読み込み中...", file=sys.stderr)
        process_stream(sys.stdin)

    # 残りをフラッシュ
    if counter:
        path = flush_counter(counter, tmpdir)
        tmp_paths.append(path)
        print(
            f"  → 最終フラッシュ: {len(counter):,} ペア → {os.path.basename(path)}",
            file=sys.stderr,
        )

    print(
        f"処理完了: {total_lines:,} 行, 一時ファイル数: {len(tmp_paths)}",
        file=sys.stderr,
    )
    return tmp_paths, tmpdir


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Wikipedia と JParaCrawl から共起統計を構築する"
    )
    parser.add_argument(
        "files",
        nargs="*",
        help="入力ファイル（省略時は stdin）",
    )
    parser.add_argument(
        "--format",
        choices=["plain", "wikipedia", "jparacrawl"],
        default="plain",
        help="入力フォーマット（デフォルト: plain）",
    )
    parser.add_argument(
        "--ja-col",
        type=int,
        default=3,
        help="jparacrawl フォーマットの日本語列インデックス（デフォルト: 3）",
    )
    parser.add_argument(
        "--window",
        type=int,
        default=10,
        help="共起ウィンドウサイズ（デフォルト: 10）",
    )
    parser.add_argument(
        "--min-count",
        type=int,
        default=5,
        help="最低共起回数（デフォルト: 5）",
    )

    args = parser.parse_args()

    tmp_paths, tmpdir = process_files(
        args.files,
        args.format,
        args.ja_col,
        args.window,
        args.min_count,
    )

    # マージソートして stdout に出力
    print("マージ中...", file=sys.stderr)
    output_count = 0
    for word, ctx, count in merge_sorted_files(tmp_paths, args.min_count):
        sys.stdout.write(f"{word}\t{ctx}\t{count}\n")
        output_count += 1
        if output_count % 1_000_000 == 0:
            print(f"出力済み: {output_count:,} エントリ", file=sys.stderr)

    print(f"出力完了: {output_count:,} エントリ", file=sys.stderr)

    # 一時ファイルを削除
    for p in tmp_paths:
        try:
            os.unlink(p)
        except OSError:
            pass
    try:
        os.rmdir(tmpdir)
    except OSError:
        pass


if __name__ == "__main__":
    main()
