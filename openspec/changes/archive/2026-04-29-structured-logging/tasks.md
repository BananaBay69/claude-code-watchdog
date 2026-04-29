## 1. Config 與 log() 核心改造

- [x] 1.1 在 `init_config()` 解析 `WATCHDOG_LOG_LEVEL env var only`（accept DEBUG/INFO/WARN/ERROR；unknown 值記錄為 fallback 待第一個 log 時 emit）；計算 `LOG_LEVEL_THRESHOLD` ordinal（DEBUG=10, INFO=20, WARN=30, ERROR=40）；確保 `WATCHDOG_LOG_LEVEL surfaced in --show-config output` 在 `--show-config` 加一行 `WATCHDOG_LOG_LEVEL=<effective>`
- [x] 1.2 改寫 `log()` body 為 `log() prefix-parse + ordinal threshold`：取 `$1` → `grep -oE '^[A-Z]+:'` 抽前綴 → 用 `_log_level_passes` 比對 ordinal → 未過 return 0；落實 `Log level threshold filters write calls`、`Semantic-flavour prefixes map to INFO bucket`（OK/DETECT/ACTION/COOLDOWN → INFO；無前綴 → INFO）、`ALERT messages bypass threshold suppression`（`^ALERT \[` 直接寫不過濾）
- [x] 1.3 新增 `_log_level_passes <level>` 內部 helper：回傳 0 / 1 對應 pass / suppress；同時負責「unknown threshold value falls back to INFO」一次性 WARN 行的 emit-once 邏輯（用 module-scope flag 避免每行重複警告）
- [x] 1.4 新增 `log_at LEVEL "msg" helper`：拼成 `LEVEL: msg` 後委派給 `log()`，確保 `log_at helper provides explicit-form API` 與 `log()` 走同一條過濾管線
- [x] 1.5 在 `parse_args()` `--help` 文字加 `WATCHDOG_LOG_LEVEL` 一段：說明可用值、預設、threshold 語意、ALERT bypass 規則（即 design topic `Semantic prefixes map to INFO; ALERT bypasses` 的使用者面向描述）

## 2. 補 silent error-suppression paths

- [x] 2.1 `attempt_restart` line 221 `tmux kill-session ... \|\| true` → 抓 rc 並在非 0 時 `log "DEBUG: kill-session no-op (rc=$rc)"`，不影響後續 start_claude（落實 `kill-session no-op emits DEBUG` scenario）
- [x] 2.2 `heartbeat_state` line 258 `read schema ... \|\| true` → 區分「檔案存在但讀失敗」與「malformed schema」；前者新增 `log "WARN: heartbeat read failed: <reason>"`，後者保留既有 WARN（落實 `heartbeat read I/O failure emits WARN` scenario）
- [x] 2.3 `outbound_state` line 300 `read schema ... \|\| true` → 同 heartbeat 模式，新增 outbound read failure WARN 行
- [x] 2.4 `read_restart_count` line 418 `cat $f \|\| echo 0` → 區分「檔案不存在」（happy path，無 log）與「檔案存在但 cat 失敗」（新增 `WARN: restart-count file unreadable: $f`），落實 `Silent error-suppression paths emit log lines` 表中 cat 列
- [x] 2.5 在 `_snapshot_capture` 內擴充失敗時 WARN 行：除 exit code 外再附最後 3 行 stderr snippet（沿用 emit_alert 的 `head -3 \| tr '\n' ' '` pattern），落實 `snapshot sub-capture failure includes stderr` scenario

## 3. Operator intervention audit log

- [x] 3.1 在 `do_reset` 結尾、所有 flag 已清完成功 return 前，呼叫 `setup_logging` 後 `log "INFO: operator: --reset (cleared $removed flags)"`，落實 `--reset writes audit line` scenario
- [x] 3.2 在 `main()` 處理 `--snapshot` 入口（既有已呼叫 setup_logging）：成功時 `log "INFO: operator: --snapshot (path: $snapshot_path)"`；失敗時 `log "ERROR: operator: --snapshot failed"`，落實 `--snapshot success writes audit line with path` scenario
- [x] 3.3 確認 `--help` / `--version` / `--show-config` / `--status` 4 路徑**不**呼叫 setup_logging 也**不**emit 任何 log 行（落實 `--help writes nothing to log` scenario，作為 negative regression test）

