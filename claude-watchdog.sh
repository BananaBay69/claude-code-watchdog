#!/bin/bash
# Claude Code Watchdog — detects stuck sessions and restarts
# https://github.com/PsychQuant/claude-code-watchdog

set -euo pipefail

# --- Configuration ---
# Override these via environment variables if needed:
#   WATCHDOG_SESSION=claude WATCHDOG_COOLDOWN=300 claude-watchdog.sh

export PATH="${WATCHDOG_PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"

TMUX_SESSION="${WATCHDOG_SESSION:-claude}"
LOG_DIR="${WATCHDOG_LOG_DIR:-$HOME/.openclaw/logs}"
LOG_FILE="$LOG_DIR/claude-watchdog.log"
COOLDOWN_FILE="$LOG_DIR/.watchdog-last-restart"
COOLDOWN_SECONDS="${WATCHDOG_COOLDOWN:-300}"
MAX_LOG_BYTES=1048576

CLAUDE_CMD="${WATCHDOG_CLAUDE_CMD:-export PATH=$PATH && claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official --channels plugin:discord@claude-plugins-official}"

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

# Case B: tmux session exists — check for stuck state
PANE_OUTPUT=$(tmux capture-pane -t "$TMUX_SESSION" -p -S -50)

if echo "$PANE_OUTPUT" | grep -qE "$PATTERN"; then
    MATCHED=$(echo "$PANE_OUTPUT" | grep -oE "$PATTERN" | head -1)
    log "DETECT: Stuck state found: '$MATCHED'"
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
