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
| `WATCHDOG_DAILY_RESTART_CAP` | `10` | Daily restart cap; `0` = disabled |
| `WATCHDOG_THROTTLED_COOLDOWN` | `3600` | Cooldown after cap (subject to safety floor) |
| `WATCHDOG_ALERT_CMD` | *(unset)* | Shell expression invoked on alerts (see "Alert protocol") |
| `WATCHDOG_LOG_LEVEL` | `INFO` | Threshold for `claude-watchdog.log` output. `DEBUG` / `INFO` / `WARN` / `ERROR`. See "Log levels and audit logging". |

## Log levels and audit logging (v0.1.9+)

`WATCHDOG_LOG_LEVEL` filters lines below the chosen severity. Default `INFO` matches v0.1.8 behaviour exactly (no migration needed). Set `DEBUG` during incident triage; revert when done.

**Prefix → level mapping** (`log()` parses the leading `^[A-Z]+:` token of each message):

| Prefix         | Mapped Level | Notes |
|----------------|--------------|-------|
| `DEBUG:`       | DEBUG (10)   | Suppressed at default INFO threshold |
| `INFO:`        | INFO (20)    | |
| `OK:`          | INFO (20)    | Semantic flavour — "what kind of event" |
| `DETECT:`      | INFO (20)    | Semantic flavour |
| `ACTION:`      | INFO (20)    | Semantic flavour |
| `COOLDOWN:`    | INFO (20)    | Semantic flavour |
| `WARN:`        | WARN (30)    | |
| `ERROR:`       | ERROR (40)   | |
| `ALERT [...]:` | **bypass**   | Always written regardless of threshold (alert dedup state machine relies on this) |
| (no prefix)    | INFO (20)    | Safe default |

Unknown values fall back to `INFO` and emit one `WARN: WATCHDOG_LOG_LEVEL='<value>' invalid` line at first call.

**Operator interventions are now audit-logged** (v0.1.9+):

```text
2026-04-29 14:32:01 INFO: operator: --reset (cleared 3 flags)
2026-04-29 16:05:18 INFO: operator: --snapshot (path: /Users/x/.claude/watchdog/logs/snapshots/silent-loop-20260429160517/)
2026-04-29 18:00:00 ERROR: unknown argument '--xyz'
```

Read-only invocations (`--help`, `--version`, `--show-config`, `--status`) leave no log line — they're informational queries, not events.

**Extract just the audit trail:**

```bash
grep "operator:\|ERROR: " ~/.claude/watchdog/logs/claude-watchdog.log
```

**Run the daemon ad-hoc with verbose logging** (without changing plist):

```bash
WATCHDOG_LOG_LEVEL=DEBUG bash ~/bin/claude-watchdog.sh
```

## Restart cap (v0.1.6+)

Watchdog tracks `kill+restart` cycles per local day. When the count
reaches `WATCHDOG_DAILY_RESTART_CAP` (default 10), the cooldown extends
from `WATCHDOG_COOLDOWN` (default 300s) to `WATCHDOG_THROTTLED_COOLDOWN`
(default 3600s) for the rest of the day, and a one-shot `cap-reached`
alert fires.

This bounds damage when the underlying issue is unrecoverable by restart
alone (e.g. corrupted credentials, network partition, upstream API
breakage). Healthy bots restart 0–3 times per day and never approach
the cap.

State files (under `$LOG_DIR`):

| File | Contents |
|------|----------|
| `.watchdog-restart-count-YYYYMMDD` | integer counter for today |
| `.watchdog-alert-sent-cap-YYYYMMDD` | empty flag — exists once cap-reached has been alerted today |

Counter rolls over at local midnight (filename change). Old files are
tiny and self-rotate; no GC needed.

To disable: set `WATCHDOG_DAILY_RESTART_CAP=0` (legacy unbounded behavior).

To recover after manual fix without waiting for midnight: `claude-watchdog --reset`.

## Terminal-state detection (v0.1.6+)

Some Claude Code states cannot be recovered by restart — most notably
"not logged in" after the OAuth session is invalidated. Each fresh
session reads the same broken keychain.

Watchdog detects these via `TERMINAL_PATTERNS`:

| Pattern | Scenario |
|---------|----------|
| `--channels ignored` | Channels disabled because auth invalid |
| `Channels require claude.ai authentication` | Same as above, alternate phrasing |
| `Not logged in` | Generic logged-out state |

