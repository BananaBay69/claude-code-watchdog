# structured-logging Specification

## Purpose

TBD - created by archiving change 'structured-logging'. Update Purpose after archive.

## Requirements

### Requirement: Log level threshold filters write calls

The watchdog SHALL accept `WATCHDOG_LOG_LEVEL` env var with values `DEBUG`, `INFO`, `WARN`, `ERROR` (case-sensitive). Default MUST be `INFO`. Unknown or empty values MUST fall back to `INFO` and emit a single `WARN` line on the first `log()` invocation noting the fallback.

`log(msg)` SHALL parse `msg` for a leading `^[A-Z]+:` prefix, map the prefix to a level ordinal, compare against the threshold ordinal, and silently return without writing if the level is below threshold. Threshold check MUST occur before timestamp formatting and file I/O.

#### Scenario: default INFO suppresses DEBUG

- **GIVEN** `WATCHDOG_LOG_LEVEL` is unset
- **WHEN** `log "DEBUG: kill-session no-op"` is called
- **THEN** the log file MUST NOT contain that line and `log()` MUST return zero without writing

#### Scenario: DEBUG threshold passes everything

- **GIVEN** `WATCHDOG_LOG_LEVEL=DEBUG`
- **WHEN** `log "DEBUG: foo"`, `log "INFO: bar"`, `log "WARN: baz"`, `log "ERROR: qux"` are each called
- **THEN** all four lines MUST appear in the log file

#### Scenario: ERROR threshold suppresses lower levels

- **GIVEN** `WATCHDOG_LOG_LEVEL=ERROR`
- **WHEN** `log "INFO: x"`, `log "WARN: y"`, `log "ERROR: z"` are each called
- **THEN** only the `ERROR: z` line MUST appear; `INFO` and `WARN` MUST be suppressed

#### Scenario: unknown threshold value falls back to INFO with warning

- **GIVEN** `WATCHDOG_LOG_LEVEL=verbose`
- **WHEN** `log "INFO: first call"` is called
- **THEN** the log file MUST contain a `WARN: WATCHDOG_LOG_LEVEL='verbose' invalid — falling back to INFO` line and the `INFO: first call` line; subsequent INFO calls MUST NOT re-emit the warning

##### Example: threshold ordinals

| Level    | Ordinal |
|----------|---------|
| `DEBUG`  | 10      |
| `INFO`   | 20      |
| `WARN`   | 30      |
| `ERROR`  | 40      |

A line passes when its ordinal is greater than or equal to the threshold ordinal.


<!-- @trace
source: structured-logging
updated: 2026-04-29
code:
  - .agents/skills/spectra-commit/SKILL.md
  - test/unit/log-at-helper.test.sh
  - CHANGELOG.md
  - test/unit/take-snapshot.test.sh
  - test/integration/cli-audit-log.test.sh
  - test/integration/snapshot-on-silent-loop.test.sh
  - test/integration/parse-args-error-mirror.test.sh
  - .spectra.yaml
  - .agents/skills/spectra-ask/SKILL.md
  - README.md
  - test/integration/silent-path-coverage.test.sh
  - .agents/skills/spectra-audit/SKILL.md
  - test/unit/snapshot-retention.test.sh
  - claude-watchdog.sh
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-ingest/SKILL.md
  - test/unit/log-level-threshold.test.sh
  - AGENTS.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - test/integration/snapshot-cli-flag.test.sh
-->

---
### Requirement: Semantic-flavour prefixes map to INFO bucket

The prefixes `OK`, `DETECT`, `ACTION`, `COOLDOWN` SHALL be treated as informational (INFO ordinal = 20) for threshold purposes. They are semantic flavours describing event type, not severity levels.

A `log()` call with a message that has no recognised `^[A-Z]+:` prefix MUST be treated as `INFO` (default safe behaviour for messages written without convention).

#### Scenario: OK line writes at default INFO threshold

- **GIVEN** `WATCHDOG_LOG_LEVEL=INFO` (default)
- **WHEN** `log "OK: Session alive"` is called
- **THEN** the line MUST appear in the log file

