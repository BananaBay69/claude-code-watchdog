#!/bin/bash
# Shared assertion helpers for watchdog tests. Source from test scripts:
#     . "$(dirname "$0")/../lib/assert.sh"
# (or one ../ deeper for integration tests).
set -e

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: ${msg:-assert_eq}: expected '$expected', got '$actual'" >&2
        exit 1
    fi
}

assert_file_exists() {
    local path="$1" msg="${2:-}"
    if [ ! -f "$path" ]; then
        echo "FAIL: ${msg:-assert_file_exists}: '$path' does not exist" >&2
        exit 1
    fi
}

assert_file_missing() {
    local path="$1" msg="${2:-}"
    if [ -f "$path" ]; then
        echo "FAIL: ${msg:-assert_file_missing}: '$path' exists but shouldn't" >&2
        exit 1
    fi
}

assert_file_contains() {
    local path="$1" pattern="$2" msg="${3:-}"
    if [ ! -f "$path" ]; then
        echo "FAIL: ${msg:-assert_file_contains}: '$path' does not exist" >&2
        exit 1
    fi
    if ! grep -qE "$pattern" "$path"; then
        echo "FAIL: ${msg:-assert_file_contains}: '$path' does not contain pattern '$pattern'" >&2
        echo "  --- file contents ---" >&2
        sed 's/^/    /' "$path" >&2
        exit 1
    fi
}

assert_file_lacks() {
    local path="$1" pattern="$2" msg="${3:-}"
    [ -f "$path" ] || return 0
    if grep -qE "$pattern" "$path"; then
        echo "FAIL: ${msg:-assert_file_lacks}: '$path' contains forbidden pattern '$pattern'" >&2
        sed 's/^/    /' "$path" >&2
        exit 1
    fi
}
