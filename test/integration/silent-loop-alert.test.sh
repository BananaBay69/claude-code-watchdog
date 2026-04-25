#!/bin/bash
# E2E: incoming + stale outbound + clean pane → silent-loop alert fires once;
# subsequent ticks with same condition stay silent (dedup); when outbound
# advances → alert flag clears.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Mock tmux: pane content fed via $MOCK_PANE_FILE
export MOCK_PANE_FILE="$TMPDIR/pane.txt"
cat > "$MOCK_PANE_FILE" <<'EOF'
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
EOF

# Mock tmux: returns pane content + says session exists
mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/tmux" <<'TMUXEOF'
#!/bin/bash
case "$1" in
    has-session) exit 0 ;;
    capture-pane) cat "$MOCK_PANE_FILE" ;;
    display-message) echo "12345" ;;
    *) echo "mock-tmux: unhandled $*" >&2; exit 0 ;;
esac
TMUXEOF
chmod +x "$TMPDIR/bin/tmux"

# Mock pgrep: claude process always alive
cat > "$TMPDIR/bin/pgrep" <<'PGEOF'
#!/bin/bash
exit 0
PGEOF
chmod +x "$TMPDIR/bin/pgrep"

# Mock alert command: writes invocations to a log
ALERT_LOG="$TMPDIR/alerts.log"
ALERT_CMD="echo \"\$WATCHDOG_ALERT_TYPE|\$WATCHDOG_ALERT_MSG\" >> $ALERT_LOG"

# Outbound file: stale (1 hour ago)
OUTBOUND="$TMPDIR/outbound"
printf '1 %d\n' "$(( $(date +%s) - 3600 ))" > "$OUTBOUND"

run_watchdog() {
    PATH="$TMPDIR/bin:$PATH" \
    WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WATCHDOG_LOG_DIR="$TMPDIR/logs" \
    WATCHDOG_SILENT_LOOP_ENABLED=1 \
    WATCHDOG_SILENT_LOOP_INCOMING_THRESHOLD=2 \
    WATCHDOG_OUTBOUND_FILE="$OUTBOUND" \
    WATCHDOG_ALERT_CMD="$ALERT_CMD" \
    WATCHDOG_HEARTBEAT_FILE="" \
    bash "$ROOT/claude-watchdog.sh"
}

# Tick 1: should emit alert
run_watchdog
[ -f "$ALERT_LOG" ] || { echo "FAIL tick1: no alert emitted"; exit 1; }
n1=$(wc -l < "$ALERT_LOG")
[ "$n1" -eq 1 ] || { echo "FAIL tick1: expected 1 alert, got $n1"; exit 1; }
grep -q '^silent-loop|' "$ALERT_LOG" || { echo "FAIL tick1: wrong alert type"; exit 1; }

# Tick 2: same condition → dedup, no new alert
run_watchdog
n2=$(wc -l < "$ALERT_LOG")
[ "$n2" -eq 1 ] || { echo "FAIL tick2 dedup: expected 1, got $n2"; exit 1; }

# Tick 3: outbound advances (fresh) → flag should clear, no new alert
printf '1 %d\n' "$(date +%s)" > "$OUTBOUND"
run_watchdog
n3=$(wc -l < "$ALERT_LOG")
[ "$n3" -eq 1 ] || { echo "FAIL tick3 advance: expected 1, got $n3"; exit 1; }
[ ! -f "$TMPDIR/logs/.watchdog-alert-sent-silent-loop" ] || { echo "FAIL tick3: flag not cleared"; exit 1; }

# Tick 4: outbound stale again → alert re-fires
printf '1 %d\n' "$(( $(date +%s) - 3600 ))" > "$OUTBOUND"
run_watchdog
n4=$(wc -l < "$ALERT_LOG")
[ "$n4" -eq 2 ] || { echo "FAIL tick4 re-entry: expected 2, got $n4"; exit 1; }

echo "PASS: silent-loop alert lifecycle (fire → dedup → clear → re-fire)"
