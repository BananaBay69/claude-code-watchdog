#!/bin/bash
# Install claude-code-watchdog on macOS
# Usage: bash install.sh [--claude-cmd "custom claude command"]

set -euo pipefail

INSTALL_DIR="$HOME/bin"
LOG_DIR="$HOME/.openclaw/logs"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.openclaw.claude-watchdog"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse arguments
CLAUDE_CMD=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --claude-cmd)
            CLAUDE_CMD="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: bash install.sh [--claude-cmd \"custom claude command\"]"
            exit 1
            ;;
    esac
done

echo "=== Claude Code Watchdog Installer ==="
echo ""

# 1. Create directories
echo "[1/5] Creating directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$PLIST_DIR"

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
    echo "  Script:   $INSTALL_DIR/claude-watchdog.sh"
    echo "  Plist:    $PLIST_DIR/$PLIST_NAME.plist"
    echo "  Log:      $LOG_DIR/claude-watchdog.log"
    echo "  Interval: every 3 minutes"
    echo ""
    echo "Commands:"
    echo "  View log:    tail -20 $LOG_DIR/claude-watchdog.log"
    echo "  Run now:     bash $INSTALL_DIR/claude-watchdog.sh"
    echo "  Uninstall:   bash $(dirname "$0")/uninstall.sh"
else
    echo "ERROR: launchd agent failed to load."
    exit 1
fi
