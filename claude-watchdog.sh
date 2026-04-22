#!/bin/bash
# Claude Code Watchdog — detects stuck sessions and restarts
# https://github.com/BananaBay69/claude-code-watchdog

set -euo pipefail

WATCHDOG_VERSION="0.1.0-dev"

# --- CLI flag parsing ---
# No args => daemon mode (launchd entrypoint, unchanged behavior).
# Flags are handled before config evaluation where possible, so --help
# and --version work even if HOME is unset.

SHOW_CONFIG=0
CONFIG_FILE=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            cat <<'USAGE'
claude-watchdog — supervise a Claude Code tmux session and restart on stuck states

Usage:
    claude-watchdog.sh                    Run one supervisory check (launchd entrypoint)
    claude-watchdog.sh --help             Show this help
    claude-watchdog.sh --version          Print version
    claude-watchdog.sh --show-config      Dump effective config and exit
    claude-watchdog.sh --config <file>    Source experimental config file then exit 0

Environment variables (all optional):
    WATCHDOG_SESSION                      tmux session name (default: claude)
    WATCHDOG_LOG_DIR                      log directory (default: $HOME/.claude/watchdog/logs)
    WATCHDOG_HEARTBEAT_FILE               heartbeat file path (default: $HOME/.claude/watchdog/heartbeat; unset = disabled)
    WATCHDOG_HEARTBEAT_STALE_SECONDS      stale threshold in seconds (default: 600)
    WATCHDOG_COOLDOWN                     min seconds between restarts (default: 300)
    WATCHDOG_PATH                         PATH override for subprocesses
    WATCHDOG_CLAUDE_CMD                   command used to (re)start Claude in tmux

Detection order:
    A. tmux session missing             -> restart
    B. heartbeat stale OR grep matched  -> restart (WARN on disagreement)
    C. claude process dead in pane      -> restart

Backward compatibility: existing installs on pre-v0.1 layouts are supported via
install.sh --log-dir / --heartbeat-file / --session flags. See CONTRIBUTING.md.
USAGE
            exit 0
            ;;
        -V|--version)
            echo "$WATCHDOG_VERSION"
            exit 0
            ;;
        --show-config)
            SHOW_CONFIG=1
            shift
            ;;
        --config)
            if [ "$#" -lt 2 ]; then
                echo "error: --config requires a file path" >&2
                exit 2
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "error: unknown argument '$1' (try --help)" >&2
            exit 2
            ;;
    esac
done

# --- Configuration ---
# Override via environment variables or the experimental --config <file> flag.

if [ -n "$CONFIG_FILE" ]; then
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "error: --config file not found: $CONFIG_FILE" >&2
        exit 2
    fi
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

export PATH="${WATCHDOG_PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"

TMUX_SESSION="${WATCHDOG_SESSION:-claude}"
LOG_DIR="${WATCHDOG_LOG_DIR:-$HOME/.openclaw/logs}"
LOG_FILE="$LOG_DIR/claude-watchdog.log"
COOLDOWN_FILE="$LOG_DIR/.watchdog-last-restart"
COOLDOWN_SECONDS="${WATCHDOG_COOLDOWN:-300}"
MAX_LOG_BYTES=1048576

CLAUDE_CMD="${WATCHDOG_CLAUDE_CMD:-export PATH=$PATH && claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official --channels plugin:discord@claude-plugins-official}"

HEARTBEAT_FILE="${WATCHDOG_HEARTBEAT_FILE:-}"
HEARTBEAT_STALE_REQUESTED="${WATCHDOG_HEARTBEAT_STALE_SECONDS:-600}"
# Safety floor: never trust a stale threshold tighter than ~2 launchd cycles
# (assumes StartInterval=180). Users can always raise the threshold; floor
# only kicks in when an unrealistically small value is set.
HEARTBEAT_STALE_FLOOR=390
if [ "$HEARTBEAT_STALE_REQUESTED" -lt "$HEARTBEAT_STALE_FLOOR" ]; then
    HEARTBEAT_STALE_SECONDS=$HEARTBEAT_STALE_FLOOR
else
    HEARTBEAT_STALE_SECONDS=$HEARTBEAT_STALE_REQUESTED
fi

if [ "$SHOW_CONFIG" -eq 1 ]; then
    cat <<EOF
WATCHDOG_VERSION=$WATCHDOG_VERSION
WATCHDOG_SESSION=$TMUX_SESSION
WATCHDOG_LOG_DIR=$LOG_DIR
WATCHDOG_HEARTBEAT_FILE=${HEARTBEAT_FILE:-(disabled)}
WATCHDOG_HEARTBEAT_STALE_SECONDS=$HEARTBEAT_STALE_SECONDS (requested=$HEARTBEAT_STALE_REQUESTED, floor=$HEARTBEAT_STALE_FLOOR)
WATCHDOG_COOLDOWN=$COOLDOWN_SECONDS
WATCHDOG_PATH=$PATH
WATCHDOG_CLAUDE_CMD=$CLAUDE_CMD
LOG_FILE=$LOG_FILE
COOLDOWN_FILE=$COOLDOWN_FILE
EOF
    exit 0
