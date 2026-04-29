#!/bin/bash
# E2E: parse_args errors mirror to main log via Option A,
# but degrade gracefully when LOG_DIR cannot be created.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# shellcheck source=../lib/assert.sh
. "$SCRIPT_DIR/../lib/assert.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# === Case 1: unknown argument with normal LOG_DIR ===
LOGDIR="$TMPDIR/normal-logs"
# Important: do NOT pre-create LOG_DIR. mkdir -p in helper must do it.
[ ! -d "$LOGDIR" ] || { echo "FAIL precondition: LOGDIR pre-exists"; exit 1; }

stderr=$(WATCHDOG_LOG_DIR="$LOGDIR" \
         WATCHDOG_HEARTBEAT_FILE="" \
         bash "$ROOT/claude-watchdog.sh" --xyz 2>&1 1>/dev/null) && rc=0 || rc=$?

[ "$rc" = "2" ] || { echo "FAIL case1: expected exit 2, got $rc"; exit 1; }
echo "$stderr" | grep -q "unknown argument '--xyz'" || \
    { echo "FAIL case1: stderr missing message: $stderr"; exit 1; }
[ -d "$LOGDIR" ] || { echo "FAIL case1: helper did not create LOG_DIR"; exit 1; }
assert_file_contains "$LOGDIR/claude-watchdog.log" "ERROR: unknown argument '--xyz'" \
    "case1: ERROR line mirrored to main log"

# Verify NO log rotation side-effect happened (file should not have any "Log rotated" line)
assert_file_lacks "$LOGDIR/claude-watchdog.log" "Log rotated" \
    "case1: pre-LOG_DIR error path must not trigger rotation"

# === Case 2: --config <missing> with normal LOG_DIR ===
LOGDIR2="$TMPDIR/normal-logs-2"
stderr2=$(WATCHDOG_LOG_DIR="$LOGDIR2" \
          WATCHDOG_HEARTBEAT_FILE="" \
          bash "$ROOT/claude-watchdog.sh" --config /no/such/path 2>&1 1>/dev/null) && rc=0 || rc=$?

[ "$rc" = "2" ] || { echo "FAIL case2: expected exit 2, got $rc"; exit 1; }
echo "$stderr2" | grep -q "config file not found" || \
    { echo "FAIL case2: stderr missing message: $stderr2"; exit 1; }
assert_file_contains "$LOGDIR2/claude-watchdog.log" "ERROR: config file not found" \
    "case2: --config <missing> mirrored to main log"

# === Case 3: graceful degradation when LOG_DIR parent is unwritable ===
# Strategy: point WATCHDOG_LOG_DIR to a path under a read-only parent.
# mkdir -p will fail; helper must NOT crash; stderr must still appear; exit still 2.
RO_PARENT="$TMPDIR/readonly-parent"
mkdir -p "$RO_PARENT"
chmod 555 "$RO_PARENT"  # read+execute, no write → mkdir of a child fails

stderr3=$(WATCHDOG_LOG_DIR="$RO_PARENT/nested-cannot-create" \
          WATCHDOG_HEARTBEAT_FILE="" \
          bash "$ROOT/claude-watchdog.sh" --xyz 2>&1 1>/dev/null) && rc=0 || rc=$?

# Restore for cleanup
chmod 755 "$RO_PARENT"

[ "$rc" = "2" ] || { echo "FAIL case3: expected exit 2 even when LOG_DIR unwritable, got $rc"; exit 1; }
echo "$stderr3" | grep -q "unknown argument '--xyz'" || \
    { echo "FAIL case3: stderr missing even after mkdir fail: $stderr3"; exit 1; }
[ ! -d "$RO_PARENT/nested-cannot-create" ] || \
    { echo "FAIL case3: should NOT have created LOG_DIR under read-only parent"; exit 1; }
# Main log absence is acceptable (no LOG_DIR = no log file possible)

echo "PASS: parse-args-error-mirror — Option A mirror works + graceful degradation"
