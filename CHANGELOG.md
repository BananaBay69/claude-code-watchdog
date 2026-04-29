# Changelog

## v0.1.9 (2026-04-29)

### Added

- **Log level threshold** via new `WATCHDOG_LOG_LEVEL` env var (`DEBUG`/`INFO`/`WARN`/`ERROR`; default `INFO`). Lines below threshold are suppressed at the start of `log()` before timestamp formatting. Unknown values fall back to `INFO` with a one-time `WARN` line. Documented in `--help`, `--show-config`, and README.
- **`log()` is now level-aware** — parses its own message for a leading `^[A-Z]+:` prefix and dispatches by ordinal. **No migration of the existing 33 call-sites needed**; on-wire format is byte-identical to v0.1.8 (existing tests pass unchanged). Semantic-flavour prefixes (`OK`/`DETECT`/`ACTION`/`COOLDOWN`) map to the INFO bucket. `ALERT [...]:` lines bypass threshold suppression (alert dedup state machine relies on visibility).
- **`log_at LEVEL "msg"` explicit-form helper** for callers where the level is variable; converges through the same threshold check as `log()`.
- **Operator-intervention audit log** — state-mutating CLI invocations now leave a single audit line in the main log:
  - `--reset` → `INFO: operator: --reset (cleared N flags)`
  - `--snapshot` (success) → `INFO: operator: --snapshot (path: ...)`
  - `--snapshot` (failure) → `ERROR: operator: --snapshot failed`
  - Read-only invocations (`--help`, `--version`, `--show-config`, `--status`) leave no log line.
- **stderr-to-main-log mirror for pre-LOG_DIR errors** (Option A: `mkdir -p` + append, no rotation):
  - Unknown CLI argument → `ERROR: unknown argument '...'` in main log + stderr
  - `--config <missing-file>` → `ERROR: config file not found: ...` in main log + stderr
  - Graceful degradation: if `mkdir` fails (e.g. read-only parent), stderr-only — no behaviour regression vs. v0.1.8.
- **Closed silent error-suppression paths** (operator visibility into previously-invisible failures):
  - `tmux kill-session` no-op → `DEBUG: kill-session no-op (rc=...)`
  - `heartbeat_state` read I/O failure → `WARN: heartbeat read failed`
  - `outbound_state` read I/O failure → `WARN: outbound read failed`
  - `read_restart_count` cat failure → `WARN: restart-count file unreadable`
  - `_snapshot_capture` failure → existing `WARN` line now includes captured stderr snippet.
- New tests: `log-level-threshold` (9 scenarios), `log-at-helper` (3 scenarios), `cli-audit-log` (8 scenarios — 4 audit + 4 negative), `silent-path-coverage` (5 scenarios), `parse-args-error-mirror` (3 scenarios). Total: 23 pass / 0 fail (was 18 in v0.1.8).

### Notes

- **Default behaviour unchanged.** `WATCHDOG_LOG_LEVEL` defaults to `INFO`; existing v0.1.8 installs see byte-identical log output until they opt in to `DEBUG`. Tests that grep on `"WARN: foo"` substrings continue to pass.
- **Format intentionally preserved.** Lines remain `YYYY-MM-DD HH:MM:SS LEVEL: msg`. Switching to `[LEVEL]` brackets would break 18 existing test assertions for zero behaviour gain (see openspec change `structured-logging`).
- **No `--log-level` CLI flag.** Operators set this once via plist `EnvironmentVariables`; mid-day override via `WATCHDOG_LOG_LEVEL=DEBUG bash ~/bin/claude-watchdog.sh` ad-hoc.
- **No structured JSON / syslog.** Main log stays human-tail-able plain text.

Driven by issue #22 (Jacky's Mac mini silent-loop diagnosis exposed how thin the log was) and issue #24 (operator request to surface previously-hidden events).

## v0.1.8 (2026-04-28)

