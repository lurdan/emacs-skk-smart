#!/usr/bin/env bash
# build_corpus.sh — skk-smart 共起統計データベース構築スクリプト
#
# 使用例:
#   ./tools/build_corpus.sh --wikipedia --output ~/.skk-cooccurrence.sqlite
#   ./tools/build_corpus.sh --jparacrawl en-ja/ --output ~/.skk-cooccurrence.sqlite
#   ./tools/build_corpus.sh --wikipedia --jparacrawl en-ja/ --output ~/.skk-cooccurrence.sqlite
#
# 必要なもの:
#   - Python 3.8 以上
#   - curl または wget
#   - pip install wikiextractor  (--wikipedia 使用時)
#
# フィルタリングの二段構造について:
#
#   このスクリプトは共起カウントを二段階でフィルタリングする。
#
#   [段階 1] 中間フィルタ (--min-count-pre, デフォルト 3)
#     build_cooccurrence.py が各コーパスを処理する際に適用する。
#     目的: 中間 TSV ファイルのサイズを抑えるパフォーマンス最適化。
#     中間 TSV はその後削除されるため、この閾値は精度ではなく速度に影響する。
#
#   [段階 2] 最終フィルタ (--min-count, デフォルト 10)
#     make_sqlite.py が複数コーパスのカウントを合算した後に適用する。
#     目的: SQLite に格納するペアの品質閾値。ユーザーが調整する主なパラメータ。
#
#   複数コーパスをマージする場合の注意:
#     段階 1 で除外されたペアは段階 2 の合算に参加できない。
#     例: Wikipedia で count=2、JParaCrawl で count=9 のペアは
#         段階 1（min-count-pre=3）で Wikipedia 側が除外されるため
#         合算値が 9 になり、段階 2（min-count=10）でも除外される。
#         実際の合計は 11 だが、段階 1 の除外により見えなくなる。
#     この損失を避けるには --min-count-pre 1 を指定する（中間ファイルが増大する）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"

# ============================================================
# デフォルト値
# ============================================================

USE_WIKIPEDIA=false
USE_JPARACRAWL=false
JPARACRAWL_DIR=""
OUTPUT="${HOME}/.skk-cooccurrence.sqlite"
WORK_DIR="${WORKSPACE_DIR}/corpus"
MIN_COUNT=10       # 最終フィルタ: SQLite に格納する最低共起回数（全コーパス合算後）
MIN_COUNT_PRE=3    # 中間フィルタ: 各コーパスの中間 TSV 生成時の最低共起回数（パフォーマンス最適化）
WINDOW=10
KEEP_INTERMEDIATE=false

# ============================================================
# ヘルプ
# ============================================================

usage() {
    cat <<EOF
使用法: $(basename "$0") [オプション]

オプション:
  --wikipedia                Wikipedia ダンプをダウンロードして処理する
  --jparacrawl DIR           JParaCrawl の展開済みディレクトリを指定する
  --output PATH              出力 SQLite ファイルパス (デフォルト: ~/.skk-cooccurrence.sqlite)
  --work-dir DIR             作業ディレクトリ (デフォルト: corpus/)
  --min-count N              最終フィルタ: SQLite に格納する最低共起回数 (デフォルト: 10)
                             全コーパス合算後に適用する。ユーザーが調整する主なパラメータ。
  --min-count-pre N          中間フィルタ: 各コーパスの中間 TSV 生成時の最低共起回数 (デフォルト: 3)
                             パフォーマンス最適化用。--min-count より大きく設定してはいけない。
                             1 にすると中間ファイルが増大するが、複数コーパス合算の精度が上がる。
  --window N                 共起ウィンドウサイズ (デフォルト: 10)
  --keep-intermediate        中間ファイル (ダンプ, wiki_out, counts.tsv) を削除しない
  -h, --help                 このヘルプを表示する

例:
  # Wikipedia のみ
  $(basename "$0") --wikipedia --output ~/.skk-cooccurrence.sqlite

  # JParaCrawl のみ (展開済みディレクトリを指定)
  $(basename "$0") --jparacrawl /data/en-ja --output ~/.skk-cooccurrence.sqlite

  # 両方マージ（中間フィルタを緩めて合算の精度を上げる）
  $(basename "$0") --wikipedia --jparacrawl /data/en-ja --min-count-pre 1 --output ~/.skk-cooccurrence.sqlite
EOF
    exit 0
}