#### Scenario: ACTION line suppressed at WARN threshold

- **GIVEN** `WATCHDOG_LOG_LEVEL=WARN`
- **WHEN** `log "ACTION: Killing tmux session 'claude'"` is called
- **THEN** the line MUST NOT appear

#### Scenario: prefix-less message defaults to INFO

- **GIVEN** `WATCHDOG_LOG_LEVEL=WARN`
- **WHEN** `log "Session restarted by operator"` is called (no `^[A-Z]+:` prefix)
- **THEN** the line MUST NOT appear (treated as INFO, below WARN threshold)

##### Example: prefix-to-level mapping

| Prefix         | Mapped Level | Notes                              |
|----------------|--------------|------------------------------------|
| `DEBUG:`       | DEBUG (10)   |                                    |
| `INFO:`        | INFO (20)    |                                    |
| `OK:`          | INFO (20)    | semantic flavour                   |
| `DETECT:`      | INFO (20)    | semantic flavour                   |
| `ACTION:`      | INFO (20)    | semantic flavour                   |
| `COOLDOWN:`    | INFO (20)    | semantic flavour                   |
| `WARN:`        | WARN (30)    |                                    |
| `ERROR:`       | ERROR (40)   |                                    |
| `ALERT [...]:` | bypass       | always written; see ALERT bypass requirement |
| (no prefix)    | INFO (20)    | safe default                       |


<!-- @trace
source: structured-logging
updated: 2026-04-29
code:
  - .agents/skills/spectra-commit/SKILL.md
  - test/unit/log-at-helper.test.sh
  - CHANGELOG.md
  - test/unit/take-snapshot.test.sh
  - test/integration/cli-audit-log.test.sh
  - test/integration/snapshot-on-silent-loop.test.sh
  - test/integration/parse-args-error-mirror.test.sh
  - .spectra.yaml
  - .agents/skills/spectra-ask/SKILL.md
  - README.md
  - test/integration/silent-path-coverage.test.sh
  - .agents/skills/spectra-audit/SKILL.md
  - test/unit/snapshot-retention.test.sh
  - claude-watchdog.sh
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-ingest/SKILL.md
  - test/unit/log-level-threshold.test.sh
  - AGENTS.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - test/integration/snapshot-cli-flag.test.sh
-->

---
### Requirement: ALERT messages bypass threshold suppression

A `log()` call whose message starts with `ALERT [` SHALL always write to the log file regardless of `WATCHDOG_LOG_LEVEL`. ALERT messages are part of the alert dedup state machine and MUST NOT be silenced by threshold filtering.

#### Scenario: ALERT writes at ERROR threshold

- **GIVEN** `WATCHDOG_LOG_LEVEL=ERROR`
- **WHEN** `log "ALERT [silent-loop]: incoming=7 outbound-stale"` is called
- **THEN** the line MUST appear in the log file (not suppressed)

#### Scenario: lowercase alert is treated as INFO (case-sensitive)

- **GIVEN** `WATCHDOG_LOG_LEVEL=WARN`
- **WHEN** `log "alert [foo]: lowercase typo"` is called
- **THEN** the line MUST NOT appear (lowercase `alert` does not match `^ALERT \[`)


<!-- @trace
source: structured-logging
updated: 2026-04-29
code:
  - .agents/skills/spectra-commit/SKILL.md
  - test/unit/log-at-helper.test.sh
  - CHANGELOG.md
  - test/unit/take-snapshot.test.sh
  - test/integration/cli-audit-log.test.sh
  - test/integration/snapshot-on-silent-loop.test.sh
  - test/integration/parse-args-error-mirror.test.sh
  - .spectra.yaml
  - .agents/skills/spectra-ask/SKILL.md
  - README.md
  - test/integration/silent-path-coverage.test.sh
  - .agents/skills/spectra-audit/SKILL.md
  - test/unit/snapshot-retention.test.sh
  - claude-watchdog.sh
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-ingest/SKILL.md
  - test/unit/log-level-threshold.test.sh
  - AGENTS.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - test/integration/snapshot-cli-flag.test.sh
