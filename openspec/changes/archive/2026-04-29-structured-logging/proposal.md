## Why

Issue #22 (Jacky's Mac mini in silent-loop for 2 days) exposed how thin `claude-watchdog.log` is for incident triage: ~10 silent error-suppression paths leave no trace, operator interventions (`--reset`, `--snapshot`) are invisible, and `parse_args` errors land in `watchdog-launchd.err` — an orphan log operators rarely check. Diagnosis #22 took longer than necessary because the log alone could not answer routine triage questions.

The codebase already follows a `LEVEL:` text-prefix convention across all 33 existing `log()` call-sites (15 WARN, 6 INFO, 4 DETECT, 3 ACTION, 2 OK, 1 ERROR, 1 DEBUG, 1 COOLDOWN, 1 ALERT template). This convention is uniform but unenforced — there is no threshold filter, so `DEBUG` would flood the log if more sites were added, and operators cannot quiet noisy levels in production.

Capitalize on the existing convention: make `log()` parse its message prefix and dispatch by level, with a configurable threshold. Zero migration cost (no call-site touches), zero on-wire format change (existing 18 tests pass unchanged), and full incident-triage coverage of today's silent paths.

## What Changes

- **New env var `WATCHDOG_LOG_LEVEL`** (default `INFO`; values `DEBUG`/`INFO`/`WARN`/`ERROR`). Threshold filter — log lines below threshold are suppressed at the start of `log()` before timestamp formatting. Unknown values fall back to `INFO` with a one-time `WARN` line.
- **`log()` becomes level-aware** by parsing its own message prefix. `OK`/`DETECT`/`ACTION`/`COOLDOWN` map to `INFO` bucket (semantic flavour, not severity). `ALERT [type]:` bypasses suppression entirely (alerts are never silenced — they have separate dedup state machines).
- **New explicit-form helper `log_at LEVEL "msg"`** for programmatic callers (e.g. variable level). Old `log "WARN: foo"` form continues to work — both paths converge in the same threshold check.
- **Close ~10 silent error-suppression paths** documented in issue #24:
  - `tmux kill-session ... 2>/dev/null \|\| true` (line 221) — log `DEBUG` on no-op
  - `read schema ... 2>/dev/null \|\| true` (lines 258, 300) — log `WARN` on read failure (separate from the existing malformed-schema branches)
  - `cat $f 2>/dev/null \|\| echo 0` (line 418, restart-count) — log `WARN` if file exists but unreadable
  - Snapshot sub-captures — extend `_snapshot_capture` so the existing `WARN` line includes stderr content, not just exit code
- **Operator-intervention audit log**:
  - `--reset` → `INFO: operator: --reset (cleared N flags)` after success
  - `--snapshot` → `INFO: operator: --snapshot (path: ...)` on success, `ERROR: operator: --snapshot failed` on failure
  - `--config <file>` not-found → `ERROR: config file not found: ...` (also stderr)
  - `parse_args` unknown argument → `ERROR: unknown argument '...'` (also stderr)
  - `--help`, `--version`, `--show-config`, `--status` → no log (purely informational, would just be noise)
- **stderr-to-main-log mirror via Option A** (mkdir + append, no rotation) for `parse_args` error paths that fire before `setup_logging`. `init_config` already populates `$LOG_DIR` at top-level, so the path is known; only the directory needs to exist. If `mkdir` fails, silently degrade to stderr-only — zero behaviour regression.
- **`--show-config`** lists `WATCHDOG_LOG_LEVEL` and current effective threshold.
- **Bump `WATCHDOG_VERSION`** from `0.1.8` to `0.1.9`.

## Non-Goals

- **Not** changing the on-wire log format. Lines stay `YYYY-MM-DD HH:MM:SS LEVEL: msg`. Switching to `[LEVEL]` brackets would break 18 existing test assertions for zero behaviour gain.
- **Not** migrating existing 33 `log "WARN:..."` call-sites to `log_at WARN "..."` API. Pure cosmetic churn — diagnosis explicitly resolved this design split via discussion.
- **Not** adding a `--log-level` CLI flag. Operators set this once via plist `EnvironmentVariables`; mid-day override is rare and doable via `WATCHDOG_LOG_LEVEL=DEBUG bash claude-watchdog.sh` ad-hoc.
- **Not** structured JSON logging. Main log stays human-tail-able plain text. Snapshot's `metadata.json` (already JSONL-shaped) is unrelated and unchanged.
- **Not** remote log shipping or syslog integration.
- **Not** changing log file location or rotation policy (1 MB / keep last 500 lines).
- **Not** suppressing `ALERT [type]:` lines via threshold — alerts always log regardless of `WATCHDOG_LOG_LEVEL`.
- **Not** introducing per-helper `DEBUG: enter / DEBUG: exit` instrumentation. DEBUG is targeted: 10 closed silent paths + a handful of decision points (which case branch matched in `main()`, which dispatcher mode in `recovery_driver`).

## Capabilities

### New Capabilities

- `structured-logging`: level-aware `log()` with `WATCHDOG_LOG_LEVEL` threshold, `log_at` explicit-form helper, closed silent paths, operator audit log, and stderr-to-main-log mirror for pre-LOG_DIR error paths.

### Modified Capabilities

(none — the silent-loop recovery capability is orthogonal; its existing log lines already follow the LEVEL: prefix convention and continue working unchanged.)

## Impact

- Affected specs: new `structured-logging` capability
- Affected code:
  - Modified:
    - `claude-watchdog.sh` — replace `log()` body with prefix-parse + threshold check; add `log_at` helper; add `_log_level_passes` ordinal check; add 10 silent-path log lines; add operator-intervention audit log lines; mirror parse_args errors to main log; add `WATCHDOG_LOG_LEVEL` to `init_config`, `--help`, `--show-config`; bump `WATCHDOG_VERSION` to `0.1.9`
    - `README.md` — add `WATCHDOG_LOG_LEVEL` to Configuration table; new "Log levels and audit logging" subsection covering threshold semantics, operator intervention audit, and `ALERT` bypass rule
    - `CHANGELOG.md` — v0.1.9 entry
  - New:
    - `test/unit/log-level-threshold.test.sh` — assert DEBUG suppressed at default INFO; all levels visible at DEBUG; ALERT bypass; OK/DETECT/ACTION map to INFO; unknown env value fallback emits one-time WARN
    - `test/integration/cli-audit-log.test.sh` — invoke `--reset`, `--snapshot`, unknown flag; assert each leaves the expected `LEVEL:` line in main log; assert `--help`/`--version`/`--show-config`/`--status` leave no log
    - `test/integration/silent-path-coverage.test.sh` — trigger known silent paths (heartbeat read failure, kill-session no-op, snapshot sub-capture failure with mocked tmux); assert each emits a log line
  - Removed: (none)
