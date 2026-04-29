#!/bin/bash
# Integration: when a pane simultaneously matches a TERMINAL pattern (e.g.
# "Not logged in") and a RESTART pattern (e.g. rate-limit prompt), the
# terminal alert is the source of truth and the restart MUST be suppressed.
# Regression for issue #25.
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
    MOCK_TMUX_LOG="$TEST_DIR/tmux.log" \
    bash "$ROOT/claude-watchdog.sh"
}

# Pane matches both:
#   - TERMINAL_PATTERN: "Not logged in"
#   - RESTART_PATTERN: "You've hit your limit" (real entry in
#     RESTART_PATTERNS in claude-watchdog.sh)
cat > "$PANE_FILE" <<'EOF'
Not logged in · Run /login

You've hit your limit, please /upgrade
EOF

run_watchdog

# Terminal alert MUST fire (existing behaviour).
assert_file_exists "$LOG_DIR/.watchdog-alert-sent-not-logged-in" "terminal flag should be created"
assert_file_contains "$TEST_DIR/alert.log" "FIRED not-logged-in" "terminal alert fires"

# Restart MUST NOT happen — i.e., no kill-session / new-session in the tmux
# command log. (mock-tmux logs every invocation when MOCK_TMUX_LOG is set.)
assert_file_lacks "$TEST_DIR/tmux.log" "kill-session" "kill-session must not be invoked when terminal pattern present"
assert_file_lacks "$TEST_DIR/tmux.log" "new-session" "new-session must not be invoked when terminal pattern present"

# The watchdog's own log should explain the suppression so operators can
# correlate this with issue #25 in the future.
assert_file_contains "$LOG_DIR/claude-watchdog.log" "suppressing restart" "log explains the suppression"

echo OK
