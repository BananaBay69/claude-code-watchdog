#!/bin/bash
# Unit: alert flag lifecycle helpers.
set -e
SCRIPT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
. "$SCRIPT_DIR/test/lib/assert.sh"

WATCHDOG_LOG_DIR=$(mktemp -d)
trap 'rm -rf "$WATCHDOG_LOG_DIR"' EXIT
WATCHDOG_HEARTBEAT_FILE="" \
. "$SCRIPT_DIR/claude-watchdog.sh"

mkdir -p "$LOG_DIR"

# Initially clear
if alert_already_sent foo; then
    echo "FAIL: foo flag should be clear initially" >&2; exit 1
fi

# After mark, set
mark_alert_sent foo
if ! alert_already_sent foo; then
    echo "FAIL: foo flag should be set after mark" >&2; exit 1
fi
assert_file_exists "$LOG_DIR/.watchdog-alert-sent-foo"

# Clear → no longer set
clear_alert_flag foo
if alert_already_sent foo; then
    echo "FAIL: foo flag should be clear after clear" >&2; exit 1
fi
assert_file_missing "$LOG_DIR/.watchdog-alert-sent-foo"

# clear is idempotent (no error on missing)
clear_alert_flag never-existed
echo OK
