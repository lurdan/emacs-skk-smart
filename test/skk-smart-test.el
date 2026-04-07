;;; skk-smart-test.el --- Tests for skk-smart.el  -*- coding: utf-8; lexical-binding: t -*-

;; Copyright (C) 2026 SKK Development Team

;; This file is part of Daredevil SKK.

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;;; Code:

(require 'ert)
(require 'skk-smart)

;;; ============================================================
;;; skk-smart--extract-kanji-words
;;; ============================================================

(ert-deftest skk-smart--extract-kanji-words/basic ()
  "Kanji sequences separated by hiragana are each returned as one word."
  (should (equal (skk-smart--extract-kanji-words "薬の効果を調べる")
                 '("薬" "効果" "調"))))

(ert-deftest skk-smart--extract-kanji-words/empty-string ()
  "Empty string returns nil."
  (should (null (skk-smart--extract-kanji-words ""))))

(ert-deftest skk-smart--extract-kanji-words/ascii-only ()
  "Pure ASCII returns nil."
  (should (null (skk-smart--extract-kanji-words "hello world"))))

(ert-deftest skk-smart--extract-kanji-words/hiragana-only ()
  "Pure hiragana returns nil (hiragana is not kanji)."
  (should (null (skk-smart--extract-kanji-words "ひらがなのみ"))))

(ert-deftest skk-smart--extract-kanji-words/compound-kanji ()
  "Consecutive kanji are returned as a single word."
  (should (equal (skk-smart--extract-kanji-words "弁護士費用")
                 '("弁護士費用"))))

(ert-deftest skk-smart--extract-kanji-words/mixed-sentence ()
  "Typical Japanese sentence splits correctly at hiragana boundaries."
  (should (equal (skk-smart--extract-kanji-words "この特許は弁護士が担当する")
                 '("特許" "弁護士" "担当"))))

(ert-deftest skk-smart--extract-kanji-words/multiple-words ()
  "Multiple kanji words are all extracted."
  (should (equal (skk-smart--extract-kanji-words "薬の治療を受けた後で")
                 '("薬" "治療" "受" "後"))))

;;; ============================================================
;;; skk-smart--candidate-string
;;; ============================================================

(ert-deftest skk-smart--candidate-string/plain-string ()
  "Plain string candidates are returned as-is."
  (should (equal (skk-smart--candidate-string "効果") "効果")))

(ert-deftest skk-smart--candidate-string/annotated-cons ()
  "Annotated candidates (cons cell) return the car."
  (should (equal (skk-smart--candidate-string '("効果" . "効き目")) "効果")))

(ert-deftest skk-smart--candidate-string/strips-semicolon-annotation ()
  "文字列候補にセミコロン注釈が含まれる場合、セミコロン前の部分のみ返す。
SKK では送り仮名エントリの候補が \"効;(effect) 薬が効く\" の形式で渡される。"
  (should (equal (skk-smart--candidate-string "効;(effect) 薬が効く") "効"))
  (should (equal (skk-smart--candidate-string "聴;注釈") "聴"))
  ;; 注釈なしはそのまま
  (should (equal (skk-smart--candidate-string "聞く") "聞く")))

;;; ============================================================
;;; skk-smart--compute-scores
;;; ============================================================

(ert-deftest skk-smart--compute-scores/no-entries ()
  "With no past entries, all scores are 0."
  (let ((scores (skk-smart--compute-scores '("効果" "高価") '("薬" "治療") nil)))
    (should (hash-table-p scores))
    (should (= (gethash "効果" scores 0) 0))
    (should (= (gethash "高価" scores 0) 0))))

(ert-deftest skk-smart--compute-scores/no-overlap ()
  "When context shares no words with past entries, all scores are 0."
  (let* ((entries '((("特許" "弁護士") . "高価")))
         (scores (skk-smart--compute-scores '("効果" "高価") '("薬" "治療") entries)))
    (should (hash-table-p scores))
    (should (= (gethash "効果" scores 0) 0))
    (should (= (gethash "高価" scores 0) 0))))

(ert-deftest skk-smart--compute-scores/single-overlap ()
  "One overlapping context word adds 1 to the candidate's score."
  (let* ((entries '((("薬" "弁護士") . "効果")))
         (scores (skk-smart--compute-scores '("効果" "高価")
                                            '("薬" "治療")
                                            entries)))
    ;; "薬" overlaps once → score 1
    (should (hash-table-p scores))
    (should (= (gethash "効果" scores 0) 1))
    (should (= (gethash "高価" scores 0) 0))))

(ert-deftest skk-smart--compute-scores/multiple-entries-accumulate ()
  "Score accumulates across multiple matching entries."
  (let* ((entries '((("薬" "治療") . "効果")   ; overlap 2: 薬,治療
                    (("法律" "弁護士") . "高価") ; overlap 0
                    (("薬" "病院" "医師") . "効果"))) ; overlap 1: 薬
         (scores (skk-smart--compute-scores '("高価" "効果" "降下")
                                            '("薬" "治療" "病院")
                                            entries)))
    ;; 効果: entry1 → 薬,治療 overlap context(薬,治療,病院) = 2
    ;;        entry3 → 薬,病院,医師 overlap context(薬,治療,病院) = 2 → total 4
    (should (hash-table-p scores))
    (should (= (gethash "効果" scores 0) 4))
    ;; 高価: entry2 → 法律,弁護士 overlap context = 0
    (should (= (gethash "高価" scores 0) 0))
    ;; 降下: no entry
    (should (= (gethash "降下" scores 0) 0))))

(ert-deftest skk-smart--compute-scores/annotated-candidates ()
  "Annotated (cons cell) candidates are scored correctly."
  (let* ((entries '((("薬") . "効果")))
         (scores (skk-smart--compute-scores '(("効果" . "efficacy") "高価")
                                            '("薬")
                                            entries)))
    (should (hash-table-p scores))
    (should (= (gethash "効果" scores 0) 1))
    (should (= (gethash "高価" scores 0) 0))))

;;; ============================================================
;;; skk-smart--rerank
;;; ============================================================

(defun skk-smart-test--scores-ht (&rest pairs)
  "PAIRS (string . number) のリストから hash-table を生成するテスト用ヘルパー。"
  (let ((ht (make-hash-table :test #'equal)))
    (dolist (p pairs)
      (puthash (car p) (cdr p) ht))
    ht))

(ert-deftest skk-smart--rerank/all-zero-scores-preserves-order ()
  "When all scores are 0, original order is preserved."
  (let* ((candidates '("甲" "乙" "丙"))
         (scores (skk-smart-test--scores-ht '("甲" . 0) '("乙" . 0) '("丙" . 0))))
    (should (equal (skk-smart--rerank candidates scores) '("甲" "乙" "丙")))))

(ert-deftest skk-smart--rerank/single-winner ()
  "Highest-scored candidate moves to front."
  (let* ((candidates '("高価" "効果" "降下"))
         (scores (skk-smart-test--scores-ht '("高価" . 0) '("効果" . 3) '("降下" . 0))))
    (should (equal (skk-smart--rerank candidates scores) '("効果" "高価" "降下")))))

(ert-deftest skk-smart--rerank/multiple-scores ()
  "All candidates ranked by score descending."
  (let* ((candidates '("高価" "効果" "降下"))
         (scores (skk-smart-test--scores-ht '("高価" . 1) '("効果" . 3) '("降下" . 2))))
    (should (equal (skk-smart--rerank candidates scores) '("効果" "降下" "高価")))))

(ert-deftest skk-smart--rerank/tie-preserves-original-order ()
  "Candidates with equal scores preserve their original relative order."
  (let* ((candidates '("甲" "乙" "丙"))
         (scores (skk-smart-test--scores-ht '("甲" . 2) '("乙" . 2) '("丙" . 5))))
    ;; 丙 first, then 甲 before 乙 (original order for tie)
    (should (equal (skk-smart--rerank candidates scores) '("丙" "甲" "乙")))))

(ert-deftest skk-smart--rerank/annotated-candidates ()
  "Rerank works with annotated (cons cell) candidates."
  (let* ((candidates '(("高価" . "たかい") ("効果" . "きく")))
         (scores (skk-smart-test--scores-ht '("高価" . 0) '("効果" . 2))))
    (should (equal (skk-smart--rerank candidates scores)
                   '(("効果" . "きく") ("高価" . "たかい"))))))

;;; ============================================================
;;; skk-smart--rerank-simple
;;; ============================================================

(ert-deftest skk-smart--rerank-simple/promotes-max-score ()
  "最大スコアの候補のみ先頭に移動する。"
  (let* ((candidates '("高価" "効果" "降下"))
         (scores (skk-smart-test--scores-ht '("高価" . 0) '("効果" . 3.0) '("降下" . 0))))
    (should (equal (skk-smart--rerank-simple candidates scores) '("効果" "高価" "降下")))))

(ert-deftest skk-smart--rerank-simple/preserves-rest-in-original-order ()
  "先頭移動以外の候補は元の相対順序を維持する。"
  (let* ((candidates '("甲" "乙" "丙" "丁"))
         (scores (skk-smart-test--scores-ht '("甲" . 0) '("乙" . 0) '("丙" . 5.0) '("丁" . 0))))
    (should (equal (skk-smart--rerank-simple candidates scores) '("丙" "甲" "乙" "丁")))))

(ert-deftest skk-smart--rerank-simple/all-zero-scores-preserves-order ()
  "全スコアが 0 のとき元の順序を返す（コンテキスト信号なし）。"
  (let* ((candidates '("甲" "乙" "丙"))
         (scores (skk-smart-test--scores-ht '("甲" . 0) '("乙" . 0) '("丙" . 0))))
    (should (equal (skk-smart--rerank-simple candidates scores) '("甲" "乙" "丙")))))

(ert-deftest skk-smart--rerank-simple/best-already-first-no-change ()
  "スコア最大の候補がすでに先頭のとき順序変化なし。"
  (let* ((candidates '("効果" "高価" "降下"))
         (scores (skk-smart-test--scores-ht '("効果" . 5.0) '("高価" . 0) '("降下" . 0))))
    (should (equal (skk-smart--rerank-simple candidates scores) '("効果" "高価" "降下")))))

(ert-deftest skk-smart--rerank-simple/annotated-candidates ()
  "注釈付き候補（コンスセル）に対して正しく動作する。"
  (let* ((candidates '(("高価" . "たかい") ("効果" . "きく")))
         (scores (skk-smart-test--scores-ht '("高価" . 0) '("効果" . 2.0))))
    (should (equal (skk-smart--rerank-simple candidates scores)
                   '(("効果" . "きく") ("高価" . "たかい"))))))

;;; ============================================================
;;; skk-smart--add-entry
;;; ============================================================

(ert-deftest skk-smart--add-entry/new-midasi ()
  "Adding to a new midasi creates a new alist entry."
  (let ((skk-smart-alist nil))
    (skk-smart--add-entry "こうか" '("薬" "治療") "効果")
    (let ((entries (cdr (assoc "こうか" skk-smart-alist))))
      (should (= (length entries) 1))
      (should (equal (car entries) '(("薬" "治療") . "効果"))))))

(ert-deftest skk-smart--add-entry/existing-midasi-prepends ()
  "Additional entries for same midasi are prepended (most recent first)."
  (let ((skk-smart-alist nil))
    (skk-smart--add-entry "こうか" '("特許") "高価")
    (skk-smart--add-entry "こうか" '("薬") "効果")
    (let ((entries (cdr (assoc "こうか" skk-smart-alist))))
      (should (= (length entries) 2))
      ;; Most recent first
      (should (equal (caar entries) '("薬")))
      (should (equal (cdar entries) "効果")))))

(ert-deftest skk-smart--add-entry/different-midasi ()
  "Different midasi keys are stored separately."
  (let ((skk-smart-alist nil))
    (skk-smart--add-entry "こうか" '("薬") "効果")
    (skk-smart--add-entry "べんり" '("IT") "便利")
    (should (assoc "こうか" skk-smart-alist))
    (should (assoc "べんり" skk-smart-alist))
    (should (= (length skk-smart-alist) 2))))

(ert-deftest skk-smart--add-entry/max-entries-trimmed ()
  "Entries beyond skk-smart-max-entries-per-midasi are discarded."
  (let ((skk-smart-alist nil)
        (skk-smart-max-entries-per-midasi 3))
    (skk-smart--add-entry "こうか" '("A") "効果")
    (skk-smart--add-entry "こうか" '("B") "高価")
    (skk-smart--add-entry "こうか" '("C") "降下")
    (skk-smart--add-entry "こうか" '("D") "口火") ; 4th entry → oldest trimmed
    (let ((entries (cdr (assoc "こうか" skk-smart-alist))))
      (should (= (length entries) 3)))))

;;; ============================================================
;;; skk-smart-context-search (integration)
;;; ============================================================

(ert-deftest skk-smart-context-search/nil-entry-passthrough ()
  "nil entry is returned as-is without error."
  (let ((skk-smart-alist nil))
    (should (null (skk-smart-context-search (current-buffer) "こうか" nil nil)))))

(ert-deftest skk-smart-context-search/single-candidate-passthrough ()
  "Single candidate list is returned without reranking."
  (let ((skk-smart-alist nil))
    (should (equal (skk-smart-context-search (current-buffer) "こうか" nil '("効果"))
                   '("効果")))))

(ert-deftest skk-smart-context-search/no-alist-passthrough ()
  "With empty skk-smart-alist, entry is returned unchanged."
  (let ((skk-smart-alist nil))
    (should (equal (skk-smart-context-search (current-buffer) "こうか" nil
                                             '("高価" "効果" "降下"))
                   '("高価" "効果" "降下")))))

(ert-deftest skk-smart-context-search/reranks-by-context ()
  "Candidates are reranked based on context matching past confirmations."
  (let ((skk-smart-alist nil)
        (skk-smart-context-chars 300))
    ;; Simulate past: 効果 confirmed in medical context
    (skk-smart--add-entry "こうか" '("薬" "治療") "効果")
    (skk-smart--add-entry "こうか" '("薬" "病院") "効果")
    ;; Simulate past: 高価 confirmed in shopping context
    (skk-smart--add-entry "こうか" '("購入" "値段") "高価")

    (with-temp-buffer
      (insert "薬の治療の")
      ;; Simulate skk-henkan-start-point at end of context text
      (let ((skk-henkan-start-point (point-max-marker)))
        (let ((result (skk-smart-context-search
                       (current-buffer) "こうか" nil
                       '("高価" "効果" "降下"))))
          ;; 効果 should be promoted due to 薬 and 治療 in context
          (should (equal (car result) "効果")))))))

(ert-deftest skk-smart-context-search/no-context-match-preserves-order ()
  "When context matches nothing, original order is preserved."
  (let ((skk-smart-alist nil)
        (skk-smart-context-chars 300))
    ;; Only legal context stored
    (skk-smart--add-entry "こうか" '("特許" "弁護士") "高価")

    (with-temp-buffer
      (insert "ランチの")  ; No kanji matching stored context
      (let ((skk-henkan-start-point (point-max-marker)))
        (let ((result (skk-smart-context-search
                       (current-buffer) "こうか" nil
                       '("高価" "効果" "降下"))))
          ;; No context match → original order
          (should (equal result '("高価" "効果" "降下"))))))))

;;; ============================================================
;;; skk-smart-context-update (integration)
;;; ============================================================

(ert-deftest skk-smart-context-update/records-context ()
  "Confirmed word with kanji context is recorded in skk-smart-alist after flush."
  (let ((skk-smart-alist nil)
        (skk-smart--pending nil)
        (skk-smart--pending-commands 0)
        (skk-smart-context-chars 300)
        (buf (generate-new-buffer " *skk-smart-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "薬の治療の効果")
            (let ((skk-henkan-start-point
                   (set-marker (make-marker) (- (point-max) 2))))
              (skk-smart-context-update buf "こうか" nil "効果" nil)))
          ;; pending 中は未記録
          (should (null skk-smart-alist))
          ;; buf がまだ生きている状態で flush → 語が変わっていないので記録される
          (skk-smart--flush-pending)
          (let ((entries (cdr (assoc "こうか" skk-smart-alist))))
            (should entries)
            (let ((ctx-words (caar entries)))
              (should (member "薬" ctx-words))
              (should (member "治療" ctx-words)))))
      (kill-buffer buf))))

(ert-deftest skk-smart-context-update/purge-skipped ()
  "Purge operations are not recorded."
  (let ((skk-smart-alist nil))
    (with-temp-buffer
      (insert "薬の治療の")
      (let ((skk-henkan-start-point (point-max-marker)))
        (skk-smart-context-update (current-buffer) "こうか" nil "効果" t)))
    (should (null skk-smart-alist))))

(ert-deftest skk-smart-context-update/no-kanji-context-skipped ()
  "Update is skipped when no kanji words are found in context."
  (let ((skk-smart-alist nil)
        (skk-smart-context-chars 300))
    (with-temp-buffer
      (insert "ひらがなのみのてきすと")  ; no kanji
      (let ((skk-henkan-start-point (point-max-marker)))
        (skk-smart-context-update (current-buffer) "こうか" nil "効果" nil)))
    ;; No kanji context → nothing recorded
    (should (null skk-smart-alist))))

;;; ============================================================
;;; Round-trip: update then search
;;; ============================================================

(ert-deftest skk-smart/round-trip-update-then-search ()
  "After recording context via update (and flush), search correctly reranks."
  (let ((skk-smart-alist nil)
        (skk-smart--pending nil)
        (skk-smart--pending-commands 0)
        (skk-smart-context-chars 300)
        (buf (generate-new-buffer " *skk-smart-test*")))
    (unwind-protect
        (progn
          ;; Session 1: user confirms 効果 while writing about medicine
          (with-current-buffer buf
            (insert "薬の治療を行う効果")
            (let ((skk-henkan-start-point
                   (set-marker (make-marker) (- (point-max) 2))))
              (skk-smart-context-update buf "こうか" nil "効果" nil)))
          ;; buf がまだ生きている状態で flush
          (skk-smart--flush-pending)
          ;; Session 2: same medical context → 効果 should be reranked first
          (with-temp-buffer
            (insert "薬を投与した後の")
            (let ((skk-henkan-start-point (point-max-marker)))
              (let ((result (skk-smart-context-search
                             (current-buffer) "こうか" nil
                             '("高価" "降下" "効果"))))
                (should (equal (car result) "効果"))))))
      (kill-buffer buf))))

;;; ============================================================
;;; Pending mechanism
;;; ============================================================

(ert-deftest skk-smart--flush-pending/records-when-unchanged ()
  "語が変更されていなければ flush で skk-smart-alist に記録される。"
  (let ((skk-smart-alist nil)
        (skk-smart--pending nil)
        (skk-smart--pending-commands 0))
    (with-temp-buffer
      (insert "薬の治療の効果")
      ;; "効果" の先頭に marker を置く
      (let ((marker (set-marker (make-marker) (- (point-max) 2))))
        (setq skk-smart--pending
              (list "こうか" '("薬" "治療") "効果" (current-buffer) marker 2))
        (skk-smart--flush-pending)
        (should (assoc "こうか" skk-smart-alist))))))

(ert-deftest skk-smart--flush-pending/skips-when-modified ()
  "語がユーザーに修正されていたら flush は記録しない。"
  (let ((skk-smart-alist nil)
        (skk-smart--pending nil)
        (skk-smart--pending-commands 0))
    (with-temp-buffer
      (insert "薬の治療の効果")
      (let ((marker (set-marker (make-marker) (- (point-max) 2))))
        (setq skk-smart--pending
              (list "こうか" '("薬" "治療") "効果" (current-buffer) marker 2))
        ;; ユーザーが "効果" を "高価" に書き換える
        (goto-char (marker-position marker))
        (delete-char 2)
        (insert "高価")
        (skk-smart--flush-pending)
        ;; 変更されているので記録されない
        (should (null skk-smart-alist))))))

(ert-deftest skk-smart--flush-pending/clears-pending ()
  "flush 後に skk-smart--pending は nil になる。"
  (let ((skk-smart-alist nil)
        (skk-smart--pending nil)
        (skk-smart--pending-commands 0))
    (with-temp-buffer
      (insert "薬の治療の効果")
      (let ((marker (set-marker (make-marker) (- (point-max) 2))))
        (setq skk-smart--pending
              (list "こうか" '("薬" "治療") "効果" (current-buffer) marker 2))
        (skk-smart--flush-pending)
        (should (null skk-smart--pending))))))

(ert-deftest skk-smart--tick-pending/no-commit-before-threshold ()
  "閾値未満のコマンド数では pending のまま記録されない。"
  (let ((skk-smart-alist nil)
        (skk-smart--pending nil)
        (skk-smart--pending-commands 0)
        (skk-smart-pending-wait 3))
    (with-temp-buffer
      (insert "薬の治療の効果")
      (let ((marker (set-marker (make-marker) (- (point-max) 2))))
        (setq skk-smart--pending
              (list "こうか" '("薬" "治療") "効果" (current-buffer) marker 2))
        (skk-smart--tick-pending)  ; 1 コマンド
        (skk-smart--tick-pending)  ; 2 コマンド
        ;; 閾値 3 未満 → まだ pending
        (should skk-smart--pending)
        (should (null skk-smart-alist))))))

(ert-deftest skk-smart--tick-pending/commits-after-threshold ()
  "閾値に達したら flush されて記録される。"
  (let ((skk-smart-alist nil)
        (skk-smart--pending nil)
        (skk-smart--pending-commands 0)
        (skk-smart-pending-wait 3))
    (with-temp-buffer
      (insert "薬の治療の効果")
      (let ((marker (set-marker (make-marker) (- (point-max) 2))))
        (setq skk-smart--pending
              (list "こうか" '("薬" "治療") "効果" (current-buffer) marker 2))
        (dotimes (_ 3) (skk-smart--tick-pending))
        ;; 3 コマンド後に flush → 記録済み
        (should (null skk-smart--pending))
        (should (assoc "こうか" skk-smart-alist))))))

(ert-deftest skk-smart-context-update/stores-pending-not-immediate ()
  "skk-smart-context-update は即記録せず pending に保持する。"
  (let ((skk-smart-alist nil)
        (skk-smart--pending nil)
        (skk-smart--pending-commands 0)
        (skk-smart-context-chars 300))
    (with-temp-buffer
      (insert "薬の治療の効果")
      (let ((skk-henkan-start-point
             (set-marker (make-marker) (- (point-max) 2))))
        (skk-smart-context-update (current-buffer) "こうか" nil "効果" nil)))
    ;; 直後はまだ記録されていない
    (should skk-smart--pending)
    (should (null skk-smart-alist))))

(ert-deftest skk-smart-context-update/flushes-old-pending-on-new-update ()
  "2 回目の update は前回の pending を flush してから新しい pending を保持する。"
  (let ((skk-smart-alist nil)
        (skk-smart--pending nil)
        (skk-smart--pending-commands 0)
        (skk-smart-context-chars 300)
        (buf1 (generate-new-buffer " *skk-smart-test-1*"))
        (buf2 (generate-new-buffer " *skk-smart-test-2*")))
    (unwind-protect
        (progn
          ;; 1 回目の確定: buf1 で "効果"
          (with-current-buffer buf1
            (insert "薬の治療の効果")
            (let ((skk-henkan-start-point
                   (set-marker (make-marker) (- (point-max) 2))))
              (skk-smart-context-update buf1 "こうか" nil "効果" nil)))
          ;; 2 回目の確定: buf2 で "高価"（前の pending を flush させる）
          ;; このとき buf1 はまだ生きており "効果" はそのまま → 記録される
          (with-current-buffer buf2
            (insert "購入の検討の高価")
            (let ((skk-henkan-start-point
                   (set-marker (make-marker) (- (point-max) 2))))
              (skk-smart-context-update buf2 "こうか" nil "高価" nil)))
          ;; 1 回目が flush されて記録済み
          (let ((entries (cdr (assoc "こうか" skk-smart-alist))))
            (should (= (length entries) 1))
            (should (equal (cdar entries) "効果"))))
      (kill-buffer buf1)
      (kill-buffer buf2))))

;;; ============================================================
;;; Corpus scoring (skk-smart--compute-corpus-scores, combined)
;;; ============================================================

(ert-deftest skk-smart--corpus-lookup/no-file-returns-zero ()
  "skk-smart-corpus-file が nil のとき skk-smart--corpus-lookup は 0 を返す。"
  (let ((skk-smart-corpus-file nil))
    (should (= (skk-smart--corpus-lookup "効果" "薬") 0))))

(ert-deftest skk-smart--compute-corpus-scores/no-corpus ()
  "skk-smart-corpus-file が nil のとき全スコア 0。"
  (let ((skk-smart-corpus-file nil))
    (let ((scores (skk-smart--compute-corpus-scores
                   '("効果" "高価")
                   '("薬" "治療"))))
      (should (hash-table-p scores))
      (should (= (gethash "効果" scores 0) 0))
      (should (= (gethash "高価" scores 0) 0)))))

(ert-deftest skk-smart--compute-corpus-scores/mock-backend ()
  "cl-letf でモックしたバックエンドでスコアが正しく合算される。"
  (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
             (lambda (candidate context-word)
               (cond
                ((and (equal candidate "効果") (equal context-word "薬"))    800)
                ((and (equal candidate "効果") (equal context-word "治療"))  600)
                (t 0)))))
    ;; corpus-file を non-nil にしてバックエンドを有効化
    (let ((skk-smart-corpus-file "/dummy/path.sqlite"))
      (let ((scores (skk-smart--compute-corpus-scores
                     '("効果" "高価")
                     '("薬" "治療"))))
        (should (hash-table-p scores))
        ;; 効果: 800 + 600 = 1400
        (should (= (gethash "効果" scores 0) 1400))
        ;; 高価: 0 + 0 = 0
        (should (= (gethash "高価" scores 0) 0))))))

(ert-deftest skk-smart--compute-combined-scores/no-corpus-same-as-learned ()
  "corpus-file が nil のとき combined の結果が learned のみの場合と同じ。"
  (let ((skk-smart-corpus-file nil)
        (skk-smart--corpus-path nil)
        (skk-smart-learned-weight 1.0)
        (skk-smart-corpus-weight 0.001))
    (let* ((candidates '("効果" "高価" "降下"))
           (context-words '("薬" "治療"))
           (entries '((("薬" "治療") . "効果")
                      (("購入") . "高価")))
           (learned-scores (skk-smart--compute-scores candidates context-words entries))
           (combined-scores (skk-smart--compute-combined-scores candidates context-words nil entries)))
      (should (hash-table-p combined-scores))
      ;; combined = learned_weight * learned + corpus_weight * 0 = learned
      (dolist (c candidates)
        (let ((ls (gethash c learned-scores 0))
              (cs (gethash c combined-scores 0)))
          (should (equal cs (* 1.0 ls))))))))

(ert-deftest skk-smart--compute-combined-scores/corpus-cold-start ()
  "learned entries が nil でも corpus スコアだけでリランクできる。"
  (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
             (lambda (candidate context-word)
               (cond
                ((and (equal candidate "効果") (equal context-word "薬")) 900)
                ((and (equal candidate "効果") (equal context-word "治療")) 700)
                (t 0)))))
    (let ((skk-smart-corpus-file "/dummy/path.sqlite")
          (skk-smart-learned-weight 1.0)
          (skk-smart-corpus-weight 0.001))
      (let* ((candidates '("高価" "効果" "降下"))
             (context-words '("薬" "治療"))
             (scores (skk-smart--compute-combined-scores candidates context-words nil nil))
             (result (skk-smart--rerank candidates scores)))
        (should (hash-table-p scores))
        ;; 効果のスコアが最高 → 先頭に来る
        (should (equal (car result) "効果"))))))

(ert-deftest skk-smart--compute-combined-scores/weighted-combination ()
  "learned と corpus 両方あるとき、両方を合算する。"
  (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
             (lambda (candidate context-word)
               (cond
                ((and (equal candidate "高価") (equal context-word "薬")) 500)
                (t 0)))))
    (let ((skk-smart-corpus-file "/dummy/path.sqlite")
          (skk-smart-learned-weight 1.0)
          (skk-smart-corpus-weight 0.001))
      (let* ((candidates '("効果" "高価"))
             (context-words '("薬"))
             ;; entries: 効果 は learned スコア 2、高価 は learned スコア 0
             (entries '((("薬" "治療") . "効果")
                        (("薬") . "効果")))
             (scores (skk-smart--compute-combined-scores candidates context-words nil entries)))
        ;; 効果: learned=2 (薬1回 + 薬1回), corpus=0
        ;;   final = 1.0*2 + 0.001*0 = 2.0
        ;; 高価: learned=0, corpus=500
        ;;   final = 1.0*0 + 0.001*500 = 0.5
        (let ((kouka-score (gethash "効果" scores 0))
              (kouka-score2 (gethash "高価" scores 0)))
          (should (> kouka-score kouka-score2))
          ;; 数値の確認
          (should (= kouka-score 2.0))
          (should (= kouka-score2 0.5)))))))

(ert-deftest skk-smart-context-search/corpus-cold-start-integration ()
  "skk-smart-alist が nil でも corpus があればリランクされる。"
  (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
             (lambda (candidate context-word)
               (cond
                ((and (equal candidate "効果") (equal context-word "薬"))   800)
                ((and (equal candidate "効果") (equal context-word "治療")) 600)
                (t 0)))))
    (let ((skk-smart-alist nil)
          (skk-smart-corpus-file "/dummy/path.sqlite")
          (skk-smart-learned-weight 1.0)
          (skk-smart-corpus-weight 0.001)
          (skk-smart-context-chars 300))
      (with-temp-buffer
        (insert "薬の治療の")
        (let ((skk-henkan-start-point (point-max-marker)))
          (let ((result (skk-smart-context-search
                         (current-buffer) "こうか" nil
                         '("高価" "効果" "降下"))))
            ;; corpus スコアにより効果が先頭に来る
            (should (equal (car result) "効果"))))))))

;;; ============================================================
;;; skk-smart--compute-jisyo-scores
;;; ============================================================

(ert-deftest skk-smart--compute-jisyo-scores/basic ()
  "先頭候補のスコアが最高で、1/(index+1) で減衰する。"
  (let ((scores (skk-smart--compute-jisyo-scores '("高価" "効果" "降下"))))
    (should (= (cdr (assoc "高価" scores)) 1.0))
    (should (= (cdr (assoc "効果" scores)) 0.5))
    (should (< (cdr (assoc "降下" scores)) 0.5))))

(ert-deftest skk-smart--compute-jisyo-scores/annotated-candidates ()
  "注釈付き候補（cons セル）でも動作する。"
  (let ((scores (skk-smart--compute-jisyo-scores '(("高価" . "note") "効果"))))
    (should (= (cdr (assoc "高価" scores)) 1.0))
    (should (= (cdr (assoc "効果" scores)) 0.5))))

(ert-deftest skk-smart-context-search/jisyo-prior-no-context ()
  "コンテキストなしでも jisyo-weight により辞書順が維持される。"
  (let ((skk-smart-alist nil)
        (skk-smart-corpus-file nil)
        (skk-smart-jisyo-weight 0.5)
        (skk-smart-context-chars 300))
    (with-temp-buffer
      ;; 漢字なし → context-words = nil
      (insert "ひらがなのみ")
      (let ((skk-henkan-start-point (point-max-marker)))
        (let ((result (skk-smart-context-search
                       (current-buffer) "こうか" nil
                       '("高価" "効果" "降下"))))
          ;; jisyo prior により先頭の "高価" がそのまま1位
          (should (equal (car result) "高価")))))))

(ert-deftest skk-smart-context-search/context-overrides-jisyo ()
  "コンテキストが強ければ jisyo prior（辞書順）を上書きする。"
  (let ((skk-smart-alist nil)
        (skk-smart-corpus-file nil)
        (skk-smart-jisyo-weight 0.5)
        (skk-smart-context-chars 300))
    ;; 医療コンテキストで "効果" を学習
    (skk-smart--add-entry "こうか" '("薬" "治療") "効果")
    (skk-smart--add-entry "こうか" '("薬" "病院") "効果")
    (with-temp-buffer
      ;; 辞書順は "高価" が先頭だが、コンテキストは医療
      (insert "薬の治療の")
      (let ((skk-henkan-start-point (point-max-marker)))
        (let ((result (skk-smart-context-search
                       (current-buffer) "こうか" nil
                       '("高価" "効果" "降下"))))
          ;; コンテキストスコアが jisyo prior を超えて "効果" が先頭
          (should (equal (car result) "効果")))))))

;;; ============================================================
;;; skk-smart--score-comp-candidate
;;; ============================================================

(ert-deftest skk-smart--score-comp-candidate/no-entries-returns-zero ()
  "skk-smart-alist にエントリがないとき 0 を返す。"
  (let ((skk-smart-alist nil))
    (should (= (skk-smart--score-comp-candidate "こうか" '("薬" "治療") nil) 0))))

(ert-deftest skk-smart--score-comp-candidate/matching-context ()
  "コンテキストが一致するとき正のスコアを返す。"
  (let ((skk-smart-alist nil))
    (skk-smart--add-entry "こうか" '("薬" "治療") "効果")
    (should (> (skk-smart--score-comp-candidate "こうか" '("薬" "病院") nil) 0))))

(ert-deftest skk-smart--score-comp-candidate/multiple-entries-accumulate ()
  "複数エントリのオーバーラップが累積される。"
  (let ((skk-smart-alist nil))
    (skk-smart--add-entry "こうか" '("薬" "治療") "効果")
    (skk-smart--add-entry "こうか" '("薬" "病院") "効果")
    (let ((score (skk-smart--score-comp-candidate "こうか" '("薬" "治療" "病院") nil)))
      ;; entry1: 薬,治療 overlap 薬,治療,病院 = 2
      ;; entry2: 薬,病院 overlap 薬,治療,病院 = 2
      ;; total = 4
      (should (= score 4)))))

;;; ============================================================
;;; skk-smart--rerank-comp-candidates
;;; ============================================================

(ert-deftest skk-smart--rerank-comp-candidates/no-context-preserves-order ()
  "コンテキストなしのとき元の順序が保たれる。"
  (let ((skk-smart-alist nil))
    (should (equal (skk-smart--rerank-comp-candidates '("こうか" "こうき" "こうこ") nil nil)
                   '("こうか" "こうき" "こうこ")))))

(ert-deftest skk-smart--rerank-comp-candidates/reranks-by-context ()
  "コンテキスト一致のある候補が上位に来る。"
  (let ((skk-smart-alist nil))
    (skk-smart--add-entry "こうき" '("薬" "治療") "効果")
    (let ((result (skk-smart--rerank-comp-candidates
                   '("こうか" "こうき" "こうこ")
                   '("薬" "治療") nil)))
      (should (equal (car result) "こうき")))))

;;; ============================================================
;;; skk-smart--comp-rerank-advice
;;; ============================================================

(ert-deftest skk-smart--comp-rerank-advice/reranks-by-context ()
  "dcomp 一覧候補がコンテキストでリランクされる。"
  (let ((skk-smart-alist nil))
    (skk-smart--add-entry "こうき" '("薬" "治療") "効果")
    (with-temp-buffer
      (insert "薬の治療の")
      (let ((result (skk-smart--comp-rerank-advice
                     (lambda (_k _p _l) '("こうか" "こうき" "こうこ"))
                     "こう" "" nil)))
        (should (equal (car result) "こうき"))))))

(ert-deftest skk-smart--comp-rerank-advice/passthrough-without-alist ()
  "skk-smart-alist が nil のとき元の順序で返る。"
  (let ((skk-smart-alist nil))
    (with-temp-buffer
      (insert "薬の治療の")
      (let ((result (skk-smart--comp-rerank-advice
                     (lambda (_k _p _l) '("こうか" "こうき" "こうこ"))
                     "こう" "" nil)))
        (should (equal result '("こうか" "こうき" "こうこ")))))))

(ert-deftest skk-smart--comp-rerank-advice/passthrough-without-context ()
  "コンテキスト漢字語がないとき元の順序で返る。"
  (let ((skk-smart-alist nil))
    (skk-smart--add-entry "こうき" '("薬" "治療") "効果")
    (with-temp-buffer
      (insert "ひらがなのみ")  ; 漢字なし
      (let ((result (skk-smart--comp-rerank-advice
                     (lambda (_k _p _l) '("こうか" "こうき" "こうこ"))
                     "こう" "" nil)))
        (should (equal result '("こうか" "こうき" "こうこ")))))))

;;; ============================================================
;;; skk-smart-comp-by-server-completion
;;; ============================================================

(ert-deftest skk-smart-comp-by-server-completion/reranks-by-context ()
  "サーバー補完候補がコンテキストに基づいてリランクされる。"
  (cl-letf (((symbol-function 'skk-server-completion-search-midasi)
             (lambda (_key) '("こうか" "こうき" "こうこ"))))
    (let ((skk-smart-alist nil)
          (skk-smart--server-comp-stack nil))
      (skk-smart--add-entry "こうき" '("薬" "治療") "効果")
      (with-temp-buffer
        (insert "薬の治療の")
        (let ((skk-comp-first t)
              (skk-comp-key "こう"))
          (let ((first (skk-smart-comp-by-server-completion)))
            (should (equal first "こうき"))))))))

(ert-deftest skk-smart-comp-by-server-completion/passthrough-without-alist ()
  "skk-smart-alist が nil のとき元の順序で返す。"
  (cl-letf (((symbol-function 'skk-server-completion-search-midasi)
             (lambda (_key) '("こうか" "こうき" "こうこ"))))
    (let ((skk-smart-alist nil)
          (skk-smart--server-comp-stack nil))
      (with-temp-buffer
        (insert "薬の治療の")
        (let ((skk-comp-first t)
              (skk-comp-key "こう"))
          (let ((first (skk-smart-comp-by-server-completion)))
            (should (equal first "こうか"))))))))

(ert-deftest skk-smart-comp-by-server-completion/subsequent-calls-pop ()
  "2 回目以降の呼び出しでスタックから順に取り出す。"
  (cl-letf (((symbol-function 'skk-server-completion-search-midasi)
             (lambda (_key) '("こうか" "こうき"))))
    (let ((skk-smart-alist nil)
          (skk-smart--server-comp-stack nil))
      (with-temp-buffer
        (let ((skk-comp-first t)
              (skk-comp-key "こう"))
          (let ((first (skk-smart-comp-by-server-completion)))
            (let ((skk-comp-first nil))
              (let ((second (skk-smart-comp-by-server-completion)))
                (should (not (equal first second)))
                (should (member first '("こうか" "こうき")))
                (should (member second '("こうか" "こうき")))))))))))

;;; ============================================================
;;; skk-smart-max-candidates (P-3)
;;; ============================================================

(ert-deftest skk-smart-context-search/max-candidates-limits-scoring-window ()
  "skk-smart-max-candidates=2 のとき、スコアリング窓外の候補はリランクされない。
窓外の候補（3番目以降）がコンテキストに強く一致していても先頭には来ない。"
  (let ((skk-smart-alist nil)
        (skk-smart-corpus-file nil)
        (skk-smart-jisyo-weight 0)
        (skk-smart-max-candidates 2)
        (skk-smart-context-chars 300))
    ;; 医療コンテキストで "降下"（3番目候補）を学習 → 窓外なので昇格しない
    (skk-smart--add-entry "こうか" '("薬" "治療") "降下")
    (skk-smart--add-entry "こうか" '("薬" "治療") "降下")
    (with-temp-buffer
      (insert "薬の治療の")
      (let ((skk-henkan-start-point (point-max-marker)))
        (let ((result (skk-smart-context-search
                       (current-buffer) "こうか" nil
                       '("効果" "高価" "降下" "口火"))))
          ;; "降下" は max-candidates=2 の窓外 → 先頭に来ない
          (should-not (equal (car result) "降下"))
          ;; 全候補が返る（長さ変わらず）
          (should (= (length result) 4)))))))

(ert-deftest skk-smart-context-search/max-candidates-nil-means-no-limit ()
  "skk-smart-max-candidates=nil のとき制限なく全候補をスコアリングする。"
  (let ((skk-smart-alist nil)
        (skk-smart-corpus-file nil)
        (skk-smart-jisyo-weight 0)
        (skk-smart-max-candidates nil)
        (skk-smart-context-chars 300))
    ;; 3番目候補 "降下" を強く学習
    (skk-smart--add-entry "こうか" '("薬" "治療") "降下")
    (skk-smart--add-entry "こうか" '("薬" "治療") "降下")
    (with-temp-buffer
      (insert "薬の治療の")
      (let ((skk-henkan-start-point (point-max-marker)))
        (let ((result (skk-smart-context-search
                       (current-buffer) "こうか" nil
                       '("効果" "高価" "降下" "口火"))))
          ;; 制限なし → "降下" が先頭に昇格する
          (should (equal (car result) "降下")))))))

(ert-deftest skk-smart-context-search/max-candidates-preserves-tail ()
  "窓外の候補は元の相対順序でリランク済み候補の後に続く。"
  (let ((skk-smart-alist nil)
        (skk-smart-corpus-file nil)
        (skk-smart-jisyo-weight 0)
        (skk-smart-max-candidates 2)
        (skk-smart-context-chars 300))
    (with-temp-buffer
      (insert "薬の治療の")
      (let ((skk-henkan-start-point (point-max-marker)))
        (let ((result (skk-smart-context-search
                       (current-buffer) "こうか" nil
                       '("効果" "高価" "降下" "口火"))))
          ;; 先頭2件（スコアリング窓）の後に残り2件が元の順序で続く
          (should (equal (nthcdr 2 result) '("降下" "口火"))))))))

(defun skk-smart-test--fixture-path (filename)
  "テスト用フィクスチャファイルの絶対パスを返す。
`load-file-name' または `default-directory' から test/fixtures/ を探す。"
  (let* ((base (or (and load-file-name
                        (file-name-directory load-file-name))
                   default-directory))
         ;; base が test/ なら一つ上、workspace/ なら test/ を追加
         (candidate1 (expand-file-name (concat "test/fixtures/" filename) base))
         (candidate2 (expand-file-name (concat "fixtures/" filename) base)))
    (cond
     ((file-readable-p candidate1) candidate1)
     ((file-readable-p candidate2) candidate2)
     (t candidate1))))  ; 存在しなくても candidate1 を返す（skip-unless で弾く）

;;; ============================================================
;;; max-corpus-context-words / max-prev-corpus-words (B, C)
;;; ============================================================

(ert-deftest skk-smart--compute-combined-scores/max-corpus-context-words ()
  "max-corpus-context-words で現在文の corpus ルックアップ語数が制限される。
超過分（先頭）は除かれ、末尾（変換位置に近い語）が残る。"
  (let ((looked-up '())
        (skk-smart-max-corpus-context-words 2)
        (skk-smart-max-prev-corpus-words 0)
        (skk-smart-corpus-file "/dummy"))
    (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
               (lambda (_cstr w)
                 (push w looked-up) 0)))
      (skk-smart--compute-combined-scores
       '("成功") '("工場" "機械" "設置" "実験") nil nil))
    ;; last 2 = (設置 実験) のみ lookup、工場・機械は除外
    (should (cl-notany (lambda (k) (string-match-p "工場\\|機械" k)) looked-up))
    (should (cl-some   (lambda (k) (string-match-p "設置" k))         looked-up))
    (should (cl-some   (lambda (k) (string-match-p "実験" k))         looked-up))))

(ert-deftest skk-smart--compute-combined-scores/max-corpus-context-words-zero ()
  "max-corpus-context-words が 0 のとき全語を lookup する（制限なし）。"
  (let ((lookup-count 0)
        (skk-smart-max-corpus-context-words 0)
        (skk-smart-max-prev-corpus-words 0)
        (skk-smart-corpus-file "/dummy"))
    (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
               (lambda (_c _w) (cl-incf lookup-count) 0)))
      (skk-smart--compute-combined-scores
       '("成功") '("工場" "機械" "設置" "実験") nil nil))
    ;; 1 候補 × 4 語 = 4 lookups
    (should (= lookup-count 4))))

(ert-deftest skk-smart--compute-combined-scores/max-prev-corpus-words ()
  "max-prev-corpus-words で前文の corpus ルックアップ語数が制限される。"
  (let ((looked-up '())
        (skk-smart-max-prev-corpus-words 2)
        (skk-smart-max-corpus-context-words 0)
        (skk-smart-corpus-file "/dummy"))
    (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
               (lambda (_cstr w)
                 (push w looked-up) 0)))
      (skk-smart--compute-combined-scores
       '("成功") '("実験") '("工場" "機械" "設置" "絶好") nil))
    ;; prev last 2 = (設置 絶好) のみ、工場・機械は除外
    (should (cl-notany (lambda (k) (string-match-p "工場\\|機械" k))
                       (cl-remove-if (lambda (k) (string-match-p "実験" k)) looked-up)))
    (should (cl-some   (lambda (k) (string-match-p "設置" k)) looked-up))
    (should (cl-some   (lambda (k) (string-match-p "絶好" k)) looked-up))))

(ert-deftest skk-smart--compute-combined-scores/max-prev-corpus-words-zero ()
  "max-prev-corpus-words が 0 のとき prev 全語を lookup する（制限なし）。"
  (let ((lookup-count 0)
        (skk-smart-max-prev-corpus-words 0)
        (skk-smart-max-corpus-context-words 0)
        (skk-smart-corpus-file "/dummy"))
    (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
               (lambda (_c _w) (cl-incf lookup-count) 0)))
      (skk-smart--compute-combined-scores
       '("成功") '("実験") '("工場" "機械" "設置" "絶好") nil))
    ;; 1 候補 × (1 cur + 4 prev) = 5 lookups
    (should (= lookup-count 5))))

(ert-deftest skk-smart--compute-corpus-scores/parity-with-lookup ()
  "P-2 最適化後も corpus スコアがモックバックエンドで正しく計算される（回帰テスト）。"
  (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
             (lambda (candidate context-word)
               (cond
                ((and (equal candidate "効果") (equal context-word "薬"))   500)
                ((and (equal candidate "効果") (equal context-word "治療")) 300)
                (t 0)))))
    (let ((skk-smart-corpus-file "/dummy/path.sqlite"))
      (let ((scores (skk-smart--compute-corpus-scores
                     '("効果" "高価" "降下")
                     '("薬" "治療"))))
        (should (= (gethash "効果" scores 0) 800))
        (should (= (gethash "高価" scores 0) 0))
        (should (= (gethash "降下" scores 0) 0))))))

;;; ============================================================
;;; skk-smart--context-since-last-sentence
;;; ============================================================

(ert-deftest skk-smart--context-since-last-sentence/no-sentence-end ()
  "文末記号がなければテキスト全体を返す。"
  (should (equal (skk-smart--context-since-last-sentence "薬の治療")
                 "薬の治療")))

(ert-deftest skk-smart--context-since-last-sentence/sentence-end-in-middle ()
  "文末記号以降の部分文字列を返す。"
  (should (equal (skk-smart--context-since-last-sentence "前の文。後の文")
                 "後の文")))

(ert-deftest skk-smart--context-since-last-sentence/sentence-end-at-start ()
  "先頭文字が文末記号のとき、残りの文字列を返す（i=0 のケース）。"
  (should (equal (skk-smart--context-since-last-sentence "。後の文")
                 "後の文")))

(ert-deftest skk-smart--context-since-last-sentence/single-sentence-end-char ()
  "文末記号 1 文字のみのとき、空文字列を返す。"
  (should (equal (skk-smart--context-since-last-sentence "。")
                 "")))

(ert-deftest skk-smart--context-since-last-sentence/newline-as-sentence-end ()
  "改行も文末記号として扱われる。"
  (should (equal (skk-smart--context-since-last-sentence "前の文\n後の文")
                 "後の文")))

(ert-deftest skk-smart--context-since-last-sentence/multiple-sentence-ends ()
  "複数の文末記号があるとき、最後のものを使う。"
  (should (equal (skk-smart--context-since-last-sentence "一文目。二文目。三文目")
                 "三文目")))

(ert-deftest skk-smart--context-since-last-sentence/empty-string ()
  "空文字列はそのまま返る。"
  (should (equal (skk-smart--context-since-last-sentence "")
                 "")))

;;; ============================================================
;;; SQLite バックエンド (F-1)
;;; ============================================================

(defun skk-smart-test--sqlite-fixture-path ()
  "テスト用 SQLite フィクスチャのパスを返す。"
  (skk-smart-test--fixture-path "test-cooccurrence.sqlite"))

(ert-deftest skk-smart--corpus-ensure-open/opens-sqlite ()
  "sqlite 拡張子のファイルが指定されたとき sqlite-open を呼ぶ。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart-corpus-file "/dummy/corpus.sqlite")
        (skk-smart--sqlite-db nil)
        (skk-smart--corpus-file-opened nil))
    (cl-letf (((symbol-function 'file-readable-p) (lambda (_) t))
              ((symbol-function 'sqlite-open) (lambda (_) 'mock-db)))
      (skk-smart--corpus-ensure-open)
      (should (eq skk-smart--sqlite-db 'mock-db)))))

(ert-deftest skk-smart--corpus-ensure-open/idempotent-when-open ()
  "すでに SQLite が開いているとき再オープンしない（べき等性）。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart-corpus-file "/dummy/corpus.sqlite")
        (skk-smart--sqlite-db 'existing-db)
        (skk-smart--corpus-file-opened "/dummy/corpus.sqlite")
        (open-called nil))
    (cl-letf (((symbol-function 'sqlite-open) (lambda (_) (setq open-called t) 'new-db)))
      (skk-smart--corpus-ensure-open)
      (should-not open-called)
      (should (eq skk-smart--sqlite-db 'existing-db)))))

(ert-deftest skk-smart--corpus-ensure-open/skips-unreadable-file ()
  "ファイルが読めないとき sqlite-db は nil のまま。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart-corpus-file "/nonexistent/corpus.sqlite")
        (skk-smart--corpus-path nil)
        (skk-smart--sqlite-db nil)
        (skk-smart--corpus-file-opened nil))
    (cl-letf (((symbol-function 'sqlite-open) (lambda (_) 'mock-db)))
      (skk-smart--corpus-ensure-open)
      (should (null skk-smart--sqlite-db)))))

(ert-deftest skk-smart--corpus-ensure-open/auto-closes-on-file-change ()
  "corpus-file が前回と変わったとき、古い SQLite 接続を閉じてから再オープンする。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart-corpus-file "/new/corpus.sqlite")
        (skk-smart--sqlite-db 'old-db)
        (skk-smart--corpus-file-opened "/old/corpus.sqlite")
        (old-closed nil))
    (cl-letf (((symbol-function 'sqlite-close) (lambda (_) (setq old-closed t)))
              ((symbol-function 'file-readable-p) (lambda (_) t))
              ((symbol-function 'sqlite-open) (lambda (_) 'new-db)))
      (skk-smart--corpus-ensure-open)
      (should old-closed)
      (should (eq skk-smart--sqlite-db 'new-db)))))

(ert-deftest skk-smart--corpus-ensure-open/logs-error-when-debug ()
  "`skk-smart-debug' が non-nil のとき ensure-open のエラーがログバッファに記録される。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart-corpus-file "/dummy/corpus.sqlite")
        (skk-smart--sqlite-db nil)
        (skk-smart--corpus-file-opened nil)
        (skk-smart-debug t))
    (cl-letf (((symbol-function 'file-readable-p) (lambda (_) t))
              ((symbol-function 'sqlite-open) (lambda (_) (error "テストエラー"))))
      (with-current-buffer (get-buffer-create "*skk-smart-debug*")
        (erase-buffer))
      (skk-smart--corpus-ensure-open)
      ;; エラー後もバックエンドは nil のまま
      (should (null skk-smart--sqlite-db))
      ;; ログバッファにエラーメッセージが記録された
      (with-current-buffer "*skk-smart-debug*"
        (should (string-match-p "ensure-open failed" (buffer-string)))))))

(ert-deftest skk-smart--corpus-close/closes-sqlite ()
  "`skk-smart--corpus-close' が SQLite 接続を閉じる。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart--sqlite-db t)
        (closed nil))
    (cl-letf (((symbol-function 'sqlite-close)
               (lambda (_db) (setq closed t))))
      (skk-smart--corpus-close))
    (should closed)
    (should (null skk-smart--sqlite-db))))

(ert-deftest skk-smart--compute-corpus-scores/sqlite-backend ()
  "SQLite バックエンド初期化済みのとき `skk-smart--sqlite-lookup' 経由でスコアを計算する（full モード）。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart--sqlite-db t)
        (skk-smart--corpus-path nil)
        (skk-smart-corpus-file "/dummy.sqlite")
        (skk-smart-rerank-mode 'full)
        (skk-smart-debug nil))
    (cl-letf (((symbol-function 'skk-smart--sqlite-lookup)
               (lambda (candidate context-word)
                 (cond
                  ((and (equal candidate "効果") (equal context-word "薬"))   500)
                  ((and (equal candidate "効果") (equal context-word "治療")) 300)
                  (t 0)))))
      (let ((scores (skk-smart--compute-corpus-scores
                     '("効果" "高価" "降下")
                     '("薬" "治療"))))
        (should (= (gethash "効果" scores 0) 800))
        (should (= (gethash "高価" scores 0) 0))
        (should (= (gethash "降下" scores 0) 0))))))

(ert-deftest skk-smart--compute-corpus-scores/sqlite-nil-context-words ()
  "SQLite バックエンド初期化済みで context-words が nil のとき、
全スコア 0 を返し `skk-smart--corpus-lookup' を呼ばない。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart--sqlite-db t)
        (skk-smart--corpus-path nil)
        (skk-smart-corpus-file "/dummy.sqlite")
        (skk-smart-debug nil)
        (lookup-called nil))
    (cl-letf (((symbol-function 'skk-smart--corpus-lookup)
               (lambda (_c _w) (setq lookup-called t) 0)))
      (let ((scores (skk-smart--compute-corpus-scores '("効果" "高価") nil)))
        (should (= (gethash "効果" scores 0) 0))
        (should (= (gethash "高価" scores 0) 0))
        (should-not lookup-called)))))

(ert-deftest skk-smart--sqlite-lookup/real-fixture ()
  "実際の SQLite フィクスチャから既知のスコアが取得できる。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((fixture-path (skk-smart-test--sqlite-fixture-path)))
    (skip-unless (file-readable-p fixture-path))
    (let ((skk-smart--sqlite-db (sqlite-open fixture-path)))
      (unwind-protect
          (progn
            (should (= (skk-smart--sqlite-lookup "効果" "薬") 800))
            (should (= (skk-smart--sqlite-lookup "効果" "治療") 600))
            (should (= (skk-smart--sqlite-lookup "高価" "購入") 750))
            (should (= (skk-smart--sqlite-lookup "存在しない" "語") 0)))
        (sqlite-close skk-smart--sqlite-db)
        (setq skk-smart--sqlite-db nil)))))

;;; ============================================================
;;; D: skk-smart-max-corpus-total-lookups
;;; ============================================================

(ert-deftest skk-smart--compute-corpus-scores/total-lookups-truncates-candidates ()
  "total-lookups 上限超過時に候補数が縮小される（floor(limit/語数) 件）。"
  (let ((skk-smart-max-corpus-total-lookups 6)
        (skk-smart-corpus-file "/dummy.sqlite")
        (skk-smart--sqlite-db t)
        (skk-smart-debug nil)
        (lookup-count 0))
    ;; 候補3件 × 語3件 = 9ルックアップ → 上限6 → floor(6/3)=2候補に縮小
    (cl-letf (((symbol-function 'skk-smart--sqlite-lookup)
               (lambda (_c _w) (cl-incf lookup-count) 0)))
      (skk-smart--compute-corpus-scores
       '("候補A" "候補B" "候補C") '("語1" "語2" "語3")))
    (should (<= lookup-count 6))))

(ert-deftest skk-smart--compute-corpus-scores/no-truncation-within-limit ()
  "total-lookups 以内なら候補数が縮小されない（全件ルックアップする）。"
  (let ((skk-smart-max-corpus-total-lookups 9)
        (skk-smart-corpus-file "/dummy.sqlite")
        (skk-smart--sqlite-db t)
        (skk-smart-rerank-mode 'full)
        (skk-smart-debug nil)
        (lookup-count 0))
    (cl-letf (((symbol-function 'skk-smart--sqlite-lookup)
               (lambda (_c _w) (cl-incf lookup-count) 0)))
      (skk-smart--compute-corpus-scores
       '("候補A" "候補B" "候補C") '("語1" "語2" "語3")))
    (should (= lookup-count 9))))

(ert-deftest skk-smart--compute-corpus-scores/zero-limit-disables-cap ()
  "total-lookups = 0 のとき制限なし（全件ルックアップ）。"
  (let ((skk-smart-max-corpus-total-lookups 0)
        (skk-smart-corpus-file "/dummy.sqlite")
        (skk-smart--sqlite-db t)
        (skk-smart-rerank-mode 'full)
        (skk-smart-debug nil)
        (lookup-count 0))
    (cl-letf (((symbol-function 'skk-smart--sqlite-lookup)
               (lambda (_c _w) (cl-incf lookup-count) 0)))
      (skk-smart--compute-corpus-scores
       '("候補A" "候補B" "候補C") '("語1" "語2" "語3")))
    (should (= lookup-count 9))))

;;; ============================================================
;;; G: simple モード — skk-smart--sqlite-compute-corpus-scores-batch
;;; ============================================================

(ert-deftest skk-smart--sqlite-compute-corpus-scores-batch/sums-scores ()
  "バッチ集約クエリで各候補のコーパススコア合計を正しく返す。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart--sqlite-db t))
    (cl-letf (((symbol-function 'sqlite-select)
               (lambda (_db _sql _params)
                 '(("効く" 800) ("利く" 200)))))
      (let ((scores (skk-smart--sqlite-compute-corpus-scores-batch
                     '("効く" "利く" "聞く") '("薬"))))
        (should (= (gethash "効く" scores 0) 800))
        (should (= (gethash "利く" scores 0) 200))
        ;; DB に存在しない候補は 0
        (should (= (gethash "聞く" scores 0) 0))))))

(ert-deftest skk-smart--sqlite-compute-corpus-scores-batch/nil-context-returns-zeros ()
  "context-words が nil のとき DB アクセスせず全スコア 0 を返す。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart--sqlite-db t)
        (select-called nil))
    (cl-letf (((symbol-function 'sqlite-select)
               (lambda (_db _sql _params) (setq select-called t) nil)))
      (let ((scores (skk-smart--sqlite-compute-corpus-scores-batch
                     '("効く" "利く") nil)))
        (should (= (gethash "効く" scores 0) 0))
        (should (= (gethash "利く" scores 0) 0))
        (should-not select-called)))))

(ert-deftest skk-smart--sqlite-compute-corpus-scores-batch/with-okurigana ()
  "okurigana を指定したとき DB キーに付加し、ht キーは短形式のまま返す。
例: 候補 \"効;annotation\" + okurigana \"く\" → DB 検索は \"効く\"、ht キーは \"効\"。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart--sqlite-db t)
        (sent-params nil))
    (cl-letf (((symbol-function 'sqlite-select)
               (lambda (_db _sql params)
                 (setq sent-params params)
                 ;; DB は "効く" を返す
                 '(("効く" 800)))))
      (let ((scores (skk-smart--sqlite-compute-corpus-scores-batch
                     '("効;(effect) 薬が効く" "利;注釈") '("薬") "く")))
        ;; SQL には "効く" が渡されるべき
        (should (member "効く" sent-params))
        ;; ht キーは注釈なし短形式
        (should (= (gethash "効" scores 0) 800))
        (should (= (gethash "利" scores 0) 0))))))

(ert-deftest skk-smart--compute-corpus-scores/sqlite-appends-okurigana ()
  "okurigana 指定時、DB ルックアップキーに okurigana を付加する。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart--sqlite-db t)
        (skk-smart--corpus-path nil)
        (skk-smart-corpus-file "/dummy.sqlite")
        (skk-smart-rerank-mode 'full)
        (skk-smart-max-corpus-total-lookups 0)
        (skk-smart-debug nil)
        (last-lookup-cand nil))
    (cl-letf (((symbol-function 'skk-smart--sqlite-lookup)
               (lambda (c _w) (setq last-lookup-cand c) 0)))
      (skk-smart--compute-corpus-scores '("効;annotation") '("薬") "く")
      ;; "効く"（okurigana 付き）でルックアップすべき
      (should (equal last-lookup-cand "効く")))))

(ert-deftest skk-smart--compute-corpus-scores/sqlite-simple-mode-uses-batch ()
  "SQLite + simple モードのとき batch クエリ（1 回の sqlite-select）を使う。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((skk-smart--sqlite-db t)
        (skk-smart--corpus-path nil)
        (skk-smart-corpus-file "/dummy.sqlite")
        (skk-smart-rerank-mode 'simple)
        (skk-smart-max-corpus-total-lookups 0)
        (skk-smart-debug nil)
        (select-count 0))
    (cl-letf (((symbol-function 'sqlite-select)
               (lambda (_db _sql _params)
                 (cl-incf select-count)
                 '(("効く" 800)))))
      (let ((scores (skk-smart--compute-corpus-scores
                     '("効く" "利く" "聞く") '("薬" "治療"))))
        ;; バッチクエリ: candidates×context_words 回ではなく 1 回だけ呼ぶ
        (should (= select-count 1))
        (should (= (gethash "効く" scores 0) 800))
        (should (= (gethash "利く" scores 0) 0))))))

;;; ============================================================
;;; G: simple モード — context-search 統合テスト
;;; ============================================================

(ert-deftest skk-smart-context-search/simple-mode-promotes-winner ()
  "simple モードで最高スコア候補が先頭に移動する。"
  (let ((skk-smart-alist nil)
        (skk-smart-corpus-file "/dummy.sqlite")
        (skk-smart--sqlite-db t)
        (skk-smart-rerank-mode 'simple)
        (skk-smart-jisyo-weight 0.0)
        (skk-smart-corpus-weight 1.0)
        (skk-smart-max-corpus-total-lookups 0)
        (skk-smart-debug nil))
    (cl-letf (((symbol-function 'sqlite-select)
               (lambda (_db _sql _params)
                 ;; 効く=800, 利く=0, 聞く=0
                 '(("効く" 800)))))
      (with-temp-buffer
        (insert "この薬は")
        (let* ((skk-henkan-start-point (point-max-marker))
               (result (skk-smart-context-search
                        (current-buffer) "きく" nil '("効く" "利く" "聞く"))))
          (should (equal (car result) "効く"))
          ;; simple モード: 2・3位は元の順序
          (should (equal (cdr result) '("利く" "聞く"))))))))

(ert-deftest skk-smart-context-search/simple-mode-preserves-rest-order ()
  "simple モードで 2 位以降の候補は元の相対順序を維持する。"
  (let ((skk-smart-alist nil)
        (skk-smart-corpus-file "/dummy.sqlite")
        (skk-smart--sqlite-db t)
        (skk-smart-rerank-mode 'simple)
        (skk-smart-jisyo-weight 0.0)
        (skk-smart-corpus-weight 1.0)
        (skk-smart-max-corpus-total-lookups 0)
        (skk-smart-debug nil))
    (cl-letf (((symbol-function 'sqlite-select)
               (lambda (_db _sql _params)
                 ;; 丙=500, 他=0
                 '(("丙" 500)))))
      (with-temp-buffer
        (insert "文脈語")
        (let* ((skk-henkan-start-point (point-max-marker))
               (result (skk-smart-context-search
                        (current-buffer) "dummy" nil '("甲" "乙" "丙" "丁"))))
          (should (equal result '("丙" "甲" "乙" "丁"))))))))

(ert-deftest skk-smart-context-search/simple-mode-corpus-disambiguates-kiku-yaku-okurigana ()
  "実際の SKK 形式（okurigana エントリ）で \"この薬はきく\" → 効;annotation が第一候補。
SKK では送り仮名エントリの候補は \"効;annotation\" 形式で渡され、okurigana=\"く\"。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((fixture-path (skk-smart-test--sqlite-fixture-path)))
    (skip-unless (file-readable-p fixture-path))
    (let ((skk-smart--sqlite-db (sqlite-open fixture-path))
          (skk-smart--corpus-path nil)
          (skk-smart-corpus-file fixture-path)
          (skk-smart--corpus-file-opened fixture-path)
          (skk-smart-rerank-mode 'simple)
          (skk-smart-alist nil)
          (skk-smart-jisyo-weight 0.0)
          (skk-smart-corpus-weight 1.0)
          (skk-smart-max-corpus-total-lookups 0)
          (skk-smart-debug nil))
      (unwind-protect
          (with-temp-buffer
            (insert "この薬は")
            (let* ((skk-henkan-start-point (point-max-marker))
                   ;; 実際の SKK 形式: okurigana エントリ、候補は短形式＋注釈
                   (result (skk-smart-context-search
                            (current-buffer) "きk" "く"
                            '("効;(effect) 薬が効く" "利;(work)" "聞"))))
              ;; corpus: (効く, 薬)=800 が最高 → 効;annotation が第一候補
              (should (equal (car result) "効;(effect) 薬が効く"))))
        (sqlite-close skk-smart--sqlite-db)
        (setq skk-smart--sqlite-db nil)))))

(ert-deftest skk-smart-context-search/simple-mode-corpus-disambiguates-kiku-hana-okurigana ()
  "実際の SKK 形式（okurigana エントリ）で \"鼻がきく\" → 利;annotation が第一候補。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((fixture-path (skk-smart-test--sqlite-fixture-path)))
    (skip-unless (file-readable-p fixture-path))
    (let ((skk-smart--sqlite-db (sqlite-open fixture-path))
          (skk-smart--corpus-path nil)
          (skk-smart-corpus-file fixture-path)
          (skk-smart--corpus-file-opened fixture-path)
          (skk-smart-rerank-mode 'simple)
          (skk-smart-alist nil)
          (skk-smart-jisyo-weight 0.0)
          (skk-smart-corpus-weight 1.0)
          (skk-smart-max-corpus-total-lookups 0)
          (skk-smart-debug nil))
      (unwind-protect
          (with-temp-buffer
            (insert "鼻が")
            (let* ((skk-henkan-start-point (point-max-marker))
                   (result (skk-smart-context-search
                            (current-buffer) "きk" "く"
                            '("効;(effect) 薬が効く" "利;(work)" "聞"))))
              ;; corpus: (利く, 鼻)=800 が最高 → 利;annotation が第一候補
              (should (equal (car result) "利;(work)"))))
        (sqlite-close skk-smart--sqlite-db)
        (setq skk-smart--sqlite-db nil)))))

(ert-deftest skk-smart-context-search/simple-mode-corpus-disambiguates-kiku-yaku ()
  "\"この薬はきく\" の文脈で corpus が 効く を第一候補に選ぶ（実 fixture 使用）。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((fixture-path (skk-smart-test--sqlite-fixture-path)))
    (skip-unless (file-readable-p fixture-path))
    (let ((skk-smart--sqlite-db (sqlite-open fixture-path))
          (skk-smart--corpus-path nil)
          (skk-smart-corpus-file fixture-path)
          (skk-smart--corpus-file-opened fixture-path)
          (skk-smart-rerank-mode 'simple)
          (skk-smart-alist nil)
          (skk-smart-jisyo-weight 0.0)
          (skk-smart-corpus-weight 1.0)
          (skk-smart-max-corpus-total-lookups 0)
          (skk-smart-debug nil))
      (unwind-protect
          (with-temp-buffer
            (insert "この薬は")
            (let* ((skk-henkan-start-point (point-max-marker))
                   (result (skk-smart-context-search
                            (current-buffer) "きく" nil '("効く" "利く" "聞く"))))
              ;; corpus: (効く, 薬)=800 が最高 → 効く が第一候補
              (should (equal (car result) "効く"))))
        (sqlite-close skk-smart--sqlite-db)
        (setq skk-smart--sqlite-db nil)))))

(ert-deftest skk-smart-context-search/simple-mode-corpus-disambiguates-kiku-hana ()
  "\"鼻がきく\" の文脈で corpus が 利く を第一候補に選ぶ（実 fixture 使用）。"
  (skip-unless (fboundp 'sqlite-open))
  (let ((fixture-path (skk-smart-test--sqlite-fixture-path)))
    (skip-unless (file-readable-p fixture-path))
    (let ((skk-smart--sqlite-db (sqlite-open fixture-path))
          (skk-smart--corpus-path nil)
          (skk-smart-corpus-file fixture-path)
          (skk-smart--corpus-file-opened fixture-path)
          (skk-smart-rerank-mode 'simple)
          (skk-smart-alist nil)
          (skk-smart-jisyo-weight 0.0)
          (skk-smart-corpus-weight 1.0)
          (skk-smart-max-corpus-total-lookups 0)
          (skk-smart-debug nil))
      (unwind-protect
          (with-temp-buffer
            (insert "鼻が")
            (let* ((skk-henkan-start-point (point-max-marker))
                   (result (skk-smart-context-search
                            (current-buffer) "きく" nil '("効く" "利く" "聞く"))))
              ;; corpus: (利く, 鼻)=800 が最高 → 利く が第一候補
              (should (equal (car result) "利く"))))
        (sqlite-close skk-smart--sqlite-db)
        (setq skk-smart--sqlite-db nil)))))

;; Local Variables:
;; indent-tabs-mode: nil
;; coding: utf-8
;; End:

;;; skk-smart-test.el ends here
