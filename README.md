# claude-code-watchdog

Watchdog for Claude Code running in background tmux sessions on macOS. Detects stuck states (rate-limit prompts, trust dialogs, dead processes) and restarts the session.

Runs under launchd as an out-of-band supervisor — independent failure domain from the Claude process it monitors.

## Problem

When Claude Code runs as a background bot (e.g., Telegram/Discord via `--channels`), interactive prompts like the rate-limit dialog block the session indefinitely with no one to press Enter.

## How It Works

```
launchd (every 3 min)
  → claude-watchdog.sh
    → tmux session exists?                          (Case A)
      ├─ No → start Claude
    → heartbeat + pane-grep check                   (Case B)
      ├─ heartbeat stale AND grep matched → restart (signals agree)
      ├─ heartbeat stale, grep clean      → INFO log only, defer to Case C (idle bots produce stale heartbeats too — see v0.1.5)
      ├─ heartbeat fresh, grep matched    → restart (WARN, grep authoritative)
      ├─ both clean                       → continue to Case C
    → claude process alive in pane?                 (Case C)
      ├─ No → kill + restart
      └─ Yes → log OK
```

### Two detection signals

1. **Heartbeat file staleness** (primary, opt-in). A liveness file written by the Claude runtime — currently external (e.g., via Phase 2 plugin hooks, not yet shipped). If its timestamp is older than `WATCHDOG_HEARTBEAT_STALE_SECONDS` (default 600), the session is considered stuck.
2. **Pane-scrape grep** (cross-check / legacy fallback). Scans the last 50 lines of the tmux pane for interactive-prompt patterns.

When both are enabled and disagree, the supervisor still restarts — and logs a `WARN` line so the disagreement dataset can inform future tuning. When the heartbeat file is unconfigured or missing, detection falls back to grep-only (Phase 0 behavior).

### Grep patterns

| Pattern | Scenario |
|---------|----------|
| `rate-limit-options` | Hit rate limit |
| `You've hit your limit` | Rate limit message |
| `Enter to confirm · Esc to cancel` | Any interactive confirmation |
| `Yes, I trust this folder` | First-run trust prompt |
| `Do you trust the files` | File trust prompt |
| `Press Enter to continue` | Other interactive prompts |
| `resets [0-9]+[ap]m` | Rate-limit reset time |

### Safety

- **5-minute cooldown** between restarts to prevent restart loops (`WATCHDOG_COOLDOWN`)
- **Log rotation** at 1 MB (keeps last 500 lines)
- **Stale-threshold safety floor** of ~2 launchd cycles + 30 s (≈390 s) — prevents self-DoS from tight thresholds
- **Process health check** detects crashed claude inside a live tmux session (Case C)

## Install

```bash
git clone https://github.com/BananaBay69/claude-code-watchdog.git
cd claude-code-watchdog
bash install.sh
```

Defaults (v0.1.0+):

| Setting | Value |
|---------|-------|
| Script | `~/bin/claude-watchdog.sh` |
| launchd plist | `~/Library/LaunchAgents/com.openclaw.claude-watchdog.plist` |
| Log directory | `~/.claude/watchdog/logs/` |
| Heartbeat file | `~/.claude/watchdog/heartbeat` *(treated as "disabled" until a writer exists)* |
| tmux session | `claude` |

### Installer flags

```
bash install.sh --log-dir <path>         # override log directory
                --heartbeat-file <path>  # override heartbeat path (pass "" to disable)
                --session <name>         # supervise a different tmux session
                --claude-cmd "<command>" # override how claude is launched
                --help                   # full usage
```

### Legacy-layout install (pre-v0.1 deployments)

Users migrating from Phase 0 (`~/.openclaw/logs/` convention) preserve their paths by passing the legacy flags:

```bash
bash install.sh --log-dir "$HOME/.openclaw/logs" \
                --heartbeat-file "$HOME/.openclaw/heartbeat"
```

### Custom Claude command

By default the watchdog launches Claude with:

```bash
claude --dangerously-skip-permissions \
  --channels plugin:telegram@claude-plugins-official \
  --channels plugin:discord@claude-plugins-official
```

Override at install time:

```bash
bash install.sh --claude-cmd "claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official"
```

Or set `WATCHDOG_CLAUDE_CMD` in the plist's `EnvironmentVariables` block after install.

## Usage

```bash
# CLI
bash ~/bin/claude-watchdog.sh --help          # usage
bash ~/bin/claude-watchdog.sh --version       # print version
bash ~/bin/claude-watchdog.sh --show-config   # effective config dump

# Operations
tail -20 ~/.claude/watchdog/logs/claude-watchdog.log   # watch activity
bash ~/bin/claude-watchdog.sh                          # run one check now (daemon mode)
launchctl list | grep claude-watchdog                  # launchd agent status
```

### Example log

