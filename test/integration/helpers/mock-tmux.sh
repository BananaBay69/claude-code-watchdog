#!/bin/bash
# Mock tmux for integration tests. Logs each invocation to MOCK_TMUX_LOG (if set);
# subcommand behavior is controlled via MOCK_* env vars.
#
# Install by copying to a directory on PATH (ahead of real tmux), named "tmux".

if [ -n "${MOCK_TMUX_LOG:-}" ]; then
    echo "tmux $*" >> "$MOCK_TMUX_LOG"
fi

case "$1" in
    has-session)
        exit "${MOCK_TMUX_HAS_SESSION_EXIT:-0}"
        ;;
    capture-pane)
        if [ -n "${MOCK_TMUX_PANE_FILE:-}" ] && [ -f "$MOCK_TMUX_PANE_FILE" ]; then
            cat "$MOCK_TMUX_PANE_FILE"
        fi
        exit 0
        ;;
    display-message)
        echo "${MOCK_TMUX_PANE_PID:-12345}"
        exit 0
        ;;
    new-session|kill-session|send-keys)
        exit 0
        ;;
    *)
        echo "mock-tmux: unimplemented subcommand '$1' ($*)" >&2
        exit 1
        ;;
esac
