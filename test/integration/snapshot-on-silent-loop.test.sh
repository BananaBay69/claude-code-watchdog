#!/bin/bash
# E2E: when WATCHDOG_SILENT_LOOP_RECOVERY=snapshot-only and silent-loop fires
# state-entry alert, a snapshot is created and the alert message includes
# the snapshot path. Subsequent same-state ticks do not produce additional
# snapshots (dedup via existing alert flag).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# shellcheck source=../lib/assert.sh
. "$SCRIPT_DIR/../lib/assert.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/bin" "$TMPDIR/logs"

# Pane content: incoming messages, no outbound. Triggers silent-loop when
# combined with stale outbound file.
PANE_FILE="$TMPDIR/pane.txt"
cat > "$PANE_FILE" <<'PANEEOF'
← telegram · 489601378: 在嗎
⏺ Bash(~/bin/invite-cli check-reply ...)
  ⎿ {"has_pending_invite": false}
✻ Baked for 9s
← telegram · 489601378: 現在有什麼問題
⏺ Bash(~/bin/invite-cli check-reply ...)
  ⎿ {"has_pending_invite": false}
✻ Baked for 9s
← telegram · 489601378: 你還在嗎
⏺ Bash(~/bin/invite-cli check-reply ...)
✻ Baked for 9s
PANEEOF

cat > "$TMPDIR/bin/tmux" <<TMUXEOF
#!/bin/bash
case "\$1" in
    has-session) exit 0 ;;
    capture-pane) cat "$PANE_FILE" ;;
    display-message) echo "12345" ;;
    ls) echo "claude: 1 windows" ;;
    *) exit 0 ;;
esac
TMUXEOF
chmod +x "$TMPDIR/bin/tmux"

cat > "$TMPDIR/bin/pgrep" <<'PGEOF'
#!/bin/bash
exit 0
PGEOF
chmod +x "$TMPDIR/bin/pgrep"

# Outbound file: stale by 1 hour
OUTBOUND="$TMPDIR/outbound"
printf '1 %d\n' "$(( $(date +%s) - 3600 ))" > "$OUTBOUND"

# Alert log captures every ALERT_CMD invocation
ALERT_LOG="$TMPDIR/alerts.log"
ALERT_CMD="echo \"\$WATCHDOG_ALERT_TYPE|\$WATCHDOG_ALERT_MSG\" >> $ALERT_LOG"

run_watchdog() {
    PATH="$TMPDIR/bin:$PATH" \
    WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WATCHDOG_LOG_DIR="$TMPDIR/logs" \
    WATCHDOG_SILENT_LOOP_ENABLED=1 \
    WATCHDOG_SILENT_LOOP_INCOMING_THRESHOLD=2 \
    WATCHDOG_SILENT_LOOP_RECOVERY="$1" \
    WATCHDOG_OUTBOUND_FILE="$OUTBOUND" \
    WATCHDOG_ALERT_CMD="$ALERT_CMD" \
    WATCHDOG_HEARTBEAT_FILE="" \
    bash "$ROOT/claude-watchdog.sh"
}

# === Tick 1: snapshot-only mode → snapshot created + alert msg includes path ===
run_watchdog snapshot-only
assert_file_exists "$ALERT_LOG"
n1=$(wc -l < "$ALERT_LOG" | tr -d ' ')
[ "$n1" = "1" ] || { echo "FAIL tick1: expected 1 alert, got $n1"; cat "$ALERT_LOG"; exit 1; }
n_snap=$(find "$TMPDIR/logs/snapshots" -mindepth 1 -maxdepth 1 -type d -name 'silent-loop-*' 2>/dev/null | wc -l | tr -d ' ')
[ "$n_snap" = "1" ] || { echo "FAIL tick1: expected 1 snapshot, got $n_snap"; exit 1; }

# Alert msg must include "Snapshot: <path>" suffix
grep -q ' Snapshot: ' "$ALERT_LOG" || { echo "FAIL tick1: alert missing 'Snapshot:' suffix"; cat "$ALERT_LOG"; exit 1; }
snap_path=$(find "$TMPDIR/logs/snapshots" -mindepth 1 -maxdepth 1 -type d -name 'silent-loop-*')
grep -q "Snapshot: $snap_path" "$ALERT_LOG" || { echo "FAIL tick1: alert path mismatch: expected $snap_path"; cat "$ALERT_LOG"; exit 1; }

# === Tick 2: same state → dedup, no new alert, no new snapshot ===
sleep 1  # different timestamp if a new snapshot were (wrongly) made
run_watchdog snapshot-only
n2=$(wc -l < "$ALERT_LOG" | tr -d ' ')
[ "$n2" = "1" ] || { echo "FAIL tick2 dedup: expected 1 alert total, got $n2"; exit 1; }
n_snap2=$(find "$TMPDIR/logs/snapshots" -mindepth 1 -maxdepth 1 -type d -name 'silent-loop-*' 2>/dev/null | wc -l | tr -d ' ')
[ "$n_snap2" = "1" ] || { echo "FAIL tick2 dedup: expected 1 snapshot, got $n_snap2"; exit 1; }

