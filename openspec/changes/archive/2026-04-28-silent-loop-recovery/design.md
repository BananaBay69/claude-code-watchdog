## Context

Silent-loop detection 已在 v0.1.7 上線（issue #15）：當 incoming channel messages 持續累積、`mcp__telegram__reply` 在 `WATCHDOG_SILENT_LOOP_OUTBOUND_STALE_SECONDS` 內未 fire、且 pane 沒有其他 stuck pattern 時，watchdog 會 emit `silent-loop` alert（state-based dedup，flag = `.watchdog-alert-sent-silent-loop`），並**刻意不重啟**。

原作者（issue #15 closing comment）給的論證是「root cause 多半是 SKILL.md instruction-leak，restart 後 fresh process 載入同一份壞檔再進 loop」，並明示「等實測證實某些 silent-loop 真能被 restart 修再說」才會考慮加 restart。

Issue #22 暴露兩個運維 gap：
1. Alert 只寫 log + 跑 `WATCHDOG_ALERT_CMD`，operator 要 ssh + `tmux capture-pane` + 肉眼回推才能診斷——摩擦太高，導致 alert 被無視（Jacky 機器 silent-loop 連續 2 天）
2. 沒有任何工具在收集 silent-loop 發生時的**結構化現場資料**，原作者等的「實測證據」永遠不會自動到手

本 change 提供 dispatch 架構 + 第一個 mode（`snapshot-only`）解決上述兩問題；同時為未來的 `soft` / `aggressive` recovery mode 鎖住 API 形狀，讓後續 PR 加行為不加架構。

## Goals / Non-Goals

**Goals:**

- Silent-loop fire 時**自動**留下足以離線診斷的現場 snapshot，operator 不需 ssh 就能判斷該 case 是 instruction-leak（restart 沒用）還是 transient state（restart 可能有用）
- 提供 dispatch 架構，未來加 `soft` / `aggressive` mode 只是新增 case branch + 實作對應函式，不需重構
- 全 backward-compat：`WATCHDOG_SILENT_LOOP_RECOVERY=disabled` 預設，現有部署完全不受影響
- 提供手動觸發機制（`--snapshot` CLI flag），operator 可在 silent-loop 之外的場景使用

**Non-Goals:**

- 不實作任何形式的 restart-on-silent-loop（`aggressive` 是 stub）
- 不實作 tmux send-keys 類 soft recovery（`soft` 是 stub）
- 不集中收集跨機 snapshot
- 不嘗試解析 / 分析 snapshot 內容（snapshot 是給人看的）
- 不改 `detect_silent_loop()` 偵測邏輯

## Decisions

### Recovery dispatch via enum env var

新增 `WATCHDOG_SILENT_LOOP_RECOVERY` 接受 4 個固定值：`disabled` / `snapshot-only` / `soft` / `aggressive`。在 silent-loop branch 內以單一 `case` 分派到對應函式。

**Rationale:** Bash `case` 對窮舉值比 nested `if` 可讀；4 mode 排成階梯（什麼都不做 → 收資料 → 軟介入 → 硬重啟）對 operator 直覺。Enum 比 boolean 多一個維度（diagnostic-only mode），讓「我只想要 snapshot 不想動 bot」是 first-class 選項。

**Alternatives considered:**
- 單一 `WATCHDOG_SILENT_LOOP_AUTO_RESTART=1` boolean：簡單但失去 snapshot-only / soft 的階梯
- 多 boolean（`WATCHDOG_SILENT_LOOP_SNAPSHOT=1`, `WATCHDOG_SILENT_LOOP_RESTART=1`）：可組合但可能組出無意義組合（restart=1, snapshot=0 等於把證據丟掉）

### Snapshot piggybacks alert dedup

Snapshot 觸發共用既有 `silent-loop` alert 的 `alert_already_sent` flag——alert fire 一次（state entry）就 snapshot 一次；之後 tick 還在 silent-loop 不再 snapshot；outbound advance 後 flag 清掉，下次又進 silent-loop 才會新 snapshot。

**Rationale:** Snapshot 跟 alert 是同一個事件的兩個輸出，本來就該同生同死。共用 dedup 避免「same state 480 個 snapshots/day」的爆量風險，且零額外 config。

**Alternatives considered:**
- 獨立 snapshot cap（`WATCHDOG_SNAPSHOT_DAILY_CAP=20`）：增加 mental model 複雜度，且需要新 state file
- Snapshot 每次 tick 都拿：診斷價值低（pane 內容變化不大），磁碟成本高

### FIFO retention by count

