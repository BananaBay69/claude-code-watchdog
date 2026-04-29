#!/bin/bash
# Unit test: take_snapshot() creates a directory with the 6 required files
# and metadata.json contains the expected shape.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# shellcheck source=../lib/assert.sh
. "$SCRIPT_DIR/../lib/assert.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Mock tmux: capture-pane outputs canned content; ls/has-session succeed.
mkdir -p "$TMPDIR/bin"
cat > "$TMPDIR/bin/tmux" <<'TMUXEOF'
#!/bin/bash
case "$1" in
    capture-pane) echo "← telegram · 100: hi"; echo "← telegram · 100: there"; exit 0 ;;
    ls) echo "claude: 1 windows"; exit 0 ;;
    has-session) exit 0 ;;
    display-message) echo "12345"; exit 0 ;;
    *) exit 0 ;;
esac
TMUXEOF
chmod +x "$TMPDIR/bin/tmux"

# Mock pgrep
cat > "$TMPDIR/bin/pgrep" <<'PGEOF'
#!/bin/bash
echo "12345 claude"; exit 0
PGEOF
chmod +x "$TMPDIR/bin/pgrep"

# Outbound file: stale by ~890s (so silent_loop_state.outbound_age_seconds is non-zero)
OUTBOUND="$TMPDIR/outbound"
NOW=$(date +%s)
printf '1 %d\n' "$(( NOW - 890 ))" > "$OUTBOUND"

# Production launchd exports WATCHDOG_* vars; mirror that in the test so
# `env | grep WATCHDOG_` inside take_snapshot finds them.
export PATH="$TMPDIR/bin:$PATH"
export WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export WATCHDOG_LOG_DIR="$TMPDIR/logs"
export WATCHDOG_OUTBOUND_FILE="$OUTBOUND"
export WATCHDOG_HEARTBEAT_FILE=""

# shellcheck disable=SC1091
. "$ROOT/claude-watchdog.sh"

mkdir -p "$LOG_DIR"
# init_config overwrote PATH from WATCHDOG_PATH; ensure mocks reachable.
export PATH="$TMPDIR/bin:$PATH"

# === Case 1: take_snapshot writes all 6 expected files ===
snapshot_path=$(take_snapshot 7)
[ -d "$snapshot_path" ] || { echo "FAIL: snapshot dir not created: $snapshot_path"; exit 1; }

assert_file_exists "$snapshot_path/pane.txt"          "pane.txt missing"
assert_file_exists "$snapshot_path/status.txt"        "status.txt missing"
assert_file_exists "$snapshot_path/env.txt"           "env.txt missing"
assert_file_exists "$snapshot_path/recent-log.txt"    "recent-log.txt missing"
assert_file_exists "$snapshot_path/active-skills.txt" "active-skills.txt missing"
assert_file_exists "$snapshot_path/metadata.json"     "metadata.json missing"

# === Case 2: pane.txt content from mock tmux ===
assert_file_contains "$snapshot_path/pane.txt" "telegram"

# === Case 3: env.txt contains WATCHDOG_* vars + tmux ls + pgrep ===
assert_file_contains "$snapshot_path/env.txt" "WATCHDOG_OUTBOUND_FILE"
assert_file_contains "$snapshot_path/env.txt" "claude: 1 windows"

# === Case 4: metadata.json shape ===
assert_file_contains "$snapshot_path/metadata.json" '"incoming": 7'
assert_file_contains "$snapshot_path/metadata.json" '"outbound_age_seconds":'
assert_file_contains "$snapshot_path/metadata.json" "\"watchdog_version\": \"$WATCHDOG_VERSION\""
assert_file_contains "$snapshot_path/metadata.json" '"captured_at":'

# === Case 5: snapshot dir lives under $LOG_DIR/snapshots/ with right name pattern ===
case "$snapshot_path" in
    "$LOG_DIR/snapshots/silent-loop-"[0-9]*) : ;;
    *) echo "FAIL: snapshot path '$snapshot_path' does not match $LOG_DIR/snapshots/silent-loop-<ts>"; exit 1 ;;
esac

# === Case 6: active-skills.txt does NOT contain SKILL.md content (path/mtime only) ===
# In test env, $HOME/.claude/plugins likely empty → file should exist but empty.
# At minimum it must not contain markdown syntax that would suggest content was dumped.
assert_file_lacks "$snapshot_path/active-skills.txt" "^# " "active-skills.txt should not contain markdown headings (would imply content dump)"

# === Case 7: take_snapshot called with no args defaults incoming to 0 (manual mode) ===
sleep 1  # ensure different timestamp
manual_path=$(take_snapshot)
[ -d "$manual_path" ] || { echo "FAIL: manual snapshot dir not created"; exit 1; }
assert_file_contains "$manual_path/metadata.json" '"incoming": 0'

echo "PASS: take_snapshot creates all 6 files with correct shape"
