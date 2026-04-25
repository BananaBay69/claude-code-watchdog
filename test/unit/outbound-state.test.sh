#!/bin/bash
# Unit test: outbound_state() returns disabled/missing/fresh/stale based on file mtime.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck disable=SC1091
WATCHDOG_LOG_DIR="$TMPDIR" \
WATCHDOG_OUTBOUND_FILE="" \
WATCHDOG_SILENT_LOOP_OUTBOUND_STALE_SECONDS=600 \
. "$ROOT/claude-watchdog.sh"

# Case 1: OUTBOUND_FILE empty → disabled
state=$(outbound_state)
[ "$state" = "disabled" ] || { echo "FAIL case1: expected disabled, got $state"; exit 1; }

# Case 2: file missing → disabled
OUTBOUND_FILE="$TMPDIR/missing-outbound"
state=$(outbound_state)
[ "$state" = "disabled" ] || { echo "FAIL case2: expected disabled, got $state"; exit 1; }

# Case 3: file fresh (now)
OUTBOUND_FILE="$TMPDIR/outbound"
printf '1 %d\n' "$(date +%s)" > "$OUTBOUND_FILE"
state=$(outbound_state)
[ "$state" = "fresh" ] || { echo "FAIL case3: expected fresh, got $state"; exit 1; }

# Case 4: file stale (1 hour ago)
old_ts=$(( $(date +%s) - 3600 ))
printf '1 %d\n' "$old_ts" > "$OUTBOUND_FILE"
state=$(outbound_state)
[ "$state" = "stale" ] || { echo "FAIL case4: expected stale, got $state"; exit 1; }

# Case 5: malformed schema → stale (fail loud)
echo "garbage content" > "$OUTBOUND_FILE"
state=$(outbound_state)
[ "$state" = "stale" ] || { echo "FAIL case5: expected stale, got $state"; exit 1; }

echo "PASS: outbound_state covers disabled/missing/fresh/stale/malformed"
