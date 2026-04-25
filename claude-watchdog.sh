#!/bin/bash
# Claude Code Watchdog — detects stuck sessions and restarts
# https://github.com/BananaBay69/claude-code-watchdog

set -euo pipefail

WATCHDOG_VERSION="0.1.7"

# --- CLI flag parsing ---
# parse_args() handles --help / --version / --show-config / --config <file>.
# Called from main() — when sourced, args are not parsed.

SHOW_CONFIG=0
CONFIG_FILE=""
DO_RESET=0
SHOW_STATUS=0

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
    claude-watchdog.sh --reset            Clear today's counter + alert flags (post-recovery)
    claude-watchdog.sh --status           Print runtime state (count, flags, cooldown) and exit

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
    WATCHDOG_DAILY_RESTART_CAP            daily kill+restart cap (default: 10;
                                          set 0 to disable)
    WATCHDOG_THROTTLED_COOLDOWN           cooldown after cap reached, seconds
                                          (default: 3600; subject to safety floor)
    WATCHDOG_SILENT_LOOP_ENABLED          enable silent-loop detection (default: 0)
    WATCHDOG_OUTBOUND_FILE                outbound timestamp file (default: $HOME/.claude/watchdog/outbound)
    WATCHDOG_SILENT_LOOP_INCOMING_THRESHOLD
                                          min incoming msgs in pane to trigger (default: 2)
    WATCHDOG_SILENT_LOOP_OUTBOUND_STALE_SECONDS
                                          outbound stale threshold, seconds (default: 600)
    WATCHDOG_SILENT_LOOP_PANE_LINES       pane lines to scan for incoming (default: 200)

Detection order:
    A. tmux session missing             -> restart
    B. heartbeat stale OR grep matched  -> restart (WARN on disagreement)
    C. claude process dead in pane      -> restart
    D. silent-loop (opt-in)             -> alert-only (no restart)

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
            --reset)
                DO_RESET=1
                shift
                ;;
            --status)
                SHOW_STATUS=1
                shift
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

    DAILY_RESTART_CAP="${WATCHDOG_DAILY_RESTART_CAP:-10}"
    THROTTLED_COOLDOWN_REQUESTED="${WATCHDOG_THROTTLED_COOLDOWN:-3600}"
    # Reuse the existing safety floor (max(value, ~2 launchd cycles + 30s)).
    if [ "$THROTTLED_COOLDOWN_REQUESTED" -lt "$HEARTBEAT_STALE_FLOOR" ]; then
        THROTTLED_COOLDOWN=$HEARTBEAT_STALE_FLOOR
    else
        THROTTLED_COOLDOWN=$THROTTLED_COOLDOWN_REQUESTED
    fi

    # v0.1.7: silent-loop detection (opt-in)
    SILENT_LOOP_ENABLED="${WATCHDOG_SILENT_LOOP_ENABLED:-0}"
    OUTBOUND_FILE="${WATCHDOG_OUTBOUND_FILE:-$HOME/.claude/watchdog/outbound}"
    SILENT_LOOP_INCOMING_THRESHOLD="${WATCHDOG_SILENT_LOOP_INCOMING_THRESHOLD:-2}"
    # Reuse the heartbeat safety floor (~2 launchd cycles)
    SILENT_LOOP_OUTBOUND_STALE_REQUESTED="${WATCHDOG_SILENT_LOOP_OUTBOUND_STALE_SECONDS:-600}"
    if [ "$SILENT_LOOP_OUTBOUND_STALE_REQUESTED" -lt "$HEARTBEAT_STALE_FLOOR" ]; then
        SILENT_LOOP_OUTBOUND_STALE_SECONDS=$HEARTBEAT_STALE_FLOOR
    else
        SILENT_LOOP_OUTBOUND_STALE_SECONDS=$SILENT_LOOP_OUTBOUND_STALE_REQUESTED
    fi
    SILENT_LOOP_PANE_LINES="${WATCHDOG_SILENT_LOOP_PANE_LINES:-200}"
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
    local cooldown="${1:-$COOLDOWN_SECONDS}"
    if [ -f "$COOLDOWN_FILE" ]; then
        local last_restart now elapsed
        last_restart=$(cat "$COOLDOWN_FILE")
        now=$(date +%s)
        elapsed=$(( now - last_restart ))
        if [ "$elapsed" -lt "$cooldown" ]; then
            log "COOLDOWN: Last restart ${elapsed}s ago (< ${cooldown}s). Skipping."
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
    bump_restart_count
    log "ACTION: Restart complete. Cooldown set. Count today: $(read_restart_count)/$DAILY_RESTART_CAP"
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

