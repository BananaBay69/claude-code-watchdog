#!/bin/bash
# Integration: --reset clears today's counter + both alert flags.
set -e
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/test/lib/assert.sh"

LOG_DIR="$TEST_DIR/log"
mkdir -p "$LOG_DIR"
TODAY=$(date +%Y%m%d)

# Pre-populate state files
echo 5 > "$LOG_DIR/.watchdog-restart-count-$TODAY"
: > "$LOG_DIR/.watchdog-alert-sent-cap-$TODAY"
: > "$LOG_DIR/.watchdog-alert-sent-not-logged-in"
echo 1234567890 > "$LOG_DIR/.watchdog-last-restart"  # should be PRESERVED

WATCHDOG_LOG_DIR="$LOG_DIR" \
WATCHDOG_HEARTBEAT_FILE="" \
bash "$ROOT/claude-watchdog.sh" --reset

assert_file_missing "$LOG_DIR/.watchdog-restart-count-$TODAY" "counter cleared"
assert_file_missing "$LOG_DIR/.watchdog-alert-sent-cap-$TODAY" "cap flag cleared"
assert_file_missing "$LOG_DIR/.watchdog-alert-sent-not-logged-in" "terminal flag cleared"
assert_file_exists "$LOG_DIR/.watchdog-last-restart" "cooldown marker preserved"

# Run --reset on already-clean dir — should not error
WATCHDOG_LOG_DIR="$LOG_DIR" \
WATCHDOG_HEARTBEAT_FILE="" \
output=$(bash "$ROOT/claude-watchdog.sh" --reset)

if ! echo "$output" | grep -q "no state files to remove"; then
    echo "FAIL: idempotent --reset should report 'no state files to remove'" >&2
    echo "  got: $output" >&2
    exit 1
fi

echo OK
