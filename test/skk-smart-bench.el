;;; skk-smart-bench.el --- Performance benchmarks for skk-smart.el  -*- coding: utf-8; lexical-binding: t -*-

;; Copyright (C) 2026 SKK Development Team
;;
;; 使用方法:
;;   make bench
;;   または
;;   emacs --batch -L . -L ddskk -L test --eval "(load \"test/skk-smart-bench.el\")"

;;; Code:

(require 'cl-lib)
(require 'skk-smart)

;;; ============================================================
;;; データ生成
;;; ============================================================

(defun skk-smart-bench--make-candidates (n)
  "N 個のダミー候補リストを生成する。"
  (mapcar (lambda (i) (format "候補%03d" i)) (number-sequence 0 (1- n))))

(defun skk-smart-bench--make-words (n)
  "N 個のダミー漢字語リストを生成する（コンテキスト語・エントリ語共用）。"
  (mapcar (lambda (i) (format "文脈%03d" i)) (number-sequence 0 (1- n))))

(defun skk-smart-bench--make-entries (n candidates context-words)
  "N 個のダミー学習エントリを生成する。
エントリは ((ctx-word-a ctx-word-b) . confirmed-word) の形式。"
  (let ((nc (length candidates))
        (nw (length context-words)))
    (mapcar (lambda (i)
              (cons (list (nth (mod i nw) context-words)
                         (nth (mod (1+ i) nw) context-words))
                    (nth (mod i nc) candidates)))
            (number-sequence 0 (1- n)))))

;;; ============================================================
;;; 計測ユーティリティ
;;; ============================================================

(defun skk-smart-bench--run (label iterations thunk)
  "THUNK を ITERATIONS 回実行して median/p95 (ms) を表示・返す。
戻り値は (:median FLOAT :p95 FLOAT) の plist。"
  (let ((times (make-vector iterations 0.0)))
    (dotimes (i iterations)
      (let ((t0 (float-time)))
        (funcall thunk)
        (aset times i (* 1000.0 (- (float-time) t0)))))
    (sort times #'<)
    (let ((median (aref times (/ iterations 2)))
          (p95    (aref times (floor (* iterations 0.95)))))
      (message "  %-65s  median=%7.4fms  p95=%7.4fms" label median p95)
      (list :label label :median median :p95 p95))))

;;; ============================================================
;;; 個別ベンチマーク
;;; ============================================================

(defun skk-smart-bench-compute-scores (iterations)
  "skk-smart--compute-scores のベンチマーク。k=10/30/50/100 × E=30 W=10。"
  (message "\n[compute-scores]  k=候補数 E=学習エントリ数 W=コンテキスト語数")
  (dolist (k '(10 30 50 100))
    (let* ((candidates    (skk-smart-bench--make-candidates k))
           (context-words (skk-smart-bench--make-words 10))
           (entries       (skk-smart-bench--make-entries 30 candidates context-words))
           (skk-smart-max-score-entries 30))
      (skk-smart-bench--run
       (format "k=%3d E=30 W=10" k)
       iterations
       (lambda () (skk-smart--compute-scores candidates context-words entries))))))

(defun skk-smart-bench-compute-corpus-scores (iterations)
  "skk-smart--compute-corpus-scores のベンチマーク（コーパスルックアップをモック）。
実際のディスク I/O を除いた Elisp オーバーヘッドを測定する。"
  (message "\n[compute-corpus-scores]  コーパスルックアップをモック (戻り値=100 固定)")
  ;; skk-smart--corpus-lookup を上書きしてディスク I/O を排除
  (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
             (lambda (_cand _ctx) 100))
            (skk-smart-corpus-file "/dummy/path"))
    (dolist (k '(10 30 50 100))
      (let* ((candidates    (skk-smart-bench--make-candidates k))
             (context-words (skk-smart-bench--make-words 10)))
        (skk-smart-bench--run
         (format "k=%3d W=10" k)
         iterations
         (lambda () (skk-smart--compute-corpus-scores candidates context-words)))))))

(defun skk-smart-bench-compute-combined-scores (iterations)
  "skk-smart--compute-combined-scores のエンドツーエンドベンチマーク（コーパスモック）。"
  (message "\n[compute-combined-scores]  E=30 W=10+10(prev) コーパスモック")
  (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
             (lambda (_cand _ctx) 100))
            (skk-smart-corpus-file "/dummy/path"))
    (dolist (k '(10 30 50 100))
      (let* ((candidates    (skk-smart-bench--make-candidates k))
             (context-words (skk-smart-bench--make-words 10))
             (prev-words    (skk-smart-bench--make-words 10))
             (entries       (skk-smart-bench--make-entries 30 candidates context-words))
             (skk-smart-max-score-entries 30))
        (skk-smart-bench--run
         (format "k=%3d E=30 W=10+10" k)
         iterations
         (lambda ()
           (skk-smart--compute-combined-scores
            candidates context-words prev-words entries)))))))

(defun skk-smart-bench-rerank (iterations)
  "skk-smart--rerank のベンチマーク。k=10/30/50/100。"
  (message "\n[rerank]")
  (dolist (k '(10 30 50 100))
    (let* ((candidates (skk-smart-bench--make-candidates k))
           ;; scores は hash-table: candidate-string → float-score
           (scores     (let ((ht (make-hash-table :test #'equal :size k)))
                         (dolist (c candidates)
                           (puthash c (random 100) ht))
                         ht)))
      (skk-smart-bench--run
       (format "k=%3d" k)
       iterations
       (lambda () (skk-smart--rerank candidates scores))))))

;;; ============================================================
;;; compute-combined-scores: max-candidates 窓の効果
;;; ============================================================

(defun skk-smart-bench-max-candidates-effect (iterations)
  "max-candidates 設定による compute-combined-scores の削減効果を計測する。
k=100 で max-candidates を 10/30/50/nil と変えて比較する。"
  (message "\n[max-candidates effect on compute-combined-scores]  k=100 E=30 W=10+10")
  (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
             (lambda (_cand _ctx) 100))
            (skk-smart-corpus-file "/dummy/path"))
    (let* ((k       100)
           (candidates    (skk-smart-bench--make-candidates k))
           (context-words (skk-smart-bench--make-words 10))
           (prev-words    (skk-smart-bench--make-words 10))
           (entries       (skk-smart-bench--make-entries 30 candidates context-words))
           (skk-smart-max-score-entries 30))
      (dolist (win '(10 30 50 nil))
        (let* ((scoring-part (if (and win (> (length candidates) win))
                                 (seq-take candidates win)
                               candidates))
               (label (if win (format "max-candidates=%3d" win) "max-candidates=nil")))
          (skk-smart-bench--run
           label
           iterations
           (lambda ()
             (skk-smart--compute-combined-scores
              scoring-part context-words prev-words entries))))))))

;;; ============================================================
;;; 全ベンチマークを実行
;;; ============================================================

(defun skk-smart-run-benchmarks (&optional iterations)
  "全ベンチマークを実行して結果を表示する。
ITERATIONS のデフォルトは 2000。"
  (let ((n (or iterations 2000)))
    (message "")
    (message "=================================================================")
    (message " skk-smart benchmark  (%d iterations each)" n)
    (message "=================================================================")
    (skk-smart-bench-compute-scores n)
    (skk-smart-bench-compute-corpus-scores n)
    (skk-smart-bench-compute-combined-scores n)
    (skk-smart-bench-rerank n)
    (skk-smart-bench-max-candidates-effect n)
    (message "")
    (message "=================================================================")
    (message " done.")))

(skk-smart-run-benchmarks)

;;; skk-smart-bench.el ends here