# ============================================================
# 引数パース
# ============================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wikipedia)       USE_WIKIPEDIA=true ;;
        --jparacrawl)      USE_JPARACRAWL=true; JPARACRAWL_DIR="$2"; shift ;;
        --output)          OUTPUT="$2"; shift ;;
        --work-dir)        WORK_DIR="$2"; shift ;;
        --min-count)       MIN_COUNT="$2"; shift ;;
        --min-count-pre)   MIN_COUNT_PRE="$2"; shift ;;
        --window)          WINDOW="$2"; shift ;;
        --keep-intermediate) KEEP_INTERMEDIATE=true ;;
        -h|--help)         usage ;;
        *) echo "不明なオプション: $1" >&2; exit 1 ;;
    esac
    shift
done

if ! $USE_WIKIPEDIA && ! $USE_JPARACRAWL; then
    echo "エラー: --wikipedia または --jparacrawl のどちらかを指定してください。" >&2
    exit 1
fi

# 中間フィルタが最終フィルタより大きい場合は最終フィルタに揃える
if (( MIN_COUNT_PRE > MIN_COUNT )); then
    echo "警告: --min-count-pre ($MIN_COUNT_PRE) が --min-count ($MIN_COUNT) より大きいため、" \
         "--min-count-pre を $MIN_COUNT に揃えます。" >&2
    MIN_COUNT_PRE=$MIN_COUNT
fi

# ============================================================
# ユーティリティ
# ============================================================

log() { echo "[$(date '+%H:%M:%S')] $*" >&2; }

download() {
    local url="$1" dest="$2"
    if command -v curl &>/dev/null; then
        curl -L --progress-bar -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress -O "$dest" "$url"
    else
        echo "エラー: curl または wget が必要です。" >&2
        exit 1
    fi
}

# ============================================================
# 準備
# ============================================================

mkdir -p "$WORK_DIR"
COUNTS_FILES=()

# ============================================================
# Wikipedia 処理
# ============================================================

if $USE_WIKIPEDIA; then
    WIKI_DUMP="${WORK_DIR}/jawiki-latest-pages-articles.xml.bz2"
    WIKI_OUT="${WORK_DIR}/wiki_out"
    WIKI_COUNTS="${WORK_DIR}/counts_wikipedia.tsv"

    # 1. ダウンロード
    if [[ ! -f "$WIKI_DUMP" ]]; then
        log "Wikipedia ダンプをダウンロード中..."
        download \
            "https://dumps.wikimedia.org/jawiki/latest/jawiki-latest-pages-articles.xml.bz2" \
            "$WIKI_DUMP"
        log "ダウンロード完了: $(du -sh "$WIKI_DUMP" | cut -f1)"
    else
        log "既存のダンプを使用: $WIKI_DUMP"
    fi

    # 2. wikiextractor
    if [[ ! -d "$WIKI_OUT" ]]; then
        log "wikiextractor でテキスト抽出中..."
        if ! command -v wikiextractor &>/dev/null && ! python3 -c "import wikiextractor" &>/dev/null; then
            echo "エラー: wikiextractor が見つかりません。pip install wikiextractor を実行してください。" >&2
            exit 1
        fi
        # Python 3.13+ では re パターン途中の (?i) フラグが禁止された。
        # wikiextractor の extract.py にその問題があれば自動パッチする。
        python3 - <<'PYEOF'
import re, sys
try:
    import wikiextractor, os
    path = os.path.join(os.path.dirname(wikiextractor.__file__), 'extract.py')
    src = open(path, encoding='utf-8').read()
    # Python 3.13: re パターン途中の (?i) フラグが禁止された。
    #   \[(((?i)protocols...) → (?i)\[((protocols...)  先頭移動
    #   ((?i)gif|png|...)     → (?i:gif|png|...)       非キャプチャ形式
    patched = src
    patched = patched.replace(r"'\[(((?i)'", r"'(?i)\[(('" )
    patched = re.sub(r'\(\(\?i\)([^)]+)\)', r'(?i:\1)', patched)
    if patched != src:
        open(path, 'w', encoding='utf-8').write(patched)
        print("wikiextractor/extract.py: Python 3.13 互換パッチを適用しました", file=sys.stderr)
except Exception:
    pass  # パッチ失敗は無視（実行時にエラーが出れば検知できる）
