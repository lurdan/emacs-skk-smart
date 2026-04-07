;;; benchmark.el --- skk-smart SQLite ベンチマーク  -*- coding: utf-8; lexical-binding: t -*-
;;
;; 実行方法:
;;   emacs --batch -L /workspace \
;;         -l /workspace/tools/benchmark.el \
;;         --eval "(skk-smart-bench-run)" \
;;         2>&1 | tee /workspace/tools/benchmark-result.txt

;;; ============================================================
;;; 依存ロード
;;; ============================================================

(require 'skk-smart)

;;; ============================================================
;;; ベンチマーク設定
;;; ============================================================

;; コーパスファイルパス
(defconst bench-sqlite-path "/workspace/corpus/skk-cooccurrence-wikipedia.sqlite")

;; --- シナリオ定義 ---
;; 各シナリオ: (name candidates context-words n-trials)
;;   - candidates    : 変換候補リスト（実際の候補数を模擬）
;;   - context-words : コンテキスト語リスト（実際の語数を模擬）
;;   - n-trials      : 繰り返し回数

(defconst bench-scenarios
  '(
    ;; (name candidates context-words n-trials)
    ;; --- small: 少候補・短コンテキスト（軽い変換） ---
    ("small"   5  2  200)
    ;; --- medium: 典型的な変換（30候補 × 5コンテキスト語） ---
    ("medium"  30  5  100)
    ;; --- large: 多候補（max-candidates上限）× 多コンテキスト語 ---
    ("large"   30  10  50)
    ;; --- xlarge: D上限前後（候補100 × コンテキスト10） ---
    ("xlarge" 100  10  20)
    ))

;; テスト用候補セット（Wikipedia corpus に実在する語）
(defconst bench-candidates-pool
  '("効果" "高価" "行為" "対象" "適用" "現在" "以下" "以上" "関係" "記録"
    "世界" "日本" "時代" "部分" "問題" "結果" "場合" "方法" "状態" "目的"
    "機能" "構造" "内容" "処理" "管理" "制度" "社会" "経済" "政治" "文化"
    "技術" "開発" "環境" "教育" "情報" "運動" "組織" "活動" "支援" "研究"
    "国家" "地域" "都市" "区域" "範囲" "水準" "規模" "基準" "条件" "影響"
    "意味" "価値" "目標" "理由" "原因" "事実" "概念" "定義" "理論" "原則"
    "計画" "政策" "行政" "法律" "規則" "権利" "義務" "責任" "役割" "立場"
    "議論" "判断" "評価" "分析" "調査" "観察" "実験" "検証" "証明" "確認"
    "生産" "消費" "供給" "需要" "市場" "価格" "費用" "収入" "利益" "損失"
    "安全" "危険" "問題" "解決" "改善" "変化" "発展" "進歩" "革新" "改革"))

(defconst bench-context-pool
  '("年" "月" "日" "後" "人" "多" "第" "受" "日本" "対"
    "出" "入" "見" "持" "上" "呼" "取" "中" "場合" "他"
    "現在" "大" "際" "含" "生" "続" "同" "間" "次" "新"))

;;; ============================================================
;;; ユーティリティ
;;; ============================================================

(defun bench-take (n lst)
  "LST の先頭 N 件を返す。"
  (let (result)
    (dotimes (i (min n (length lst)))
      (push (nth i lst) result))
    (nreverse result)))

(defun bench-elapsed-ms (t0)
  "T0（float-time）からの経過ミリ秒を返す。"
  (* 1000.0 (- (float-time) t0)))