# === Tick 3: outbound clears flag, then re-enters silent-loop → new snapshot ===
printf '1 %d\n' "$(date +%s)" > "$OUTBOUND"
run_watchdog snapshot-only  # clears flag (alert was dedup'd, now state-cleared)
# re-enter silent-loop
sleep 1
printf '1 %d\n' "$(( $(date +%s) - 3600 ))" > "$OUTBOUND"
run_watchdog snapshot-only

n3=$(wc -l < "$ALERT_LOG" | tr -d ' ')
[ "$n3" = "2" ] || { echo "FAIL tick3 re-entry: expected 2 alerts total, got $n3"; cat "$ALERT_LOG"; exit 1; }
n_snap3=$(find "$TMPDIR/logs/snapshots" -mindepth 1 -maxdepth 1 -type d -name 'silent-loop-*' 2>/dev/null | wc -l | tr -d ' ')
[ "$n_snap3" = "2" ] || { echo "FAIL tick3 re-entry: expected 2 snapshots, got $n_snap3"; exit 1; }

# === Tick 4: disabled mode → no snapshot, alert msg has v0.1.7 format (no Snapshot:) ===
rm -rf "$TMPDIR/logs"
mkdir -p "$TMPDIR/logs"
rm -f "$ALERT_LOG"
printf '1 %d\n' "$(( $(date +%s) - 3600 ))" > "$OUTBOUND"

run_watchdog disabled
assert_file_exists "$ALERT_LOG"
[ ! -d "$TMPDIR/logs/snapshots" ] || { echo "FAIL tick4: snapshot dir created in disabled mode"; exit 1; }
grep -q 'Snapshot:' "$ALERT_LOG" && { echo "FAIL tick4: disabled mode alert wrongly contains Snapshot:"; cat "$ALERT_LOG"; exit 1; }

# === Tick 5: soft / aggressive stub modes → WARN log line, no snapshot ===
rm -rf "$TMPDIR/logs"
mkdir -p "$TMPDIR/logs"
rm -f "$ALERT_LOG"
printf '1 %d\n' "$(( $(date +%s) - 3600 ))" > "$OUTBOUND"

run_watchdog soft
grep -q 'WARN: soft mode requested but not implemented' "$TMPDIR/logs/claude-watchdog.log" || \
    { echo "FAIL tick5a: soft stub did not log WARN"; cat "$TMPDIR/logs/claude-watchdog.log"; exit 1; }
[ ! -d "$TMPDIR/logs/snapshots" ] || { echo "FAIL tick5a: soft stub created a snapshot"; exit 1; }

# Clear state before testing aggressive (otherwise dedup suppresses the recovery_driver call)
rm -rf "$TMPDIR/logs"
mkdir -p "$TMPDIR/logs"
rm -f "$ALERT_LOG"
printf '1 %d\n' "$(( $(date +%s) - 3600 ))" > "$OUTBOUND"

run_watchdog aggressive
grep -q 'WARN: aggressive mode requested but not implemented' "$TMPDIR/logs/claude-watchdog.log" || \
    { echo "FAIL tick5b: aggressive stub did not log WARN"; cat "$TMPDIR/logs/claude-watchdog.log"; exit 1; }
[ ! -d "$TMPDIR/logs/snapshots" ] || { echo "FAIL tick5b: aggressive stub created a snapshot"; exit 1; }

# === Tick 6: unknown enum value → WARN, fall back to disabled (no snapshot, no Snapshot: in alert) ===
rm -rf "$TMPDIR/logs"
mkdir -p "$TMPDIR/logs"
rm -f "$ALERT_LOG"
printf '1 %d\n' "$(( $(date +%s) - 3600 ))" > "$OUTBOUND"

run_watchdog "garbage"
grep -q "WARN: unknown WATCHDOG_SILENT_LOOP_RECOVERY value 'garbage'" "$TMPDIR/logs/claude-watchdog.log" || \
    { echo "FAIL tick6: unknown value did not log WARN"; cat "$TMPDIR/logs/claude-watchdog.log"; exit 1; }
[ ! -d "$TMPDIR/logs/snapshots" ] || { echo "FAIL tick6: unknown value created a snapshot"; exit 1; }
grep -q 'Snapshot:' "$ALERT_LOG" && { echo "FAIL tick6: unknown value alert wrongly contains Snapshot:"; cat "$ALERT_LOG"; exit 1; }

echo "PASS: snapshot-on-silent-loop dispatch + dedup + alert msg integration"
