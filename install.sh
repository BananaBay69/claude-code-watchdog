#!/bin/bash
# Install claude-code-watchdog on macOS.
#
# Usage:
#   bash install.sh                                 # use defaults
#   bash install.sh --log-dir <path>                # override log dir
#   bash install.sh --heartbeat-file <path>         # enable heartbeat signal (default: disabled)
#   bash install.sh --session <name>                # tmux session name (default: claude)
#   bash install.sh --claude-cmd "<command>"        # custom claude command
#   bash install.sh --help

set -euo pipefail

# --- Installer defaults ---
INSTALL_DIR="$HOME/bin"
LOG_DIR="$HOME/.openclaw/logs"
HEARTBEAT_FILE=""
SESSION="claude"
CLAUDE_CMD=""

PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.openclaw.claude-watchdog"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<'USAGE'
claude-code-watchdog installer

Usage:
    bash install.sh [options]

Options:
    --log-dir <path>         log directory (default: $HOME/.openclaw/logs)
    --heartbeat-file <path>  heartbeat file for liveness signal
                             (default: disabled; enable for use with Phase 2 plugin)
    --session <name>         tmux session name to supervise (default: claude)
    --claude-cmd "<cmd>"     override the default claude command
    --help, -h               show this message

Legacy-layout install (existing Mac Mini deployments):
    bash install.sh --log-dir "$HOME/.openclaw/logs" \
                    --heartbeat-file "$HOME/.openclaw/heartbeat"

Recommended new install:
    bash install.sh --log-dir "$HOME/.claude/watchdog/logs" \
                    --heartbeat-file "$HOME/.claude/watchdog/heartbeat"
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --log-dir)         LOG_DIR="$2"; shift 2 ;;
        --heartbeat-file)  HEARTBEAT_FILE="$2"; shift 2 ;;
        --session)         SESSION="$2"; shift 2 ;;
        --claude-cmd)      CLAUDE_CMD="$2"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
done

echo "=== Claude Code Watchdog Installer ==="
echo "  Log dir:        $LOG_DIR"
echo "  Heartbeat file: ${HEARTBEAT_FILE:-(disabled)}"
echo "  Session:        $SESSION"
echo ""

# 1. Create directories
echo "[1/5] Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$PLIST_DIR"
if [ -n "$HEARTBEAT_FILE" ]; then
    mkdir -p "$(dirname "$HEARTBEAT_FILE")"
fi

# 2. Copy watchdog script
echo "[2/5] Installing watchdog script to $INSTALL_DIR/claude-watchdog.sh..."
cp "$SCRIPT_DIR/claude-watchdog.sh" "$INSTALL_DIR/claude-watchdog.sh"
chmod +x "$INSTALL_DIR/claude-watchdog.sh"

# If custom claude command provided, patch it into the script
if [ -n "$CLAUDE_CMD" ]; then
    echo "  Custom claude command: $CLAUDE_CMD"
    sed -i '' "s|WATCHDOG_CLAUDE_CMD:-.*}|WATCHDOG_CLAUDE_CMD:-export PATH=\$PATH \&\& $CLAUDE_CMD}|" "$INSTALL_DIR/claude-watchdog.sh"
fi

# 3. Generate launchd plist from template
echo "[3/5] Installing launchd plist to $PLIST_DIR/$PLIST_NAME.plist..."
sed -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    -e "s|__HOME__|$HOME|g" \
    -e "s|__HEARTBEAT_FILE__|$HEARTBEAT_FILE|g" \
    -e "s|__WATCHDOG_SESSION__|$SESSION|g" \
    "$SCRIPT_DIR/com.openclaw.claude-watchdog.plist" > "$PLIST_DIR/$PLIST_NAME.plist"

# 4. Unload existing agent (if any), then load
echo "[4/5] Loading launchd agent..."
launchctl unload "$PLIST_DIR/$PLIST_NAME.plist" 2>/dev/null || true
launchctl load "$PLIST_DIR/$PLIST_NAME.plist"

# 5. Verify
echo "[5/5] Verifying..."
if launchctl list | grep -q "$PLIST_NAME"; then
    echo ""
    echo "=== Installation complete ==="
    echo ""
    echo "  Script:    $INSTALL_DIR/claude-watchdog.sh"
    echo "  Plist:     $PLIST_DIR/$PLIST_NAME.plist"
    echo "  Log:       $LOG_DIR/claude-watchdog.log"
    echo "  Heartbeat: ${HEARTBEAT_FILE:-(disabled — grep-only detection)}"
    echo "  Session:   $SESSION"
    echo "  Interval:  every 3 minutes"
    echo ""
    echo "Commands:"
    echo "  View log:    tail -20 $LOG_DIR/claude-watchdog.log"
    echo "  Show config: bash $INSTALL_DIR/claude-watchdog.sh --show-config"
    echo "  Run now:     bash $INSTALL_DIR/claude-watchdog.sh"
    echo "  Uninstall:   bash $(dirname "$0")/uninstall.sh"
else
    echo "ERROR: launchd agent failed to load."
    exit 1
fi
