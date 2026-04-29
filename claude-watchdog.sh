#!/bin/bash
# Claude Code Watchdog — detects stuck sessions and restarts
# https://github.com/BananaBay69/claude-code-watchdog

set -euo pipefail

WATCHDOG_VERSION="0.1.9"

# --- CLI flag parsing ---
# parse_args() handles --help / --version / --show-config / --config <file>.
# Called from main() — when sourced, args are not parsed.

SHOW_CONFIG=0
CONFIG_FILE=""
DO_RESET=0
SHOW_STATUS=0
DO_SNAPSHOT=0

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
    claude-watchdog.sh --snapshot         Capture a diagnostic snapshot now (independent of detection state)

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
    WATCHDOG_SILENT_LOOP_RECOVERY         action on silent-loop detection
                                          (disabled|snapshot-only|soft|aggressive; default: disabled)
    WATCHDOG_SNAPSHOT_RETAIN_COUNT        max snapshot directories to keep, FIFO (default: 20)
    WATCHDOG_LOG_LEVEL                    threshold for log() output
                                          (DEBUG|INFO|WARN|ERROR; default: INFO)
                                          Lines below threshold are suppressed.
                                          ALERT [type]: lines bypass threshold (always written).
                                          Unknown values fall back to INFO with one-time WARN.
                                          Semantic prefixes map to INFO; ALERT bypasses
                                          (OK/DETECT/ACTION/COOLDOWN treated as INFO bucket).

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
            --snapshot)
                DO_SNAPSHOT=1
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                _log_error_pre_setup "unknown argument '$1'"
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

    # v0.1.8: silent-loop recovery dispatch + snapshot retention
    # Unknown / empty values are tolerated here; the dispatcher emits a WARN
    # and falls back to disabled. Validation deferred to runtime so config
    # parsing has no side effects requiring $LOG_DIR.
    SILENT_LOOP_RECOVERY="${WATCHDOG_SILENT_LOOP_RECOVERY:-disabled}"
    SNAPSHOT_RETAIN_COUNT="${WATCHDOG_SNAPSHOT_RETAIN_COUNT:-20}"
    # Floor at 1 — operator who passes 0 or negative would otherwise lose all snapshots
    if ! [ "$SNAPSHOT_RETAIN_COUNT" -ge 1 ] 2>/dev/null; then
        SNAPSHOT_RETAIN_COUNT=20
    fi

    SNAPSHOT_DIR="$LOG_DIR/snapshots"

    # v0.1.9: log level threshold (WATCHDOG_LOG_LEVEL env var only — no CLI flag).
    # Unknown values resolve to INFO and trigger a one-time WARN at first log() call.
    # See specs/structured-logging/spec.md for the full prefix-to-level mapping.
    local _input_level="${WATCHDOG_LOG_LEVEL:-INFO}"
    LOG_LEVEL_FALLBACK_FROM=""
    case "$_input_level" in
        DEBUG)  LOG_LEVEL_THRESHOLD=10; LOG_LEVEL_EFFECTIVE=DEBUG ;;
        INFO)   LOG_LEVEL_THRESHOLD=20; LOG_LEVEL_EFFECTIVE=INFO ;;
        WARN)   LOG_LEVEL_THRESHOLD=30; LOG_LEVEL_EFFECTIVE=WARN ;;
        ERROR)  LOG_LEVEL_THRESHOLD=40; LOG_LEVEL_EFFECTIVE=ERROR ;;
        *)      LOG_LEVEL_THRESHOLD=20
                LOG_LEVEL_EFFECTIVE=INFO
                LOG_LEVEL_FALLBACK_FROM="$_input_level"
                ;;
    esac
    # Reset emit-once flag (re-source / --config re-init scenarios).
    LOG_LEVEL_FALLBACK_EMITTED=""

    # Detect a `timeout` command for sub-capture wrapping. Coreutils provides
    # gtimeout on macOS via brew. If neither exists, sub-captures run unwrapped
    # — acceptable degradation for diagnostic snapshots.
    if command -v gtimeout >/dev/null 2>&1; then
        SNAPSHOT_TIMEOUT_CMD="gtimeout"
    elif command -v timeout >/dev/null 2>&1; then
        SNAPSHOT_TIMEOUT_CMD="timeout"
    else
        SNAPSHOT_TIMEOUT_CMD=""
    fi
}

# Top-level: populate globals from current env so sourcing the script works
# for tests.  main() will re-call init_config after --config file source so
# file overrides take effect.
init_config

# --- Helpers ---