(defun bench-format-stats (times-ms)
  "TIMES-MS のリストから統計文字列を返す。"
  (let* ((n     (length times-ms))
         (total (apply #'+ times-ms))
         (mean  (/ total n))
         (sorted (sort (copy-sequence times-ms) #'<))
         (min-v  (car sorted))
         (max-v  (car (last sorted)))
         (p50    (nth (/ n 2) sorted))
         (p95    (nth (round (* 0.95 (1- n))) sorted))
         (p99    (nth (round (* 0.99 (1- n))) sorted)))
    (format "n=%d  total=%.1fms  mean=%.2fms  min=%.2fms  p50=%.2fms  p95=%.2fms  p99=%.2fms  max=%.2fms"
            n total mean min-v p50 p95 p99 max-v)))

;;; ============================================================
;;; コア計測関数
;;; ============================================================

(defun bench-run-scenario (scenario mode)
  "SCENARIO を MODE (:cold / :warm) で計測する。
戻り値: (mean-ms . times-ms-list)"
  (let* ((name       (nth 0 scenario))
         (n-cands    (nth 1 scenario))
         (n-ctx      (nth 2 scenario))
         (n-trials   (nth 3 scenario))
         (candidates (bench-take n-cands bench-candidates-pool))
         (ctx-words  (bench-take n-ctx bench-context-pool))
         ;; D 上限を無効化（公平比較のため）
         (skk-smart-max-corpus-total-lookups 0)
         times)

    (dotimes (i n-trials)
      ;; cold モード: 毎回キャッシュをクリア
      (when (eq mode :cold)
        (clrhash skk-smart--corpus-cache))
      (let ((t0 (float-time)))
        (skk-smart--compute-corpus-scores candidates ctx-words)
        (push (bench-elapsed-ms t0) times)))
    (cons (/ (apply #'+ times) (length times))
          (nreverse times))))

;;; ============================================================
;;; メイン計測ループ
;;; ============================================================

(defun bench-run-sqlite (corpus-file)
  "CORPUS-FILE（SQLite）で全シナリオを計測して結果を出力する。"
  (message "\n========================================")
  (message "Backend: SQLite  (%s)" corpus-file)
  (message "========================================")

  (skk-smart--corpus-close)
  (setq skk-smart-corpus-file corpus-file)
  (skk-smart--corpus-ensure-open)

  ;; rerank-mode: full（バッチ最適化なし、個別クエリ）
  (let ((skk-smart-rerank-mode 'full))
    (message "\n--- rerank-mode: full ---")
    (dolist (scenario bench-scenarios)
      (let* ((name    (nth 0 scenario))
             (n-cands (nth 1 scenario))
             (n-ctx   (nth 2 scenario)))

        (let* ((res   (bench-run-scenario scenario :cold))
               (times (cdr res)))
          (message "[%s / full / cold] cands=%d ctx=%d  %s"
                   name n-cands n-ctx (bench-format-stats times)))

        (bench-run-scenario scenario :cold) ; warm-up
        (let* ((res   (bench-run-scenario scenario :warm))
               (times (cdr res)))
          (message "[%s / full / warm] cands=%d ctx=%d  %s"
                   name n-cands n-ctx (bench-format-stats times))))))

  ;; rerank-mode: simple（SQLite バッチ最適化が有効になる）
  (let ((skk-smart-rerank-mode 'simple))
    (message "\n--- rerank-mode: simple ---")
    (dolist (scenario bench-scenarios)
      (let* ((name    (nth 0 scenario))
             (n-cands (nth 1 scenario))
             (n-ctx   (nth 2 scenario)))

        (let* ((res   (bench-run-scenario scenario :cold))
               (times (cdr res)))
          (message "[%s / simple / cold] cands=%d ctx=%d  %s"
                   name n-cands n-ctx (bench-format-stats times)))

        (bench-run-scenario scenario :cold) ; warm-up
        (let* ((res   (bench-run-scenario scenario :warm))
               (times (cdr res)))
          (message "[%s / simple / warm] cands=%d ctx=%d  %s"
                   name n-cands n-ctx (bench-format-stats times))))))

  (skk-smart--corpus-close))

;;; ============================================================
;;; エントリポイント
;;; ============================================================

(defun skk-smart-bench-run ()
  "SQLite の全シナリオベンチマークを実行する。"
  (message "skk-smart benchmark: SQLite")
  (message "Emacs version: %s" emacs-version)
  (message "Corpus rows: ~24.6M (Wikipedia)")
  (message "Scenarios: %s" (mapcar #'car bench-scenarios))
  (message "Candidates pool: %d words, Context pool: %d words"
           (length bench-candidates-pool) (length bench-context-pool))
  (message "")

  (if (file-readable-p bench-sqlite-path)
      (condition-case err
          (bench-run-sqlite bench-sqlite-path)
        (error (message "SQLite bench failed: %s" (error-message-string err))))
    (message "SQLite file not found: %s" bench-sqlite-path))

  (message "\nDone.")
  (kill-emacs 0))