When matched, watchdog **does NOT restart** — restart cannot help.
Instead it emits a one-shot `not-logged-in` alert with recovery
instructions (`ssh` + `tmux attach` + `/login`). The flag clears
when the symptom disappears, so future re-entry triggers a fresh alert.

State file: `$LOG_DIR/.watchdog-alert-sent-not-logged-in` (no date
suffix — state-based, not time-based).

### Silent-loop detection (v0.1.7+, opt-in)

Detects when an active bot is consuming incoming channel messages but not producing outbound replies — a "silent loop" caused by SKILL.md instruction-leak or similar logic bugs that restart cannot fix.

**Enable:**

```bash
WATCHDOG_SILENT_LOOP_ENABLED=1
```

**Tunables:**

| Env var | Default | Purpose |
|---|---|---|
| `WATCHDOG_OUTBOUND_FILE` | `$HOME/.claude/watchdog/outbound` | Outbound timestamp file (written by bananabay-watchdog plugin v0.2.0+) |
| `WATCHDOG_SILENT_LOOP_INCOMING_THRESHOLD` | `2` | Min `← telegram · CHATID:` lines in pane to consider |
| `WATCHDOG_SILENT_LOOP_OUTBOUND_STALE_SECONDS` | `600` | How long without outbound reply before flagging (subject to ~390s safety floor) |
| `WATCHDOG_SILENT_LOOP_PANE_LINES` | `200` | Pane lines to scan |

**Requires:** `bananabay-watchdog` plugin v0.2.0+ to be installed and writing `$WATCHDOG_OUTBOUND_FILE`. If the file is missing, silent-loop check no-ops (logs `no-outbound-signal`).

**Alert behavior:** Emits `WATCHDOG_ALERT_TYPE=silent-loop`. **Never restarts** — root cause is typically SKILL.md leak that restart re-enters. Operator must inspect pane and address upstream.

**Currently scoped to Telegram channel** (`mcp__telegram__reply` tool). Discord support tracked separately.

### Silent-loop recovery dispatch (v0.1.8+, opt-in)

v0.1.7 alerts on silent-loop but the operator still has to `ssh` in and `tmux capture-pane` to triage. v0.1.8 adds a `WATCHDOG_SILENT_LOOP_RECOVERY` mode that selects what happens after detection:

| Mode             | Behavior                                                                                                          |
|------------------|-------------------------------------------------------------------------------------------------------------------|
| `disabled` (default) | Alert only. Identical to v0.1.7.                                                                              |
| `snapshot-only`  | Alert + write a diagnostic snapshot directory. Alert message includes the snapshot path. Recommended for production. |
| `soft`           | (stub — logs `WARN: soft mode requested but not implemented`)                                                     |
| `aggressive`     | (stub — logs `WARN: aggressive mode requested but not implemented`)                                               |

