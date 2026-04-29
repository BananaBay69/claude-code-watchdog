#!/bin/bash
# E2E: state-mutating CLI invocations leave audit log lines;
# read-only CLI invocations leave nothing.
# Covers Operator interventions emit audit log lines requirement.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# shellcheck source=../lib/assert.sh
. "$SCRIPT_DIR/../lib/assert.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/bin"

# Mock tmux: healthy session
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

run_wd() {
    local logdir="$1"
    shift
    PATH="$TMPDIR/bin:$PATH" \
    WATCHDOG_PATH="$TMPDIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    WATCHDOG_LOG_DIR="$logdir" \
    WATCHDOG_HEARTBEAT_FILE="" \
    bash "$ROOT/claude-watchdog.sh" "$@"
}

# === Case 1: --reset emits "operator: --reset" line ===
LOGDIR1="$TMPDIR/logs1"
mkdir -p "$LOGDIR1"
TODAY=$(date +%Y%m%d)
echo "5" > "$LOGDIR1/.watchdog-restart-count-$TODAY"
touch "$LOGDIR1/.watchdog-alert-sent-cap-$TODAY"

run_wd "$LOGDIR1" --reset >/dev/null
assert_file_contains "$LOGDIR1/claude-watchdog.log" "operator: --reset" \
    "case1: --reset must leave audit line in main log"
assert_file_contains "$LOGDIR1/claude-watchdog.log" "cleared 2 flags" \
    "case1: --reset audit line must report cleared flag count"

# === Case 2: --snapshot success emits "operator: --snapshot (path:" line ===
LOGDIR2="$TMPDIR/logs2"
mkdir -p "$LOGDIR2"
run_wd "$LOGDIR2" --snapshot
assert_file_contains "$LOGDIR2/claude-watchdog.log" "operator: --snapshot" \
    "case2: --snapshot must leave audit line"
assert_file_contains "$LOGDIR2/claude-watchdog.log" "path: $LOGDIR2/snapshots/silent-loop-" \
    "case2: --snapshot audit line must include snapshot dir path"

# === Case 3: unknown flag emits ERROR line in main log + stderr ===
LOGDIR3="$TMPDIR/logs3"
mkdir -p "$LOGDIR3"
stderr3=$(run_wd "$LOGDIR3" --xyz 2>&1 1>/dev/null) && rc=0 || rc=$?
[ "$rc" = "2" ] || { echo "FAIL case3: expected exit 2, got $rc"; exit 1; }
echo "$stderr3" | grep -q "unknown argument '--xyz'" || { echo "FAIL case3: stderr missing 'unknown argument' message"; echo "stderr: $stderr3"; exit 1; }
assert_file_contains "$LOGDIR3/claude-watchdog.log" "ERROR: unknown argument '--xyz'" \
    "case3: unknown flag must mirror to main log as ERROR"

# === Case 4: --config <missing> emits ERROR line ===
LOGDIR4="$TMPDIR/logs4"
mkdir -p "$LOGDIR4"
stderr4=$(run_wd "$LOGDIR4" --config /nonexistent/path/to/config 2>&1 1>/dev/null) && rc=0 || rc=$?
[ "$rc" = "2" ] || { echo "FAIL case4: expected exit 2, got $rc"; exit 1; }
assert_file_contains "$LOGDIR4/claude-watchdog.log" "ERROR: config file not found" \
    "case4: --config <missing> must mirror to main log as ERROR"

# === Case 5: --help leaves NO new log line ===
LOGDIR5="$TMPDIR/logs5"
mkdir -p "$LOGDIR5"
run_wd "$LOGDIR5" --help >/dev/null
[ ! -e "$LOGDIR5/claude-watchdog.log" ] || \
    { echo "FAIL case5: --help wrote to log: $(cat $LOGDIR5/claude-watchdog.log)"; exit 1; }

# === Case 6: --version leaves NO new log line ===
LOGDIR6="$TMPDIR/logs6"
mkdir -p "$LOGDIR6"
run_wd "$LOGDIR6" --version >/dev/null
[ ! -e "$LOGDIR6/claude-watchdog.log" ] || \
    { echo "FAIL case6: --version wrote to log"; exit 1; }

# === Case 7: --show-config leaves NO new log line ===
LOGDIR7="$TMPDIR/logs7"
mkdir -p "$LOGDIR7"
run_wd "$LOGDIR7" --show-config >/dev/null
[ ! -e "$LOGDIR7/claude-watchdog.log" ] || \
    { echo "FAIL case7: --show-config wrote to log"; exit 1; }

# === Case 8: --status leaves NO new log line ===
LOGDIR8="$TMPDIR/logs8"
mkdir -p "$LOGDIR8"
run_wd "$LOGDIR8" --status >/dev/null
[ ! -e "$LOGDIR8/claude-watchdog.log" ] || \
    { echo "FAIL case8: --status wrote to log"; exit 1; }

echo "PASS: cli-audit-log covers --reset/--snapshot/unknown/--config + 4 negative read-only cases"
