#!/bin/bash
# Claude Code Watchdog — detects stuck sessions and restarts
# https://github.com/BananaBay69/claude-code-watchdog

set -euo pipefail

WATCHDOG_VERSION="0.1.5"

# --- CLI flag parsing ---
# parse_args() handles --help / --version / --show-config / --config <file>.
# Called from main() — when sourced, args are not parsed.

SHOW_CONFIG=0
CONFIG_FILE=""

parse_args() {
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
    WATCHDOG_HEARTBEAT_FILE               heartbeat file path (unset = disabled;
                                          installer default: $HOME/.claude/watchdog/heartbeat)
    WATCHDOG_HEARTBEAT_STALE_SECONDS      stale threshold in seconds (default: 600)
    WATCHDOG_COOLDOWN                     min seconds between restarts (default: 300)
    WATCHDOG_PATH                         PATH override for subprocesses
    WATCHDOG_CLAUDE_CMD                   command used to (re)start Claude in tmux
    WATCHDOG_ALERT_CMD                    shell expression invoked on alerts
                                          (receives WATCHDOG_ALERT_TYPE and
                                          WATCHDOG_ALERT_MSG env vars)

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
}

# --- Configuration ---
# Override via environment variables or the experimental --config <file> flag.
# init_config() resolves WATCHDOG_* env vars into the globals used by helpers.
# It is called once at top-level so that sourcing the script (e.g. by unit
# tests) immediately populates all globals.  main() re-calls it after sourcing
# a --config file so that file overrides take effect before any logic runs.

init_config() {
    export PATH="${WATCHDOG_PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"

    TMUX_SESSION="${WATCHDOG_SESSION:-claude}"
    LOG_DIR="${WATCHDOG_LOG_DIR:-$HOME/.claude/watchdog/logs}"
    LOG_FILE="$LOG_DIR/claude-watchdog.log"
    COOLDOWN_FILE="$LOG_DIR/.watchdog-last-restart"
    COOLDOWN_SECONDS="${WATCHDOG_COOLDOWN:-300}"
    MAX_LOG_BYTES=1048576

    CLAUDE_CMD="${WATCHDOG_CLAUDE_CMD:-export PATH=$PATH && claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official --channels plugin:discord@claude-plugins-official}"

    HEARTBEAT_FILE="${WATCHDOG_HEARTBEAT_FILE:-}"
    ALERT_CMD="${WATCHDOG_ALERT_CMD:-}"
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
}

# Top-level: populate globals from current env so sourcing the script works
# for tests.  main() will re-call init_config after --config file source so
# file overrides take effect.
init_config

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
    # Pin session cwd to $HOME so Claude never inherits launchd's default `/`
    # (workspace `/` triggers a trust prompt that --dangerously-skip-permissions
    # does not bypass in Claude Code v2.1.x, causing infinite restart loops — #10).
    tmux new-session -d -s "$TMUX_SESSION" -c "$HOME" "$CLAUDE_CMD"
    date +%s > "$COOLDOWN_FILE"
    log "ACTION: Restart complete. Cooldown set."
}

# Echoes one of: disabled | fresh | stale
#
# File format (v1): a single line "SCHEMA_VERSION TIMESTAMP" where
# SCHEMA_VERSION is "1" and TIMESTAMP is a unix epoch integer. Example:
#
#     1 1745382601
#
# Unknown schemas or malformed content are treated as stale so that a
# misbehaving writer still triggers the supervisor (fail loud, not silent).
# "disabled" is reserved for "no signal available" — env unset or file
# missing — where the supervisor falls back to grep-only detection.
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
    local schema hb_ts now age
    schema=""
    hb_ts=""
    # shellcheck disable=SC2162
    read schema hb_ts _rest < "$HEARTBEAT_FILE" 2>/dev/null || true
    if [ "$schema" != "1" ]; then
        log "WARN: heartbeat unsupported schema '$schema' in $HEARTBEAT_FILE — treating as stale"
        echo "stale"
        return
    fi
    if ! [[ "$hb_ts" =~ ^[0-9]+$ ]]; then
        log "WARN: heartbeat malformed timestamp '$hb_ts' in $HEARTBEAT_FILE — treating as stale"
        echo "stale"
        return
    fi
    now=$(date +%s)
    age=$(( now - hb_ts ))
    if [ "$age" -gt "$HEARTBEAT_STALE_SECONDS" ]; then
        echo "stale"
    else
        echo "fresh"
    fi
}

