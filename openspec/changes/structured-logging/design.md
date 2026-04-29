## Context

`claude-watchdog.sh` 已經有 35 個 `log()` 呼叫，全部使用 `LEVEL:` 文字前綴慣例（15 WARN / 6 INFO / 4 DETECT / 3 ACTION / 2 OK / 1 ERROR / 1 DEBUG / 1 COOLDOWN / 1 ALERT 模板）。慣例 100% adherence，但無強制機制：所有層級平等寫入，無門檻過濾，operator 無法靜音 DEBUG 噪音。

Issue #22 (Jacky's Mac mini silent-loop 持續 2 天) 暴露運維 gap：
1. `2>/dev/null \|\| true` 等 silent path 約 10 處，I/O / permission / kill 失敗完全不留痕跡
2. Operator 跑 `--reset` / `--snapshot` 等狀態變更指令，主 log 沒任何紀錄
3. `parse_args` 錯誤 `echo ... >&2` 進 launchd `.err` 檔，operator 通常只看主 log → orphan log

Diagnosis #24 + 後續 spectra-discuss 已收斂出 5 個 design 決策（見下 Decisions 章節），其中**最關鍵的 trade-off** 是「prefix-parsing 重用既有慣例」vs「明確 API + 33-site 遷移」。前者選擇了，因為 codebase 慣例 100% 一致使 prefix-parsing 可靠，且零 test churn（現有 18 個 test 全部 grep `WARN: foo` 子字串，format 一改就全紅）。

Existing silent-loop-recovery capability (v0.1.8, see openspec/specs/silent-loop-recovery/) is orthogonal：silent-loop 的偵測 / dispatcher / snapshot 邏輯不動，只是它的既有 `WARN:` / `INFO:` log 行會自動被新門檻治理。

## Goals / Non-Goals

**Goals:**

- 既有 33 個 `log()` call-site 全部享有層級門檻過濾，零程式碼遷移
- Operator `--reset` / `--snapshot` 等狀態變更指令必有 audit log 紀錄
- 約 10 個 silent error-suppression path 各補一行 log（DEBUG 或 WARN，視嚴重度）
- `parse_args` 錯誤同時寫主 log + stderr，消除 launchd `.err` orphan log gap
- 現有 18 個 test pass unchanged（hard acceptance criterion，作為 Phase 1 完成的閘門）
- ALERT 永不被 threshold 抑制（不破壞 alert dedup 協定）

**Non-Goals:**

- 不改 on-wire 格式（保持 `YYYY-MM-DD HH:MM:SS LEVEL: msg`）
- 不遷移既有 33 個 `log "WARN:..."` 到 `log_at` API
- 不加 `--log-level` CLI flag
- 不引入 structured JSON / syslog / 遠端 log shipping
- 不改 log rotation 策略
- 不做 per-helper enter/exit DEBUG instrumentation

## Decisions

### log() prefix-parse + ordinal threshold

`log()` body 變成：取 `$1`、用 `grep -oE '^[A-Z]+:'` 抽前綴、轉成 ordinal、跟 `LOG_LEVEL_THRESHOLD` 比對、未過直接 return。具備前綴的 33 個既有 site 自動受治理；無前綴的呼叫預設 INFO（保險 fallback）。

**Rationale:** 既有 codebase 100% 遵循 `LEVEL:` 慣例，prefix-parsing 可靠且零遷移成本。Threshold 過濾必須**早於** timestamp formatting — 否則 `WATCHDOG_LOG_LEVEL=ERROR` 在繁忙 daemon 上仍每 tick 浪費字串格式化的 CPU。

**Alternatives considered:**
- **遷移到 `log_at LEVEL "msg"` API**（33-site 改動）：純 cosmetic，diff noise 大，且如果 callers 同時保留舊 `log()` 必須兩套 API 都支援
- **強制要求所有 `log()` 呼叫都有前綴並 lint 檢查**：增加維護負擔，但既有 33/33 已遵循

### log_at LEVEL "msg" helper

新增 `log_at <level> <msg>` 給程式化 callers（例如 `level="$WHATEVER"`）。內部直接呼叫同一個 `_log_level_passes` ordinal check，與 `log()` 走同一條過濾管線。**不取代** `log()`。

**Rationale:** 有些情境 level 是變數（例如未來 alert 訊息要轉成 log，level 從外部傳入）；硬塞進 `log "$VAR: msg"` 會脆弱。`log_at` 是 escape hatch，不會被廣泛使用。

**Alternatives considered:**
- **只做 `log()` 不做 `log_at`**：未來變數 level 場景就要拼接字串，醜。零成本就保留。

### Option A pre-LOG_DIR error mirror

`parse_args` 在 `setup_logging` 前 fire 的錯誤路徑，用 `mkdir -p "$LOG_DIR" 2>/dev/null && printf '%s\n' "$line" >> "$LOG_FILE"` 的最小路徑寫入，**不**呼叫 `setup_logging`（避開 rotation 副作用）。如果 `mkdir` 失敗（perm 問題等罕見場景），靜默退到 stderr-only。

