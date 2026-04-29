#!/bin/bash
# Unit test: log_at LEVEL "msg" matches log "LEVEL: msg" exactly,
# and respects the same threshold.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# shellcheck source=../lib/assert.sh
. "$SCRIPT_DIR/../lib/assert.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# === Case 1: log_at WARN writes the same shape as log "WARN: ..." at INFO threshold ===
WATCHDOG_LOG_LEVEL=INFO \
WATCHDOG_LOG_DIR="$TMPDIR/c1" \
WATCHDOG_HEARTBEAT_FILE="" \
. "$ROOT/claude-watchdog.sh"
mkdir -p "$LOG_DIR"
: > "$LOG_FILE"

log_at WARN "alert command exited 7"
log "WARN: control message"

# Both lines should appear; both should have the timestamp + WARN: prefix
assert_file_contains "$LOG_FILE" "WARN: alert command exited 7" "case1: log_at WARN renders identically"
assert_file_contains "$LOG_FILE" "WARN: control message" "case1: log control"

# Both timestamps follow YYYY-MM-DD HH:MM:SS pattern
n=$(grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} WARN: ' "$LOG_FILE" || echo 0)
[ "$n" = "2" ] || { echo "FAIL case1: expected 2 timestamped WARN lines, got $n"; cat "$LOG_FILE"; exit 1; }

# === Case 2: log_at uses same threshold (suppressed at ERROR) ===
WATCHDOG_LOG_LEVEL=ERROR \
WATCHDOG_LOG_DIR="$TMPDIR/c2" \
WATCHDOG_HEARTBEAT_FILE="" \
. "$ROOT/claude-watchdog.sh"
mkdir -p "$LOG_DIR"
: > "$LOG_FILE"

log_at INFO "operator: --reset cleared 2 flags"
log_at WARN "still suppressed"
log_at ERROR "this passes"

assert_file_lacks "$LOG_FILE" "operator: --reset" "case2: log_at INFO suppressed at ERROR threshold"
assert_file_lacks "$LOG_FILE" "still suppressed"  "case2: log_at WARN suppressed at ERROR threshold"
assert_file_contains "$LOG_FILE" "ERROR: this passes" "case2: log_at ERROR visible"

# === Case 3: log_at semantic-flavour levels (OK/DETECT/ACTION/COOLDOWN) match log() behavior ===
WATCHDOG_LOG_LEVEL=WARN \
WATCHDOG_LOG_DIR="$TMPDIR/c3" \
WATCHDOG_HEARTBEAT_FILE="" \
. "$ROOT/claude-watchdog.sh"
mkdir -p "$LOG_DIR"
: > "$LOG_FILE"

log_at OK "session alive"
log_at WARN "explicit warning"

assert_file_lacks "$LOG_FILE" "OK: session alive" "case3: log_at OK suppressed at WARN (maps to INFO bucket)"
assert_file_contains "$LOG_FILE" "WARN: explicit warning" "case3: log_at WARN visible"

echo "PASS: log_at helper matches log() shape and threshold"