fi

# --- Helpers ---

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

check_cooldown() {
    if [ -f "$COOLDOWN_FILE" ]; then
        local last_restart now elapsed
        last_restart=$(cat "$COOLDOWN_FILE")
        now=$(date +%s)
        elapsed=$(( now - last_restart ))
        if [ "$elapsed" -lt "$COOLDOWN_SECONDS" ]; then
            log "COOLDOWN: Last restart ${elapsed}s ago (< ${COOLDOWN_SECONDS}s). Skipping."
            return 1
        fi
    fi
    return 0
}

start_claude() {
    log "ACTION: Killing tmux session '$TMUX_SESSION'"
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    sleep 2
    log "ACTION: Starting new tmux session '$TMUX_SESSION'"
    tmux new-session -d -s "$TMUX_SESSION" "$CLAUDE_CMD"
    date +%s > "$COOLDOWN_FILE"
    log "ACTION: Restart complete. Cooldown set."
}

# Echoes one of: disabled | fresh | stale
# "disabled" = heartbeat signal unavailable for cross-check (env unset or file
# not yet created by plugin). In that state, fall back to grep-only detection
# (Phase 0 backward-compat path).
heartbeat_state() {
    if [ -z "$HEARTBEAT_FILE" ]; then
        echo "disabled"
        return
    fi
    if [ ! -f "$HEARTBEAT_FILE" ]; then
        log "DEBUG: heartbeat file not found: $HEARTBEAT_FILE (plugin not installed?)"
        echo "disabled"
        return
    fi
    local hb_mtime now age
    hb_mtime=$(stat -f%m "$HEARTBEAT_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - hb_mtime ))
    if [ "$age" -gt "$HEARTBEAT_STALE_SECONDS" ]; then
        echo "stale"
    else
        echo "fresh"
    fi
}

# --- Setup ---

mkdir -p "$LOG_DIR"

# Log rotation: keep last 500 lines if > 1MB
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
    tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    log "Log rotated (exceeded 1MB)"
fi

# --- Stuck patterns ---

STUCK_PATTERNS=(
    "rate-limit-options"
    "Enter to confirm.*Esc to cancel"
    "Yes, I trust this folder"
    "You've hit your limit"
    "resets [0-9]+[ap]m"
    "Press Enter to continue"
    "Do you trust the files"
)
PATTERN=$(IFS='|'; echo "${STUCK_PATTERNS[*]}")

# --- Main ---

# Case A: tmux session does not exist
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "DETECT: tmux session '$TMUX_SESSION' not found"
    if check_cooldown; then
        start_claude
    fi
    exit 0
fi

# Case B: tmux session exists — check for stuck state using heartbeat
# (primary when enabled) and pane-scrape grep (cross-check / fallback).
PANE_OUTPUT=$(tmux capture-pane -t "$TMUX_SESSION" -p -S -50)

GREP_MATCHED=0
MATCHED=""
if echo "$PANE_OUTPUT" | grep -qE "$PATTERN"; then
    GREP_MATCHED=1
    MATCHED=$(echo "$PANE_OUTPUT" | grep -oE "$PATTERN" | head -1)
fi

HB_STATE=$(heartbeat_state)
SHOULD_RESTART=0

case "$HB_STATE:$GREP_MATCHED" in
    stale:1)
        log "DETECT: heartbeat stale AND pane pattern '$MATCHED' (signals agree)"
        SHOULD_RESTART=1
        ;;
    stale:0)
        log "WARN: heartbeat stale but no stuck pattern in pane; restarting (heartbeat authoritative)"
        SHOULD_RESTART=1
        ;;
    fresh:1)
        log "WARN: pane pattern '$MATCHED' matched but heartbeat fresh; restarting (grep authoritative — may be false positive from conversation content)"
        SHOULD_RESTART=1
        ;;
    fresh:0)
        : # both clean, fall through to Case C
        ;;
    disabled:1)
        # Phase 0 backward-compat path: heartbeat unavailable, grep decides alone.
        log "DETECT: Stuck state found: '$MATCHED'"
        SHOULD_RESTART=1
        ;;
    disabled:0)
        : # grep-only, clean, fall through to Case C
        ;;
esac

if [ "$SHOULD_RESTART" -eq 1 ]; then
    if check_cooldown; then
        start_claude
    fi
    exit 0
fi

# Case C: tmux session exists but claude process died
PANE_PID=$(tmux display-message -t "$TMUX_SESSION" -p '#{pane_pid}')
if ! pgrep -P "$PANE_PID" -f "claude" >/dev/null 2>&1; then
    log "DETECT: No claude process found in tmux session (pane_pid=$PANE_PID)"
    if check_cooldown; then
        start_claude
    fi
    exit 0
fi

log "OK: Session alive, no stuck patterns detected"
exit 0