### Added
- **Silent-loop recovery dispatch** (opt-in via `WATCHDOG_SILENT_LOOP_RECOVERY=snapshot-only`) — when v0.1.7 silent-loop fires its state-entry alert, the dispatcher captures a diagnostic snapshot directory under `$LOG_DIR/snapshots/silent-loop-<YYYYMMDDhhmmss>/`. Reduces operator triage friction from "ssh + tmux capture-pane + eyeball" to "open one directory of small text files".
- **`recovery_driver()` dispatcher** with 4-mode enum: `disabled` (default — v0.1.7 behaviour preserved), `snapshot-only` (Phase 1, this release), `soft` and `aggressive` (stubs reserved for future PRs after empirical evidence as required by issue #15 closing decision). Unknown values fall back to `disabled` and log `WARN`.
- **`take_snapshot()`** writes 6 files per snapshot directory: `pane.txt` (last 2000 pane lines), `status.txt` (`--status` output), `env.txt` (`WATCHDOG_*` env + `tmux ls` + `pgrep -lf claude`), `recent-log.txt` (last 200 watchdog log lines), `active-skills.txt` (path + ISO mtime for `~/.claude/plugins/**/skills/*.md` — paths only, no SKILL.md content), `metadata.json` (`{captured_at, silent_loop_state, watchdog_version}`).
- **`prune_old_snapshots()`** enforces FIFO retention via `WATCHDOG_SNAPSHOT_RETAIN_COUNT` (default 20). Refuses to remove paths outside `$LOG_DIR/snapshots/silent-loop-*`.
- **`--snapshot` CLI flag** for manual ad-hoc capture, independent of detection state. Does not consult or modify the alert dedup flag.
- **Snapshot dedup** piggybacks on existing `silent-loop` alert flag — one snapshot per state-entry, not per tick. Re-entry after outbound advances produces a new snapshot.
- **Alert message integration** — when a snapshot is created, `WATCHDOG_ALERT_MSG` gets ` Snapshot: <absolute_path>` appended so operators receive the path in their notification.
- New env vars: `WATCHDOG_SILENT_LOOP_RECOVERY`, `WATCHDOG_SNAPSHOT_RETAIN_COUNT`.
- Tests: 2 unit (`take-snapshot`, `snapshot-retention`) + 2 integration (`snapshot-on-silent-loop`, `snapshot-cli-flag`). Total: 18 pass / 0 fail.

### Notes
- **Default behaviour unchanged.** `WATCHDOG_SILENT_LOOP_RECOVERY` defaults to `disabled`; existing v0.1.7 installs are not affected until they opt in. `silent-loop` alert message format also unchanged when in `disabled` mode.
- **Privacy.** `pane.txt` may contain sensitive conversation content; snapshots inherit `$LOG_DIR` permissions. Default retention bounds disk use to ~10 MB worst case.
- **Sub-capture timeouts.** Each snapshot sub-capture is wrapped in a 5-second timeout (via `gtimeout` or `timeout` if available; runs unwrapped otherwise). Failures log `WARN` lines but do not abort the snapshot — partial-snapshot semantics.
- **`soft` and `aggressive` are stubs by design.** Issue #15 closing comment: "Restart opt-in for silent-loop 暫不開 — 等實測證實某些 silent-loop 真能被 restart 修再說." This release provides the instrumentation to gather that evidence (via the snapshot archive over time), without yet adding restart behaviour. Future PR will implement these modes once snapshot data shows them warranted.

Driven by issue #22 (Jacky's Mac mini in `silent-loop` state for 2 days with no operator response — the friction of remote diagnosis was the bottleneck, not the alert itself).

## v0.1.7 (2026-04-26)

### Added
- **Silent-loop detection** (opt-in via `WATCHDOG_SILENT_LOOP_ENABLED=1`) — Case D in main loop. Counts inbound channel markers in pane (`← telegram · CHATID:`) and cross-references with outbound file mtime (`$WATCHDOG_OUTBOUND_FILE`, written by bananabay-watchdog plugin v0.2.0+). If incoming ≥ threshold and outbound stale beyond window → emits `silent-loop` alert with state-based dedup.
- New env vars: `WATCHDOG_SILENT_LOOP_ENABLED`, `WATCHDOG_OUTBOUND_FILE`, `WATCHDOG_SILENT_LOOP_INCOMING_THRESHOLD`, `WATCHDOG_SILENT_LOOP_OUTBOUND_STALE_SECONDS`, `WATCHDOG_SILENT_LOOP_PANE_LINES`.
- New helpers: `outbound_state()`, `count_pane_incoming()`, `detect_silent_loop()`.
- `do_reset` now also clears `silent-loop` alert flag; `--status` exposes `ALERT_FLAG_SILENT_LOOP`.
- Tests: 3 unit (`outbound-state`, `count-incoming`, `silent-loop-detect`) + 2 integration (`silent-loop-alert`, `silent-loop-disabled`). Total: 14 pass / 0 fail.

### Notes
- **No restart on silent-loop** — alert-only by design. Root causes (SKILL.md instruction-leak) re-enter on restart.
- **Telegram only** in this release. Discord and other channels require additional `PostToolUse` matchers in plugin hooks.json (trivial extension).
- **PoC pane-scrape for incoming**; production-grade Telegram `getUpdates` poller deferred to v0.1.8 (issue TBD).
- Backward-compatible — defaults to disabled. Existing v0.1.6 installs are unaffected until they opt in.

Closes #15.

## v0.1.6 — 2026-04-25

### Added
- **Daily restart cap (`#12`)**. New env var `WATCHDOG_DAILY_RESTART_CAP`
  (default 10) bounds the total kill+restart cycles per local day. After
  the cap is reached, cooldown extends from `WATCHDOG_COOLDOWN` (default
  300s) to `WATCHDOG_THROTTLED_COOLDOWN` (default 3600s) for the rest
  of the day. A one-shot `cap-reached` alert fires the moment the cap
  is hit. Set `WATCHDOG_DAILY_RESTART_CAP=0` to disable (legacy unbounded
  behavior).
- **Terminal-state detection (`#13`)**. New `TERMINAL_PATTERNS` array
  recognizes states restart cannot recover from:
  - `--channels ignored`
  - `Channels require claude.ai authentication`
  - `Not logged in`
  When matched, watchdog emits a `not-logged-in` alert (no restart)
  with recovery instructions. State-based dedup: alert fires once per
  state-entry, suppresses while symptom persists, re-fires after recovery
  + re-entry.
- **Pluggable alert hook**. `WATCHDOG_ALERT_CMD` env var: shell expression
  invoked on alerts. Receives `WATCHDOG_ALERT_TYPE` and `WATCHDOG_ALERT_MSG`
  env vars. Unset = log-only (`ALERT [<type>]: <msg>` line in
  `claude-watchdog.log`).
- **CLI flags**:
  - `--reset` clears today's counter + both alert flags (use after
    manual recovery to restore normal cooldown without waiting for
    midnight).
  - `--status` dumps version, count vs cap, effective cooldown, last
    restart age, next restart allowed in, and both flag states.
