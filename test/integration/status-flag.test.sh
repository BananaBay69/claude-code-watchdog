#!/bin/bash
# Integration: --status outputs sensible fields under various states.
set -e
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/test/lib/assert.sh"

LOG_DIR="$TEST_DIR/log"
mkdir -p "$LOG_DIR"
TODAY=$(date +%Y%m%d)

# --- empty state ---
output=$(WATCHDOG_LOG_DIR="$LOG_DIR" \
         WATCHDOG_HEARTBEAT_FILE="" \
         bash "$ROOT/claude-watchdog.sh" --status)

echo "$output" | grep -q "RESTART_COUNT_TODAY=0 / 10" || {
    echo "FAIL: empty state should show 0/10"; echo "$output"; exit 1
}
echo "$output" | grep -q "EFFECTIVE_COOLDOWN=300s" || {
    echo "FAIL: empty state should show 300s cooldown"; echo "$output"; exit 1
}
echo "$output" | grep -q "ALERT_FLAG_CAP_REACHED=clear" || {
    echo "FAIL: empty state should show cap flag clear"; echo "$output"; exit 1
}
echo "$output" | grep -q "ALERT_FLAG_NOT_LOGGED_IN=clear" || {
    echo "FAIL: empty state should show terminal flag clear"; echo "$output"; exit 1
}

# --- active state: at cap with both flags set ---
echo 10 > "$LOG_DIR/.watchdog-restart-count-$TODAY"
echo $(($(date +%s) - 600)) > "$LOG_DIR/.watchdog-last-restart"
: > "$LOG_DIR/.watchdog-alert-sent-cap-$TODAY"
: > "$LOG_DIR/.watchdog-alert-sent-not-logged-in"

output=$(WATCHDOG_LOG_DIR="$LOG_DIR" \
         WATCHDOG_HEARTBEAT_FILE="" \
         bash "$ROOT/claude-watchdog.sh" --status)

echo "$output" | grep -q "RESTART_COUNT_TODAY=10 / 10" || {
    echo "FAIL: at cap should show 10/10"; echo "$output"; exit 1
}
echo "$output" | grep -q "EFFECTIVE_COOLDOWN=3600s" || {
    echo "FAIL: at cap should show throttled cooldown"; echo "$output"; exit 1
}
echo "$output" | grep -q "ALERT_FLAG_CAP_REACHED=set" || {
    echo "FAIL: cap flag should be set"; echo "$output"; exit 1
}
echo "$output" | grep -q "ALERT_FLAG_NOT_LOGGED_IN=set" || {
    echo "FAIL: terminal flag should be set"; echo "$output"; exit 1
}

echo OK