**Rationale:** `init_config` 在 top-level 跑（line 163），所以 `$LOG_DIR` 變數已經有值，只是目錄可能還沒建。`mkdir -p` idempotent + 微秒級 cost。Rotation 不該在 exit-2 錯誤路徑觸發 — 那是 `setup_logging` 的職責，留給正常 daemon tick。

**Alternatives considered:**
- **Option B（buffer + flush）**：要把錯誤訊息存進變數、跑 `setup_logging`、再 flush。耦合 parse_args ↔ setup_logging 順序，增加 mental overhead
- **Option C（stderr-only）**：保持現狀，等於沒解 issue #24 的「stderr orphan log」問題

### Semantic prefixes map to INFO; ALERT bypasses

Prefix → level 映射表：
- `DEBUG:` → DEBUG (10)
- `INFO:` / `OK:` / `DETECT:` / `ACTION:` / `COOLDOWN:` → INFO (20)
- `WARN:` → WARN (30)
- `ERROR:` → ERROR (40)
- `ALERT [...]:` → bypass（永遠寫，不論 threshold）

**Rationale:** OK/DETECT/ACTION/COOLDOWN 描述的是「發生什麼類型的事件」，不是「多嚴重」。把它們當 INFO bucket 的 semantic flavour 比加 4 個獨立層級乾淨（`WATCHDOG_LOG_LEVEL=ACTION` 是無意義的 query）。ALERT 有獨立 dedup state machine（`.watchdog-alert-sent-*` flag），用 threshold 抑制會破壞 alert 協定 — alerts 永遠該寫。

**Alternatives considered:**
- **每個前綴都當獨立層級**：matrix 爆炸，9 個層級 vs 4 個。沒有 use case 支撐
- **ALERT 跟 INFO 同等待遇**：危險。`WATCHDOG_LOG_LEVEL=ERROR` 會靜音所有 ALERT，包括 silent-loop 通知 — 違背 issue #24 想做「更多可見性」的目標

### WATCHDOG_LOG_LEVEL env var only

只透過環境變數設定門檻。Documented in `parse_args` `--help` text 和 `--show-config` 輸出。

**Rationale:** Operator 通常透過 plist `EnvironmentVariables` 設一次定終身。Mid-day override 罕見且可用 `WATCHDOG_LOG_LEVEL=DEBUG bash claude-watchdog.sh` ad-hoc 達成。少一個 CLI flag = 少一條測試需求。如果之後有實際需求，零成本加上去。

**Alternatives considered:**
- **同時加 `--log-level X`**：增加 parse_args 分支、--help 文字、新測試。YAGNI

## Risks / Trade-offs

- **[Existing tests grep on log content — format BC 是硬約束]** 18 個 test 用 `grep "WARN: foo"` 模式 assert log。任何格式變動（例如改成 `[WARN]`）會全紅。 → **Mitigation:** Goals 章節列為 hard criterion；Phase 1 結束前必跑全 regression。任何 PR 改 on-wire 格式 = 立即 reject
- **[Prefix-parsing 依賴 100% adherence]** 既有 33/33 site 遵循 `LEVEL:` 慣例，但未來 contributor 寫 `log "Session restarted"`（無前綴）會 default INFO。如果該 message 應該是 WARN，threshold = WARN 的 operator 會看到它。 → **Mitigation:** 新增 unit test 抓「無前綴 → 預設 INFO」行為。Future PR 可加 shellcheck-style lint 強制前綴
- **[ALERT bypass 的隱藏假設]** `log "ALERT [type]: msg"` 永遠寫 — 但若 caller 誤打成 `log "alert [type]: msg"`（小寫）會被當無前綴 → INFO bucket → 可能被靜音。 → **Mitigation:** unit test 含 case-sensitivity 檢查；prefix 解析用 `^[A-Z]+:` 強制大寫
- **[Pre-LOG_DIR mkdir 失敗的罕見情境]** 若 `$LOG_DIR` 父目錄不存在或 perm 錯，`mkdir -p` 失敗 → 退 stderr-only → 主 log 仍無紀錄。 → **Mitigation:** 既有 `install.sh` 確保目錄存在；自動化裝設不會踩到此路徑。文件警告 ad-hoc 安裝者
- **[DEBUG 門檻被遺忘留在 production]** Operator debug 完忘了改回 `WATCHDOG_LOG_LEVEL=INFO`，DEBUG 噪音持續寫入 → log rotation 觸發更頻繁。 → **Mitigation:** rotation 自動 (1 MB / keep 500 lines) 已有 cap；README 強調 DEBUG 是 incident triage 用，非 steady state
- **[壓縮 audit log 與 normal log 進同一檔]** `--reset` / `--snapshot` audit 行混在 daemon tick 之間。Operator 用 grep 找仍可區分（`grep "operator:"`），但若需要乾淨的 audit trail 要事後解析。 → **Mitigation:** 文件範例「How to extract audit trail」用 `grep operator:` 即可；單獨檔案是 over-engineering（issue #24 Non-Goals）