- **Test harness** under `test/`:
  - Unit tests source the script (via new source-guard) and call helpers
    directly.
  - Integration tests run the script as a subprocess with mocked
    `tmux`/`pgrep` in PATH; observe state files, log lines, and tmux
    call traces.
  - `test/run.sh` discovers and runs all `*.test.sh` files.
- **CI** (`.github/workflows/ci.yml`): shellcheck + test suite on
  macos-latest for push and PR.

### Changed
- `claude-watchdog.sh` main flow is now wrapped in `main()` with a
  source-guard at the bottom, enabling unit tests. Daemon-mode behavior
  is unchanged.
- `STUCK_PATTERNS` renamed to `RESTART_PATTERNS` (semantically clearer
  paired with new `TERMINAL_PATTERNS`); `detect_restart_pattern` and
  `detect_terminal_state` helpers extracted from the inline pane scan.
- `check_cooldown` now accepts the cooldown duration as `$1` (default
  `$COOLDOWN_SECONDS` preserves backward-compat for any in-script callers).

### Backward compatibility
- All existing env vars and CLI flags continue to work unchanged.
- Plist Label `com.openclaw.claude-watchdog` unchanged.
- v0.1.5 → v0.1.6 upgrade gains `WATCHDOG_DAILY_RESTART_CAP=10` by
  default. Healthy bots (0–3 restarts/day) won't notice. Users who want
  the legacy unbounded behavior: set `WATCHDOG_DAILY_RESTART_CAP=0`.

