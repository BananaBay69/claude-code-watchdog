# Changelog

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
