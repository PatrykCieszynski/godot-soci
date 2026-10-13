#!/usr/bin/env bash
set -euo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"
# Work around Godot issue #111048: immediate editor shutdown can race GDExtension docs generation.
"$GODOT_BIN" --headless --path . --editor --quit-after 120 --frame-delay 50
"$GODOT_BIN" --headless --path . --script res://tests/sqlite_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/async_sqlite_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/sqlite_wal_concurrency_test.gd
"$GODOT_BIN" --headless --path . --script res://tests/async_failure_test.gd
"$GODOT_BIN" --headless --path . --script res://demo/sqlite/threaded.gd
if [[ -n "${GODOT_SOCI_PG:-}" ]]; then
    "$GODOT_BIN" --headless --path . --script res://tests/postgresql_test.gd
    "$GODOT_BIN" --headless --path . --script res://tests/async_postgresql_test.gd
else
    echo 'POSTGRESQL TEST SKIPPED: set GODOT_SOCI_PG to run it.'
fi
