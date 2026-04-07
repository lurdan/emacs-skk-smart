EMACS    ?= emacs
DDSKK_DIR = ddskk
DDSKK_URL = https://github.com/skk-dev/ddskk

.PHONY: test fixture clean-ddskk

# ddskk が未クローンなら shallow clone する
$(DDSKK_DIR):
	git clone --depth 1 $(DDSKK_URL) $(DDSKK_DIR)

# SQLite テスト用フィクスチャを生成
fixture:
	python3 tools/make_sqlite.py --test-fixture

# 全テストを実行（ddskk を load path に追加）
test: $(DDSKK_DIR)
	$(EMACS) --batch -L . -L $(DDSKK_DIR) -L test \
	  --eval "(require 'ert)" \
	  --eval "(load \"test/skk-smart-test.el\")" \
	  --eval "(ert-run-tests-batch-and-exit t)"

# パフォーマンスベンチマークを実行
bench: $(DDSKK_DIR)
	$(EMACS) --batch -L . -L $(DDSKK_DIR) -L test \
	  --eval "(load \"test/skk-smart-bench.el\")"

# ddskk を削除して再クローンできる状態にする
clean-ddskk:
	rm -rf $(DDSKK_DIR)
