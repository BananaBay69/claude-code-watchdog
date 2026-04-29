## 1. Config 與 dispatch 架構

- [x] 1.1 在 `init_config()` 解析 `WATCHDOG_SILENT_LOOP_RECOVERY` enum env var（接受 disabled / snapshot-only / soft / aggressive；unknown 值 fallback `disabled` 並 log WARN — recovery dispatch via enum env var），以及 `WATCHDOG_SNAPSHOT_RETAIN_COUNT`（default 20，FIFO retention by count）
- [x] 1.2 實作 `recovery_driver()` dispatcher：case 分派到對應函式，包含 `disabled` 無動作、`snapshot-only` 呼叫 `take_snapshot`、`soft` / `aggressive` 各自 stub 印 `WARN: <mode> mode requested but not implemented`（Recovery dispatch on silent-loop detection）
- [x] 1.3 在 `main()` 的 silent-loop branch 內，將 `recovery_driver()` 接在既有 `alert_already_sent silent-loop` 檢查之後，確保 Snapshot piggybacks alert dedup 且 Snapshot generation deduplicates per silent-loop state-entry

## 2. Snapshot capture 實作

- [x] 2.1 實作 `take_snapshot()` 建立 `$LOG_DIR/snapshots/silent-loop-<YYYYMMDDhhmmss>/` 目錄結構（Snapshot is a directory of small text files；Snapshot capture writes a fixed file set）
- [x] 2.2 在 `take_snapshot()` 內以 `timeout 5s` 包住，依序寫 `pane.txt`（`tmux capture-pane -p -S -2000`）、`status.txt`、`env.txt`（含 `WATCHDOG_*` env + `tmux ls` + `pgrep -lf claude`）、`recent-log.txt`（log 後 200 行）
- [x] 2.3 寫 `active-skills.txt`：列 `~/.claude/plugins/**/skills/*.md` 路徑加 ISO 8601 mtime（active-skills.txt records mtime, not content）
- [x] 2.4 寫 `metadata.json`：`{captured_at, silent_loop_state: {incoming, outbound_age_seconds}, watchdog_version}`
- [x] 2.5 實作 sub-capture 失敗的 partial-snapshot 語意：任一 sub-capture timeout 或 exit non-zero 時 log `WARN: snapshot <file> failed (<reason>)`，但不 abort 整個 snapshot

## 3. Retention 與手動 CLI

- [x] 3.1 實作 `prune_old_snapshots()`：依目錄名稱 timestamp 排序，prune 到剩 `WATCHDOG_SNAPSHOT_RETAIN_COUNT - 1` 個（Snapshot retention enforces FIFO count cap）
- [x] 3.2 在 `take_snapshot()` 開頭呼叫 `prune_old_snapshots()`，確保新 snapshot 寫入後總數不超過 cap
- [x] 3.3 在 `parse_args()` 加 `--snapshot` CLI flag（Manual --snapshot CLI flag）
- [x] 3.4 在 `main()` 處理 `--snapshot` 入口：呼叫 `take_snapshot()` 後直接 exit；MUST NOT 查 alert dedup flag、MUST NOT 改 alert state

## 4. Alert 訊息整合

- [x] 4.1 修改 silent-loop alert 路徑：snapshot 成功建立時，傳給 `WATCHDOG_ALERT_CMD` 的 `WATCHDOG_ALERT_MSG` 結尾 append ` Snapshot: <absolute_path>`；snapshot 失敗或 mode 非 snapshot-only 時保持 v0.1.7 格式（Alert message includes snapshot path when snapshot mode is active）

## 5. Tests（沿用 v0.1.6 既有 harness）

- [x] 5.1 [P] `test/unit/take-snapshot.test.sh`：mock tmux + 環境，assert snapshot 目錄存在且含 6 個預期檔案，metadata.json schema 正確
- [x] 5.2 [P] `test/unit/snapshot-retention.test.sh`：建立 N 個假 snapshot 目錄，呼叫 `prune_old_snapshots()`，assert 剩餘 = cap-1 且 prune 的是最舊
- [x] 5.3 [P] `test/integration/snapshot-on-silent-loop.test.sh`：模擬 silent-loop trigger（incoming pane content + outbound stale），assert snapshot dir 出現；連跑兩 tick 同 state，assert 仍只有一個 snapshot
- [x] 5.4 [P] `test/integration/snapshot-cli-flag.test.sh`：以 `--snapshot` 直接呼叫，assert 不論 detection 狀態都產生 snapshot 且 alert flag 不變

## 6. Documentation 與 version bump

- [x] 6.1 [P] `README.md` 加 `WATCHDOG_SILENT_LOOP_RECOVERY` / `WATCHDOG_SNAPSHOT_RETAIN_COUNT` env vars 說明、snapshot 目錄結構表、`--snapshot` flag、triage flow 範例（如何看 snapshot 判斷 instruction-leak vs transient state）
- [x] 6.2 [P] `CHANGELOG.md` 寫 v0.1.8 entry：列新 env vars、新 CLI flag、snapshot 結構、引用 issue #22 與 issue #15 closing decision
- [x] 6.3 [P] 在 `claude-watchdog.sh` 開頭 `WATCHDOG_VERSION` 從 `0.1.7` bump 到 `0.1.8`
