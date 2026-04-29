#!/bin/bash
# Unit test: log() honors WATCHDOG_LOG_LEVEL threshold via prefix parsing.
# Covers spec scenarios:
#   - default INFO suppresses DEBUG
#   - DEBUG threshold passes everything
#   - ERROR threshold suppresses lower levels
#   - unknown threshold falls back to INFO with one-time WARN
#   - OK/DETECT/ACTION/COOLDOWN map to INFO bucket
#   - prefix-less message defaults to INFO
#   - ALERT bypasses threshold (case-sensitive)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# shellcheck source=../lib/assert.sh
. "$SCRIPT_DIR/../lib/assert.sh"

# Helper: source script with given log level, then assert behavior
source_at_level() {
    local level="$1"
    local logdir="$2"
    # Reset module state for fresh source. We unset and re-set then re-source.
    # shellcheck disable=SC2034
    LOG_LEVEL_FALLBACK_EMITTED=
    if [ -n "$level" ]; then
        WATCHDOG_LOG_LEVEL="$level" \
        WATCHDOG_LOG_DIR="$logdir" \
        WATCHDOG_HEARTBEAT_FILE="" \
        . "$ROOT/claude-watchdog.sh"
    else
        unset WATCHDOG_LOG_LEVEL
        WATCHDOG_LOG_DIR="$logdir" \
        WATCHDOG_HEARTBEAT_FILE="" \
        . "$ROOT/claude-watchdog.sh"
    fi
    mkdir -p "$LOG_DIR"
    : > "$LOG_FILE"  # truncate
}

# === Case 1: default INFO suppresses DEBUG ===
TMPDIR=$(mktemp -d)
source_at_level "" "$TMPDIR/c1"
log "DEBUG: kill-session no-op"
log "INFO: should appear"
assert_file_lacks "$LOG_FILE" "DEBUG: kill-session" "case1: DEBUG should be suppressed at default INFO threshold"
assert_file_contains "$LOG_FILE" "INFO: should appear" "case1: INFO should pass at default threshold"
rm -rf "$TMPDIR"

# === Case 2: DEBUG threshold passes everything ===
TMPDIR=$(mktemp -d)
source_at_level "DEBUG" "$TMPDIR/c2"
log "DEBUG: foo"
log "INFO: bar"
log "WARN: baz"
log "ERROR: qux"
assert_file_contains "$LOG_FILE" "DEBUG: foo"  "case2: DEBUG visible at DEBUG threshold"
assert_file_contains "$LOG_FILE" "INFO: bar"   "case2: INFO visible"
assert_file_contains "$LOG_FILE" "WARN: baz"   "case2: WARN visible"
assert_file_contains "$LOG_FILE" "ERROR: qux"  "case2: ERROR visible"
rm -rf "$TMPDIR"

# === Case 3: ERROR threshold suppresses INFO/WARN ===
TMPDIR=$(mktemp -d)
source_at_level "ERROR" "$TMPDIR/c3"
log "INFO: x"
log "WARN: y"
log "ERROR: z"
assert_file_lacks "$LOG_FILE" "INFO: x" "case3: INFO suppressed at ERROR"
assert_file_lacks "$LOG_FILE" "WARN: y" "case3: WARN suppressed at ERROR"
assert_file_contains "$LOG_FILE" "ERROR: z" "case3: ERROR visible"
rm -rf "$TMPDIR"

# === Case 4: unknown threshold falls back to INFO + one-time WARN ===
TMPDIR=$(mktemp -d)
source_at_level "verbose" "$TMPDIR/c4"
log "INFO: first call"
log "INFO: second call"
log "INFO: third call"
# fallback WARN should appear exactly once
n=$(grep -c "invalid — falling back to INFO" "$LOG_FILE" || echo 0)
[ "$n" = "1" ] || { echo "FAIL case4: expected 1 fallback WARN line, got $n"; cat "$LOG_FILE"; exit 1; }
assert_file_contains "$LOG_FILE" "WATCHDOG_LOG_LEVEL='verbose' invalid" "case4: fallback WARN mentions invalid value"
assert_file_contains "$LOG_FILE" "INFO: first call" "case4: INFO calls still pass after fallback"
rm -rf "$TMPDIR"

# === Case 5: OK at INFO threshold writes (semantic-flavour mapping) ===
TMPDIR=$(mktemp -d)
source_at_level "INFO" "$TMPDIR/c5"
log "OK: Session alive"
log "DETECT: stuck pattern"
log "ACTION: restarting"
log "COOLDOWN: 300s"
assert_file_contains "$LOG_FILE" "OK: Session alive" "case5: OK maps to INFO bucket"
assert_file_contains "$LOG_FILE" "DETECT: stuck"     "case5: DETECT maps to INFO"
assert_file_contains "$LOG_FILE" "ACTION: restart"   "case5: ACTION maps to INFO"
assert_file_contains "$LOG_FILE" "COOLDOWN: 300s"    "case5: COOLDOWN maps to INFO"
rm -rf "$TMPDIR"

# === Case 6: ACTION at WARN threshold suppressed ===
TMPDIR=$(mktemp -d)
source_at_level "WARN" "$TMPDIR/c6"
log "ACTION: Killing tmux session"
log "WARN: heartbeat malformed"
assert_file_lacks "$LOG_FILE" "ACTION: Killing" "case6: ACTION suppressed at WARN threshold"
assert_file_contains "$LOG_FILE" "WARN: heartbeat" "case6: WARN visible"
rm -rf "$TMPDIR"

# === Case 7: prefix-less message defaults to INFO (suppressed at WARN) ===
TMPDIR=$(mktemp -d)
source_at_level "WARN" "$TMPDIR/c7"
log "Session restarted by operator"
log "WARN: explicit warning"
assert_file_lacks "$LOG_FILE" "Session restarted" "case7: prefix-less defaults to INFO, suppressed at WARN"
assert_file_contains "$LOG_FILE" "WARN: explicit warning" "case7: WARN visible"
rm -rf "$TMPDIR"

# === Case 8: ALERT bypasses threshold (always written) ===
TMPDIR=$(mktemp -d)
source_at_level "ERROR" "$TMPDIR/c8"
log "ALERT [silent-loop]: incoming=7 outbound-stale"
log "INFO: should be suppressed"
assert_file_contains "$LOG_FILE" "ALERT \[silent-loop\]" "case8: ALERT bypasses ERROR threshold"
assert_file_lacks "$LOG_FILE" "INFO: should be suppressed" "case8: INFO still suppressed"
rm -rf "$TMPDIR"

# === Case 9: lowercase 'alert' is treated as prefix-less → INFO bucket → suppressed at WARN ===
TMPDIR=$(mktemp -d)
source_at_level "WARN" "$TMPDIR/c9"
log "alert [foo]: lowercase typo"
assert_file_lacks "$LOG_FILE" "alert \[foo\]" "case9: lowercase alert does NOT bypass (case-sensitive)"
rm -rf "$TMPDIR"

echo "PASS: log-level-threshold covers all 9 scenarios"
