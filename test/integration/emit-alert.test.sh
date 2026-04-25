#!/bin/bash
# Integration: WATCHDOG_ALERT_CMD invocation passes correct env vars.
set -e
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/test/lib/assert.sh"

LOG_DIR="$TEST_DIR/log"
mkdir -p "$LOG_DIR"

# An alert command that captures env vars to a file
ALERT_CAPTURE="$TEST_DIR/captured.env"
ALERT_CMD="env | grep -E '^WATCHDOG_ALERT_(TYPE|MSG)=' | sort > $ALERT_CAPTURE"

# Source watchdog to access emit_alert directly
WATCHDOG_LOG_DIR="$LOG_DIR" \
WATCHDOG_HEARTBEAT_FILE="" \
WATCHDOG_ALERT_CMD="$ALERT_CMD" \
bash -c "
set -e
. '$ROOT/claude-watchdog.sh'
setup_logging
emit_alert demo-type 'demo message with spaces and special chars'
"

# Verify env vars were passed
assert_file_exists "$ALERT_CAPTURE" "alert command should have run"
assert_file_contains "$ALERT_CAPTURE" "^WATCHDOG_ALERT_MSG=demo message with spaces and special chars$" "msg passed correctly"
assert_file_contains "$ALERT_CAPTURE" "^WATCHDOG_ALERT_TYPE=demo-type$" "type passed correctly"

# Verify ALERT line in log
assert_file_contains "$LOG_DIR/claude-watchdog.log" "ALERT \[demo-type\]: demo message" "ALERT line written"

# Verify failure handling: ALERT_CMD that exits non-zero shouldn't break watchdog
WATCHDOG_LOG_DIR="$LOG_DIR" \
WATCHDOG_HEARTBEAT_FILE="" \
WATCHDOG_ALERT_CMD="exit 7" \
bash -c "
set -e
. '$ROOT/claude-watchdog.sh'
setup_logging
emit_alert fail-type 'should not crash'
echo 'after emit_alert (script still alive)'
" > "$TEST_DIR/run.out" 2>&1

assert_file_contains "$TEST_DIR/run.out" "after emit_alert" "emit_alert must not propagate failure under set -e"
assert_file_contains "$LOG_DIR/claude-watchdog.log" "WARN: alert command exited 7" "WARN logged"

echo OK
