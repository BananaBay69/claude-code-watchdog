#!/bin/bash
# Integration: cap reach triggers throttle + alert; below cap = normal.
set -e
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/test/lib/assert.sh"

# --- setup mocks ---
MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"
cp "$HERE/helpers/mock-tmux.sh" "$MOCK_BIN/tmux"
cp "$HERE/helpers/mock-pgrep.sh" "$MOCK_BIN/pgrep"
chmod +x "$MOCK_BIN/tmux" "$MOCK_BIN/pgrep"

PANE_FILE="$TEST_DIR/pane.txt"
echo "rate-limit-options" > "$PANE_FILE"

LOG_DIR="$TEST_DIR/log"
mkdir -p "$LOG_DIR"
TODAY=$(date +%Y%m%d)

run_watchdog() {
    PATH="$MOCK_BIN:$PATH" \
    WATCHDOG_PATH="$MOCK_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WATCHDOG_LOG_DIR="$LOG_DIR" \
    WATCHDOG_HEARTBEAT_FILE="" \
    WATCHDOG_DAILY_RESTART_CAP=10 \
    WATCHDOG_THROTTLED_COOLDOWN=3600 \
    WATCHDOG_COOLDOWN=300 \
    WATCHDOG_ALERT_CMD="echo \"FIRED \$WATCHDOG_ALERT_TYPE: \$WATCHDOG_ALERT_MSG\" >> $TEST_DIR/alert.log" \
    WATCHDOG_CLAUDE_CMD="echo mock-claude" \
    MOCK_TMUX_PANE_FILE="$PANE_FILE" \
    MOCK_TMUX_LOG="$TEST_DIR/tmux-calls.log" \
    bash "$ROOT/claude-watchdog.sh"
}

# --- scenario 1: count = 9 → +1 = 10 → cap-reached fires ---
echo 9 > "$LOG_DIR/.watchdog-restart-count-$TODAY"
echo $(($(date +%s) - 3600)) > "$LOG_DIR/.watchdog-last-restart"

run_watchdog

assert_eq "10" "$(cat "$LOG_DIR/.watchdog-restart-count-$TODAY")" "counter should be 10"
assert_file_exists "$LOG_DIR/.watchdog-alert-sent-cap-$TODAY" "cap flag should exist"
assert_file_contains "$TEST_DIR/alert.log" "FIRED cap-reached" "alert script should have fired with cap-reached"
assert_file_contains "$LOG_DIR/claude-watchdog.log" "ALERT \[cap-reached\]" "log should contain cap-reached ALERT"
assert_file_contains "$TEST_DIR/tmux-calls.log" "kill-session" "kill-session should have been called"

# --- scenario 2: count already 10, last restart 5 min ago, throttle blocks ---
rm -f "$TEST_DIR/alert.log" "$TEST_DIR/tmux-calls.log"
echo $(($(date +%s) - 300)) > "$LOG_DIR/.watchdog-last-restart"

run_watchdog

assert_eq "10" "$(cat "$LOG_DIR/.watchdog-restart-count-$TODAY")" "counter should still be 10 (throttle blocked)"
assert_file_contains "$LOG_DIR/claude-watchdog.log" "COOLDOWN.*< 3600s.*Skipping" "throttled cooldown should block restart"
assert_file_lacks "$TEST_DIR/tmux-calls.log" "kill-session" "kill-session should NOT have been called"

# --- scenario 3: below cap, normal cooldown, no alert ---
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"
rm -f "$TEST_DIR/alert.log" "$TEST_DIR/tmux-calls.log"
echo $(($(date +%s) - 3600)) > "$LOG_DIR/.watchdog-last-restart"

run_watchdog

assert_eq "1" "$(cat "$LOG_DIR/.watchdog-restart-count-$TODAY")" "counter should be 1 after first restart"
assert_file_missing "$LOG_DIR/.watchdog-alert-sent-cap-$TODAY" "cap flag should NOT exist below cap"
assert_file_lacks "$TEST_DIR/alert.log" "cap-reached" "no cap-reached alert below cap"

echo OK