# --- Alert state helpers ---
#
# Alert flag files live in $LOG_DIR alongside .watchdog-last-restart.
# Naming:
#   .watchdog-alert-sent-<key>           — state-based (deleted when state clears)
#   .watchdog-alert-sent-<key>-YYYYMMDD  — time-based (rolls over at midnight)
# Caller decides which flavor by passing the bare key or the dated key.
#
# Callers must ensure $LOG_DIR exists before mark_alert_sent (e.g. via
# setup_logging). In production, main() calls setup_logging() first.
# Unit tests should call setup_logging() or `mkdir -p "$LOG_DIR"` in
# their setup.

alert_flag_path() {
    echo "$LOG_DIR/.watchdog-alert-sent-$1"
}

alert_already_sent() {
    [ -f "$(alert_flag_path "$1")" ]
}

mark_alert_sent() {
    : > "$(alert_flag_path "$1")"
}

clear_alert_flag() {
    rm -f "$(alert_flag_path "$1")"
}

# Emit an alert. Always writes an "ALERT [<type>]: <msg>" line to the log.
# If $ALERT_CMD is set, invokes it with WATCHDOG_ALERT_TYPE and
# WATCHDOG_ALERT_MSG env vars. Failures are logged as WARN but do not
# break the watchdog (alert is best-effort).
# Args are passed via env vars (not $1/$2) so user's ALERT_CMD can use them
# in constructs like `--data-urlencode "text=$WATCHDOG_ALERT_MSG"` without
# shell-escape gymnastics. This is part of the v0.1.6 public alert contract.
#
# Args: $1 = type (e.g. cap-reached, not-logged-in)
#       $2 = human-readable message
emit_alert() {
    local type="$1"
    local msg="$2"
    log "ALERT [$type]: $msg"
    if [ -n "$ALERT_CMD" ]; then
        local out rc=0
        # Capture exit code via `|| rc=$?` so `set -e` doesn't abort when the
        # user's ALERT_CMD fails. Alert delivery is best-effort and must not
        # break the watchdog tick.
        out=$(WATCHDOG_ALERT_TYPE="$type" WATCHDOG_ALERT_MSG="$msg" \
              sh -c "$ALERT_CMD" 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
            local snippet
            snippet=$(echo "$out" | head -3 | tr '\n' ' ')
            snippet="${snippet% }"
            if [ -n "$snippet" ]; then
                log "WARN: alert command exited $rc: $snippet"
            else
                log "WARN: alert command exited $rc (no output)"
            fi
        fi
    fi
}

# Echoes "yes:<matched_pattern>" or "no:" based on whether $1 (pane content)
# matches any RESTART_PATTERNS entry. RESTART_PATTERNS are interactive prompts
# the supervisor must restart out of (rate limit, trust dialog, etc.).
detect_restart_pattern() {
    local pane="$1"
    local pat
    pat=$(IFS='|'; echo "${RESTART_PATTERNS[*]}")
    if echo "$pane" | grep -qE "$pat"; then
        echo "yes:$(echo "$pane" | grep -oE "$pat" | head -1)"
    else
        echo "no:"
    fi
}

# Echoes "yes:<matched_pattern>" or "no:" based on whether $1 (pane content)
# matches any TERMINAL_PATTERNS entry. TERMINAL_PATTERNS indicate states
# restart cannot recover from (e.g. logged out — needs interactive /login).
# Result is consumed by main() to emit an alert without restarting.
detect_terminal_state() {
    local pane="$1"
    local pat
    if [ "${#TERMINAL_PATTERNS[@]}" -eq 0 ]; then
        echo "no:"
        return
    fi
    pat=$(IFS='|'; echo "${TERMINAL_PATTERNS[*]}")
    if [ -z "$pat" ]; then
        echo "no:"
        return
    fi
    if echo "$pane" | grep -qE "$pat"; then
        echo "yes:$(echo "$pane" | grep -oE "$pat" | head -1)"
    else
        echo "no:"
    fi
}

setup_logging() {
    mkdir -p "$LOG_DIR"
    # Log rotation: keep last 500 lines if > 1MB
    if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt "$MAX_LOG_BYTES" ]; then
        tail -500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
        log "Log rotated (exceeded 1MB)"
    fi
}

