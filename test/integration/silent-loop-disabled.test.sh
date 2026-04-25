#!/bin/bash
# E2E: WATCHDOG_SILENT_LOOP_ENABLED unset (default 0) → no detection runs,
# no alert fires, no log noise.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export MOCK_PANE_FILE="$TMPDIR/pane.txt"
cat > "$MOCK_PANE_FILE" <<'EOF'
← telegram · 489601378: 在嗎
← telegram · 489601378: 還在嗎
← telegram · 489601378: 哈囉
EOF

mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/tmux" <<'TMUXEOF'
#!/bin/bash
case "$1" in
    has-session) exit 0 ;;
    capture-pane) cat "$MOCK_PANE_FILE" ;;
    display-message) echo "12345" ;;
esac
TMUXEOF
chmod +x "$TMPDIR/bin/tmux"

cat > "$TMPDIR/bin/pgrep" <<'PGEOF'
#!/bin/bash
exit 0
PGEOF
chmod +x "$TMPDIR/bin/pgrep"

ALERT_LOG="$TMPDIR/alerts.log"

PATH="$TMPDIR/bin:$PATH" \
WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
WATCHDOG_LOG_DIR="$TMPDIR/logs" \
WATCHDOG_OUTBOUND_FILE="$TMPDIR/missing-outbound" \
WATCHDOG_ALERT_CMD="echo \"\$WATCHDOG_ALERT_TYPE\" >> $ALERT_LOG" \
WATCHDOG_HEARTBEAT_FILE="" \
bash "$ROOT/claude-watchdog.sh"

# No alert should fire
[ ! -f "$ALERT_LOG" ] || {
    echo "FAIL: alert fired despite SILENT_LOOP_ENABLED unset"
    cat "$ALERT_LOG"
    exit 1
}

# Log should NOT mention silent-loop check (avoid noise when disabled)
if grep -q "silent-loop" "$TMPDIR/logs/claude-watchdog.log"; then
    echo "FAIL: silent-loop noise in log when disabled"
    grep silent-loop "$TMPDIR/logs/claude-watchdog.log"
    exit 1
fi

echo "PASS: silent-loop detection inert when disabled (default)"
