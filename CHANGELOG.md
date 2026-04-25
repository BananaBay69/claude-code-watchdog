# Changelog

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
