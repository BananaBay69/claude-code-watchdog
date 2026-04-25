#!/bin/bash
# Integration: terminal-state alerts once on entry, clears flag on recovery.
set -e
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/test/lib/assert.sh"

MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$MOCK_BIN"
cp "$HERE/helpers/mock-tmux.sh" "$MOCK_BIN/tmux"
cp "$HERE/helpers/mock-pgrep.sh" "$MOCK_BIN/pgrep"
chmod +x "$MOCK_BIN/tmux" "$MOCK_BIN/pgrep"

LOG_DIR="$TEST_DIR/log"
mkdir -p "$LOG_DIR"
PANE_FILE="$TEST_DIR/pane.txt"

run_watchdog() {
    PATH="$MOCK_BIN:$PATH" \
    WATCHDOG_PATH="$MOCK_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WATCHDOG_LOG_DIR="$LOG_DIR" \
    WATCHDOG_HEARTBEAT_FILE="" \
    WATCHDOG_ALERT_CMD="echo \"FIRED \$WATCHDOG_ALERT_TYPE\" >> $TEST_DIR/alert.log" \
    MOCK_TMUX_PANE_FILE="$PANE_FILE" \
    bash "$ROOT/claude-watchdog.sh"
}

# tick 1: not-logged-in present, no flag → alert fires
echo "Not logged in · Run /login" > "$PANE_FILE"
run_watchdog
assert_file_exists "$LOG_DIR/.watchdog-alert-sent-not-logged-in" "flag should be created"
assert_file_contains "$TEST_DIR/alert.log" "FIRED not-logged-in" "first tick fires alert"

# tick 2: same content, flag exists → silent
rm -f "$TEST_DIR/alert.log"
run_watchdog
assert_file_lacks "$TEST_DIR/alert.log" "FIRED" "second tick (still in state) is silent"
assert_file_exists "$LOG_DIR/.watchdog-alert-sent-not-logged-in" "flag still set"
assert_file_contains "$LOG_DIR/claude-watchdog.log" "still present.*alert already sent" "INFO log mentions silenced"

# tick 3: pattern clears → flag removed
echo "❯ " > "$PANE_FILE"
run_watchdog
assert_file_missing "$LOG_DIR/.watchdog-alert-sent-not-logged-in" "flag should be removed on recovery"
assert_file_contains "$LOG_DIR/claude-watchdog.log" "terminal-state cleared" "INFO log mentions clear"

# tick 4: pattern returns → fresh alert
rm -f "$TEST_DIR/alert.log"
echo "Not logged in · Run /login" > "$PANE_FILE"
run_watchdog
assert_file_exists "$LOG_DIR/.watchdog-alert-sent-not-logged-in" "flag re-created"
assert_file_contains "$TEST_DIR/alert.log" "FIRED not-logged-in" "re-entry fires alert again"

echo OK
