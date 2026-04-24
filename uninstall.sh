#!/bin/bash
# Uninstall claude-code-watchdog
set -euo pipefail

INSTALL_DIR="$HOME/bin"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.openclaw.claude-watchdog"

echo "=== Claude Code Watchdog Uninstaller ==="
echo ""

echo "[1/4] Unloading launchd agent..."
launchctl unload "$PLIST_DIR/$PLIST_NAME.plist" 2>/dev/null || true

echo "[2/4] Removing files..."
rm -f "$INSTALL_DIR/claude-watchdog.sh"
rm -f "$PLIST_DIR/$PLIST_NAME.plist"

echo "[3/4] Removing sidecar config..."
rm -f "$HOME/.claude/watchdog/config.env"

echo "[4/4] Done."
echo ""
echo "  Log files preserved at the directory configured during install."
echo "  Common locations to check:"
echo "    ~/.claude/watchdog/logs/    (default for installs from v0.1.0+)"
echo "    ~/.openclaw/logs/           (legacy pre-v0.1 installs)"
echo "  To inspect: bash -c 'for d in ~/.claude/watchdog/logs ~/.openclaw/logs; do [ -d \"\$d\" ] && ls -la \"\$d\"; done'"