`WATCHDOG_SNAPSHOT_RETAIN_COUNT`（預設 20）控保留數；每次新 snapshot 寫入前 prune 最舊到剛好剩 cap-1 個。

**Rationale:** 單一機制、無時間邏輯、可預測。20 個夠覆蓋多次 incident 但不至於塞爆磁碟（每個 snapshot 估 < 100 KB → max 2 MB）。

**Alternatives considered:**
- 日期型 retention（保留 7 天）：silent-loop 頻率不固定，可能 7 天才 1 個或 1 天 50 個，不穩
- 大小型 retention（總大小 < 50 MB）：要 du 算總和，慢且實作易錯

### Snapshot is a directory of small text files

每個 snapshot 一個目錄 `silent-loop-{YYYYMMDDhhmmss}/` 含 6 個檔案（`pane.txt`, `status.txt`, `env.txt`, `recent-log.txt`, `active-skills.txt`, `metadata.json`）。

**Rationale:** Operator 可用 `cat`、`grep`、editor 直接看任何一份；不需 unpack；`grep -r "skill_x" snapshots/` 跨 snapshot 搜尋也直接。

**Alternatives considered:**
- 單一 tarball：要 untar 才看；交給 operator 額外步驟
- 單一 JSON blob：pane content 嵌進 JSON 不好讀且要 escape
- Append-only single log：失去「這次 incident」的 grouping

### active-skills.txt records mtime, not content

`active-skills.txt` 列 `~/.claude/plugins/**/skills/*.md` 路徑 + `stat` mtime，**不**含檔案內容。

**Rationale:** SKILL.md 可能很大、可能含 secret（API keys、private prompt）。Mtime 已足以診斷「最近改過哪份 SKILL，可能是 instruction-leak 嫌疑」；要看內容 operator 可手動 cat。

**Alternatives considered:**
- 連 content 都收：自動化但有隱私 / 大小風險
- 只列檔名不含 mtime：失去「最近改過」這個關鍵診斷訊號

### Manual --snapshot CLI flag

`claude-watchdog.sh --snapshot` 不論偵測狀態都產生 snapshot，與 silent-loop trigger 共用 `take_snapshot()` 實作。

**Rationale:** Operator 偶爾想「現在抓一份看看」（例如 bot 看起來怪但 silent-loop 還沒 fire）；提供同樣機制的手動入口零成本。

**Alternatives considered:**
- 僅自動觸發：operator 要等 silent-loop fire 才有資料，反應慢
- 寫獨立 `claude-watchdog-snapshot.sh`：重複實作 + 多一個檔案

## Risks / Trade-offs

- **[Pane content 可能含 secret]** Snapshot pane 內容可能包含使用者私訊、API token、credential。 → **Mitigation:** README 明文警告 snapshot 是 sensitive；retention default 只留 20 個；operator 自行決定要不要清掉。

- **[$LOG_DIR 磁碟爆掉]** 雖然 FIFO 有 cap，但若 `pane.txt` 異常大（例如 pane 被塞 megabytes 的輸出），20 個 snapshot 可能超過預期。 → **Mitigation:** `tmux capture-pane -S -2000` 限制最多 2000 行；單一 snapshot 估上限 ~500 KB；20 個 = 10 MB worst case。

- **[Snapshot 在 high-load 期間漏資料]** `take_snapshot()` 跑 `tmux capture-pane`、`stat`、`launchctl print` 數個 syscalls，若系統 IO 飽和可能 timeout。 → **Mitigation:** 每個 sub-command 用 `timeout 5s` 包住；任一失敗只記 WARN 不 abort，snapshot 仍寫部分檔案。

- **[Operator 不去看 snapshot]** Snapshot 自動產生但無人 triage 等於沒做。 → **Mitigation:** Alert 訊息加 `Snapshot: <path>` 字尾，operator 收 alert 同時拿到路徑；README 加「triage flow」一節示範如何看 snapshot 判斷類型。

- **[Stub 函式被誤呼叫]** `try_soft_recovery()` 和 `maybe_restart()` 是 stub，若未來實作前有 bug 路徑誤觸 dispatch 到這些 mode 會悄悄無動作。 → **Mitigation:** Stub 必 log `WARN: <mode> mode requested but not implemented` 不能靜默 return；測試覆蓋 enum 所有值（含 stub modes）。

- **[Dispatch 架構鎖太早]** 現在定的 4-mode enum 未來可能不夠用（例如想加 `escalate-to-human`）。 → **Mitigation:** Bash case 加新 branch 成本極低；env var 接受 unknown value 時 fallback 到 `disabled` + log WARN，不讓 typo 變 silent breakage。
