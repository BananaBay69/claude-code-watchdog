#!/bin/bash
# Unit: detect_restart_pattern matches RESTART_PATTERNS entries.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$SCRIPT_DIR/test/lib/assert.sh"

WATCHDOG_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$WATCHDOG_LOG_DIR"' EXIT
WATCHDOG_HEARTBEAT_FILE="" \
. "$SCRIPT_DIR/claude-watchdog.sh"

# Matches
assert_eq "yes:rate-limit-options" "$(detect_restart_pattern 'foo
rate-limit-options
bar')" "rate-limit-options match"

assert_eq "yes:Yes, I trust this folder" \
    "$(detect_restart_pattern '? Yes, I trust this folder')" "trust prompt match"

# No match
assert_eq "no:" "$(detect_restart_pattern 'just regular conversation text')" "no match"
assert_eq "no:" "$(detect_restart_pattern '')" "empty input"

echo OK
