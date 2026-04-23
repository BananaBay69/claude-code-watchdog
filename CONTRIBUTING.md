# Contributing to claude-code-watchdog

This doc captures design decisions that aren't obvious from reading the code — the *why* behind the architecture choices made in issue #1 and refined in Phase 1.

## Architecture — why CLI + optional plugin, not MCP

Full discussion: [issue #1](https://github.com/BananaBay69/claude-code-watchdog/issues/1).

The watchdog's job is to act when Claude Code **can't act on its own behalf** — rate-limit modal blocks the input loop, process dies, trust dialog waits for Enter. Any supervisor protocol that shares a liveness dependency with the supervisee fails the basic supervisor contract.

- **MCP** (rejected): MCP tools only fire during active inference. Claude can't call an MCP tool to rescue itself when it's stuck on a modal.
- **CLI binary** (adopted): launchd-driven, independent failure domain.
- **Plugin** (Phase 2, deferred): Claude Code hooks (`UserPromptSubmit` / `Stop`) are the only in-runtime way to emit a liveness signal. Plugin provides hooks + `/watchdog-install` UX, but does **not** run the supervisor (which must survive Claude's death).

## Phase 1 design decisions (v0.1.0)

### Detection: heartbeat primary + grep cross-check

When the optional `WATCHDOG_HEARTBEAT_FILE` is configured:

```
Case A: tmux session missing        → restart
Case B: heartbeat stale AND grep clean  → restart + log WARN (heartbeat authoritative)
        heartbeat fresh AND grep matched → restart + log WARN (grep authoritative, likely conversation content)
        both agree                   → restart
        both clean                   → OK
Case C: claude process dead          → restart
```

**Why not "require both signals to agree before restart"**: if the plugin (Phase 2) crashes, heartbeat goes stale and grep may still be clean. Requiring AND would leave the supervisor unable to act during the exact failure mode we care about. The WARN log is a feature — it's the dataset Phase 3 will use to benchmark heartbeat vs pane-scrape false-positive rates.

**Why not grep-only**: pane-scrape can match "rate-limit-options" legitimately appearing in Claude's conversation output (false positive). Heartbeat is immune to this.

### Heartbeat file format: `SCHEMA_VERSION TIMESTAMP`

A single line, space-separated. Example: `1 1745382601`.

Parsed in bash via `read schema ts < "$HEARTBEAT_FILE"`. Unknown schema → treated as stale with a WARN log.

**Why not JSON**: would pull `jq` as a runtime dependency. Phase 1 goal is zero-dep bash.
**Why not mtime-only**: no room to add fields (pid, session, claude version) later without breaking v1 readers.

### Default paths: `~/.claude/watchdog/` (new) with installer flags for legacy layouts

| | Default | Override |
|-|---------|----------|
| Log dir | `~/.claude/watchdog/logs/` | `install.sh --log-dir <path>` or `WATCHDOG_LOG_DIR` env |
| Heartbeat file | `~/.claude/watchdog/heartbeat` | `install.sh --heartbeat-file <path>` or `WATCHDOG_HEARTBEAT_FILE` env |
| tmux session name | `claude` | `install.sh --session <name>` or `WATCHDOG_SESSION` env |

The `openclaw` naming is an internal convention of a single downstream user and doesn't belong in upstream defaults. Existing installs (notably the Mac Mini dogfood target) migrate by passing the legacy flags.

### Stale threshold: `WATCHDOG_HEARTBEAT_STALE_SECONDS` (default 600)

Internal floor of `max(user_value, 2 × launchd_interval + 30s)` to prevent self-DoS when someone sets `WATCHDOG_HEARTBEAT_STALE_SECONDS=60` but launchd calls every 180s.

### Config file format: not in Phase 1

Env vars + CLI flags are the Phase 1 config surface. The `--config <path>` flag accepts a bash-source file but is documented as **experimental** — `source <anything>` in a supervisor context is a security-adjacent decision that deserves a separate issue when there's a real use case. Phase 2's plugin will likely introduce its own config format (`.json`), at which point the CLI config story gets redesigned as a pair.

### CLI flag handling

Implemented as a `case "${1:-}"` block at the top of `claude-watchdog.sh`. No args = daemon mode (launchd entrypoint, unchanged behavior). Supported flags:

- `--help`, `-h` — usage
- `--version`, `-V` — emit `WATCHDOG_VERSION`
- `--show-config` — dump effective config for debug
- `--config <path>` — source experimental config file

### Release: manual tag + `gh release create` in Phase 1

`git tag v0.1.0` + `gh release upload` by hand. GitHub Actions auto-release is tracked separately to avoid debugging workflow YAML on the first-ever release.

## Backward-compatibility contract (v0.1.0)

These are **public interfaces** and won't change without a major version bump:

- Env vars: `WATCHDOG_LOG_DIR`, `WATCHDOG_SESSION`, `WATCHDOG_COOLDOWN`, `WATCHDOG_PATH`, `WATCHDOG_CLAUDE_CMD` (existing, unchanged semantics)
- New env vars added in v0.1.0: `WATCHDOG_HEARTBEAT_FILE`, `WATCHDOG_HEARTBEAT_STALE_SECONDS` (stabilized as of v0.1.0)
- Plist Label: `com.openclaw.claude-watchdog` (legacy name, preserved for existing `launchctl` bindings)
- Legacy default paths when installer is called without flags on a pre-v0.1 install: still supported via flags
- Exit code 0 = daemon success (launchd depends on this)
- Cooldown file format: single line, unix timestamp

## Not in scope (tracked separately)

- **Phase 2**: Claude Code plugin with `UserPromptSubmit`/`Stop` heartbeat hooks
- **Phase 3**: empirical benchmark of heartbeat vs pane-scrape false-positive rates
- **Auto-release workflow**: GitHub Actions on tag push
- **Packaging**: Homebrew tap, `curl | sh` installer
- **Language rewrite**: bash stays for Phase 1+2; any port to Go/Rust/Swift needs its own design issue first
- **Linux port**: `stat -f %m` is macOS BSD syntax — upstream is macOS-only