### Note for downstream installs
- Configure `WATCHDOG_ALERT_CMD` to a script of your choosing (e.g.
  `osascript` for macOS notifications, `curl` to a Telegram bot, ntfy,
  etc.) to receive alerts. Without it, alerts are visible only as
  `ALERT:` lines in `claude-watchdog.log`. See README "Alert protocol"
  section for the calling convention.

## v0.1.5 — 2026-04-25

### Changed
- Heartbeat-stale-alone no longer triggers restart. Bots that go idle for
  longer than `WATCHDOG_HEARTBEAT_STALE_SECONDS` (default 600s) without
  receiving a Telegram/Discord message produce a stale heartbeat naturally —
  the v0.1.0 behavior of `heartbeat authoritative` killed healthy idle bots
  every 6 minutes (cooldown-bounded). Heartbeat is now treated as a positive
  signal: stale + grep clean falls through to the process-alive check (Case
  C) instead of restarting. Fully agreed signals (stale + grep match) still
  restart.

### Note for plugin authors
- The `bananabay-watchdog` plugin's hooks fire only on `UserPromptSubmit` and
  `Stop` events. There's no continuous heartbeat. v0.1.5 accepts this as the
  contract; future plugins may add a background writer if "plugin alive but
  bot idle" detection becomes important.

## v0.1.4 — 2026-04-24

### Fixed
- `start_claude()` now pins the tmux session's working directory to `$HOME`
  via `tmux new-session -c "$HOME"`. Fresh installs driven by launchd
  previously inherited launchd's default cwd `/`, causing Claude Code to
  treat `/` as the workspace and block on the "Yes, I trust this folder"
  prompt — a dialog `--dangerously-skip-permissions` does **not** bypass in
  Claude Code v2.1.x. The result was an infinite kill+restart loop bounded
  only by the 5-minute cooldown. Fixes #10.

## v0.1.3 — 2026-04-24

### Fixed
- Script version string bumped to `0.1.3` (was left at `0.1.1` when v0.1.2
  shipped — the v0.1.2 release contained the install.sh remote-fetch fix but
  missed the corresponding `WATCHDOG_VERSION` bump, so `--version` would
  report `0.1.1` on v0.1.2 installs, confusing the `bananabay-watchdog`
  plugin's update detection). Reporting is now consistent with tag.

## v0.1.2 — 2026-04-24

### Fixed
- `install.sh` now supports `curl -fsSL .../install.sh | bash` remote
  invocation by detecting when the companion artifacts (`claude-watchdog.sh`,
  plist template) aren't on disk next to it and fetching them from
  GitHub raw. Previously the remote pattern documented by the
  `bananabay-watchdog` plugin's auto-install hook failed at step [2/5].

## v0.1.1 — 2026-04-24

### Added
- `install.sh` writes a sidecar config file at `~/.claude/watchdog/config.env`
  advertising `WATCHDOG_HEARTBEAT_FILE` to non-launchd consumers (e.g. the
  `bananabay-watchdog` Claude Code plugin). Pairs with `uninstall.sh` removal.

## v0.1.0 — 2026-04-23
(see GitHub release notes)