-->

---
### Requirement: log_at helper provides explicit-form API

The watchdog SHALL expose `log_at LEVEL "msg"` as an explicit-form helper for callers where the level is variable. `log_at` MUST converge through the same threshold check as `log()`. Callers using `log "WARN: msg"` and `log_at WARN "msg"` MUST observe identical behaviour.

#### Scenario: log_at WARN matches log "WARN: ..."

- **GIVEN** `WATCHDOG_LOG_LEVEL=INFO`
- **WHEN** `log_at WARN "alert command exited 7"` is called
- **THEN** the log file MUST contain a line with the exact text `WARN: alert command exited 7` after the timestamp prefix

#### Scenario: log_at uses same threshold as log

- **GIVEN** `WATCHDOG_LOG_LEVEL=ERROR`
- **WHEN** `log_at INFO "operator: --reset cleared 2 flags"` is called
- **THEN** the line MUST NOT appear (suppressed by threshold)


<!-- @trace
source: structured-logging
updated: 2026-04-29
code:
  - .agents/skills/spectra-commit/SKILL.md
  - test/unit/log-at-helper.test.sh
  - CHANGELOG.md
  - test/unit/take-snapshot.test.sh
  - test/integration/cli-audit-log.test.sh
  - test/integration/snapshot-on-silent-loop.test.sh
  - test/integration/parse-args-error-mirror.test.sh
  - .spectra.yaml
  - .agents/skills/spectra-ask/SKILL.md
  - README.md
  - test/integration/silent-path-coverage.test.sh
  - .agents/skills/spectra-audit/SKILL.md
  - test/unit/snapshot-retention.test.sh
  - claude-watchdog.sh
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-ingest/SKILL.md
  - test/unit/log-level-threshold.test.sh
  - AGENTS.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - test/integration/snapshot-cli-flag.test.sh
-->

---
### Requirement: Silent error-suppression paths emit log lines

The following code paths in `claude-watchdog.sh` SHALL each emit a log line at an appropriate level, replacing or augmenting the current `2>/dev/null \|\| true` silent-suppression patterns:

| Path                                    | Level | When                                          |
|-----------------------------------------|-------|-----------------------------------------------|
| `tmux kill-session` non-zero exit       | DEBUG | session already gone (no-op kill)             |
| `read schema` failure (heartbeat parse) | WARN  | file exists but unreadable / I/O error        |
| `read schema` failure (outbound parse)  | WARN  | file exists but unreadable / I/O error        |
| `cat` failure on restart-count file     | WARN  | file exists but unreadable (vs. simply absent)|
| Snapshot sub-capture failure            | WARN  | extend existing line to include stderr snippet|

A path firing in its happy case (e.g. heartbeat file not present and not configured) MUST NOT emit a log line — only failure paths emit.

#### Scenario: kill-session no-op emits DEBUG

- **GIVEN** `WATCHDOG_LOG_LEVEL=DEBUG` and tmux session does not exist
- **WHEN** `attempt_restart` calls `tmux kill-session -t claude` (which exits non-zero because session is gone)
- **THEN** the log file MUST contain `DEBUG: kill-session no-op (rc=...)` and the watchdog MUST proceed to start_claude

#### Scenario: heartbeat read I/O failure emits WARN

- **GIVEN** `$WATCHDOG_HEARTBEAT_FILE` exists but is not readable (permissions)
- **WHEN** `heartbeat_state` runs
- **THEN** the log file MUST contain a `WARN: heartbeat read failed` line and `heartbeat_state` MUST return `stale`

#### Scenario: snapshot sub-capture failure includes stderr

- **GIVEN** `tmux capture-pane` exits non-zero with stderr `error: pane not found`
- **WHEN** `_snapshot_capture` wraps that call
- **THEN** the log file MUST contain a `WARN: snapshot pane.txt failed (exit=N): error: pane not found` line including the captured stderr snippet