_log_level_passes() {
    # Returns 0 if the level passes threshold, 1 if suppressed.
    # Semantic flavours (OK/DETECT/ACTION/COOLDOWN) map to INFO bucket.
    local level="$1"
    local ordinal
    case "$level" in
        DEBUG) ordinal=10 ;;
        INFO|OK|DETECT|ACTION|COOLDOWN) ordinal=20 ;;
        WARN) ordinal=30 ;;
        ERROR) ordinal=40 ;;
        *) ordinal=20 ;;  # unknown → INFO bucket (defensive)
    esac
    [ "$ordinal" -ge "$LOG_LEVEL_THRESHOLD" ]
}

log() {
    # One-time fallback WARN — emitted before the actual line, ignores threshold.
    # Operator who typoed WATCHDOG_LOG_LEVEL must always see this notice.
    if [ -n "${LOG_LEVEL_FALLBACK_FROM:-}" ] && [ -z "${LOG_LEVEL_FALLBACK_EMITTED:-}" ]; then
        LOG_LEVEL_FALLBACK_EMITTED=1
        echo "$(date '+%Y-%m-%d %H:%M:%S') WARN: WATCHDOG_LOG_LEVEL='$LOG_LEVEL_FALLBACK_FROM' invalid — falling back to INFO" >> "$LOG_FILE"
    fi

    local msg="$1"
    case "$msg" in
        "ALERT ["*)
            : # ALERT messages always pass — alert dedup state machine relies on visibility
            ;;
        *)
            local level=INFO
            # ^[A-Z]+: extracts the leading token; case-sensitive by design.
            # Lowercase 'alert' or arbitrary text → no match → defaults to INFO.
            # Use bash regex to avoid pipefail issues from grep returning empty.
            if [[ "$msg" =~ ^([A-Z]+): ]]; then
                level="${BASH_REMATCH[1]}"
            fi
            _log_level_passes "$level" || return 0
            ;;
    esac
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$LOG_FILE"
}

# log_at LEVEL "msg" — explicit-form helper for callers where level is variable.
# Internally delegates to log() so threshold + ALERT bypass + fallback behave identically.
log_at() {
    local level="$1"
    local msg="$2"
    log "$level: $msg"
}