## 4. Pre-LOG_DIR error 鏡射 main log（Option A）

- [x] 4.1 新增 `_log_error_pre_setup <msg>` helper（`Option A pre-LOG_DIR error mirror` 實作）：`mkdir -p "$LOG_DIR" 2>/dev/null && printf '%s ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE"` — 不呼叫 setup_logging（避免 rotation side-effect）；mkdir 失敗時靜默退化，落實 `parse_args errors mirror to main log via Option A`
- [x] 4.2 在 `parse_args` 的 `*) echo "error: unknown argument '$1'..." >&2` 前先呼叫 `_log_error_pre_setup "unknown argument '$1'"`，落實 `unknown argument logs to both stderr and main log` scenario
- [x] 4.3 在 `main()` 的 `--config <bad>` not-found 分支同樣前置 `_log_error_pre_setup "config file not found: $CONFIG_FILE"`
- [x] 4.4 驗證 `parse_args error degrades gracefully when LOG_DIR is unwritable` scenario：用 read-only 父目錄做 mock，確認 stderr 仍寫、exit 仍 2、不 crash

## 5. Tests（沿用 v0.1.6 既有 harness；hard criterion = 既有 18 tests pass unchanged）

- [x] 5.1 [P] `test/unit/log-level-threshold.test.sh`：覆蓋 5 個 spec scenario — default INFO suppresses DEBUG / DEBUG threshold passes everything / ERROR threshold suppresses lower / unknown value fallback emits one-time WARN / OK 行在 INFO threshold 寫 / ACTION 行在 WARN threshold 不寫 / 無前綴行 default INFO / lowercase alert 被當無前綴
- [x] 5.2 [P] `test/unit/log-at-helper.test.sh`：覆蓋 `log_at WARN matches log "WARN: ..."` 與 `log_at uses same threshold as log` 兩 scenario，確保 `log_at helper provides explicit-form API` 完整
- [x] 5.3 [P] `test/integration/cli-audit-log.test.sh`：以 mock tmux/pgrep 跑 `--reset`、`--snapshot`、unknown flag、`--config <bad>`、`--help`、`--version`、`--show-config`、`--status`，分別 assert log 行存在或缺席（落實 `Operator interventions emit audit log lines` 全部 8 行 + `--help writes nothing to log` 等 4 個 negative scenarios）
- [x] 5.4 [P] `test/integration/silent-path-coverage.test.sh`：以 mock 觸發 kill-session no-op / heartbeat read 失敗 / outbound read 失敗 / restart-count cat 失敗 / snapshot capture-pane 失敗，assert 各 silent path 都 emit 對應 log 行（落實 `Silent error-suppression paths emit log lines` 全表）
- [x] 5.5 [P] `test/integration/parse-args-error-mirror.test.sh`：覆蓋 `parse_args errors mirror to main log via Option A` 兩個 scenario — 正常 LOG_DIR 與 unwritable LOG_DIR
- [x] 5.6 跑全 regression `bash test/run.sh`，確認既有 18 tests 仍 18/18 PASS（hard acceptance criterion；任何破壞代表 on-wire 格式被誤改）

## 6. Documentation 與 version bump

- [x] 6.1 [P] `README.md` Configuration table 加 `WATCHDOG_LOG_LEVEL` 列；新增「Log levels and audit logging (v0.1.9+)」subsection 涵蓋：threshold 語意、prefix-to-level 映射表、ALERT bypass 規則、operator intervention audit 範例（含 `grep "operator:" claude-watchdog.log` 一行抽 audit trail 範例）、unknown-value fallback 行為
- [x] 6.2 [P] `CHANGELOG.md` 寫 v0.1.9 entry：列新 env var、log_at helper、closed silent paths 清單、operator audit log、stderr→主 log 鏡射；引用 issue #22 與 #24
- [x] 6.3 [P] 在 `claude-watchdog.sh` 開頭 `WATCHDOG_VERSION` 從 `0.1.8` bump 到 `0.1.9`
