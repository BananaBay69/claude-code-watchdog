#!/bin/bash
# Unit: effective_cooldown returns normal vs throttled based on count + cap.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$SCRIPT_DIR/test/lib/assert.sh"

# Source the script (won't run main due to source-guard)
WATCHDOG_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$WATCHDOG_LOG_DIR"' EXIT
WATCHDOG_HEARTBEAT_FILE="" \
WATCHDOG_DAILY_RESTART_CAP=10 \
WATCHDOG_THROTTLED_COOLDOWN=3600 \
WATCHDOG_COOLDOWN=300 \
. "$SCRIPT_DIR/claude-watchdog.sh"

# Below cap → normal
assert_eq 300 "$(effective_cooldown 0)" "0 < 10 → normal"
assert_eq 300 "$(effective_cooldown 9)" "9 < 10 → normal"

# At/above cap → throttled
assert_eq 3600 "$(effective_cooldown 10)" "10 >= 10 → throttled"
assert_eq 3600 "$(effective_cooldown 99)" "99 >= 10 → throttled"

# CAP=0 → always normal
DAILY_RESTART_CAP=0
assert_eq 300 "$(effective_cooldown 0)" "cap=0 → normal"
assert_eq 300 "$(effective_cooldown 100)" "cap=0 → normal even at 100"

echo OK