`soft` and `aggressive` are reserved enum values for future PRs (see issue #15 closing comment). Unknown values fall back to `disabled` and log a `WARN`.

**Tunables:**

| Env var                          | Default    | Purpose                                                            |
|----------------------------------|------------|--------------------------------------------------------------------|
| `WATCHDOG_SILENT_LOOP_RECOVERY`  | `disabled` | Dispatch mode (above)                                              |
| `WATCHDOG_SNAPSHOT_RETAIN_COUNT` | `20`       | Max snapshot directories kept under `$LOG_DIR/snapshots/`, FIFO    |

**Snapshot triggering** piggybacks on the existing alert dedup flag — one snapshot per silent-loop *state-entry*, not per tick. After `outbound` advances and clears the flag, a re-entry produces a new snapshot.

**Snapshot directory contents** (`$LOG_DIR/snapshots/silent-loop-YYYYMMDDhhmmss/`):

| File                | Source                                                                                                  |
|---------------------|---------------------------------------------------------------------------------------------------------|
| `pane.txt`          | `tmux capture-pane -p -S -2000`                                                                         |
| `status.txt`        | `claude-watchdog.sh --status`                                                                           |
| `env.txt`           | `WATCHDOG_*` env vars + `tmux ls` + `pgrep -lf claude`                                                  |
| `recent-log.txt`    | last 200 lines of `claude-watchdog.log`                                                                 |
| `active-skills.txt` | path + ISO 8601 mtime for every `~/.claude/plugins/**/skills/*.md` (no content — may contain secrets)   |
| `metadata.json`     | `{captured_at, silent_loop_state: {incoming, outbound_age_seconds}, watchdog_version}`                  |

**Manual capture:** `claude-watchdog.sh --snapshot` writes a snapshot regardless of detection state. The alert dedup flag is *not* consulted or modified — useful for ad-hoc diagnostics.

**Privacy warning:** `pane.txt` may contain user messages, tokens, or other sensitive content from the bot's conversation history. Treat snapshot directories as sensitive. Default retention of 20 caps disk use at ~10 MB worst case (each snapshot ~500 KB max).

**Triage flow** (when you receive a `silent-loop` alert):

1. Open `metadata.json` — confirm `incoming > 0` and `outbound_age_seconds` is large
2. Open `pane.txt` — look at the bot's last few turns. Is it running tools (e.g. `check-reply`) but never sending messages? → SKILL.md leak (restart won't fix; fix the SKILL.md)
3. If `pane.txt` shows nothing recent → could be transient state (Claude itself stuck). Manual restart may help: `tmux send-keys -t claude C-c` then re-launch
4. Open `active-skills.txt` — sort by mtime; recently modified SKILL.md is the leading suspect for instruction-leak
5. Open `recent-log.txt` — confirm watchdog itself is healthy (no daemon-side WARNs)

## Alert protocol (v0.1.6+)

Alerts are pluggable via the `WATCHDOG_ALERT_CMD` env var:

```bash
WATCHDOG_ALERT_CMD='/path/to/your/alert-handler.sh'
# or inline:
WATCHDOG_ALERT_CMD='osascript -e "display notification \"$WATCHDOG_ALERT_MSG\" with title \"watchdog\""'
```

When watchdog has an alert to deliver, it invokes:

```bash
WATCHDOG_ALERT_TYPE="<type>" WATCHDOG_ALERT_MSG="<message>" sh -c "$WATCHDOG_ALERT_CMD"
```

Your handler reads those env vars. Available types in v0.1.6:

| `WATCHDOG_ALERT_TYPE` | When |
|----------------------|------|
| `cap-reached` | Daily restart cap was just hit |
| `not-logged-in` | Terminal-state pattern matched (auth needed) |

If `WATCHDOG_ALERT_CMD` is unset, alerts still appear in
`claude-watchdog.log` as `ALERT [<type>]: <msg>` lines but no external
notification fires. If your command exits non-zero, the watchdog logs
a `WARN` and continues — alert delivery is best-effort and never blocks
the supervisor.

### Reference dual-channel handler (Telegram + macOS Notification)

```bash
#!/bin/bash
# ~/.claude/watchdog/alert.sh — example dual-channel handler
set +e
TYPE="${WATCHDOG_ALERT_TYPE:-info}"
MSG="${WATCHDOG_ALERT_MSG:-}"
[ -z "$MSG" ] && exit 0

# macOS notification
/usr/bin/osascript -e \
    "display notification \"$MSG\" with title \"claude-watchdog [$TYPE]\"" \
    2>/dev/null

# Telegram
TG_ENV="$HOME/.claude/channels/telegram/.env"
if [ -f "$TG_ENV" ]; then
    . "$TG_ENV"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
        /usr/bin/curl -fsS --max-time 10 \
            -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=[claude-watchdog ${TYPE}] ${MSG}" \
            >/dev/null
    fi
fi
exit 0
```

## CLI flags (v0.1.6+)

```
claude-watchdog.sh                Daemon mode (launchd entrypoint)
claude-watchdog.sh --help         Show help
claude-watchdog.sh --version      Print version
claude-watchdog.sh --show-config  Dump effective config
claude-watchdog.sh --status       Dump runtime state (count, flags, cooldown)
claude-watchdog.sh --reset        Clear today's counter + both alert flags
```

`--status` example output:

```
WATCHDOG_VERSION=0.1.6
RESTART_COUNT_TODAY=3 / 10
EFFECTIVE_COOLDOWN=300s
LAST_RESTART_AGE=1842s
NEXT_RESTART_ALLOWED_IN=0s
ALERT_FLAG_CAP_REACHED=clear
ALERT_FLAG_NOT_LOGGED_IN=clear
```

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
