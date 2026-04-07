;;; skk-smart.el --- Context-aware candidate reranking for SKK  -*- coding: utf-8; lexical-binding: t -*-

;; Copyright (C) 2026 SKK Development Team

;; Author: SKK Development Team
;; Maintainer: SKK Development Team
;; URL: https://github.com/skk-dev/ddskk
;; Keywords: japanese, input method
;; Version: 0.1.0

;; This file is NOT part of Daredevil SKK, but is designed to work with it.

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied
;; warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
;; PURPOSE.  See the GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; skk-smart は SKK の変換候補をバッファの文脈に応じて並び替える拡張パッケージです。
;;
;; 変換確定時にその前後の漢字語をコンテキストとして記録し、次回同じ読みを変換する際に
;; 同様のコンテキストで過去に確定された候補を上位に表示します。
;;
;; <インストール>
;;
;;   ~/.skk に以下を追加:
;;
;;     (require 'skk-smart)
;;     (skk-smart-setup)
;;
;; <外部 API の利用 (Phase 2)>
;;
;;   `skk-smart-llm-function' に関数を設定することで LLM による
;;   候補リランキングを有効にできます（将来実装予定）。
;;
;; <データ構造>
;;
;;   skk-smart-alist の構造:
;;
;;   ((midasi . ((context-words . confirmed-word) ...))
;;    ...)
;;
;;   例:
;;   (("こうか" . ((("薬" "治療") . "効果")
;;                  (("特許" "弁護士") . "高価")))
;;    ("べんり" . ((("IT" "システム") . "便利"))))

;;; Code:

(eval-when-compile
  (require 'cl-lib))

;;; ============================================================
;;; External SKK variable declarations
;;; ============================================================

;; SKK 本体から参照する変数を special 変数として宣言する。
;; これにより lexical-binding 環境でも let バインドが動的に機能する。
(defvar skk-search-end-function nil)
(defvar skk-update-end-function nil)
(defvar skk-henkan-start-point nil)
(defvar skk-comp-first nil)
(defvar skk-comp-key nil)

;;; ============================================================
;;; Customization
;;; ============================================================

(defgroup skk-smart nil
  "Context-aware candidate reranking for SKK."
  :prefix "skk-smart-"
  :group 'skk)

(defcustom skk-smart-context-chars 300
  "変換位置より前を何文字スキャンしてコンテキストを抽出するか。"
  :type 'integer
  :group 'skk-smart)

(defcustom skk-smart-max-entries-per-midasi 30
  "1 つの見出し語に保持するコンテキストエントリの上限数。

デフォルトは `skk-smart-max-score-entries' と同じ 30。
この値は `skk-smart-max-score-entries' 以上に設定しないと意味がない
（保存されていても参照されないエントリが生じるだけになる）。

`skk-smart-llm-function' で過去の全確定履歴を LLM に渡す場合など、
参照窓より多くのエントリを保持したい場合は、この値と
`skk-smart-max-score-entries' を両方引き上げること。
例: max-entries-per-midasi=200, max-score-entries=200"
  :type 'integer
  :group 'skk-smart)

(defcustom skk-smart-data-file
  (expand-file-name "~/.skk-smart")
  "skk-smart のコンテキストデータを保存するファイルパス。"
  :type 'file
  :group 'skk-smart)

(defcustom skk-smart-llm-function nil
  "LLM による候補リランキングを行う関数（オプション、Phase 2 用）。
non-nil の場合、(candidates context-text midasi) を引数として呼ばれ、
リランクされた候補リストを返すことが期待される。
nil の場合、LLM リランキングは無効。"
  :type '(choice (const nil) function)
  :group 'skk-smart)

(defcustom skk-smart-corpus-file nil
  "共起統計コーパスファイルのパス（SQLite 形式）。nil のとき共起スコアリングは無効。

Emacs 29.1 以降の組み込み sqlite3 サポートを使用する。
ファイルは tools/make_sqlite.py で生成する。

例:
  (setq skk-smart-corpus-file \"~/.skk-cooccurrence.sqlite\")"
  :type '(choice (const nil) file)
  :group 'skk-smart)

(defcustom skk-smart-learned-weight 1.0
  "学習データ（過去の確定履歴）スコアの重み。"
  :type 'float
  :group 'skk-smart)

(defcustom skk-smart-pending-wait 15
  "確定後、何回のコマンドを待ってから学習データに記録するか。
この間にユーザーが確定語を修正した場合は記録しない（skk-bayesian の pending 機構と同様）。

カウントは確定の直後のコマンドから始まり、N 回目のコマンド実行後に記録される。
例: pending-wait=15 のとき、確定後に 15 回キー入力があれば記録する。

0 以下のとき即時記録する。"
  :type 'integer
  :group 'skk-smart)

(defcustom skk-smart-corpus-weight 0.001
  "共起統計スコアの重み。
学習スコアは 0-10 程度の整数、共起スコアは 0-999 の整数 × コンテキスト語数なので
デフォルト 0.001 で概ね同じ大きさになる。"
  :type 'float
  :group 'skk-smart)

(defcustom skk-smart-jisyo-weight 0.3
  "個人辞書内の位置から計算する prior スコアの重み。

個人辞書の先頭にある候補（SKK 学習で最後に確定した語）ほど高いスコアを与える。
0 番目の候補のスコアは weight × 1.0、1 番目は weight × 0.5、2 番目は weight × 0.33 …

コンテキスト信号が弱い場合の fallback として機能する。
0 にすると辞書位置の影響を完全に無効にする。"
  :type 'float
  :group 'skk-smart)

(defcustom skk-smart-max-score-entries 30
  "スコアリング時に参照する学習エントリの最大数。
エントリは新しい順に並んでいるため、直近の N 件だけを使う。
`skk-smart-max-entries-per-midasi' は保存上限、こちらは参照上限。
この値を `skk-smart-max-entries-per-midasi' より大きくしても効果はない。
0 以下のとき制限なし（`skk-smart-max-entries-per-midasi' 件まで全件参照）。"
  :type 'integer
  :group 'skk-smart)

(defcustom skk-smart-max-context-words 10
  "コンテキスト語として使用する漢字語の最大数。
変換位置に近い語から優先して取る。
コーパスルックアップ数（候補数 × 語数）を抑制してパフォーマンスを向上させる。
0 以下のとき制限なし。"
  :type 'integer
  :group 'skk-smart)

(defcustom skk-smart-max-corpus-context-words 5
  "コーパス共起スコアに使用する現在文コンテキスト語の最大数。
`skk-smart-max-context-words' で取得した語をさらにここで絞り込む。
変換位置に近い語（リスト末尾）を優先して残す。

学習スコア（高精度）と違い、コーパスは統計的ノイズが多いため
少ない語数でも十分な信号が得られる場合が多い。
コーパスルックアップ数を候補数 × この値に抑制できる。
0 以下のとき制限なし（`skk-smart-max-context-words' 件まで全語を使用）。"
  :type 'integer
  :group 'skk-smart)

(defcustom skk-smart-max-prev-corpus-words 3
  "コーパス共起スコアに使用する前の文コンテキスト語の最大数。
前の文の語は `skk-smart-prev-sentence-weight' で割り引かれるため、
精度への寄与は現在文より低い。コーパスルックアップ数を抑制するために絞り込む。
変換位置に近い語（リスト末尾）を優先して残す。
0 以下のとき制限なし。"
  :type 'integer
  :group 'skk-smart)

(defcustom skk-smart-max-corpus-total-lookups 100
  "1 回の `skk-smart--compute-corpus-scores' 呼び出しにおける最大ルックアップ数。
候補数 × コンテキスト語数 がこの値を超える場合、候補数を floor(上限 / 語数) に縮小する。
`skk-smart-max-corpus-context-words' や `skk-smart-max-prev-corpus-words' で語数を
絞り込んでも候補数が多い場合のワーストケース保護として機能する。
0 以下のとき制限なし。"
  :type 'integer
  :group 'skk-smart)

(defcustom skk-smart-max-candidates 30
  "スコアリングする候補の上限数。nil のとき制限なし（全候補をスコアリングする）。

SKK の個人辞書は最後に確定した候補が先頭に来る構造のため、後半の候補は
実際にはほぼ選ばれない。先頭 N 件のみをスコアリングすることで
`skk-smart--compute-combined-scores' の計算量を O(k) から O(N) に削減できる。

窓外の候補（N+1 件目以降）は元の相対順序でリランク済み候補の後に続く。

0 以下のとき nil と同じ扱いで制限なし。"
  :type '(choice (const nil) integer)
  :group 'skk-smart)

(defcustom skk-smart-prev-sentence-weight 0.3
  "前の文のコンテキスト語に掛けるスコアの重み（0〜1）。
0 のとき前の文は完全に無視する（文境界で厳密に区切る）。
1 のとき現在の文と同じ重みになる（文境界を無視する以前の動作に近い）。"
  :type 'float
  :group 'skk-smart)

(defcustom skk-smart-rerank-mode 'simple
  "候補並び替えの方式。
- simple: スコア最大の候補のみ先頭に移動し、他は元の順序を維持する（デフォルト）。
          SQLite バックエンド使用時は 1 クエリのバッチ集約で高速化される。
- full:   全候補をスコアでソートする。変換精度は同等だが処理コストが高い。"
  :type '(choice (const simple) (const full))
  :group 'skk-smart)

(defcustom skk-smart-debug nil
  "non-nil のとき変換・学習のたびに動作詳細を *skk-smart-debug* バッファに出力する。"
  :type 'boolean
  :group 'skk-smart)

;;; ============================================================
;;; Internal variables
;;; ============================================================

(defvar skk-smart-alist nil
  "コンテキスト学習データ。(midasi . entries) の連想リスト。
各 entries は ((context-words . confirmed-word) ...) の形式。")

(defvar skk-smart--sqlite-db nil
  "オープン済みの SQLite データベース接続オブジェクト。未接続なら nil。
Emacs 29.1 以降の組み込み sqlite 機能を使用する。")

(defvar skk-smart--corpus-file-opened nil
  "最後にオープンしたコーパスファイルのパス。
`skk-smart--corpus-ensure-open' が `skk-smart-corpus-file' と比較し、
ファイルが変更されていた場合に古いバックエンドを自動クローズするために使用する。")

(defvar skk-smart--server-comp-stack nil
  "サーバー補完候補のリランク済みスタック。skk-smart-comp-by-server-completion が使用。")

(defvar skk-smart--pending nil
  "保留中の学習データ。(midasi context-words word buffer marker word-len) の形式。
`skk-smart-context-update' が設定し、`skk-smart--flush-pending' が処理する。")

(defvar skk-smart--pending-commands 0
  "前回確定からのコマンド実行回数。`skk-smart--tick-pending' が更新する。")


;;; ============================================================
;;; Debug logging
;;; ============================================================

(defun skk-smart--log-to-buffer (label text)
  "デバッグログを *skk-smart-debug* バッファに追記する。"
  (with-current-buffer (get-buffer-create "*skk-smart-debug*")
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert (format "[skk-smart %-8s %s] %s\n"
                      label
                      (format-time-string "%H:%M:%S.%3N")
                      text)))))

(defmacro skk-smart--log (label fmt &rest args)
  "skk-smart-debug が非 nil のとき *skk-smart-debug* バッファにログを書く。
LABEL はログの種別文字列（SEARCH / SCORES / RESULT / CORPUS / LEARN / COMMIT など）。"
  `(when skk-smart-debug
     (skk-smart--log-to-buffer ,label (format ,fmt ,@args))))

(defun skk-smart--debug-scores-lines (scoring-part scores reranked)
  "SCORES / RERANKED から上位 5 件のスコア行を文字列リストで返す。
各行の形式: \"  候補   score  (旧位置→新位置) ★\"
★ は順位が上がった候補に付く。SCORING-PART が元の順序の基準。"
  (let* ((orig (mapcar #'skk-smart--candidate-string scoring-part))
         (top5 (seq-take reranked (min 5 (length reranked)))))
    (cl-loop for c in top5
             for new-i from 0
             for cstr = (skk-smart--candidate-string c)
             for old-i = (or (cl-position cstr orig :test #'equal) 0)
             for score = (gethash cstr scores 0)
             collect (format "  %-10s %.3f  (%d→%d)%s"
                             cstr score old-i new-i
                             (if (> old-i new-i) " ★" "")))))

;;; ============================================================
;;; Internal functions (pure, testable without SKK)
;;; ============================================================

(defconst skk-smart--kanji-regexp
  ;; Emacs の文字カテゴリ C (Chinese = CJK 漢字) を使用
  ;; ひらがな・カタカナは含まない
  "\\cC+"
  "漢字（CJK 統合漢字）の連続にマッチする正規表現。")

(defun skk-smart--extract-kanji-words (text)
  "TEXT から漢字語（CJK 文字列）を抽出してリストで返す。
ひらがな・カタカナ・ASCII は区切りとして扱われる。"
  (let (result (start 0))
    (while (string-match skk-smart--kanji-regexp text start)
      (push (match-string 0 text) result)
      (setq start (match-end 0)))
    (nreverse result)))

(defun skk-smart--candidate-string (candidate)
  "CANDIDATE の文字列部分を返す。
注釈付き候補（cons セル）の場合は car を返す。
文字列候補に ';' が含まれる場合は ';' 以前の部分のみを返す（注釈を除去する）。
SKK では送り仮名エントリの候補が \"効;(effect) 薬が効く\" の形式で渡される。"
  (let ((s (if (consp candidate) (car candidate) candidate)))
    (if (string-match ";" s) (substring s 0 (match-beginning 0)) s)))

(defun skk-smart--list-overlap-count (list1 list2)
  "LIST1 と LIST2 の共通要素数を返す（`equal' で比較）。"
  (let ((count 0))
    (dolist (e list1)
      (when (member e list2)
        (setq count (1+ count))))
    count))

(defun skk-smart--compute-scores (candidates context-words entries)
  "CANDIDATES のスコアを CONTEXT-WORDS と ENTRIES から計算して返す。

ENTRIES は ((context-words-list . confirmed-word) ...) の形式。
戻り値は candidate-string をキー、スコアを値とする hash-table。

スコアはその候補がコンテキストの漢字語とオーバーラップした回数の累積値。"
  (let ((ht (make-hash-table :test #'equal :size (length candidates))))
    (dolist (c candidates)
      (puthash (skk-smart--candidate-string c) 0 ht))
    (when (and entries context-words)
      ;; context-words をハッシュセット化してエントリループ内の照合を O(1) にする
      (let* ((effective-entries (if (> skk-smart-max-score-entries 0)
                                    (seq-take entries skk-smart-max-score-entries)
                                  entries))
             (ctx-set (make-hash-table :test #'equal
                                       :size (length context-words))))
        (dolist (w context-words) (puthash w t ctx-set))
        (dolist (entry effective-entries)
          (let* ((entry-ctx  (car entry))
                 (entry-word (cdr entry))
                 (overlap    (let ((n 0))
                               (dolist (w entry-ctx)
                                 (when (gethash w ctx-set)
                                   (setq n (1+ n))))
                               n)))
            ;; overlap > 0 のエントリのみ gethash を呼ぶ
            (when (> overlap 0)
              (let ((cur (gethash entry-word ht)))
                (when cur
                  (puthash entry-word (+ cur overlap) ht))))))))
    ht))

(defun skk-smart--rerank (candidates scores)
  "CANDIDATES を SCORES (降順) で安定ソートして返す。

スコアが同じ場合は元の順序を維持する。
SCORES は candidate-string をキー、スコアを値とする hash-table。"
  (let ((indexed nil)
        (i 0))
    (dolist (c candidates)
      (let ((score (gethash (skk-smart--candidate-string c) scores 0)))
        (push (list c score i) indexed))
      (setq i (1+ i)))
    (setq indexed (nreverse indexed))
    (mapcar #'car
            (sort indexed
                  (lambda (a b)
                    (or (> (nth 1 a) (nth 1 b))
                        (and (= (nth 1 a) (nth 1 b))
                             (< (nth 2 a) (nth 2 b)))))))))

(defun skk-smart--rerank-simple (candidates scores)
  "CANDIDATES の中でスコアが最大の候補のみ先頭に移動し、他は元の順序を維持する。

最大スコアが 0 以下（コンテキスト信号なし）のときは元の順序を返す。
同点最大の場合は元の順序で最も前にある候補を先頭にする。
SCORES は candidate-string をキー、スコアを値とする hash-table。"
  (let ((best-score 0.0)
        (best-cand nil))
    (dolist (c candidates)
      (let ((s (gethash (skk-smart--candidate-string c) scores 0.0)))
        (when (> s best-score)
          (setq best-score s
                best-cand c))))
    (if (null best-cand)
        candidates
      (cons best-cand
            (cl-remove best-cand candidates :test #'equal)))))

(defun skk-smart--add-entry (midasi context-words word)
  "MIDASI の見出し語に対し、CONTEXT-WORDS の状況で WORD が確定したことを記録する。
`skk-smart-alist' を更新する。"
  (let ((existing (assoc midasi skk-smart-alist))
        (new-entry (cons context-words word)))
    (if existing
        (progn
          (setcdr existing (cons new-entry (cdr existing)))
          ;; 上限を超えた古いエントリを切り捨てる
          (let ((tail (nthcdr skk-smart-max-entries-per-midasi (cdr existing))))
            (when tail
              (setcdr (nthcdr (1- skk-smart-max-entries-per-midasi)
                              (cdr existing))
                      nil))))
      (push (cons midasi (list new-entry)) skk-smart-alist))))

(defun skk-smart--context-since-last-sentence (text)
  "TEXT の直近の文末記号（。！？改行）以降の部分文字列を返す。
文末記号がなければ TEXT 全体を返す。"
  (let ((i (1- (length text)))
        result)
    (while (and (>= i 0) (not result))
      (when (memq (aref text i) '(?。 ?！ ?？ ?\n))
        (setq result (1+ i)))
      (cl-decf i))
    (if result (substring text result) text)))

(defun skk-smart--trim-context-words (words)
  "WORDS を `skk-smart-max-context-words' で切り詰めて返す。
変換位置に近い語（リスト末尾）を優先して残す。"
  (if (and (> skk-smart-max-context-words 0)
           (> (length words) skk-smart-max-context-words))
      (last words skk-smart-max-context-words)
    words))

(defun skk-smart--get-context-word-pair (buffer pos)
  "BUFFER の POS 前のテキストを一度だけ読み取り (current-words . prev-words) を返す。
current-words は直近の文の漢字語、prev-words は前の文の漢字語。
どちらも `skk-smart-max-context-words' で上限を切る。"
  (with-current-buffer buffer
    (let* ((start        (max (point-min) (- pos skk-smart-context-chars)))
           (text         (buffer-substring-no-properties start pos))
           (current-text (skk-smart--context-since-last-sentence text))
           (current-words (skk-smart--trim-context-words
                           (skk-smart--extract-kanji-words current-text)))
           (prev-words   (when (> skk-smart-prev-sentence-weight 0)
                           (let* ((prev-end (- (length text) (length current-text)))
                                  (prev-text (substring text 0 prev-end)))
                             (skk-smart--trim-context-words
                              (skk-smart--extract-kanji-words prev-text))))))
      (cons current-words prev-words))))

(defun skk-smart--get-context-words (buffer pos)
  "BUFFER 内の POS より前の漢字語リストを返す（現在の文のみ）。
学習記録など current-words だけ必要な場面で使う。"
  (car (skk-smart--get-context-word-pair buffer pos)))

(defun skk-smart--get-prev-context-words (buffer pos)
  "BUFFER 内の POS より前の、直近の文末記号より前にある漢字語リストを返す。
`skk-smart-prev-sentence-weight' が 0 のときは nil を返す。"
  (cdr (skk-smart--get-context-word-pair buffer pos)))

(defun skk-smart--compute-jisyo-scores (candidates)
  "CANDIDATES の辞書内位置から prior スコアを計算して返す。

先頭（SKK 学習で最後に確定した語）ほど高く、1/(index+1) で減衰する。
重み付けは呼び出し側で `skk-smart-jisyo-weight' を掛けて行う。
戻り値は (candidate-string . score) の連想リスト。"
  (let ((i 0))
    (mapcar (lambda (c)
              (prog1 (cons (skk-smart--candidate-string c) (/ 1.0 (1+ i)))
                (setq i (1+ i))))
            candidates)))

(defun skk-smart--henkan-start-pos (buffer)
  "BUFFER 内の `skk-henkan-start-point' の位置を返す。未設定なら nil。"
  (with-current-buffer buffer
    (and (boundp 'skk-henkan-start-point)
         skk-henkan-start-point
         (markerp skk-henkan-start-point)
         (marker-position skk-henkan-start-point))))

;;; ============================================================
;;; Corpus backend (SQLite)
;;; ============================================================

(defun skk-smart--corpus-ensure-open ()
  "共起統計 SQLite ファイルを必要に応じて初期化する。

`skk-smart-corpus-file' が前回オープン時と異なる場合、古い接続を
自動クローズしてからオープンし直す（キャッシュもクリアされる）。

Emacs 29.1 以降の組み込み sqlite3 が必要。
エラーはキャッチして握りつぶす（ファイルが壊れていても落ちない）。
デバッグ時は `skk-smart-debug' を non-nil にするとエラーログが記録される。"
  (when (and skk-smart-corpus-file
             (not (equal skk-smart-corpus-file skk-smart--corpus-file-opened))
             skk-smart--sqlite-db)
    (skk-smart--corpus-close))
  (when (and skk-smart-corpus-file
             (null skk-smart--sqlite-db))
    (condition-case err
        (when (file-readable-p skk-smart-corpus-file)
          (unless (fboundp 'sqlite-open)
            (error "skk-smart には Emacs 29.1 以降が必要です"))
          (setq skk-smart--sqlite-db (sqlite-open skk-smart-corpus-file))
          (setq skk-smart--corpus-file-opened skk-smart-corpus-file))
      (error
       (skk-smart--log "CORPUS" "ensure-open failed: %s" (error-message-string err))
       nil))))

(defun skk-smart--sqlite-lookup (candidate context-word)
  "SQLite バックエンドで CANDIDATE と CONTEXT-WORD の共起スコアを返す。
バックエンド未接続なら 0 を返す。"
  (condition-case _err
      (let ((rows (sqlite-select
                   skk-smart--sqlite-db
                   "SELECT score FROM cooccurrence WHERE candidate=? AND context_word=?"
                   (list candidate context-word))))
        (if rows (caar rows) 0))
    (error 0)))

(defun skk-smart--sqlite-compute-corpus-scores-batch (candidates context-words &optional okurigana)
  "SQLite で CANDIDATES × CONTEXT-WORDS の共起スコアを集約クエリ 1 発で返す。

N×W 個別クエリの代わりに単一の集約 SQL を使うため、コールドキャッシュ時に
特に高速。`skk-smart-rerank-mode' が `simple' のとき
`skk-smart--compute-corpus-scores' から呼ばれる。

OKURIGANA が non-nil のとき、候補文字列に okurigana を付加して DB 検索する。
SKK の送り仮名エントリでは候補が漢字のみ（\"効\"）だが corpus は
フル形式（\"効く\"）で格納されているため、この変換が必要。

戻り値は candidate-string（注釈除去済み短形式）をキー、SUM(score) を値とする hash-table。
DB に存在しない候補のスコアは 0。"
  (let ((ht (make-hash-table :test #'equal :size (length candidates))))
    (dolist (c candidates)
      (puthash (skk-smart--candidate-string c) 0 ht))
    (when (and skk-smart--sqlite-db candidates context-words)
      (let* ((cstrs    (mapcar #'skk-smart--candidate-string candidates))
             ;; DB検索キー: okurigana があれば付加（例: "効" → "効く"）
             (db-cstrs (if okurigana
                           (mapcar (lambda (s) (concat s okurigana)) cstrs)
                         cstrs))
             ;; DB返却キー → ht キーの逆引きマップ
             (revmap   (let ((m (make-hash-table :test #'equal)))
                         (cl-mapc (lambda (db ht-key) (puthash db ht-key m))
                                  db-cstrs cstrs)
                         m))
             (ph-c     (mapconcat (lambda (_) "?") db-cstrs ","))
             (ph-w     (mapconcat (lambda (_) "?") context-words ","))
             (sql      (format
                        "SELECT candidate, SUM(score) AS total FROM cooccurrence WHERE candidate IN (%s) AND context_word IN (%s) GROUP BY candidate"
                        ph-c ph-w))
             (params   (append db-cstrs context-words))
             (rows     (condition-case _err
                           (sqlite-select skk-smart--sqlite-db sql params)
                         (error nil))))
        (dolist (row rows)
          (when (car row)
            ;; DB キーを ht キーに逆引き（okurigana なしなら同一）
            (let ((ht-key (gethash (car row) revmap (car row))))
              (puthash ht-key (or (cadr row) 0) ht))))))
    ht))

(defun skk-smart--corpus-lookup (candidate context-word)
  "CANDIDATE と CONTEXT-WORD の共起スコアを返す。
バックエンド未初期化または `skk-smart-corpus-file' が nil なら 0。"
  (skk-smart--corpus-ensure-open)
  (if skk-smart--sqlite-db
      (skk-smart--sqlite-lookup candidate context-word)
    0))

(defun skk-smart--corpus-close ()
  "共起統計 SQLite 接続を閉じる。`kill-emacs-hook' に追加して使用する。"
  (when skk-smart--sqlite-db
    (condition-case _err
        (sqlite-close skk-smart--sqlite-db)
      (error nil))
    (setq skk-smart--sqlite-db nil))
  (setq skk-smart--corpus-file-opened nil))

;;; ============================================================
;;; Corpus scoring
;;; ============================================================

(defun skk-smart--compute-corpus-scores (candidates context-words &optional okurigana)
  "CANDIDATES の各候補について共起統計スコアを計算して返す。

CONTEXT-WORDS の各語との共起スコアを合計する。
戻り値は candidate-string をキー、合計スコアを値とする hash-table。

OKURIGANA が non-nil のとき、corpus DB 検索キーに okurigana を付加する。
SKK の送り仮名エントリでは候補が短形式（\"効\"）だが corpus は
フル形式（\"効く\"）で格納されているため、この変換が必要。
ht キーは常に注釈除去済みの短形式（`skk-smart--candidate-string' の戻り値）を使う。

バックエンド未設定 (`skk-smart-corpus-file' が nil) なら全スコア 0。

SQLite バックエンドが初期化済みのとき、`skk-smart--sqlite-lookup' で直接クエリする。
バックエンド未初期化のとき（テストモックなど）は `skk-smart--corpus-lookup' にフォールバックする。

D: 候補数 × 語数 が `skk-smart-max-corpus-total-lookups' を超える場合、
候補数を floor(上限 / 語数) に縮小してワーストケースのルックアップ数を保証する。"
  ;; D: total-lookups ハード上限
  (when (and context-words
             (> skk-smart-max-corpus-total-lookups 0)
             (> (* (length candidates) (length context-words))
                skk-smart-max-corpus-total-lookups))
    (setq candidates
          (seq-take candidates
                    (max 1 (/ skk-smart-max-corpus-total-lookups
                               (length context-words))))))
  (let ((ht (make-hash-table :test #'equal :size (length candidates)))
        (t0 (when skk-smart-debug (float-time))))
    (cond
     ;; context-words が nil または corpus-file 未設定: 全スコア 0
     ((not (and context-words skk-smart-corpus-file))
      (dolist (c candidates)
        (puthash (skk-smart--candidate-string c) 0 ht)))
     ;; SQLite 初期化済み + simple モード: 集約クエリ 1 発で高速化
     ((and skk-smart--sqlite-db (eq skk-smart-rerank-mode 'simple))
      (let ((batch (skk-smart--sqlite-compute-corpus-scores-batch
                    candidates context-words okurigana)))
        (maphash (lambda (k v) (puthash k v ht)) batch)))
     ;; SQLite 初期化済み（full モード）: 個別クエリ + キャッシュ
     (skk-smart--sqlite-db
      (dolist (c candidates)
        (let* ((cstr    (skk-smart--candidate-string c))
               (db-cstr (concat cstr (or okurigana "")))
               (sum     (let ((s 0))
                          (dolist (w context-words)
                            (setq s (+ s (skk-smart--sqlite-lookup db-cstr w))))
                          s)))
          (puthash cstr sum ht))))
     ;; バックエンド未初期化: skk-smart--corpus-lookup 経由（テストモック用）
     (t
      (dolist (c candidates)
        (let* ((cstr    (skk-smart--candidate-string c))
               (db-cstr (concat cstr (or okurigana "")))
               (sum     (let ((s 0))
                          (dolist (w context-words)
                            (setq s (+ s (skk-smart--corpus-lookup db-cstr w))))
                          s)))
          (puthash cstr sum ht)))))
    (when skk-smart-debug
      (skk-smart--log-to-buffer
       "CORPUS"
       (format "n=%d ctx=%d elapsed=%.2fms"
               (length candidates) (length context-words)
               (* 1000.0 (- (float-time) t0)))))
    ht))

(defun skk-smart--limit-corpus-words (words limit)
  "WORDS を LIMIT 件（0 以下なら制限なし）に絞る。末尾（変換位置に近い語）を優先。"
  (if (and (> limit 0) (> (length words) limit))
      (last words limit)
    words))

(defun skk-smart--compute-combined-scores (candidates current-words prev-words entries
                                            &optional okurigana)
  "CANDIDATES のスコアを学習データと共起統計を組み合わせて計算する。

現在の文（CURRENT-WORDS）は重み 1.0、前の文（PREV-WORDS）は
`skk-smart-prev-sentence-weight' を掛けて合算する。

final = learned_weight  × (current_learned + prev_weight × prev_learned)
      + corpus_weight   × (current_corpus  + prev_weight × prev_corpus)

OKURIGANA が non-nil のとき corpus DB 検索キーに付加する（送り仮名エントリ対応）。
corpus ルックアップ語数は `skk-smart-max-corpus-context-words'（現在文）と
`skk-smart-max-prev-corpus-words'（前文）で別々に制限される。

戻り値は candidate-string をキー、float-score を値とする hash-table。"
  (let* ((cur-corpus-words (skk-smart--limit-corpus-words
                            current-words skk-smart-max-corpus-context-words))
         (prv-corpus-words (when prev-words
                             (skk-smart--limit-corpus-words
                              prev-words skk-smart-max-prev-corpus-words)))
         (cur-learned (skk-smart--compute-scores candidates current-words entries))
         (cur-corpus  (skk-smart--compute-corpus-scores candidates cur-corpus-words okurigana))
         (prv-learned (when prev-words
                        (skk-smart--compute-scores candidates prev-words entries)))
         (prv-corpus  (when prv-corpus-words
                        (skk-smart--compute-corpus-scores candidates prv-corpus-words okurigana)))
         (pw  skk-smart-prev-sentence-weight)
         (lw  skk-smart-learned-weight)
         (cw  skk-smart-corpus-weight)
         (ht  (make-hash-table :test #'equal :size (length candidates))))
    (dolist (c candidates)
      (let* ((cstr (skk-smart--candidate-string c))
             (cl   (gethash cstr cur-learned 0))
             (cc   (gethash cstr cur-corpus  0))
             (pl   (if prv-learned (gethash cstr prv-learned 0) 0))
             (pc   (if prv-corpus  (gethash cstr prv-corpus  0) 0))
             (final (+ (* lw (+ cl (* pw pl)))
                       (* cw (+ cc (* pw pc))))))
        (puthash cstr final ht)))
    ht))

;;; ============================================================
;;; Pending mechanism
;;; ============================================================

(defun skk-smart--store-pending (midasi context-words word buffer okurigana)
  "確定データを BUFFER のマーカー付きで保留する。
OKURIGANA 分と WORD 分だけ BUFFER 内の現在位置から遡ってマーカーを設定する。
`post-command-hook' に `skk-smart--tick-pending' を追加する。"
  (let* ((word-str  (skk-smart--candidate-string word))
         (okuri-len (length (or okurigana "")))
         (word-len  (length word-str))
         (marker    (with-current-buffer buffer
                      (save-excursion
                        (forward-char (- 0 okuri-len word-len))
                        (point-marker)))))
    (setq skk-smart--pending
          (list midasi context-words word-str buffer marker word-len)
          ;; -1 から始める理由:
          ;; add-hook の直後、確定コマンド自体の post-command-hook が 1 回発火して
          ;; skk-smart--tick-pending が -1 → 0 にカウントアップする。
          ;; これにより「確定コマンドそのもの」を待機カウントに含めず、
          ;; skk-smart-pending-wait の値がそのまま「確定後の次のコマンドから数えて
          ;; N 回」という直感的な意味になる。
          skk-smart--pending-commands -1))
  (add-hook 'post-command-hook #'skk-smart--tick-pending))

(defun skk-smart--flush-pending ()
  "保留中の学習データをコミットまたは破棄する。
マーカー位置の語がまだ変更されていなければ `skk-smart--add-entry' で記録する。
変更されていれば記録せず破棄する（ユーザーが確定語を訂正したケース）。"
  (when skk-smart--pending
    (remove-hook 'post-command-hook #'skk-smart--tick-pending)
    (cl-destructuring-bind (midasi context-words word buffer marker word-len)
        skk-smart--pending
      (setq skk-smart--pending nil
            skk-smart--pending-commands 0)
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (let* ((start (marker-position marker))
                 (end   (and start (+ start word-len)))
                 (current (and start end
                               (<= (point-min) start)
                               (<= end (point-max))
                               (buffer-substring-no-properties start end))))
            (if (and current (string= current word))
                (progn
                  (skk-smart--log "COMMIT"
                                  "midasi=%s  word=%s  ctx=%s  → committed"
                                  midasi word context-words)
                  (skk-smart--add-entry midasi context-words word))
              (skk-smart--log "COMMIT"
                              "midasi=%s  word=%s  → discarded (text changed)"
                              midasi word))))))))

(defun skk-smart--tick-pending ()
  "コマンド実行回数をカウントし、閾値到達で `skk-smart--flush-pending' を呼ぶ。
`post-command-hook' に登録して使用する。"
  (when skk-smart--pending
    (setq skk-smart--pending-commands (1+ skk-smart--pending-commands))
    (when (>= skk-smart--pending-commands skk-smart-pending-wait)
      (skk-smart--flush-pending))))

;;; ============================================================
;;; Server completion reranking
;;; ============================================================

(defun skk-smart--score-comp-candidate (reading current-words prev-words)
  "READING 候補の文脈スコアを返す。

skk-smart-alist の READING エントリと CURRENT-WORDS / PREV-WORDS のオーバーラップ累計値。
PREV-WORDS には `skk-smart-prev-sentence-weight' を掛けて合算する。
学習データがない場合は 0 を返す。"
  (let ((entries (cdr (assoc reading skk-smart-alist)))
        (score 0))
    (dolist (entry entries)
      (let ((ctx (car entry)))
        (setq score (+ score
                       (skk-smart--list-overlap-count ctx current-words)
                       (* skk-smart-prev-sentence-weight
                          (skk-smart--list-overlap-count ctx prev-words))))))
    score))

(defun skk-smart--rerank-comp-candidates (candidates current-words prev-words)
  "CANDIDATES（読み文字列のリスト）を CURRENT-WORDS / PREV-WORDS に基づいてリランクする。
スコア降順の安定ソート。スコアが 0 のとき元の順序を維持する。"
  (let ((indexed nil)
        (i 0))
    (dolist (c candidates)
      (push (list c (skk-smart--score-comp-candidate c current-words prev-words) i) indexed)
      (setq i (1+ i)))
    (setq indexed (nreverse indexed))
    (mapcar #'car
            (sort indexed
                  (lambda (a b)
                    (or (> (nth 1 a) (nth 1 b))
                        (and (= (nth 1 a) (nth 1 b))
                             (< (nth 2 a) (nth 2 b)))))))))

;;;###autoload
(defun skk-smart--comp-rerank-advice (orig-fun key prefix prog-list)
  "`skk-comp-get-all-candidates' の結果をコンテキストでリランクするアドバイス。

dcomp 複数表示（`skk-dcomp-multiple-activate'）や TAB 補完一覧
（`skk-completion-search' 経由）で候補が一括取得される場面に対応する。

skk-smart-alist にエントリがない、またはコンテキスト漢字語がない場合は
元の順序のまま返す。"
  (let* ((candidates    (funcall orig-fun key prefix prog-list))
         (pair          (skk-smart--get-context-word-pair (current-buffer) (point)))
         (current-words (car pair))
         (prev-words    (cdr pair)))
    (if (and candidates current-words skk-smart-alist)
        (skk-smart--rerank-comp-candidates candidates current-words prev-words)
      candidates)))

;;;###autoload
(defun skk-smart-comp-by-server-completion ()
  "skk-smart によるコンテキストリランキング付きサーバー補完プログラム。

`skk-completion-prog-list' に追加して使用する。
`skk-comp-by-server-completion' の代替として機能する。

最初の呼び出し時（`skk-comp-first' が non-nil）にサーバーから全候補を取得し、
バッファの文脈に基づいてリランクしてから順に返す。
2 回目以降の呼び出しではリランク済みのスタックから順に返し、
候補がなくなったら nil を返す。"
  (when skk-comp-first
    (let* ((key skk-comp-key)
           (midasi-list (when (and key (fboundp 'skk-server-completion-search-midasi))
                          (skk-server-completion-search-midasi key)))
           (pair          (skk-smart--get-context-word-pair (current-buffer) (point)))
           (context-words (car pair))
           (prev-words    (cdr pair)))
      (setq skk-smart--server-comp-stack
            (if (and midasi-list skk-smart-alist context-words)
                (skk-smart--rerank-comp-candidates midasi-list context-words prev-words)
              midasi-list))))
  (pop skk-smart--server-comp-stack))

;;; ============================================================
;;; Hook functions
;;; ============================================================

;;;###autoload
(defun skk-smart-context-search (henkan-buffer midasi okurigana entry)
  "コンテキストに基づいて ENTRY の変換候補を並び替える。

`skk-search-end-function' に追加して使用する。
引数は (henkan-buffer midasi okurigana entry)。

HENKAN-BUFFER の変換位置前のテキストから漢字語を抽出し、
過去に同様のコンテキストで確定した候補や共起統計を使って
スコアの高い候補を上位に移動させる。

OKURIGANA が non-nil のとき corpus DB 検索キーに付加する。
SKK の送り仮名エントリ（midasi が \"きk\" 形式）では候補が短形式（\"効\"）で
渡されるが corpus はフル形式（\"効く\"）で格納されているため、この変換が必要。"
  (let ((t0 (when skk-smart-debug (float-time))))
    (if (not (and entry (cdr entry)))
        (progn
          (skk-smart--log "SKIP" "midasi=%s  reason=single-cand" midasi)
          entry)
      ;; 学習データも corpus 設定も jisyo-weight もない場合は早期リターン
      (let ((entries (cdr (assoc midasi skk-smart-alist))))
        (if (not (or entries skk-smart-corpus-file (> skk-smart-jisyo-weight 0)))
            (progn
              (skk-smart--log "SKIP" "midasi=%s  reason=no-sources" midasi)
              entry)
          (let* (;; スコアリング窓: 先頭 max-candidates 件のみ対象にする
                 (win-size     (and skk-smart-max-candidates
                                    (> skk-smart-max-candidates 0)
                                    skk-smart-max-candidates))
                 (scoring-part (if (and win-size (> (length entry) win-size))
                                   (seq-take entry win-size)
                                 entry))
                 (tail-part    (when (and win-size (> (length entry) win-size))
                                 (seq-drop entry win-size)))
                 (pos          (skk-smart--henkan-start-pos henkan-buffer))
                 (pair         (when pos
                                 (skk-smart--get-context-word-pair henkan-buffer pos)))
                 (context-words (car pair))
                 (prev-words    (cdr pair))
                 ;; コンテキスト信号がある場合のみ context/corpus スコアを計算
                 (ctx-scores   (when (and context-words
                                         (or entries skk-smart-corpus-file))
                                 (skk-smart--compute-combined-scores
                                  scoring-part context-words prev-words entries
                                  ;; 送り仮名エントリ: okurigana を corpus DB キーに付加
                                  (when (and okurigana (not (string-empty-p okurigana)))
                                    okurigana))))
                 ;; 辞書位置 prior（jisyo-weight > 0 のとき常に計算）
                 (jisyo-scores (when (> skk-smart-jisyo-weight 0)
                                 (skk-smart--compute-jisyo-scores scoring-part)))
                 ;; 合成: ctx-scores (hash-table) と jisyo-scores (alist) をマージ
                 (scores       (cond
                                ((and ctx-scores jisyo-scores)
                                 ;; jisyo スコアを ctx-scores hash-table に加算（破壊的変更 OK、局所変数）
                                 (dolist (pair jisyo-scores)
                                   (let* ((cstr (car pair))
                                          (cur  (gethash cstr ctx-scores 0)))
                                     (puthash cstr
                                              (+ cur (* skk-smart-jisyo-weight (cdr pair)))
                                              ctx-scores)))
                                 ctx-scores)
                                (ctx-scores   ctx-scores)
                                (jisyo-scores
                                 ;; ctx-scores なし: jisyo スコアのみを hash-table に変換
                                 (let ((ht (make-hash-table :test #'equal
                                                            :size (length scoring-part))))
                                   (dolist (pair jisyo-scores)
                                     (puthash (car pair)
                                              (* skk-smart-jisyo-weight (cdr pair))
                                              ht))
                                   ht))
                                (t nil))))
            ;; SEARCH ログ: スコア計算の概要（scores が nil でも出力）
            (when skk-smart-debug
              (let* ((n-total   (length entry))
                     (n-scoring (length scoring-part))
                     (sources   (mapconcat #'identity
                                           (delq nil
                                                 (list (when (> skk-smart-jisyo-weight 0) "jisyo")
                                                       (when entries "learned")
                                                       (when skk-smart-corpus-file "corpus")))
                                           "+")))
                (skk-smart--log-to-buffer
                 "SEARCH"
                 (format "midasi=%s  n=%d(scoring=%d)  ctx=%s  prev=%s  entries=%d  sources=[%s]"
                         midasi n-total n-scoring
                         context-words prev-words
                         (length entries) sources))))
            (if (not scores)
                (progn
                  (skk-smart--log "SKIP" "midasi=%s  reason=no-context" midasi)
                  entry)
              ;; リランク実行（simple モードは最高スコア候補のみ先頭移動）
              (let* ((reranked (if (eq skk-smart-rerank-mode 'simple)
                                   (skk-smart--rerank-simple scoring-part scores)
                                 (skk-smart--rerank scoring-part scores)))
                     (result   (append reranked tail-part)))
                (when skk-smart-debug
                  ;; SCORES: 上位 5 件の順位変化とスコア
                  (dolist (line (skk-smart--debug-scores-lines scoring-part scores reranked))
                    (skk-smart--log-to-buffer "SCORES" line))
                  ;; RESULT: 経過時間・top-3 前後・移動した候補数
                  (let* ((orig    (mapcar #'skk-smart--candidate-string scoring-part))
                         (new     (mapcar #'skk-smart--candidate-string reranked))
                         (moved   (cl-loop for o in orig for n in new
                                           count (not (equal o n))))
                         (before3 (mapconcat #'identity (seq-take orig (min 3 (length orig))) " "))
                         (after3  (mapconcat #'identity (seq-take new  (min 3 (length new)))  " ")))
                    (skk-smart--log-to-buffer
                     "RESULT"
                     (format "elapsed=%.2fms  [%s] ← [%s]  moved=%d"
                             (* 1000.0 (- (float-time) t0))
                             after3 before3 moved))))
                (setq entry result)))
            entry))))))

;;;###autoload
(defun skk-smart-context-update (henkan-buffer midasi okurigana word purge)
  "MIDASI の確定語 WORD とそのときのコンテキストを保留する。

`skk-update-end-function' に追加して使用する。
引数は (henkan-buffer midasi okurigana word purge)。

即時記録はせず、`skk-smart-pending-wait' 回のコマンド後に確定語が
バッファ上で変更されていないことを確認してから `skk-smart-alist' に記録する。

PURGE が non-nil のとき、または漢字コンテキストが空のときは記録しない。
前回の保留データがある場合はここで flush する。"
  (unless (or purge (null word) (string= word ""))
    (let* ((pos           (skk-smart--henkan-start-pos henkan-buffer))
           (context-words (when pos
                            (skk-smart--get-context-words henkan-buffer pos))))
      (when context-words
        (skk-smart--flush-pending)
        (skk-smart--log "LEARN"
                        "midasi=%s  word=%s  ctx=%s  (pending)"
                        midasi word context-words)
        (skk-smart--store-pending midasi context-words word henkan-buffer okurigana)))))

;;; ============================================================
;;; Persistence
;;; ============================================================

;;;###autoload
(defun skk-smart-save (&optional nomsg)
  "`skk-smart-alist' を `skk-smart-data-file' に保存する。"
  (interactive)
  (when skk-smart-alist
    (condition-case err
        (with-temp-file skk-smart-data-file
          (let ((print-level nil)
                (print-length nil))
            (prin1 skk-smart-alist (current-buffer))))
      (error
       (unless nomsg
         (message "skk-smart: 保存に失敗しました: %s" (error-message-string err)))))
    (unless nomsg
      (message "skk-smart: %s に保存しました" skk-smart-data-file))))

;;;###autoload
(defun skk-smart-load (&optional nomsg)
  "`skk-smart-data-file' から `skk-smart-alist' を読み込む。"
  (interactive)
  (when (file-readable-p skk-smart-data-file)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents skk-smart-data-file)
          (setq skk-smart-alist (read (current-buffer)))
          (unless nomsg
            (message "skk-smart: %s から読み込みました" skk-smart-data-file)))
      (error
       (unless nomsg
         (message "skk-smart: 読み込みに失敗しました: %s" (error-message-string err)))))))

;;; ============================================================
;;; Status
;;; ============================================================

;;;###autoload
(defun skk-smart-status ()
  "skk-smart の現在の状態を *skk-smart-status* バッファに表示する。"
  (interactive)
  (with-current-buffer (get-buffer-create "*skk-smart-status*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "=== skk-smart status ===\n\n")
      (insert (format "デバッグモード  : %s\n"
                      (if skk-smart-debug "有効" "無効 (M-x customize-variable skk-smart-debug で変更)")))
      (insert (format "データファイル  : %s\n" skk-smart-data-file))
      (insert (format "ファイル存在    : %s\n"
                      (if (file-readable-p skk-smart-data-file) "あり" "なし")))
      (insert (format "学習見出し語数  : %d\n" (length skk-smart-alist)))
      (insert (format "学習エントリ総数: %d\n"
                      (apply #'+ (mapcar (lambda (e) (length (cdr e))) skk-smart-alist))))
      (insert (format "共起コーパスファイル: %s\n"
                      (or skk-smart-corpus-file "未設定")))
      (insert (format "SQLite バックエンド: %s\n"
                      (if skk-smart--sqlite-db "接続済み" "未接続")))
      (insert (format "保留中の学習    : %s\n"
                      (if skk-smart--pending
                          (format "あり (midasi=%s, word=%s, あと %d コマンド)"
                                  (nth 0 skk-smart--pending)
                                  (nth 2 skk-smart--pending)
                                  (max 0 (- skk-smart-pending-wait
                                            skk-smart--pending-commands)))
                        "なし")))
      (when (> (length skk-smart-alist) 0)
        (insert "\n--- 学習済み見出し語（先頭 20 件）---\n")
        (let ((count 0))
          (dolist (e skk-smart-alist)
            (when (< count 20)
              (insert (format "  %s: %d エントリ\n" (car e) (length (cdr e))))
              (setq count (1+ count))))))
      (insert "\n--- フック登録状況 ---\n")
      (insert (format "  skk-search-end-function: %s\n"
                      (if (member #'skk-smart-context-search
                                  (bound-and-true-p skk-search-end-function))
                          "登録済み" "未登録")))
      (insert (format "  skk-update-end-function: %s\n"
                      (if (member #'skk-smart-context-update
                                  (bound-and-true-p skk-update-end-function))
                          "登録済み" "未登録")))
      (insert (format "  comp-rerank advice      : %s\n"
                      (if (advice-member-p #'skk-smart--comp-rerank-advice
                                           'skk-comp-get-all-candidates)
                          "登録済み" "未登録")))))
  (display-buffer "*skk-smart-status*"))

;;; ============================================================
;;; Setup
;;; ============================================================

;;;###autoload
(defun skk-smart-setup ()
  "skk-smart を SKK に登録する。

~/.skk に `(require 'skk-smart)' の後で呼び出すこと:

  (require 'skk-smart)
  (skk-smart-setup)

外部 API リランキングを有効にするには:

  (setq skk-smart-llm-function #'my-llm-rerank-function)"
  (add-to-list 'skk-search-end-function #'skk-smart-context-search)
  (add-to-list 'skk-update-end-function #'skk-smart-context-update)
  (advice-add 'skk-comp-get-all-candidates :around
              #'skk-smart--comp-rerank-advice)
  (add-hook 'kill-emacs-hook #'skk-smart--flush-pending)
  (add-hook 'kill-emacs-hook #'skk-smart-save)
  (add-hook 'kill-emacs-hook #'skk-smart--corpus-close)
  (skk-smart-load 'nomsg)
  (skk-smart--corpus-ensure-open))

(provide 'skk-smart)

;; Local Variables:
;; indent-tabs-mode: nil
;; coding: utf-8
;; End:

;;; skk-smart.el ends here
