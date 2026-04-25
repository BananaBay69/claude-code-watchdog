#!/bin/bash
# Unit test: count_pane_incoming() counts "← telegram · CHATID:" markers in
# given pane content.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/../.."

# shellcheck disable=SC1091
. "$ROOT/claude-watchdog.sh"

# Case 1: zero matches
pane="OK: nothing here
just plain text
no channels"
count=$(count_pane_incoming "$pane")
[ "$count" -eq 0 ] || { echo "FAIL case1: expected 0, got $count"; exit 1; }

# Case 2: 3 matches with realistic Mr.Coconut snippet
pane="← telegram · 489601378: 在嗎
⏺ Bash(check-reply ...)
← telegram · 489601378: 現在有什麼問題
⏺ Bash(check-reply ...)
← telegram · 100000000: another chat hi
some other text"
count=$(count_pane_incoming "$pane")
[ "$count" -eq 3 ] || { echo "FAIL case2: expected 3, got $count"; exit 1; }

# Case 3: lookalike text that should NOT match (no leading arrow)
pane="discussion of telegram · 12345 in user prompt
some result mentioning telegram"
count=$(count_pane_incoming "$pane")
[ "$count" -eq 0 ] || { echo "FAIL case3: expected 0 (lookalike), got $count"; exit 1; }

echo "PASS: count_pane_incoming counts inbound markers correctly"
