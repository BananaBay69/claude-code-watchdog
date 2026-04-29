## ADDED Requirements

### Requirement: Recovery dispatch on silent-loop detection

When `detect_silent_loop()` returns a positive detection, the watchdog SHALL invoke a recovery dispatcher whose behavior is selected by the `WATCHDOG_SILENT_LOOP_RECOVERY` environment variable. The dispatcher MUST accept the values `disabled`, `snapshot-only`, `soft`, and `aggressive`. Unknown or empty values MUST fall back to `disabled` and emit a `WARN` log line.

#### Scenario: dispatch defaults to disabled

- **WHEN** `WATCHDOG_SILENT_LOOP_RECOVERY` is unset and silent-loop is detected
- **THEN** the dispatcher MUST take no recovery action and the watchdog tick MUST log only the existing `silent-loop` alert and `OK: Session alive` lines

#### Scenario: dispatch invokes snapshot mode

- **WHEN** `WATCHDOG_SILENT_LOOP_RECOVERY=snapshot-only` and silent-loop fires its first state-entry alert
- **THEN** the dispatcher MUST call `take_snapshot()` exactly once before returning

#### Scenario: stub modes log not-implemented warning

- **WHEN** `WATCHDOG_SILENT_LOOP_RECOVERY=soft` or `WATCHDOG_SILENT_LOOP_RECOVERY=aggressive` and silent-loop is detected
- **THEN** the dispatcher MUST log `WARN: <mode> mode requested but not implemented` and MUST NOT alter watchdog state

##### Example: enum dispatch matrix

| `WATCHDOG_SILENT_LOOP_RECOVERY` | First state-entry detection | Subsequent ticks (same state) |
|---|---|---|
| (unset) | alert only | alert dedup'd |
| `disabled` | alert only | alert dedup'd |
| `snapshot-only` | alert + snapshot | alert dedup'd, no new snapshot |
| `soft` | alert + WARN log | alert dedup'd |
| `aggressive` | alert + WARN log | alert dedup'd |
| `garbage` | alert + WARN (treated as disabled) | alert dedup'd |

### Requirement: Snapshot capture writes a fixed file set

When `take_snapshot()` runs, it SHALL create a directory `$LOG_DIR/snapshots/silent-loop-<YYYYMMDDhhmmss>/` containing exactly the following files. Each sub-capture MUST be wrapped in a 5-second timeout; failures MUST log `WARN` lines but MUST NOT abort the snapshot.

| File | Content source |
|---|---|
| `pane.txt` | `tmux capture-pane -t $TMUX_SESSION -p -S -2000` |
| `status.txt` | output of `claude-watchdog.sh --status` |
| `env.txt` | all `WATCHDOG_*` environment variables, plus `tmux ls` and `pgrep -lf claude` output |
| `recent-log.txt` | last 200 lines of `$LOG_FILE` |
| `active-skills.txt` | one line per `~/.claude/plugins/**/skills/*.md` listing path and `stat` mtime in ISO 8601 format |
| `metadata.json` | JSON object `{"captured_at": "<ISO8601>", "silent_loop_state": {"incoming": <int>, "outbound_age_seconds": <int>}, "watchdog_version": "<semver>"}` |

`active-skills.txt` MUST NOT contain SKILL.md file contents — only paths and mtimes.

#### Scenario: snapshot written with all expected files

- **WHEN** `take_snapshot()` is called and all sub-captures succeed
- **THEN** the snapshot directory MUST exist and MUST contain exactly the 6 files listed above

#### Scenario: partial snapshot when sub-capture fails

- **WHEN** `take_snapshot()` is called and `tmux capture-pane` exits non-zero or times out
- **THEN** the snapshot directory MUST still be created, the failed file MUST be omitted, the watchdog log MUST contain `WARN: snapshot pane.txt failed (<reason>)`, and the remaining files MUST be written

##### Example: metadata.json shape

- **GIVEN** silent-loop fires with `incoming=7`, `outbound_age_seconds=890`, watchdog version `0.1.8`
- **WHEN** `take_snapshot()` runs at `2026-04-28T22:57:25+0800`
- **THEN** `metadata.json` contains: `{"captured_at": "2026-04-28T22:57:25+0800", "silent_loop_state": {"incoming": 7, "outbound_age_seconds": 890}, "watchdog_version": "0.1.8"}`

### Requirement: Snapshot generation deduplicates per silent-loop state-entry

