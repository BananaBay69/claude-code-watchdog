#!/bin/bash
# E2E: --snapshot CLI flag captures unconditionally and does not touch alert state.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# shellcheck source=../lib/assert.sh
. "$SCRIPT_DIR/../lib/assert.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/bin" "$TMPDIR/logs"

# Mock tmux: behave like a healthy session.
cat > "$TMPDIR/bin/tmux" <<'TMUXEOF'
#!/bin/bash
case "$1" in
    has-session) exit 0 ;;
    capture-pane) echo "fresh idle pane"; exit 0 ;;
    display-message) echo "12345" ;;
    ls) echo "claude: 1 windows" ;;
    *) exit 0 ;;
esac
TMUXEOF
chmod +x "$TMPDIR/bin/tmux"

cat > "$TMPDIR/bin/pgrep" <<'PGEOF'
#!/bin/bash
echo "12345 claude"; exit 0
PGEOF
chmod +x "$TMPDIR/bin/pgrep"

run_snapshot() {
    PATH="$TMPDIR/bin:$PATH" \
    WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WATCHDOG_LOG_DIR="$TMPDIR/logs" \
    WATCHDOG_HEARTBEAT_FILE="" \
    bash "$ROOT/claude-watchdog.sh" --snapshot
}

# === Case 1: --snapshot creates a snapshot dir on a clean watchdog state ===
[ ! -d "$TMPDIR/logs/snapshots" ] || { echo "FAIL precondition: snapshots dir already exists"; exit 1; }

run_snapshot
[ -d "$TMPDIR/logs/snapshots" ] || { echo "FAIL case1: snapshots dir not created"; exit 1; }
n=$(find "$TMPDIR/logs/snapshots" -mindepth 1 -maxdepth 1 -type d -name 'silent-loop-*' | wc -l | tr -d ' ')
[ "$n" = "1" ] || { echo "FAIL case1: expected 1 snapshot dir, got $n"; exit 1; }

# === Case 2: --snapshot does NOT create the alert dedup flag ===
[ ! -f "$TMPDIR/logs/.watchdog-alert-sent-silent-loop" ] || \
    { echo "FAIL case2: alert flag was created by --snapshot"; exit 1; }

# === Case 3: pre-existing alert flag is preserved (--snapshot must not modify it) ===
touch "$TMPDIR/logs/.watchdog-alert-sent-silent-loop"
sleep 1  # ensure new timestamp
run_snapshot
[ -f "$TMPDIR/logs/.watchdog-alert-sent-silent-loop" ] || \
    { echo "FAIL case3: alert flag was cleared by --snapshot"; exit 1; }
n=$(find "$TMPDIR/logs/snapshots" -mindepth 1 -maxdepth 1 -type d -name 'silent-loop-*' | wc -l | tr -d ' ')
[ "$n" = "2" ] || { echo "FAIL case3: expected 2 snapshot dirs, got $n"; exit 1; }

# === Case 4: --snapshot exits 0 on success ===
sleep 1
run_snapshot && rc=0 || rc=$?
[ "$rc" = "0" ] || { echo "FAIL case4: --snapshot exited $rc"; exit 1; }

# === Case 5: --snapshot writes the same 6 files as automatic snapshot ===
latest=$(find "$TMPDIR/logs/snapshots" -mindepth 1 -maxdepth 1 -type d -name 'silent-loop-*' | sort | tail -1)
assert_file_exists "$latest/pane.txt"
assert_file_exists "$latest/status.txt"
assert_file_exists "$latest/env.txt"
assert_file_exists "$latest/recent-log.txt"
assert_file_exists "$latest/active-skills.txt"
assert_file_exists "$latest/metadata.json"

echo "PASS: --snapshot CLI flag captures unconditionally and does not touch alert state"
