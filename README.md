# godot-soci

An MIT-licensed **Godot 4.7+ GDExtension** powered by [SOCI](https://github.com/SOCI/soci), exposing synchronous and asynchronous SQLite/PostgreSQL APIs to GDScript.

> **Status: v0.3.1 preview.** Under active validation; avoid using it for production payments or game economies without further testing. Installable ZIP artifacts are produced by the release workflow for Linux and Windows x86_64. Linux CI builds and runs integration tests against Godot 4.7.2, SQLite and PostgreSQL.

## Features

- `GodotSociDatabase` native `RefCounted` class plus optional `SociDatabase` wrapper in `addons/godot_soci/database.gd`.
- SQLite (`sqlite3`) and PostgreSQL (`postgresql`) via native SOCI backends.
- Named SQL binds for `null`, `bool`, 64-bit signed integers, floats and UTF-8 strings.
- Bounded results: `query()` returns `{ok, error, rows, truncated}`; `execute()` returns `{ok, error, affected_rows}`.
- Explicit transactions: `begin()`, SQLite `begin_immediate()`, `commit()`, and `rollback()`.
- Duplicate SQL result column names rejected (use `AS` aliases).
- Native single-worker asynchronous dispatcher, bounded pending requests and retained request completion.
- A dedicated threaded SQLite example for users of the synchronous API.

## Build

Requires CMake 3.23+, Git, Python 3, C++17 compiler, SQLite development libraries and optionally PostgreSQL/`libpq`. CMake fetches pinned `godot-cpp` and SOCI revisions.

```bash
sudo apt-get install -y build-essential cmake git python3 libsqlite3-dev libpq-dev libfmt-dev
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DGODOTCPP_API_VERSION=4.7 -DGODOT_SOCI_WITH_POSTGRESQL=ON
cmake --build build --parallel 4
```

Local Windows builds require an appropriate MSVC/vcpkg setup; automated Windows packaging is handled by `.github/workflows/release.yml`. Native binaries are written to `addons/godot_soci/bin/<platform>/` and the `soci.gdextension` manifest requires Godot 4.7+.

Copy `addons/godot_soci/` into another project's `res://addons/`, including native binaries and required runtime libraries (e.g. `libpq`). The extension loads automatically; there is no EditorPlugin to enable.

## Installable release ZIPs

The `Package Godot 4.7 addon` workflow builds two Godot-compatible binaries
(debug and release) per platform on Ubuntu 22.04 and Windows 2022, using pinned
vcpkg dependencies. The workflow statically links libpq, SQLite and required
native libraries (the packaging job verifies Linux linkage), gathers third-party
license notices and tests a packaged addon in a clean Godot 4.7.2 project.

To try a release candidate, open GitHub Actions and run the packaging workflow
manually, or inspect its artifacts on the release PR. Download
`godot-soci-installable`, extract its ZIP, then copy `addons/godot_soci/` into
your Godot project. Debug and release binaries are included.

**Tagging after merging:** a tag like `v0.3.1` pushed on `main`
triggers the same checks and, only if both platforms pass, publishes
`godot-soci-v0.3.1.zip` as a prerelease on GitHub Releases.

There is no `plugin.cfg` or EditorPlugin activation step. The package is a
GDExtension (Godot 4.7+), not a standalone application. The extension still
does not support macOS, Android, iOS, or non-x86_64 builds. Keep PostgreSQL
credentials exclusively on the trusted game server. Linux binaries target
Ubuntu 22.04-era glibc or newer; older distributions are not guaranteed.

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

## Async usage (v0.2)

The native `SociQueryDispatcher` runs a single long-lived C++ worker on a dedicated database session. `SociQueryRequest` exposes `is_done()`, `get_result()` and the `completed(result)` signal. **It does not require an additional Godot worker thread.**

For a convenient GDScript `await` API, create a `SociAsyncDatabase` node and **add it to the SceneTree**. The node calls `dispatcher.poll()` every frame to deliver results on the main thread.

```gdscript
var db := SociAsyncDatabase.new()
add_child(db)
if not db.start("sqlite3", ProjectSettings.globalize_path("user://example.db")):
    push_error(db.get_last_error())
    return

var inserted: Dictionary = await db.execute_async(
    "INSERT INTO players(id, name) VALUES (:id, :name)",
    {"id": 42, "name": "Archer"}
)
var selected: Dictionary = await db.query_async(
    "SELECT id, name FROM players WHERE id=:id", {"id": 42}
)
if selected.ok:
    print(selected.rows)
db.stop()
db.queue_free()
```

`start()` schedules connection setup on the worker; it does **not** guarantee the database is reachable. A connection failure appears in the completed request's error. A request submitted at capacity is rejected immediately (native API returns `null`; the GDScript wrapper returns an `ok=false` Dictionary). `max_pending` defaults to 128 and includes running/completed-but-not-polled requests.

**Limits:** one worker per dispatcher, atomic transaction batches but no long-lived interactive transaction handles, no query cancellation or universal query timeout. `stop()` waits for any active blocking database call to finish. Configure DB/driver-side timeouts before relying on shutdown during network failures. Explicit transactions remain available through the synchronous connection API.

## Atomic async transaction batches

For small MMO operations that must either all commit or all roll back, use
`transaction_async()`. The entire batch runs as one queued job on one SOCI
session; unrelated requests cannot execute between its statements.

```gdscript
var outcome: Dictionary = await db.transaction_async([
    {"sql": "UPDATE wallets SET yang = yang - :amount WHERE id=:id AND yang >= :amount",
     "params": {"amount": 100, "id": 10}, "expected_affected_rows": 1},
    {"sql": "UPDATE wallets SET yang = yang + :amount WHERE id=:id",
     "params": {"amount": 100, "id": 20}, "expected_affected_rows": 1}
])
if not outcome.ok:
    if outcome.get("outcome_unknown", false):
        push_error("Commit outcome unknown; reconcile before retrying")
    else:
        push_error(outcome.error)
```

Each entry requires `sql`, with optional `params: Dictionary` and
`expected_affected_rows: int`. A mismatch aborts and rolls back the entire
batch. Supported statements should be non-returning SQL (DML); do not embed
transaction control or `RETURNING`. Commit failures can have an unknown outcome,
which is explicitly flagged. Use durable operation IDs/idempotency in a real
game economy and do **not** retry an unknown commit blindly.

For individual asynchronous statements use `query_async()` and
`execute_async()`. The batch feature is intentionally **not** a long-lived
transaction handle. If you need dynamic decisions between statements, use
an explicit single-session transactional service instead.

### Timeouts and shutdown

`stop()` joins the database worker and may block if a driver call hangs. For
PostgreSQL configure `connect_timeout` in the libpq connection string and
database-side `statement_timeout` / `lock_timeout` as appropriate. For
SQLite configure `PRAGMA busy_timeout` to bound lock waits; it does not cap
query execution time. These are backend-specific mitigations, **not** a
universal timeout or safe query cancellation facility.

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

v0.3 does **not** provide multi-worker connection pooling, interactive async transaction handles, query cancellation, generic timeouts, BLOB/`PackedByteArray` bindings, or first-class PostgreSQL JSON/UUID/ARRAY support. Limit large result sets using SQL pagination.

The v0.3 native request/worker/dispatcher provide a single-worker foundation plus atomic transaction batches. Multi-worker pooling requires transaction affinity and lifecycle tests. See `docs/ARCHITECTURE.md`.

SOCI does not abstract SQL dialects or migrations. Never distribute production database credentials with a game client or send raw database errors to untrusted multiplayer users.

## License

The wrapper is MIT-licensed (`LICENSE`). SOCI uses the Boost Software License 1.0, and godot-cpp is MIT. Preserve required third-party notices when distributing binaries and bundled dependencies. See `docs/UPSTREAM.md`.