<!-- @trace
source: structured-logging
updated: 2026-04-29
code:
  - .agents/skills/spectra-commit/SKILL.md
  - test/unit/log-at-helper.test.sh
  - CHANGELOG.md
  - test/unit/take-snapshot.test.sh
  - test/integration/cli-audit-log.test.sh
  - test/integration/snapshot-on-silent-loop.test.sh
  - test/integration/parse-args-error-mirror.test.sh
  - .spectra.yaml
  - .agents/skills/spectra-ask/SKILL.md
  - README.md
  - test/integration/silent-path-coverage.test.sh
  - .agents/skills/spectra-audit/SKILL.md
  - test/unit/snapshot-retention.test.sh
  - claude-watchdog.sh
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-ingest/SKILL.md
  - test/unit/log-level-threshold.test.sh
  - AGENTS.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - test/integration/snapshot-cli-flag.test.sh
-->

---
### Requirement: Operator interventions emit audit log lines

State-mutating CLI invocations SHALL emit one log line each. Read-only CLI invocations MUST NOT emit a log line.

| CLI flag         | Audit log line emitted                                       |
|------------------|--------------------------------------------------------------|
| `--reset`        | `INFO: operator: --reset (cleared N flags)` after success     |
| `--snapshot`     | `INFO: operator: --snapshot (path: <abs_path>)` on success    |
| `--snapshot`     | `ERROR: operator: --snapshot failed` on failure               |
| `--config <bad>` | `ERROR: config file not found: <path>` (also stderr)         |
| Unknown flag     | `ERROR: unknown argument '<arg>'` (also stderr)              |
| `--help`         | (no log)                                                      |
| `--version`      | (no log)                                                      |
| `--show-config`  | (no log)                                                      |
| `--status`       | (no log)                                                      |

#### Scenario: --reset writes audit line

- **GIVEN** `$LOG_DIR/.watchdog-restart-count-<today>` and `.watchdog-alert-sent-cap-<today>` both exist (2 flags)
- **WHEN** the operator runs `claude-watchdog.sh --reset`
- **THEN** the log file MUST contain `INFO: operator: --reset (cleared 2 flags)` and the command MUST exit 0

#### Scenario: --snapshot success writes audit line with path

- **GIVEN** a healthy daemon with `WATCHDOG_LOG_DIR=/var/logs/wd`
- **WHEN** the operator runs `claude-watchdog.sh --snapshot` and the snapshot lands at `/var/logs/wd/snapshots/silent-loop-20260429120000/`
- **THEN** the log file MUST contain `INFO: operator: --snapshot (path: /var/logs/wd/snapshots/silent-loop-20260429120000/)`

#### Scenario: --help writes nothing to log

- **GIVEN** any valid `WATCHDOG_LOG_LEVEL` setting
- **WHEN** the operator runs `claude-watchdog.sh --help`
- **THEN** the log file MUST NOT gain any new line


<!-- @trace
source: structured-logging
updated: 2026-04-29
code:
  - .agents/skills/spectra-commit/SKILL.md
  - test/unit/log-at-helper.test.sh
  - CHANGELOG.md
  - test/unit/take-snapshot.test.sh
  - test/integration/cli-audit-log.test.sh
  - test/integration/snapshot-on-silent-loop.test.sh
  - test/integration/parse-args-error-mirror.test.sh
  - .spectra.yaml
  - .agents/skills/spectra-ask/SKILL.md
  - README.md
  - test/integration/silent-path-coverage.test.sh
  - .agents/skills/spectra-audit/SKILL.md
  - test/unit/snapshot-retention.test.sh
  - claude-watchdog.sh
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-ingest/SKILL.md
  - test/unit/log-level-threshold.test.sh
  - AGENTS.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - test/integration/snapshot-cli-flag.test.sh
-->

---
### Requirement: parse_args errors mirror to main log via Option A

