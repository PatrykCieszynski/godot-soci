#!/usr/bin/env bash
set -euo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"
# Work around Godot issue #111048: immediate editor shutdown can race
# GDExtension documentation generation.
echo "::group::Import project in Godot editor"
timeout --signal=TERM --kill-after=5s 45s \
  "$GODOT_BIN" --headless --path . --editor --quit-after 120 --frame-delay 50
echo "::endgroup::"

run_test() {
    local resource="$1"
    local expected_marker="$2"
    local output
    output="$(mktemp)"
    echo "::group::Integration: $resource"
    # A script parse error can prevent SceneTree.quit() and otherwise hang CI.
    if ! timeout --signal=TERM --kill-after=5s 60s \
        "$GODOT_BIN" --headless --path . --script "$resource" 2>&1 | tee "$output"; then
        echo "::error::$resource returned a failure or exceeded 60 seconds."
        rm -f "$output"
        exit 1
    fi
    if ! grep -Fq "$expected_marker" "$output"; then
        echo "::error::$resource terminated without expected PASS marker: $expected_marker"
        rm -f "$output"
        exit 1
    fi
    rm -f "$output"
    echo "::endgroup::"
}

run_test res://tests/sqlite_test.gd "SQLITE INTEGRATION PASS"
run_test res://tests/async_sqlite_test.gd "ASYNC SQLITE PASS"
run_test res://tests/sqlite_wal_concurrency_test.gd "SQLITE WAL CONCURRENCY PASS"
run_test res://tests/async_failure_test.gd "ASYNC FAILURE PATHS PASS"
run_test res://demo/sqlite/threaded.gd "THREAD DEMO PASS"

if [[ -n "${GODOT_SOCI_PG:-}" ]]; then
    run_test res://tests/postgresql_test.gd "POSTGRESQL INTEGRATION PASS"
    run_test res://tests/async_postgresql_test.gd "ASYNC POSTGRESQL PASS"
else
    echo 'POSTGRESQL TEST SKIPPED: set GODOT_SOCI_PG to run it.'
fi