# --- Pattern lists ---

# RESTART_PATTERNS: pane content that warrants a kill+restart (interactive
# prompts the supervisor must clear).
RESTART_PATTERNS=(
    "rate-limit-options"
    "Enter to confirm.*Esc to cancel"
    "Yes, I trust this folder"
    "You've hit your limit"
    "resets [0-9]+[ap]m"
    "Press Enter to continue"
    "Do you trust the files"
)

# TERMINAL_PATTERNS: pane content that indicates an unrecoverable state where
# restart cannot help (e.g. OAuth invalidated). Populated in v0.1.6 Task 4.
TERMINAL_PATTERNS=()

# --- Main ---

main() {
    parse_args "$@"

    # --config: source experimental config file (sets/overrides env vars),
    # then re-run init_config so WATCHDOG_* values from the file take effect.
    if [ -n "$CONFIG_FILE" ]; then
        if [ ! -f "$CONFIG_FILE" ]; then
            echo "error: --config file not found: $CONFIG_FILE" >&2
            exit 2
        fi
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
        init_config
    fi

    # --show-config exits before any side-effects
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
WATCHDOG_ALERT_CMD=${ALERT_CMD:-(unset, log-only)}
LOG_FILE=$LOG_FILE
COOLDOWN_FILE=$COOLDOWN_FILE
EOF
        exit 0
    fi

    setup_logging

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

    RESTART_MATCH=$(detect_restart_pattern "$PANE_OUTPUT")
    if [ "${RESTART_MATCH%%:*}" = "yes" ]; then
        GREP_MATCHED=1
        MATCHED="${RESTART_MATCH#*:}"
    else
        GREP_MATCHED=0
        MATCHED=""
    fi

    HB_STATE=$(heartbeat_state)
    SHOULD_RESTART=0

    case "$HB_STATE:$GREP_MATCHED" in
        stale:1)
            log "DETECT: heartbeat stale AND pane pattern '$MATCHED' (signals agree)"
            SHOULD_RESTART=1
            ;;
        stale:0)
            # v0.1.5: do NOT restart on heartbeat-stale-alone. Idle bots that
            # haven't received a UserPromptSubmit/Stop event in `WATCHDOG_HEARTBEAT_STALE_SECONDS`
            # produce a stale heartbeat naturally — restarting them was a false
            # positive. Fall through to Case C (process-alive check) which catches
            # the actually-stuck-without-pattern scenario.
            log "INFO: heartbeat stale but pane clean — likely idle; deferring to process check"
            ;;
        fresh:1)
            log "WARN: pane pattern '$MATCHED' matched but heartbeat fresh; restarting (grep authoritative — may be false positive from conversation content)"
            SHOULD_RESTART=1
            ;;
        fresh:0)
            : # both clean, fall through to Case C
            ;;
        disabled:1)
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
}

# Source-guard: only run main when this script is executed, not sourced.
# When sourced (e.g. by tests), config is set and functions are defined,
# but main() is not invoked.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
fi
