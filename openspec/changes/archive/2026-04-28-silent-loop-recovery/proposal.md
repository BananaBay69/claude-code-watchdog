## Why

v0.1.7 上線的 silent-loop detection（closes #15）能正確識別 bot 活著但不回覆——incoming 在 pane 累積、`mcp__telegram__reply` 600 秒內沒 fire——並 emit `silent-loop` alert 而**刻意不重啟**（root cause 通常是 SKILL.md instruction-leak，fresh process 會載入同一份壞檔再進 loop）。設計本身合理。

但運維上不夠用。Issue #22 暴露這個 gap：實機（Jacky 的 Mac mini）已經 silent-loop alerting **連續 2 天無人處理**——alert 只寫了 log line + 跑 `WATCHDOG_ALERT_CMD`，operator 要 ssh 進去 `tmux capture-pane` 然後肉眼回推 pane 內容才能診斷。這個摩擦就是 alert 被無視的原因。

更關鍵的是：原作者在 issue #15 收尾留言明確**將 restart-on-silent-loop 暫緩**——但**附帶條件**「等實測證實某些 silent-loop 真能被 restart 修再說」。要蒐集那份證據，目前的工具完全沒準備好。

## What Changes

在 `claude-watchdog.sh` 內加一個 **recovery driver** dispatch 機制，silent-loop 偵測到時根據新 env var 決定行為：

```
WATCHDOG_SILENT_LOOP_RECOVERY = disabled       (預設；等同現行 alert-only)
                              | snapshot-only  (Phase 1 — 本次實作)
                              | soft           (未來 — tmux send-keys)
                              | aggressive     (未來 — 升級到 restart)
```

Phase 1 **僅**實作 `snapshot-only`：silent-loop 第一次 state-entry alert fire 時，同時寫一個診斷 snapshot 目錄，內含 pane content、status 輸出、env vars、最近 log、active-skill mtimes。`soft` 與 `aggressive` 是 stub（log "not implemented" + return），純粹鎖住 dispatch 形狀讓未來 PR 加行為不加架構。

Snapshots 落腳 `$LOG_DIR/snapshots/silent-loop-{YYYYMMDDhhmmss}/`，FIFO 保留上限預設 20。Snapshot 觸發 piggyback 在既有 `silent-loop` alert 的 state-dedup flag 上——一次 state-entry 最多一個 snapshot，自動有界、不需額外 config。

Alert 訊息加 `Snapshot: <path>` 字尾，operator 收到 alert 同時拿到 snapshot 路徑。

新增 `claude-watchdog.sh --snapshot` CLI flag，operator 可手動觸發同樣的 capture（ad-hoc 用，與 silent-loop 偵測獨立）。

## Non-Goals

- **任何形式的 restart-on-silent-loop。** `aggressive` 是保留枚舉值，本次**不**實作。Issue #15 結論明列「需要實測證據先行」——這個 snapshot 工具就是要蒐集那份證據。
- **Soft recovery（tmux send-keys、`/resume`）。** 同理，stub 保留位置不實作。
- **依日期 prune snapshot。** 只用 FIFO 數量限制；日期型 retention 增加複雜度卻無明顯收益。
- **跨機 snapshot 集中收集。** Snapshots 是 local files；要 aggregate 是 operator 自己的事。
- **Snapshot 內含 SKILL.md 完整內容。** `active-skills.txt` 只列路徑 + mtime（內容可能很大、可能含 secret）。
- **改 silent-loop 偵測邏輯本身。** `detect_silent_loop()` 完全不動，本次只在它之後加 dispatch。

## Capabilities

### New Capabilities

- `silent-loop-recovery`: silent-loop 偵測到時的 dispatch 架構。Phase 1 實作 `disabled` 與 `snapshot-only` 兩個 mode；`soft` 與 `aggressive` 是 stub，保留給未來 PR。

### Modified Capabilities

(無——silent-loop detection 本體不動，alert 那段只是多一個 dispatch call。)

## Impact

- Affected specs: 新增 `silent-loop-recovery` capability（無既有 capability 需要改）
- Affected code:
  - Modified:
    - `claude-watchdog.sh` — 新增 `take_snapshot()`、stub `try_soft_recovery()` / `maybe_restart()`、`recovery_driver()` dispatcher；接到 `main()` 內 silent-loop branch；`init_config()` 解析新 env vars；`parse_args()` 加 `--snapshot`；bump `WATCHDOG_VERSION` 至 `0.1.8`
    - `README.md` — 文件化 `WATCHDOG_SILENT_LOOP_RECOVERY` 與 `WATCHDOG_SNAPSHOT_RETAIN_COUNT`、snapshot 目錄結構、`--snapshot` flag
    - `CHANGELOG.md` — v0.1.8 entry
  - New:
    - `test/unit/take-snapshot.test.sh` — snapshot 寫出預期檔案 + 內容
    - `test/unit/snapshot-retention.test.sh` — FIFO 超過 cap 時 prune 最舊
    - `test/integration/snapshot-on-silent-loop.test.sh` — silent-loop trigger 產生 snapshot；同 state 第二 tick 不再產生
    - `test/integration/snapshot-cli-flag.test.sh` — `--snapshot` 不論偵測狀態都寫一份
  - Removed: (無)
