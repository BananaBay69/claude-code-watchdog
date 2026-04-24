# Changelog

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
