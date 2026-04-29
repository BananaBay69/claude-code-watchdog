#!/bin/bash
# E2E: trigger known silent-suppress code paths and assert each emits a log line.
# Covers Silent error-suppression paths emit log lines requirement.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# shellcheck source=../lib/assert.sh
. "$SCRIPT_DIR/../lib/assert.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/bin" "$TMPDIR/logs"

# === Case 1: tmux kill-session no-op emits DEBUG line ===
# Mock tmux: kill-session always exits non-zero (session gone)
cat > "$TMPDIR/bin/tmux" <<'TMUXEOF'
#!/bin/bash
case "$1" in
    has-session) exit 1 ;;  # session not found → triggers Case A restart path
    kill-session) exit 1 ;; # always fail (no-op simulation)
    new-session) exit 0 ;;
    capture-pane) echo ""; exit 0 ;;
    display-message) echo "12345" ;;
    *) exit 0 ;;
esac
TMUXEOF
chmod +x "$TMPDIR/bin/tmux"

cat > "$TMPDIR/bin/pgrep" <<'PGEOF'
#!/bin/bash
exit 0
PGEOF
chmod +x "$TMPDIR/bin/pgrep"

# Run watchdog at DEBUG level so DEBUG line is visible in log
PATH="$TMPDIR/bin:$PATH" \
WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
WATCHDOG_LOG_DIR="$TMPDIR/logs" \
WATCHDOG_LOG_LEVEL=DEBUG \
WATCHDOG_HEARTBEAT_FILE="" \
WATCHDOG_CLAUDE_CMD="true" \
bash "$ROOT/claude-watchdog.sh"

assert_file_contains "$TMPDIR/logs/claude-watchdog.log" "DEBUG: kill-session no-op" \
    "case1: kill-session non-zero should emit DEBUG line"

# === Case 2: heartbeat read failure emits WARN ===
# For this case we need a session-alive mock so we reach heartbeat_state.
cat > "$TMPDIR/bin/tmux" <<'TMUXEOF'
#!/bin/bash
case "$1" in
    has-session) exit 0 ;;
    capture-pane) echo ""; exit 0 ;;
    display-message) echo "12345" ;;
    *) exit 0 ;;
esac
TMUXEOF

# Create unreadable heartbeat file (chmod 000)
HB="$TMPDIR/heartbeat-unreadable"
echo "1 1745382601" > "$HB"
chmod 000 "$HB"

# Reset log
rm -rf "$TMPDIR/logs2"
mkdir -p "$TMPDIR/logs2"

PATH="$TMPDIR/bin:$PATH" \
WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
WATCHDOG_LOG_DIR="$TMPDIR/logs2" \
WATCHDOG_LOG_LEVEL=WARN \
WATCHDOG_HEARTBEAT_FILE="$HB" \
WATCHDOG_CLAUDE_CMD="true" \
bash "$ROOT/claude-watchdog.sh" 2>/dev/null

# Restore so trap cleanup doesn't fail
chmod 644 "$HB"

assert_file_contains "$TMPDIR/logs2/claude-watchdog.log" "WARN: heartbeat read failed" \
    "case2: unreadable heartbeat file should emit WARN"

# === Case 3: outbound read failure emits WARN ===
OB="$TMPDIR/outbound-unreadable"
echo "1 1745382601" > "$OB"
chmod 000 "$OB"

# Mock tmux for healthy session (so we reach silent-loop branch)
cat > "$TMPDIR/bin/tmux" <<'TMUXEOF'
#!/bin/bash
case "$1" in
    has-session) exit 0 ;;
    capture-pane) echo "← telegram · 100: msg1"; echo "← telegram · 100: msg2"; exit 0 ;;
    display-message) echo "12345" ;;
    *) exit 0 ;;
esac
TMUXEOF

rm -rf "$TMPDIR/logs3"
mkdir -p "$TMPDIR/logs3"

PATH="$TMPDIR/bin:$PATH" \
WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
WATCHDOG_LOG_DIR="$TMPDIR/logs3" \
WATCHDOG_LOG_LEVEL=WARN \
WATCHDOG_HEARTBEAT_FILE="" \
WATCHDOG_OUTBOUND_FILE="$OB" \
WATCHDOG_SILENT_LOOP_ENABLED=1 \
WATCHDOG_CLAUDE_CMD="true" \
bash "$ROOT/claude-watchdog.sh" 2>/dev/null

chmod 644 "$OB"

assert_file_contains "$TMPDIR/logs3/claude-watchdog.log" "WARN: outbound read failed" \
    "case3: unreadable outbound file should emit WARN"

# === Case 4: restart-count file unreadable emits WARN ===
# Need Case A mock (session not found) so attempt_restart fires → read_restart_count.
cat > "$TMPDIR/bin/tmux" <<'TMUXEOF'
#!/bin/bash
case "$1" in
    has-session) exit 1 ;;
    kill-session) exit 0 ;;
    new-session) exit 0 ;;
    capture-pane) echo ""; exit 0 ;;
    display-message) echo "12345" ;;
    *) exit 0 ;;
esac
TMUXEOF

# Set up: restart-count file exists for today but is unreadable
TODAY=$(date +%Y%m%d)
COUNTFILE="$TMPDIR/logs4/.watchdog-restart-count-$TODAY"
mkdir -p "$TMPDIR/logs4"
echo "5" > "$COUNTFILE"
chmod 000 "$COUNTFILE"

PATH="$TMPDIR/bin:$PATH" \
WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
WATCHDOG_LOG_DIR="$TMPDIR/logs4" \
WATCHDOG_LOG_LEVEL=WARN \
WATCHDOG_HEARTBEAT_FILE="" \
WATCHDOG_CLAUDE_CMD="true" \
bash "$ROOT/claude-watchdog.sh" 2>/dev/null

chmod 644 "$COUNTFILE"

assert_file_contains "$TMPDIR/logs4/claude-watchdog.log" "WARN: restart-count file unreadable" \
    "case4: unreadable restart-count should emit WARN (not silent fall-through to 0)"

# === Case 5: snapshot sub-capture failure includes stderr snippet ===
# Replace tmux mock so capture-pane fails with stderr message
cat > "$TMPDIR/bin/tmux" <<'TMUXEOF'
#!/bin/bash
case "$1" in
    capture-pane) echo "error: pane not found" >&2; exit 1 ;;
    has-session) exit 0 ;;
    display-message) echo "12345" ;;
    ls) echo "claude: 1 windows" ;;
    *) exit 0 ;;
esac
TMUXEOF

rm -rf "$TMPDIR/logs5"
mkdir -p "$TMPDIR/logs5"

PATH="$TMPDIR/bin:$PATH" \
WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
WATCHDOG_LOG_DIR="$TMPDIR/logs5" \
WATCHDOG_LOG_LEVEL=WARN \
WATCHDOG_HEARTBEAT_FILE="" \
WATCHDOG_CLAUDE_CMD="true" \
bash "$ROOT/claude-watchdog.sh" --snapshot

assert_file_contains "$TMPDIR/logs5/claude-watchdog.log" "WARN: snapshot pane.txt failed" \
    "case5: snapshot capture failure should emit WARN"
assert_file_contains "$TMPDIR/logs5/claude-watchdog.log" "error: pane not found" \
    "case5: WARN line should include captured stderr snippet (per spec scenario)"

echo "PASS: silent-path-coverage covers 5 silent suppression sites"
