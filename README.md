# godot-soci

An MIT-licensed **Godot 4.7+ GDExtension** powered by [SOCI](https://github.com/SOCI/soci), exposing SQLite and PostgreSQL through a common synchronous GDScript API.

> **Status: v0.1.x preview.** Under active validation; avoid using it for production payments or game economies without further testing. The source repository does not ship binaries. Linux CI builds and runs integration tests against Godot 4.7.2, SQLite and PostgreSQL.

## Features

- `GodotSociDatabase` native `RefCounted` class plus optional `SociDatabase` wrapper in `addons/godot_soci/database.gd`.
- SQLite (`sqlite3`) and PostgreSQL (`postgresql`) via native SOCI backends.
- Named SQL binds for `null`, `bool`, 64-bit signed integers, floats and UTF-8 strings.
- Bounded results: `query()` returns `{ok, error, rows, truncated}`; `execute()` returns `{ok, error, affected_rows}`.
- Explicit transactions: `begin()`, SQLite `begin_immediate()`, `commit()`, and `rollback()`.
- Duplicate SQL result column names rejected (use `AS` aliases).
- A dedicated threaded SQLite example; native `query_async()` is not available yet.

## Build

Requires CMake 3.23+, Git, Python 3, C++17 compiler, SQLite development libraries and optionally PostgreSQL/`libpq`. CMake fetches pinned `godot-cpp` and SOCI revisions.

```bash
sudo apt-get install -y build-essential cmake git python3 libsqlite3-dev libpq-dev libfmt-dev
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DGODOTCPP_API_VERSION=4.7 -DGODOT_SOCI_WITH_POSTGRESQL=ON
cmake --build build --parallel 4
```

Windows requires an appropriate MSVC/vcpkg setup; automated Windows builds remain a future task. Native binaries are written to `addons/godot_soci/bin/<platform>/` and the `soci.gdextension` manifest requires Godot 4.7+.

Copy `addons/godot_soci/` into another project's `res://addons/`, including native binaries and required runtime libraries (e.g. `libpq`). The extension loads automatically; there is no EditorPlugin to enable.

## Example

```gdscript
var db := GodotSociDatabase.new()
if not db.open("sqlite3", ProjectSettings.globalize_path("user://example.db")):
    push_error(db.get_last_error())
    return

db.execute("CREATE TABLE IF NOT EXISTS players(id BIGINT PRIMARY KEY, name TEXT)")
var inserted := db.execute("INSERT INTO players(id, name) VALUES(:id, :name)", {"id": 42, "name": "Archer"})
var result := db.query("SELECT id, name FROM players WHERE id=:id", {"id": 42})
if result["ok"]:
    print(result["rows"])
db.close()
```

You can also instantiate `SociDatabase.new()` for the equivalent thin GDScript wrapper API. **Both APIs are synchronous** and may block the caller; keep slow SQL away from gameplay frames. For off-thread use, create/open/use/close a separate instance inside each worker thread; see `demo/sqlite/threaded.gd`.

Use the explicit transaction methods; `execute("BEGIN")` bypasses the native transaction-state flag. A failed commit has an unknown outcome and must not be blindly retried for currency/item transfers.

## Demos and tests

```bash
export GODOT_BIN=godot
bash scripts/run_demos.sh
bash scripts/run_tests.sh
```

To enable local PostgreSQL tests using a disposable database:

```bash
docker compose -f demo/postgresql/docker-compose.yml up -d --wait
export GODOT_SOCI_PG='host=127.0.0.1 port=55432 dbname=godot_soci_demo user=demo password=demo'
bash scripts/run_tests.sh
docker compose -f demo/postgresql/docker-compose.yml down -v
```

Demos: `demo/sqlite/basic.gd`, `demo/sqlite/threaded.gd`, `demo/postgresql/basic.gd`. Tests: `tests/sqlite_test.gd`, `tests/postgresql_test.gd`.

## Roadmap / limitations

v0.1 does **not** provide a native dispatcher, connection pooling, query cancellation, generic timeouts, BLOB/`PackedByteArray` bindings, or first-class PostgreSQL JSON/UUID/ARRAY support. Limit large result sets using SQL pagination.

Next, implement real `query_request` and `query_worker` components with bounded queues, safe completion, and worker-owned sessions. Avoid creating unused placeholders. See `docs/ARCHITECTURE.md`.

SOCI does not abstract SQL dialects or migrations. Never distribute production database credentials with a game client or send raw database errors to untrusted multiplayer users.

## License

The wrapper is MIT-licensed (`LICENSE`). SOCI uses the Boost Software License 1.0, and godot-cpp is MIT. Preserve required third-party notices when distributing binaries and bundled dependencies. See `docs/UPSTREAM.md`.
