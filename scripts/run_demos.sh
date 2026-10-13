#!/usr/bin/env bash
set -euo pipefail
GODOT_BIN="${GODOT_BIN:-godot}"
"$GODOT_BIN" --headless --path . --editor --quit
"$GODOT_BIN" --headless --path . --script res://demo/scripts/sqlite_demo.gd
"$GODOT_BIN" --headless --path . --script res://demo/scripts/threaded_sqlite.gd
if [[ -n "${GODOT_SOCI_PG:-}" ]]; then
  "$GODOT_BIN" --headless --path . --script res://demo/scripts/postgres_demo.gd
else
  echo 'Skipped PostgreSQL demo: set GODOT_SOCI_PG.'
fi
