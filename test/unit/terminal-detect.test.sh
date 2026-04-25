#!/bin/bash
# Unit: detect_terminal_state matches TERMINAL_PATTERNS entries.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$SCRIPT_DIR/test/lib/assert.sh"

WATCHDOG_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$WATCHDOG_LOG_DIR"' EXIT
WATCHDOG_HEARTBEAT_FILE="" \
. "$SCRIPT_DIR/claude-watchdog.sh"

# Each TERMINAL_PATTERN
result=$(detect_terminal_state 'Not logged in · Run /login')
assert_eq "yes:Not logged in" "$result" "Not logged in match"

result=$(detect_terminal_state '--channels ignored (plugin:telegram)')
assert_eq "yes:--channels ignored" "$result" "--channels ignored match"

result=$(detect_terminal_state 'Channels require claude.ai authentication')
assert_eq "yes:Channels require claude.ai authentication" "$result" "Channels require match"

# No match
assert_eq "no:" "$(detect_terminal_state 'normal pane content')" "no match"
assert_eq "no:" "$(detect_terminal_state '')" "empty input"

echo OK
