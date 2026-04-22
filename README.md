# claude-code-watchdog

Watchdog for Claude Code running in background tmux sessions on macOS. Automatically detects stuck states (rate limit prompts, trust dialogs) and restarts the session.

## Problem

When Claude Code runs as a background bot (e.g., Telegram/Discord via `--channels`), interactive prompts like rate limit dialogs block the session indefinitely with no one to press Enter.

## How It Works

```
launchd (every 3 min)
  → claude-watchdog.sh
    → tmux session exists?
      ├─ No → start Claude
      ├─ Yes, stuck prompt detected → kill + restart
      ├─ Yes, claude process dead → kill + restart
      └─ Yes, healthy → log OK
```

### Detected Stuck States

| Pattern | Scenario |
|---------|----------|
| `rate-limit-options` | Hit rate limit |
| `You've hit your limit` | Rate limit message |
| `Enter to confirm · Esc to cancel` | Any interactive confirmation |
| `Yes, I trust this folder` | First-run trust prompt |
| `Do you trust the files` | File trust prompt |

### Safety

- **5-minute cooldown** between restarts to prevent restart loops
- **Log rotation** at 1MB (keeps last 500 lines)
- **Process health check** detects crashed claude inside a live tmux session

## Install

```bash
git clone https://github.com/PsychQuant/claude-code-watchdog.git
cd claude-code-watchdog
bash install.sh
```

### Custom Claude Command

By default, the watchdog starts Claude with:

```bash
claude --dangerously-skip-permissions \
  --channels plugin:telegram@claude-plugins-official \
  --channels plugin:discord@claude-plugins-official
```

To customize:

```bash
bash install.sh --claude-cmd "claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official"
```

Or set the environment variable `WATCHDOG_CLAUDE_CMD` in the script after install.

## Usage

```bash
# View watchdog log
tail -20 ~/.openclaw/logs/claude-watchdog.log

# Run watchdog manually (useful for testing)
bash ~/bin/claude-watchdog.sh

# Check launchd agent status
launchctl list | grep claude-watchdog
```

### Example Log

```
2026-04-22 18:41:01 OK: Session alive, no stuck patterns detected
2026-04-22 18:44:01 DETECT: Stuck state found: 'rate-limit-options'
2026-04-22 18:44:01 ACTION: Killing tmux session 'claude'
2026-04-22 18:44:03 ACTION: Starting new tmux session 'claude'
2026-04-22 18:44:03 ACTION: Restart complete. Cooldown set.
2026-04-22 18:47:01 OK: Session alive, no stuck patterns detected
```

## Uninstall

```bash
bash uninstall.sh
```

## Configuration

All settings can be overridden via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `WATCHDOG_SESSION` | `claude` | tmux session name |
| `WATCHDOG_COOLDOWN` | `300` | Seconds between restarts |
| `WATCHDOG_LOG_DIR` | `~/.openclaw/logs` | Log directory |
| `WATCHDOG_CLAUDE_CMD` | *(see above)* | Full Claude launch command |
| `WATCHDOG_PATH` | `/opt/homebrew/bin:...` | PATH for the script |

## Requirements

- macOS (uses launchd + `stat -f%z`)
- tmux
- Claude Code CLI (`claude`)

## Files

| File | Location |
|------|----------|
| Watchdog script | `~/bin/claude-watchdog.sh` |
| launchd plist | `~/Library/LaunchAgents/com.openclaw.claude-watchdog.plist` |
| Activity log | `~/.openclaw/logs/claude-watchdog.log` |
| Cooldown file | `~/.openclaw/logs/.watchdog-last-restart` |

## License

MIT
