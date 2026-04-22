#!/bin/bash
# Uninstall claude-code-watchdog
set -euo pipefail

INSTALL_DIR="$HOME/bin"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.openclaw.claude-watchdog"

echo "=== Claude Code Watchdog Uninstaller ==="
echo ""

echo "[1/3] Unloading launchd agent..."
launchctl unload "$PLIST_DIR/$PLIST_NAME.plist" 2>/dev/null || true

echo "[2/3] Removing files..."
rm -f "$INSTALL_DIR/claude-watchdog.sh"
rm -f "$PLIST_DIR/$PLIST_NAME.plist"

echo "[3/3] Done."
echo ""
echo "  Log files preserved at: ~/.openclaw/logs/claude-watchdog.log"
echo "  To remove logs: rm ~/.openclaw/logs/claude-watchdog.log ~/.openclaw/logs/.watchdog-last-restart"