# _log_error_pre_setup — Option A pre-LOG_DIR error mirror.
# Used by parse_args / config error paths that fire BEFORE setup_logging.
# init_config (top-level) populates $LOG_DIR; only the directory itself may
# be missing. We mkdir + append directly without touching log rotation. If
# mkdir fails (e.g. read-only parent), silently degrade — stderr still has
# the operator-facing message and exit code is preserved. No regression vs.
# v0.1.8: stderr-only behaviour is the lower bound, never lost.
_log_error_pre_setup() {
    local msg="$1"
    if mkdir -p "$LOG_DIR" 2>/dev/null; then
        printf '%s ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE" 2>/dev/null || :
    fi
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
    # v0.1.9: don't silently swallow rc; non-zero is expected when session is
    # already gone (Case A path), but we still want operator visibility.
    local _kill_rc=0
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || _kill_rc=$?
    if [ "$_kill_rc" -ne 0 ]; then
        log "DEBUG: kill-session no-op (rc=$_kill_rc, session likely already gone)"
    fi
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
    # v0.1.9: distinguish read failure (I/O / permissions) from malformed schema
    # (handled in the next branch). Read failure deserves a WARN — operator may
    # need to fix file permissions.
    if ! read schema hb_ts _rest < "$HEARTBEAT_FILE" 2>/dev/null; then
        log "WARN: heartbeat read failed (file exists but I/O error or permission denied): $HEARTBEAT_FILE"
        echo "stale"
        return
    fi
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
    # v0.1.9: same I/O-vs-malformed split as heartbeat_state.
    if ! read schema ob_ts _rest < "$OUTBOUND_FILE" 2>/dev/null; then
        log "WARN: outbound read failed (file exists but I/O error or permission denied): $OUTBOUND_FILE"
        echo "stale"
        return
    fi
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
        # v0.1.9: distinguish "file unreadable" (perm error → WARN) from
        # "file empty" (legit edge case → silent fall-through to 0).
        local v _cat_rc=0
        v=$(cat "$f" 2>/dev/null) || _cat_rc=$?
        if [ "$_cat_rc" -ne 0 ]; then
            log "WARN: restart-count file unreadable (rc=$_cat_rc, treating as 0): $f"
            v=0
        fi
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
    # v0.1.9: audit log — operator state-mutating intervention.
    # setup_logging ensures LOG_DIR exists for the log() append.
    setup_logging
    log "INFO: operator: --reset (cleared $removed flags)"
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

# --- v0.1.8: snapshot capture + retention + recovery dispatch ---
#
# take_snapshot creates a directory under $SNAPSHOT_DIR with diagnostic files
# (pane content, watchdog status, env, recent log, active SKILL.md mtimes,
# metadata.json). Each sub-capture is wrapped by `_snapshot_capture` which
# applies a 5-second timeout when available and tolerates partial failure
# (logs WARN, removes the failed file, continues with remaining captures).
# Echoes the absolute snapshot directory path on stdout. Returns 0 even if
# some sub-captures failed (partial-snapshot semantics); returns non-zero
# only when the snapshot directory itself cannot be created.

_snapshot_capture() {
    # Args: $1=outfile $2=display_name $3..=command [args...]
    local outfile="$1" name="$2" rc=0
    shift 2
    if [ -n "${SNAPSHOT_TIMEOUT_CMD:-}" ]; then
        "$SNAPSHOT_TIMEOUT_CMD" 5 "$@" > "$outfile" 2>&1 || rc=$?
    else
        "$@" > "$outfile" 2>&1 || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        # v0.1.9: include first ~3 lines of captured stderr so operator can
        # diagnose without re-running. Reuses emit_alert's snippet pattern.
        local snippet=""
        if [ -s "$outfile" ]; then
            snippet=$(head -3 "$outfile" | tr '\n' ' ')
            snippet="${snippet% }"
        fi
        if [ -n "$snippet" ]; then
            log "WARN: snapshot $name failed (exit=$rc): $snippet"
        else
            log "WARN: snapshot $name failed (exit=$rc, no stderr captured)"
        fi
        rm -f "$outfile"
        return 1
    fi
    return 0
}

# prune_old_snapshots removes oldest silent-loop-* directories under
# $SNAPSHOT_DIR until at most $SNAPSHOT_RETAIN_COUNT - 1 remain, leaving
# room for one new snapshot. Sorts by directory name (timestamp-sortable).
# No-op if the snapshots dir does not yet exist.
prune_old_snapshots() {
    [ -d "$SNAPSHOT_DIR" ] || return 0
    local target=$(( SNAPSHOT_RETAIN_COUNT - 1 ))
    [ "$target" -lt 0 ] && target=0
    # List existing snapshot dirs sorted oldest-first
    # shellcheck disable=SC2207
    local dirs=( $(find "$SNAPSHOT_DIR" -maxdepth 1 -mindepth 1 -type d -name 'silent-loop-*' 2>/dev/null | sort) )
    local count=${#dirs[@]}
    while [ "$count" -gt "$target" ]; do
        local oldest="${dirs[0]}"
        # Defensive: never rm outside $SNAPSHOT_DIR (case "$oldest" must start with $SNAPSHOT_DIR/silent-loop-)
        case "$oldest" in
            "$SNAPSHOT_DIR/silent-loop-"*)
                rm -rf "$oldest"
                ;;
            *)
                log "WARN: prune_old_snapshots refused to remove unexpected path: $oldest"
                ;;
        esac
        dirs=( "${dirs[@]:1}" )
        count=${#dirs[@]}
    done
}

# take_snapshot [incoming=0]
# Creates one snapshot directory; echoes absolute path on stdout.
take_snapshot() {
    local incoming="${1:-0}"
    local ts dir captured_at outbound_age

    prune_old_snapshots

    ts=$(date '+%Y%m%d%H%M%S')
    dir="$SNAPSHOT_DIR/silent-loop-$ts"

    if ! mkdir -p "$dir"; then
        log "ERROR: snapshot mkdir failed: $dir"
        return 1
    fi

    captured_at=$(date '+%Y-%m-%dT%H:%M:%S%z')

    # Compute outbound age in seconds (0 if file missing/disabled/malformed).
    outbound_age=0
    if [ -n "${OUTBOUND_FILE:-}" ] && [ -f "$OUTBOUND_FILE" ]; then
        local schema ob_ts _rest now mtime_age
        # Best-effort parse of "1 <unix_ts>\n" schema; fall back to mtime.
        # shellcheck disable=SC2034
        if read -r schema ob_ts _rest < "$OUTBOUND_FILE" 2>/dev/null && \
           [ "$schema" = "1" ] && \
           [ "$ob_ts" -eq "$ob_ts" ] 2>/dev/null; then
            now=$(date +%s)
            outbound_age=$(( now - ob_ts ))
            [ "$outbound_age" -lt 0 ] && outbound_age=0
        else
            # Fall back to file mtime
            now=$(date +%s)
            mtime_age=$(stat -f%m "$OUTBOUND_FILE" 2>/dev/null || echo "$now")
            outbound_age=$(( now - mtime_age ))
            [ "$outbound_age" -lt 0 ] && outbound_age=0
        fi
    fi

    # pane.txt: full pane history (last 2000 lines)
    _snapshot_capture "$dir/pane.txt" "pane.txt" \
        tmux capture-pane -t "$TMUX_SESSION" -p -S -2000 || true

    # status.txt: re-invoke this script with --status. ${BASH_SOURCE[0]:-$0}
    # works under both `bash script.sh` and `. script.sh` execution.
    local self="${BASH_SOURCE[0]:-$0}"
    _snapshot_capture "$dir/status.txt" "status.txt" \
        bash "$self" --status || true

    # env.txt: WATCHDOG_* env, tmux ls, pgrep claude
    {
        env | grep '^WATCHDOG_' | sort
        echo "---"
        echo "# tmux ls"
        tmux ls 2>&1 || true
        echo "---"
        echo "# pgrep -lf claude"
        pgrep -lf claude 2>&1 || true
    } > "$dir/env.txt" 2>&1 || log "WARN: snapshot env.txt failed"

    # recent-log.txt: last 200 lines of watchdog log
    if [ -f "$LOG_FILE" ]; then
        tail -200 "$LOG_FILE" > "$dir/recent-log.txt" 2>/dev/null || \
            log "WARN: snapshot recent-log.txt failed"
    else
        : > "$dir/recent-log.txt"
    fi

    # active-skills.txt: list ~/.claude/plugins/**/skills/*.md path + ISO mtime.
    # NEVER include file content (may be large or contain secrets).
    {
        if [ -d "$HOME/.claude/plugins" ]; then
            find "$HOME/.claude/plugins" -path '*/skills/*.md' -type f 2>/dev/null \
                | while IFS= read -r f; do
                    local mt
                    mt=$(stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S%z' "$f" 2>/dev/null || echo "?")
                    printf '%s\t%s\n' "$mt" "$f"
                done | sort -r
        fi
    } > "$dir/active-skills.txt" 2>&1 || log "WARN: snapshot active-skills.txt failed"

    # metadata.json: hand-built (jq optional, may not be installed)
    cat > "$dir/metadata.json" <<METAJSON
{
  "captured_at": "$captured_at",
  "silent_loop_state": {
    "incoming": $incoming,
    "outbound_age_seconds": $outbound_age
  },
  "watchdog_version": "$WATCHDOG_VERSION"
}
METAJSON

    echo "$dir"
    return 0
}

# recovery_driver dispatches silent-loop recovery action based on
# $SILENT_LOOP_RECOVERY. Echoes snapshot path on stdout when a snapshot
# is taken (snapshot-only mode); echoes empty otherwise.
# Args: $1 = incoming count
recovery_driver() {
    local incoming="${1:-0}"
    case "$SILENT_LOOP_RECOVERY" in
        snapshot-only)
            take_snapshot "$incoming"
            ;;
        soft)
            log "WARN: soft mode requested but not implemented"
            ;;
        aggressive)
            log "WARN: aggressive mode requested but not implemented"
            ;;
        disabled|"")
            : # no-op
            ;;
        *)
            log "WARN: unknown WATCHDOG_SILENT_LOOP_RECOVERY value '$SILENT_LOOP_RECOVERY' — falling back to disabled"
            ;;
    esac
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
            _log_error_pre_setup "config file not found: $CONFIG_FILE"
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

    # --snapshot: manual diagnostic capture, independent of detection state.
    # MUST NOT consult or modify the alert dedup flag. Sets up logging first
    # so take_snapshot's WARN lines (if any) land in the watchdog log.
    if [ "$DO_SNAPSHOT" -eq 1 ]; then
        setup_logging
        local _snap_path
        if _snap_path=$(take_snapshot 0); then
            # v0.1.9: audit log — operator artifact-creating intervention.
            log "INFO: operator: --snapshot (path: $_snap_path)"
            exit 0
        else
            log "ERROR: operator: --snapshot failed"
            exit 1
        fi
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
WATCHDOG_LOG_LEVEL=$LOG_LEVEL_EFFECTIVE${LOG_LEVEL_FALLBACK_FROM:+ (requested='$LOG_LEVEL_FALLBACK_FROM' invalid → fell back to INFO)}
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
            local silent_msg snapshot_path
            silent_msg="Silent loop detected: ${SILENT_RESULT#*:}. Bot pane shows incoming channel messages but no outbound reply within ${SILENT_LOOP_OUTBOUND_STALE_SECONDS}s. Restart will NOT fix (root cause typically SKILL.md instruction-leak). Recovery: ssh into host, tmux capture-pane -t $TMUX_SESSION, inspect skill behavior."
            # v0.1.8: invoke recovery dispatcher; snapshot-only mode echoes
            # snapshot dir on stdout. Append to alert msg only when a snapshot
            # was actually produced (not for disabled/soft/aggressive/unknown).
            snapshot_path=$(recovery_driver "$INCOMING_COUNT")
            if [ -n "$snapshot_path" ]; then
                silent_msg="$silent_msg Snapshot: $snapshot_path"
            fi
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
