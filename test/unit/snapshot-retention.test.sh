#!/bin/bash
# Unit test: prune_old_snapshots() enforces FIFO retention by count and
# refuses to touch unexpected paths.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# shellcheck source=../lib/assert.sh
. "$SCRIPT_DIR/../lib/assert.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export PATH="$TMPDIR/bin:$PATH"
export WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export WATCHDOG_LOG_DIR="$TMPDIR/logs"
export WATCHDOG_HEARTBEAT_FILE=""

# shellcheck disable=SC1091
. "$ROOT/claude-watchdog.sh"

mkdir -p "$LOG_DIR" "$SNAPSHOT_DIR"

# === Case 1: retention prunes oldest when cap reached ===
# SBE example from spec: cap=3, three existing dirs, new one written →
# oldest removed, four remain after enforcement.
SNAPSHOT_RETAIN_COUNT=3

mkdir -p \
    "$SNAPSHOT_DIR/silent-loop-20260101000000" \
    "$SNAPSHOT_DIR/silent-loop-20260102000000" \
    "$SNAPSHOT_DIR/silent-loop-20260103000000"

# Run prune; this should leave 2 (cap-1=2) so the next snapshot writes the 3rd.
prune_old_snapshots

[ ! -d "$SNAPSHOT_DIR/silent-loop-20260101000000" ] || { echo "FAIL case1: oldest not pruned"; exit 1; }
[ -d "$SNAPSHOT_DIR/silent-loop-20260102000000" ] || { echo "FAIL case1: 02 wrongly pruned"; exit 1; }
[ -d "$SNAPSHOT_DIR/silent-loop-20260103000000" ] || { echo "FAIL case1: 03 wrongly pruned"; exit 1; }

remain=$(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$remain" = "2" ] || { echo "FAIL case1 count: expected 2 remaining, got $remain"; exit 1; }

# Simulate writing a 4th snapshot dir (which is what take_snapshot would do
# AFTER prune_old_snapshots returns)
mkdir -p "$SNAPSHOT_DIR/silent-loop-20260104000000"
final=$(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$final" = "3" ] || { echo "FAIL case1 final: expected 3 dirs after new write, got $final"; exit 1; }

# === Case 2: retention is no-op below cap ===
rm -rf "$SNAPSHOT_DIR"
mkdir -p "$SNAPSHOT_DIR"
SNAPSHOT_RETAIN_COUNT=20

mkdir -p \
    "$SNAPSHOT_DIR/silent-loop-20260201000000" \
    "$SNAPSHOT_DIR/silent-loop-20260202000000" \
    "$SNAPSHOT_DIR/silent-loop-20260203000000" \
    "$SNAPSHOT_DIR/silent-loop-20260204000000" \
    "$SNAPSHOT_DIR/silent-loop-20260205000000"

prune_old_snapshots

remain=$(find "$SNAPSHOT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$remain" = "5" ] || { echo "FAIL case2: expected 5 remaining, got $remain"; exit 1; }

# === Case 3: prune_old_snapshots ignores non-snapshot directories ===
rm -rf "$SNAPSHOT_DIR"
mkdir -p "$SNAPSHOT_DIR"
# shellcheck disable=SC2034  # consumed by prune_old_snapshots via the sourced script
SNAPSHOT_RETAIN_COUNT=1

mkdir -p \
    "$SNAPSHOT_DIR/silent-loop-20260301000000" \
    "$SNAPSHOT_DIR/silent-loop-20260302000000" \
    "$SNAPSHOT_DIR/random-dir" \
    "$SNAPSHOT_DIR/should-not-touch"

prune_old_snapshots

# silent-loop-20260301 should be pruned (older), 20260302 kept (cap-1=0... wait, cap=1, target=0, so all pruned)
# Actually with cap=1, target = 0, so both silent-loop dirs get pruned.
# But random-dir and should-not-touch must remain (they don't match name pattern).
[ -d "$SNAPSHOT_DIR/random-dir" ] || { echo "FAIL case3: random-dir was wrongly removed"; exit 1; }
[ -d "$SNAPSHOT_DIR/should-not-touch" ] || { echo "FAIL case3: should-not-touch was wrongly removed"; exit 1; }
[ ! -d "$SNAPSHOT_DIR/silent-loop-20260301000000" ] || { echo "FAIL case3: 03-01 not pruned"; exit 1; }
[ ! -d "$SNAPSHOT_DIR/silent-loop-20260302000000" ] || { echo "FAIL case3: 03-02 not pruned"; exit 1; }

# === Case 4: no snapshots dir → no-op (no error) ===
rm -rf "$SNAPSHOT_DIR"
prune_old_snapshots
[ ! -d "$SNAPSHOT_DIR" ] || { echo "FAIL case4: dir spuriously created"; exit 1; }

echo "PASS: prune_old_snapshots enforces FIFO cap and refuses unexpected paths"