The `take_snapshot()` invocation triggered by silent-loop detection MUST be gated by the existing `alert_already_sent silent-loop` flag check. The first detection in a state-entry MUST produce a snapshot; subsequent ticks within the same state-entry MUST NOT produce additional snapshots. After the alert flag is cleared (outbound advances) and silent-loop re-enters, a new snapshot MUST be produced.

#### Scenario: same state-entry produces one snapshot

- **WHEN** silent-loop is detected on tick N (state-entry) and again on ticks N+1, N+2, N+3 (same state)
- **THEN** exactly one snapshot directory MUST exist after tick N+3

#### Scenario: re-entry after clearance produces a new snapshot

- **WHEN** silent-loop fires (snapshot 1), outbound advances and clears the flag, and silent-loop fires again later (state re-entry)
- **THEN** two snapshot directories MUST exist with distinct timestamps

### Requirement: Snapshot retention enforces FIFO count cap

Before each new snapshot is written, the watchdog SHALL prune oldest snapshot directories under `$LOG_DIR/snapshots/` until at most `WATCHDOG_SNAPSHOT_RETAIN_COUNT - 1` directories remain. Default cap MUST be `20`. Pruning MUST sort by directory name (which is timestamp-sortable) and MUST NOT touch any file outside `$LOG_DIR/snapshots/`.

#### Scenario: retention prunes oldest when cap reached

- **GIVEN** `WATCHDOG_SNAPSHOT_RETAIN_COUNT=3` and three snapshot directories `silent-loop-20260101000000`, `silent-loop-20260102000000`, `silent-loop-20260103000000` exist
- **WHEN** a new snapshot is written at `20260104000000`
- **THEN** `silent-loop-20260101000000` MUST be removed and four directories MUST remain after enforcement: `20260102`, `20260103`, `20260104`

#### Scenario: retention is no-op below cap

- **GIVEN** `WATCHDOG_SNAPSHOT_RETAIN_COUNT=20` and 5 snapshot directories exist
- **WHEN** a new snapshot is written
- **THEN** all 5 prior directories MUST remain alongside the new one

### Requirement: Manual --snapshot CLI flag

`claude-watchdog.sh --snapshot` SHALL invoke the same `take_snapshot()` capture used by the silent-loop dispatcher, regardless of whether silent-loop is currently detected. The flag MUST NOT consult the alert dedup flag, MUST NOT modify alert state, and MUST exit with status 0 on success or non-zero on capture failure. Retention MUST apply equally to manually triggered snapshots.

#### Scenario: manual flag captures snapshot when detection is clean

- **WHEN** `claude-watchdog.sh --snapshot` is invoked while no silent-loop is detected
- **THEN** a snapshot directory MUST be created and the alert dedup flag MUST remain in its prior state

#### Scenario: manual flag captures snapshot when alert flag is set

- **WHEN** `claude-watchdog.sh --snapshot` is invoked while `.watchdog-alert-sent-silent-loop` flag is already set
- **THEN** a snapshot directory MUST be created (manual capture bypasses dedup)

### Requirement: Alert message includes snapshot path when snapshot mode is active

When `WATCHDOG_SILENT_LOOP_RECOVERY=snapshot-only` (or any future mode that calls `take_snapshot()`) and a snapshot is successfully created, the `silent-loop` alert message passed to `WATCHDOG_ALERT_CMD` MUST include `Snapshot: <absolute_path>` as a suffix on the existing alert message. When the recovery mode is `disabled` or snapshot creation fails, the alert message MUST remain in its v0.1.7 format.

#### Scenario: alert includes snapshot path

- **GIVEN** `WATCHDOG_SILENT_LOOP_RECOVERY=snapshot-only`
- **WHEN** silent-loop fires and `take_snapshot()` succeeds, writing to `/var/log/watchdog/snapshots/silent-loop-20260428225725/`
- **THEN** the `WATCHDOG_ALERT_MSG` env passed to `WATCHDOG_ALERT_CMD` MUST end with ` Snapshot: /var/log/watchdog/snapshots/silent-loop-20260428225725/`

#### Scenario: alert preserves v0.1.7 format when disabled

- **GIVEN** `WATCHDOG_SILENT_LOOP_RECOVERY=disabled` (default)
- **WHEN** silent-loop fires
- **THEN** `WATCHDOG_ALERT_MSG` MUST NOT contain the substring `Snapshot:`
