#!/bin/bash
# Top-level test runner. Discovers and runs all *.test.sh files under
# test/unit/ and test/integration/. Exits 0 on full pass, 1 on any fail.
#
# Usage: bash test/run.sh
set +e

cd "$(dirname "$0")"

PASS=0
FAIL=0
FAILED_TESTS=()

for test_file in unit/*.test.sh integration/*.test.sh; do
    [ -f "$test_file" ] || continue
    printf "RUN  %-55s ... " "$test_file"
    if output=$(bash "$test_file" 2>&1); then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL"
        echo "$output" | sed 's/^/      /'
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$test_file")
    fi
done

echo
echo "===================="
echo "Results: $PASS pass, $FAIL fail"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
exit 0
