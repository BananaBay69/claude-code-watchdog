#!/bin/bash
# Mock pgrep — exit code controlled by MOCK_PGREP_EXIT (default 0 = process found).
exit "${MOCK_PGREP_EXIT:-0}"