When `parse_args` encounters an unrecoverable error (unknown argument, `--config <missing-file>`) BEFORE `setup_logging` runs, the watchdog SHALL ensure the error is recorded in `claude-watchdog.log` in addition to stderr. Implementation MUST use Option A: `mkdir -p "$LOG_DIR" 2>/dev/null` followed by direct append to `$LOG_FILE` (no rotation invocation). If `mkdir` fails, the error MUST still go to stderr (no behaviour regression vs. v0.1.8); main-log mirror is best-effort.

#### Scenario: unknown argument logs to both stderr and main log

- **GIVEN** an empty `$LOG_DIR` that doesn't yet exist on disk (parent directory exists)
- **WHEN** the operator runs `claude-watchdog.sh --xyz`
- **THEN** stderr MUST contain `error: unknown argument '--xyz' (try --help)` AND the main log file MUST contain `ERROR: unknown argument '--xyz'` AND the command MUST exit 2

#### Scenario: parse_args error degrades gracefully when LOG_DIR is unwritable

- **GIVEN** `$LOG_DIR` parent directory is read-only (mkdir will fail)
- **WHEN** the operator runs `claude-watchdog.sh --xyz`
- **THEN** stderr MUST contain `error: unknown argument '--xyz'` AND the watchdog MUST exit 2 without crashing AND no main log file is required to be created


<!-- @trace
source: structured-logging
updated: 2026-04-29
code:
  - .agents/skills/spectra-commit/SKILL.md
  - test/unit/log-at-helper.test.sh
  - CHANGELOG.md
  - test/unit/take-snapshot.test.sh
  - test/integration/cli-audit-log.test.sh
  - test/integration/snapshot-on-silent-loop.test.sh
  - test/integration/parse-args-error-mirror.test.sh
  - .spectra.yaml
  - .agents/skills/spectra-ask/SKILL.md
  - README.md
  - test/integration/silent-path-coverage.test.sh
  - .agents/skills/spectra-audit/SKILL.md
  - test/unit/snapshot-retention.test.sh
  - claude-watchdog.sh
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-ingest/SKILL.md
  - test/unit/log-level-threshold.test.sh
  - AGENTS.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - test/integration/snapshot-cli-flag.test.sh
-->

---
### Requirement: WATCHDOG_LOG_LEVEL surfaced in --show-config output

The `--show-config` output SHALL include a line of the form `WATCHDOG_LOG_LEVEL=<effective_value>` where `<effective_value>` is the level after fallback resolution (so `verbose` → `INFO`).

The `--help` text SHALL document `WATCHDOG_LOG_LEVEL` as an environment variable with allowed values, default, and behaviour summary.

#### Scenario: --show-config reports effective level

- **GIVEN** `WATCHDOG_LOG_LEVEL=DEBUG` is set
- **WHEN** the operator runs `claude-watchdog.sh --show-config`
- **THEN** the output MUST contain `WATCHDOG_LOG_LEVEL=DEBUG`

#### Scenario: --show-config reports fallback for unknown value

- **GIVEN** `WATCHDOG_LOG_LEVEL=verbose` is set
- **WHEN** the operator runs `claude-watchdog.sh --show-config`
- **THEN** the output MUST contain `WATCHDOG_LOG_LEVEL=INFO` (effective value after fallback)

<!-- @trace
source: structured-logging
updated: 2026-04-29
code:
  - .agents/skills/spectra-commit/SKILL.md
  - test/unit/log-at-helper.test.sh
  - CHANGELOG.md
  - test/unit/take-snapshot.test.sh
  - test/integration/cli-audit-log.test.sh
  - test/integration/snapshot-on-silent-loop.test.sh
  - test/integration/parse-args-error-mirror.test.sh
  - .spectra.yaml
  - .agents/skills/spectra-ask/SKILL.md
  - README.md
  - test/integration/silent-path-coverage.test.sh
  - .agents/skills/spectra-audit/SKILL.md
  - test/unit/snapshot-retention.test.sh
  - claude-watchdog.sh
  - .agents/skills/spectra-archive/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-ingest/SKILL.md
  - test/unit/log-level-threshold.test.sh
  - AGENTS.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - test/integration/snapshot-cli-flag.test.sh
-->