```
2026-04-22 18:41:01 OK: Session alive, no stuck patterns detected
2026-04-22 18:44:01 DETECT: heartbeat stale AND pane pattern 'rate-limit-options' (signals agree)
2026-04-22 18:44:01 ACTION: Killing tmux session 'claude'
2026-04-22 18:44:03 ACTION: Starting new tmux session 'claude'
2026-04-22 18:44:03 ACTION: Restart complete. Cooldown set.
2026-04-22 18:47:01 OK: Session alive, no stuck patterns detected
2026-04-22 19:32:15 WARN: pane pattern 'rate-limit-options' matched but heartbeat fresh; restarting (grep authoritative — may be false positive from conversation content)
```

## Heartbeat protocol (v1)

This is the contract for anything that wants to emit a liveness signal for the watchdog to consume — notably the future Phase 2 Claude Code plugin.

### File format

A single line: `SCHEMA_VERSION TIMESTAMP`

```
1 1745382601
```

- `SCHEMA_VERSION`: integer, currently `1`. Readers that see an unknown schema version treat the file as stale and log a `WARN`.
- `TIMESTAMP`: unix epoch seconds (integer, `^[0-9]+$`).
- Subsequent tokens are ignored by v1 readers, enabling forward-compatible extensions (e.g., pid, session name, Claude version) without a schema bump.

### Writer contract

- Write atomically. On POSIX, the common idiom is to write to `$HEARTBEAT_FILE.tmp` and `mv` into place.
- Write frequently enough to stay under the stale threshold. Current default threshold: `600 s` (10 minutes). Writers should emit a heartbeat at **every** `UserPromptSubmit` and `Stop` event.
- The file's *content* timestamp is authoritative, not its mtime. (The supervisor no longer relies on `stat -f%m`.)
- Malformed content is treated as stale with a `WARN`, which is the supervisor's way of surfacing writer bugs.

### Reader behavior

- Unset `WATCHDOG_HEARTBEAT_FILE` **or** non-existent path → `heartbeat: disabled`, falls back to grep-only.
- File present but unreadable/unparseable → `heartbeat: stale` + `WARN`.
- File present and parseable, age ≤ threshold → `heartbeat: fresh`.
- File present and parseable, age > threshold → `heartbeat: stale`.

### Sidecar config (v0.1.1+)

`install.sh` writes `~/.claude/watchdog/config.env` containing
`WATCHDOG_HEARTBEAT_FILE=<path>`. This allows cross-process consumers
(notably the `bananabay-watchdog` Claude Code plugin) to discover the
custom heartbeat path without reading the launchd plist.

Readers should source the file conditionally:

```bash
[ -f "$HOME/.claude/watchdog/config.env" ] && . "$HOME/.claude/watchdog/config.env"
F="${WATCHDOG_HEARTBEAT_FILE:-$HOME/.claude/watchdog/heartbeat}"
```

The file is removed by `uninstall.sh`.

## Configuration

All settings can be overridden via environment variables (the installer writes them into the plist's `EnvironmentVariables` block):

| Variable | Default | Description |
|----------|---------|-------------|
| `WATCHDOG_SESSION` | `claude` | tmux session name |
| `WATCHDOG_LOG_DIR` | `~/.claude/watchdog/logs` | Log directory |
| `WATCHDOG_HEARTBEAT_FILE` | *(installer: `~/.claude/watchdog/heartbeat`; script default: disabled)* | Heartbeat file path. Unset = disabled. |
| `WATCHDOG_HEARTBEAT_STALE_SECONDS` | `600` | Stale threshold. Clamped to at least ~2 launchd cycles + 30 s. |
| `WATCHDOG_COOLDOWN` | `300` | Minimum seconds between restarts |
| `WATCHDOG_CLAUDE_CMD` | *(see above)* | Full Claude launch command |
| `WATCHDOG_PATH` | `/opt/homebrew/bin:...` | PATH for subprocesses |

## Requirements

- macOS (uses launchd, `stat -f%z`, `plutil`). Linux is a non-goal.
- tmux
- Claude Code CLI (`claude`)

## Files

v0.1.0 defaults:

| File | Location |
|------|----------|
| Watchdog script | `~/bin/claude-watchdog.sh` |
| launchd plist | `~/Library/LaunchAgents/com.openclaw.claude-watchdog.plist` |
| Activity log | `~/.claude/watchdog/logs/claude-watchdog.log` |
| launchd stdout/err | `~/.claude/watchdog/logs/watchdog-launchd.{out,err}` |
| Cooldown marker | `~/.claude/watchdog/logs/.watchdog-last-restart` |
| Heartbeat file | `~/.claude/watchdog/heartbeat` *(optional; written by external runtime)* |

Legacy (pre-v0.1) installs that pass `--log-dir "$HOME/.openclaw/logs"` continue to write under `~/.openclaw/`.

## Related documents

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — design rationale and backward-compatibility contract
- [Issue #1](https://github.com/BananaBay69/claude-code-watchdog/issues/1) — architecture direction: MCP vs CLI vs Plugin

## License

MIT
