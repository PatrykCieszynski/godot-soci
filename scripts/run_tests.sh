#!/usr/bin/env bash
set -euo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"
"$GODOT_BIN" --headless --path . --editor --quit
"$GODOT_BIN" --headless --path . --script res://tests/sqlite_test.gd
"$GODOT_BIN" --headless --path . --script res://demo/sqlite/threaded.gd
if [[ -n "${GODOT_SOCI_PG:-}" ]]; then
    "$GODOT_BIN" --headless --path . --script res://tests/postgresql_test.gd
else
    echo 'POSTGRESQL TEST SKIPPED: set GODOT_SOCI_PG to run it.'
fi
