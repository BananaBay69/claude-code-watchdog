#!/bin/bash
# Unit test: detect_silent_loop() returns "yes:<reason>" or "no:<reason>"
# based on (incoming_count, outbound_state, enabled flag).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Source with controlled env
# shellcheck disable=SC1091
WATCHDOG_LOG_DIR="$TMPDIR" \
WATCHDOG_SILENT_LOOP_ENABLED=1 \
WATCHDOG_SILENT_LOOP_INCOMING_THRESHOLD=2 \
WATCHDOG_SILENT_LOOP_OUTBOUND_STALE_SECONDS=600 \
. "$ROOT/claude-watchdog.sh"
mkdir -p "$LOG_DIR"

# Case 1: enabled=0 → always "no:disabled" regardless of inputs
# shellcheck disable=SC2034  # consumed by detect_silent_loop via the sourced script
SILENT_LOOP_ENABLED=0
result=$(detect_silent_loop 5 stale)
[ "${result%%:*}" = "no" ] || { echo "FAIL case1 yes/no: $result"; exit 1; }

# Case 2: enabled=1 + incoming below threshold → no:below-threshold
# shellcheck disable=SC2034  # consumed by detect_silent_loop via the sourced script
SILENT_LOOP_ENABLED=1
result=$(detect_silent_loop 1 stale)
[ "${result%%:*}" = "no" ] || { echo "FAIL case2: $result"; exit 1; }

# Case 3: enabled=1 + incoming meets threshold + outbound disabled → no:no-outbound-signal
result=$(detect_silent_loop 5 disabled)
[ "${result%%:*}" = "no" ] || { echo "FAIL case3: $result"; exit 1; }

# Case 4: enabled=1 + incoming meets threshold + outbound fresh → no:outbound-fresh
result=$(detect_silent_loop 5 fresh)
[ "${result%%:*}" = "no" ] || { echo "FAIL case4: $result"; exit 1; }

# Case 5: enabled=1 + incoming meets threshold + outbound stale → yes
result=$(detect_silent_loop 5 stale)
[ "${result%%:*}" = "yes" ] || { echo "FAIL case5: expected yes, got $result"; exit 1; }

# Case 6: incoming exactly at threshold (boundary) → yes
result=$(detect_silent_loop 2 stale)
[ "${result%%:*}" = "yes" ] || { echo "FAIL case6 boundary: $result"; exit 1; }

echo "PASS: detect_silent_loop matrix covers enabled/threshold/outbound states"