# Echoes one of: disabled | fresh | stale
#
# Same v1 schema as heartbeat: "1 <unix_ts>". Read by Case D (silent-loop)
# to determine whether the bot has produced an outbound reply within the
# configured window.
#
# "disabled" reserved for "no signal available" — env unset or file missing —
# in which case Case D is skipped (cannot determine silent-loop without
# outbound signal).
outbound_state() {
    if [ -z "$OUTBOUND_FILE" ]; then
        echo "disabled"
        return
    fi
    if [ ! -f "$OUTBOUND_FILE" ]; then
        echo "disabled"
        return
    fi
    local schema ob_ts now age
    schema=""
    ob_ts=""
    # shellcheck disable=SC2162
    read schema ob_ts _rest < "$OUTBOUND_FILE" 2>/dev/null || true
    if [ "$schema" != "1" ]; then
        log "WARN: outbound unsupported schema '$schema' in $OUTBOUND_FILE — treating as stale"
        echo "stale"
        return
    fi
    if ! [[ "$ob_ts" =~ ^[0-9]+$ ]]; then
        log "WARN: outbound malformed timestamp '$ob_ts' in $OUTBOUND_FILE — treating as stale"
        echo "stale"
        return
    fi
    now=$(date +%s)
    age=$(( now - ob_ts ))
    if [ "$age" -gt "$SILENT_LOOP_OUTBOUND_STALE_SECONDS" ]; then
        echo "stale"
    else
        echo "fresh"
    fi
}

# Echoes the count of inbound channel markers in $1 (pane content).
# Currently matches Telegram's "← telegram · <CHATID>:" line prefix that
# the channels plugin emits. Anchored at line start (^) to avoid false
# positives from user prompt content.
count_pane_incoming() {
    local pane="$1"
    if [ -z "$pane" ]; then
        echo 0
        return
    fi
    # grep -c counts matching lines. Returns 1 when no matches under set -e,
    # so use `|| echo 0` to coerce.
    local n
    n=$(echo "$pane" | grep -cE '^← telegram · [0-9]+:' || true)
    echo "${n:-0}"
}