PYEOF
        if command -v wikiextractor &>/dev/null; then
            wikiextractor --json -o "$WIKI_OUT" "$WIKI_DUMP"
        else
            # 古いバージョン（__main__.py あり）向けのフォールバック
            python3 -m wikiextractor --json -o "$WIKI_OUT" "$WIKI_DUMP"
        fi
        log "抽出完了: $(find "$WIKI_OUT" -type f | wc -l) ファイル"
    else
        log "既存の抽出済みデータを使用: $WIKI_OUT"
    fi

    # 3. 共起カウント
    if [[ ! -f "$WIKI_COUNTS" ]]; then
        log "Wikipedia 共起カウント中..."
        python3 "$SCRIPT_DIR/build_cooccurrence.py" \
            --format wikipedia \
            --window "$WINDOW" \
            --min-count "$MIN_COUNT_PRE" \
            "$WIKI_OUT"/*/wiki_* \
            > "$WIKI_COUNTS"
        log "Wikipedia カウント完了: $(wc -l < "$WIKI_COUNTS") エントリ"
    else
        log "既存の Wikipedia カウントを使用: $WIKI_COUNTS"
    fi

    COUNTS_FILES+=("$WIKI_COUNTS")
fi

# ============================================================
# JParaCrawl 処理
# ============================================================

if $USE_JPARACRAWL; then
    JPC_COUNTS="${WORK_DIR}/counts_jparacrawl.tsv"

    if [[ ! -d "$JPARACRAWL_DIR" ]]; then
        echo "エラー: JParaCrawl ディレクトリが見つかりません: $JPARACRAWL_DIR" >&2
        exit 1
    fi

    if [[ ! -f "$JPC_COUNTS" ]]; then
        log "JParaCrawl 共起カウント中..."
        python3 "$SCRIPT_DIR/build_cooccurrence.py" \
            --format jparacrawl \
            --window "$WINDOW" \
            --min-count "$MIN_COUNT_PRE" \
            "$JPARACRAWL_DIR"/*.gz \
            > "$JPC_COUNTS"
        log "JParaCrawl カウント完了: $(wc -l < "$JPC_COUNTS") エントリ"
    else
        log "既存の JParaCrawl カウントを使用: $JPC_COUNTS"
    fi

    COUNTS_FILES+=("$JPC_COUNTS")
fi

# ============================================================
# SQLite 生成
# ============================================================

log "SQLite を生成中: $OUTPUT"

# 複数コーパスは中間 TSV をカウント合算してから make_sqlite.py に渡す
if [[ ${#COUNTS_FILES[@]} -eq 1 ]]; then
    python3 "$SCRIPT_DIR/make_sqlite.py" \
        --input "${COUNTS_FILES[0]}" \
        --output "$OUTPUT" \
        --min-count "$MIN_COUNT" \
        --score-threshold 300 \
        --streaming
else
    # 複数コーパスのカウントを合算して一時ファイルに書き出す
    MERGED_COUNTS="${WORK_DIR}/counts_merged.tsv"
    log "複数コーパスをマージ中..."
    cat "${COUNTS_FILES[@]}" > "$MERGED_COUNTS"
    python3 "$SCRIPT_DIR/make_sqlite.py" \
        --input "$MERGED_COUNTS" \
        --output "$OUTPUT" \
        --min-count "$MIN_COUNT" \
        --score-threshold 300 \
        --streaming
    rm -f "$MERGED_COUNTS"
fi

log "SQLite 生成完了: $(du -sh "$OUTPUT" | cut -f1)  →  $OUTPUT"

# ============================================================
# 中間ファイルの削除
# ============================================================

if ! $KEEP_INTERMEDIATE; then
    log "中間ファイルを削除中..."
    if $USE_WIKIPEDIA; then
        rm -f "${WORK_DIR}/jawiki-latest-pages-articles.xml.bz2"
        rm -rf "${WORK_DIR}/wiki_out"
        rm -f "${WORK_DIR}/counts_wikipedia.tsv"
    fi
    if $USE_JPARACRAWL; then
        rm -f "${WORK_DIR}/counts_jparacrawl.tsv"
    fi
fi

log "完了。~/.skk に以下を追加してください:"
echo ""
echo '  (setq skk-smart-corpus-file "'"$OUTPUT"'")'
echo ""
