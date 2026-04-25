# Changelog

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