# Echoes "yes:<reason>" if silent-loop detected, "no:<reason>" otherwise.
#
# Args: $1 = incoming count (int)
#       $2 = outbound state (disabled|fresh|stale)
#
# Decision matrix (only fires when SILENT_LOOP_ENABLED=1):
#   incoming < threshold       -> no:below-threshold
#   outbound = disabled        -> no:no-outbound-signal (cannot determine)
#   outbound = fresh           -> no:outbound-fresh
#   outbound = stale           -> yes:incoming=N outbound-stale
detect_silent_loop() {
    local incoming="$1"
    local ob_state="$2"
    if [ "$SILENT_LOOP_ENABLED" -ne 1 ]; then
        echo "no:disabled"
        return
    fi
    if [ "$incoming" -lt "$SILENT_LOOP_INCOMING_THRESHOLD" ]; then
        echo "no:below-threshold(incoming=$incoming threshold=$SILENT_LOOP_INCOMING_THRESHOLD)"
        return
    fi
    if [ "$ob_state" = "disabled" ]; then
        echo "no:no-outbound-signal"
        return
    fi
    if [ "$ob_state" = "fresh" ]; then
        echo "no:outbound-fresh"
        return
    fi
    echo "yes:incoming=$incoming outbound-stale"
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

# --- Restart counter (per-day) ---
#
# Counter file is named with today's YYYYMMDD so it self-rotates at local
# midnight without explicit GC. Old files retain a record of past activity
# (small; no maintenance needed).

today_yyyymmdd() {
    date +%Y%m%d
}

restart_count_file() {
    echo "$LOG_DIR/.watchdog-restart-count-$(today_yyyymmdd)"
}

read_restart_count() {
    local f
    f=$(restart_count_file)
    if [ -f "$f" ]; then
        # Tolerate empty/non-numeric content; treat as 0.
        local v
        v=$(cat "$f" 2>/dev/null || echo 0)
        if [[ "$v" =~ ^[0-9]+$ ]]; then
            echo "$v"
        else
            echo 0
        fi
    else
        echo 0
    fi
}

bump_restart_count() {
    local f cur next tmp
    f=$(restart_count_file)
    cur=$(read_restart_count)
    next=$((cur + 1))
    tmp="$f.tmp"
    echo "$next" > "$tmp" && mv -f "$tmp" "$f"
}

# Echoes the cooldown (in seconds) appropriate for the given restart count
# and CAP setting. CAP=0 disables the cap entirely (always normal).
effective_cooldown() {
    local count="$1"
    if [ "$DAILY_RESTART_CAP" -le 0 ]; then
        echo "$COOLDOWN_SECONDS"
    elif [ "$count" -ge "$DAILY_RESTART_CAP" ]; then
        echo "$THROTTLED_COOLDOWN"
    else
        echo "$COOLDOWN_SECONDS"
    fi
}

# attempt_restart: cap-aware wrapper around (check_cooldown + start_claude).
# - Reads today's restart count
# - Computes the effective cooldown (normal vs throttled based on cap)
# - If cooldown allows, runs start_claude (which bumps the counter)
# - If the resulting count crosses the cap, emits a one-shot cap-reached alert
attempt_restart() {
    local count eff_cd new_count cap_msg
    count=$(read_restart_count)
    eff_cd=$(effective_cooldown "$count")
    if check_cooldown "$eff_cd"; then
        start_claude
        new_count=$(read_restart_count)
        if [ "$DAILY_RESTART_CAP" -gt 0 ] \
           && [ "$new_count" -ge "$DAILY_RESTART_CAP" ] \
           && ! alert_already_sent "cap-$(today_yyyymmdd)"; then
            cap_msg="Daily restart cap reached ($DAILY_RESTART_CAP) — throttling cooldown to ${THROTTLED_COOLDOWN}s for the rest of the day. Watchdog will continue logging status. Recovery: claude-watchdog --reset (after fixing root cause), or wait for midnight rollover."
            emit_alert cap-reached "$cap_msg"
            mark_alert_sent "cap-$(today_yyyymmdd)"
        fi
    fi
}

do_reset() {
    local today f removed=0
    today=$(today_yyyymmdd)
    for f in \
        "$LOG_DIR/.watchdog-restart-count-$today" \
        "$LOG_DIR/.watchdog-alert-sent-cap-$today" \
        "$LOG_DIR/.watchdog-alert-sent-not-logged-in" \
        "$LOG_DIR/.watchdog-alert-sent-silent-loop"; do
        if [ -e "$f" ]; then
            rm -f "$f"
            removed=$((removed + 1))
            echo "removed: $f"
        fi
    done
    if [ "$removed" -eq 0 ]; then
        echo "no state files to remove"
    fi
}

show_status() {
    local count eff_cd last_restart now elapsed remaining flag_cap flag_term flag_silent
    count=$(read_restart_count)
    eff_cd=$(effective_cooldown "$count")
    if [ -f "$COOLDOWN_FILE" ]; then
        last_restart=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
        # Tolerate corrupted cooldown file: non-numeric content → treat as 0
        # (same defensive pattern as read_restart_count). Without this, a
        # garbage cooldown file would crash --status under set -u.
        [[ "$last_restart" =~ ^[0-9]+$ ]] || last_restart=0
        now=$(date +%s)
        elapsed=$(( now - last_restart ))
        remaining=$(( eff_cd - elapsed ))
        [ "$remaining" -lt 0 ] && remaining=0
        elapsed="${elapsed}s"
        remaining="${remaining}s"
    else
        elapsed="(never)"
        remaining="0s"
    fi
    if alert_already_sent "cap-$(today_yyyymmdd)"; then
        flag_cap="set"
    else
        flag_cap="clear"
    fi
    if alert_already_sent not-logged-in; then
        flag_term="set"
    else
        flag_term="clear"
    fi
    if alert_already_sent silent-loop; then
        flag_silent="set"
    else
        flag_silent="clear"
    fi
    cat <<EOF
WATCHDOG_VERSION=$WATCHDOG_VERSION
RESTART_COUNT_TODAY=$count / $DAILY_RESTART_CAP
EFFECTIVE_COOLDOWN=${eff_cd}s
LAST_RESTART_AGE=$elapsed
NEXT_RESTART_ALLOWED_IN=$remaining
ALERT_FLAG_CAP_REACHED=$flag_cap
ALERT_FLAG_NOT_LOGGED_IN=$flag_term
ALERT_FLAG_SILENT_LOOP=$flag_silent
EOF
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
    if echo "$pane" | grep -qE -- "$pat"; then
        echo "yes:$(echo "$pane" | grep -oE -- "$pat" | head -1)"
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
    if echo "$pane" | grep -qE -- "$pat"; then
        echo "yes:$(echo "$pane" | grep -oE -- "$pat" | head -1)"
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
TERMINAL_PATTERNS=(
    "--channels ignored"
    "Channels require claude.ai authentication"
    "Not logged in"
)

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

    # --reset and --status: operator inspection commands — exit before setup_logging
    # so they don't trigger log rotation or any writes
    if [ "$DO_RESET" -eq 1 ]; then
        do_reset
        exit 0
    fi
    if [ "$SHOW_STATUS" -eq 1 ]; then
        show_status
        exit 0
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
WATCHDOG_DAILY_RESTART_CAP=$DAILY_RESTART_CAP
WATCHDOG_THROTTLED_COOLDOWN=$THROTTLED_COOLDOWN (requested=$THROTTLED_COOLDOWN_REQUESTED, floor=$HEARTBEAT_STALE_FLOOR)
WATCHDOG_SILENT_LOOP_ENABLED=$SILENT_LOOP_ENABLED
WATCHDOG_OUTBOUND_FILE=$OUTBOUND_FILE
WATCHDOG_SILENT_LOOP_INCOMING_THRESHOLD=$SILENT_LOOP_INCOMING_THRESHOLD
WATCHDOG_SILENT_LOOP_OUTBOUND_STALE_SECONDS=$SILENT_LOOP_OUTBOUND_STALE_SECONDS (requested=$SILENT_LOOP_OUTBOUND_STALE_REQUESTED, floor=$HEARTBEAT_STALE_FLOOR)
WATCHDOG_SILENT_LOOP_PANE_LINES=$SILENT_LOOP_PANE_LINES
RESTART_COUNT_TODAY=$(read_restart_count)
LOG_FILE=$LOG_FILE
COOLDOWN_FILE=$COOLDOWN_FILE
EOF
        exit 0
    fi

    setup_logging

    # Case A: tmux session does not exist
    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        log "DETECT: tmux session '$TMUX_SESSION' not found"
        attempt_restart
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

    # Terminal-state branch: orthogonal to restart logic. If we detect a
    # state restart cannot recover from (e.g. Not logged in), emit a
    # one-shot alert and let the user fix it manually. Dedup via flag file
    # that's cleared when the symptom disappears.
    TERMINAL_MATCH=$(detect_terminal_state "$PANE_OUTPUT")
    if [ "${TERMINAL_MATCH%%:*}" = "yes" ]; then
        if ! alert_already_sent not-logged-in; then
            local terminal_msg
            terminal_msg="Claude Code is not logged in (TUI shows: ${TERMINAL_MATCH#*:}). Restart cannot fix — needs interactive /login. Recovery: ssh into host, tmux attach -t $TMUX_SESSION, then run /login."
            emit_alert not-logged-in "$terminal_msg"
            mark_alert_sent not-logged-in
        else
            log "INFO: terminal-state '${TERMINAL_MATCH#*:}' still present (alert already sent — silent until cleared)"
        fi
    else
        if alert_already_sent not-logged-in; then
            log "INFO: terminal-state cleared — removing alert flag"
            clear_alert_flag not-logged-in
        fi
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
        attempt_restart
        exit 0
    fi

    # Case C: tmux session exists but claude process died
    PANE_PID=$(tmux display-message -t "$TMUX_SESSION" -p '#{pane_pid}')
    if ! pgrep -P "$PANE_PID" -f "claude" >/dev/null 2>&1; then
        log "DETECT: No claude process found in tmux session (pane_pid=$PANE_PID)"
        attempt_restart
        exit 0
    fi

    # Case D: silent-loop (opt-in via WATCHDOG_SILENT_LOOP_ENABLED=1)
    # Distinguishes (a) genuinely idle bot from (b) bot consuming inputs but
    # not producing outbound replies. Alert only — never restart (root cause
    # is typically SKILL.md instruction-leak which restart cannot fix).
    INCOMING_COUNT=$(count_pane_incoming "$PANE_OUTPUT")
    OB_STATE=$(outbound_state)
    SILENT_RESULT=$(detect_silent_loop "$INCOMING_COUNT" "$OB_STATE")
    if [ "${SILENT_RESULT%%:*}" = "yes" ]; then
        if ! alert_already_sent silent-loop; then
            local silent_msg
            silent_msg="Silent loop detected: ${SILENT_RESULT#*:}. Bot pane shows incoming channel messages but no outbound reply within ${SILENT_LOOP_OUTBOUND_STALE_SECONDS}s. Restart will NOT fix (root cause typically SKILL.md instruction-leak). Recovery: ssh into host, tmux capture-pane -t $TMUX_SESSION, inspect skill behavior."
            emit_alert silent-loop "$silent_msg"
            mark_alert_sent silent-loop
        else
            log "INFO: silent-loop still present (${SILENT_RESULT#*:}, alert already sent — silent until cleared)"
        fi
    else
        if alert_already_sent silent-loop; then
            log "INFO: silent-loop cleared (${SILENT_RESULT#*:}) — removing alert flag"
            clear_alert_flag silent-loop
        fi
        # Only log the no-detection state when enabled (avoid log spam when default-disabled)
        if [ "$SILENT_LOOP_ENABLED" -eq 1 ]; then
            log "INFO: silent-loop check: ${SILENT_RESULT#*:}"
        fi
    fi

    if [ "$SILENT_LOOP_ENABLED" -eq 1 ]; then
        log "OK: Session alive, no stuck patterns detected (silent-loop: ${SILENT_RESULT##*:})"
    else
        log "OK: Session alive, no stuck patterns detected"
    fi
    exit 0
}

# Source-guard: only run main when this script is executed, not sourced.
# When sourced (e.g. by tests), config is set and functions are defined,
# but main() is not invoked.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
    main "$@"
fi
