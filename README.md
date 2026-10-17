# godot-soci

**SQLite and PostgreSQL for Godot 4.7+ — one GDScript API, native C++ execution.**

[![Build and tests](https://github.com/PatrykCieszynski/godot-soci/actions/workflows/ci.yml/badge.svg)](https://github.com/PatrykCieszynski/godot-soci/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Godot 4.7+](https://img.shields.io/badge/Godot-4.7%2B-478CBF)

A [GDExtension](https://docs.godotengine.org/en/stable/tutorials/scripting/gdextension/what_is_gdextension.html) built on [SOCI](https://github.com/SOCI/soci). Start with local **SQLite** during development and switch to **PostgreSQL** on a trusted server without replacing your Godot database API.

> **Project status:** Early development. The current package targets **Windows x86_64** and **Linux x86_64**; other platforms are not packaged. This project has not been validated for production-critical game economies. Check [Releases](https://github.com/PatrykCieszynski/godot-soci/releases) for downloadable binaries — GitHub's automatically generated source ZIP is **not** an installable addon.

## Features

| Feature | Support |
| --- | --- |
| SQLite and PostgreSQL | Both through the same Godot API |
| Async SQL | Native worker thread, awaitable GDScript wrapper |
| Parameter binding | Named values, e.g. `:id` with `{"id": 42}` |
| Atomic transactions | Statement batches with rollback and optional affected-row checks |
| Backpressure | Bounded pending requests; no unbounded job queue |
| Async observability (v0.5) | Connection state notifications, queue depth and timing statistics |
| Result data | Rows returned as `Array[Dictionary]` inside an explicit result dictionary |
| Query completion | `SociQueryRequest.completed(result)` signal or just `await` |
| Binary columns | Explicit `SociBinary` helper for SQLite `BLOB` / PostgreSQL `BYTEA` (not direct native `PackedByteArray` binding yet) |
| Documentation | Godot editor class reference for native classes, [API reference](docs/API.md), [examples](demo/) |
| Distribution | Precompiled debug/release Windows and Linux x86_64 GDExtension builds |

No ORM, SQL dialect translator or connection pool is included. See [limitations](#limitations-and-safety).

## Installation

1. Download the **installable addon ZIP** from [GitHub Releases](https://github.com/PatrykCieszynski/godot-soci/releases). If there is no release yet, use [Build from source](#build-from-source).
2. Extract the included `addons/godot_soci/` folder into your project at `res://addons/godot_soci/`.
3. Restart/open Godot 4.7+ and use `SociAsyncDatabase` or `SociDatabase` in GDScript.

```text
your_project/
└── addons/
    └── godot_soci/
        ├── soci.gdextension
        ├── database.gd
        ├── async_database.gd
        ├── binary.gd
        ├── docs/
        ├── licenses/
        └── bin/
            ├── linux/
            └── windows/
```

**No EditorPlugin activation required.** Godot loads the `.gdextension` automatically. Use the packaged binaries, not the repository's source-code ZIP. PostgreSQL must be configured on a **trusted server**, never in an untrusted game client with embedded credentials.

## Quick start — async SQLite

Attach this script to a node in your scene:

```gdscript
extends Node

var db: SociAsyncDatabase


func _ready() -> void:
    db = SociAsyncDatabase.new()
    add_child(db) # Must be in the SceneTree: polls results every frame.

    var path := ProjectSettings.globalize_path("user://game.db")
    if not db.start("sqlite3", path):
        push_error(db.get_last_error())
        return

    var schema: Dictionary = await db.execute_async(
        "CREATE TABLE IF NOT EXISTS players (id BIGINT PRIMARY KEY, name TEXT)"
    )
    if not schema.get("ok", false):
        push_error(schema.get("error", "Schema creation failed"))
        return

    var inserted: Dictionary = await db.execute_async(
        "INSERT OR REPLACE INTO players (id, name) VALUES (:id, :name)",
        {"id": 42, "name": "Hero"}
    )
    if not inserted.get("ok", false):
        push_error(inserted.get("error", "Insert failed"))
        return

    var result: Dictionary = await db.query_async(
        "SELECT id, name FROM players WHERE id = :id", {"id": 42}
    )
    if result.get("ok", false):
        print(result["rows"])  # [{"id": 42, "name": "Hero"}]
    else:
        push_error(result["error"])


func _exit_tree() -> void:
    if db != null:
        db.stop()
```

The `start()` method starts the **worker**, not necessarily a successful SQL connection. An actual connection error is reported by a subsequent query. Check `result["ok"]` and `result["error"]`.

Queries run sequentially **per dispatcher**, off the Godot main thread; their results are delivered on the main thread during `poll()`. A single dispatcher is not a connection pool.

### Switch to PostgreSQL

Keep your `query_async()`, `execute_async()` and `transaction_async()` calls; change the connection configuration:

```gdscript
# For server-side code only; load the connection string from server configuration.
db.start("postgresql", OS.get_environment("GODOT_SOCI_PG"))
```

SQL **dialects still differ**. For example, the SQLite `INSERT OR REPLACE` statement above must be adapted to PostgreSQL `INSERT ... ON CONFLICT ...`. For a truly shared SQL example, see [demo/backend_switch.gd](demo/backend_switch.gd), which uses SQL supported by both backends.

## API at a glance

| GDScript entry point | Purpose |
| --- | --- |
| `SociAsyncDatabase.new()` | Node wrapper: `start()`, `query_async()`, `execute_async()`, `transaction_async()`, `stop()` |
| `SociDatabase.new()` | Blocking synchronous wrapper |
| `GodotSociDatabase.new()` | Native synchronous SQL session |
| `SociQueryDispatcher.new()` | Native async dispatcher with explicit `poll()` |
| `SociQueryRequest` | Native request with `is_done()`, `get_result()` and `completed` signal |

Query result shape:

```gdscript
{"ok": true, "error": "", "rows": [{"id": 42, "name": "Hero"}], "truncated": false}
```

Execute result shape:

```gdscript
{"ok": true, "error": "", "affected_rows": 1}
```

Use **named parameters** for values — never interpolate user input into SQL. Maximum returned rows default to **1000**, configurable via `max_rows`; check `truncated`.

Full method signatures, constraints and type mappings: **[API documentation](docs/API.md)**.

## Connection and queue diagnostics (v0.5)

`SociAsyncDatabase` exposes `get_connection_state()`,
`connection_state_changed(state)`, and `get_stats()` for measuring
native backlog, SQL execution and main-thread delivery delays.

```gdscript
db.connection_state_changed.connect(func(state: String):
    print("Database: ", state))
print(db.get_stats())
```

Connection states: `stopped`, `connecting`, `connected`, `failed`,
`disconnected`. A liveness check occurs **only after a failed SQL
operation**, not periodically. The addon never automatically retries
mutations or reconnects; game logic must reconcile uncertain outcomes.

## Native synchronous error details

`GodotSociDatabase` and `SociDatabase` expose `get_last_error_details()`. Failed
`execute`/`query` results include backend/category/code/SQLSTATE alongside the
existing error text; boolean transaction methods retain their return types. Read
details before successful rollback clears them. This adds diagnostics, not an
automatic retry policy. See [the API contract](docs/API.md#synchronous-structured-failures).

## Transactions

Use `transaction_async()` to execute a batch atomically. The optional `expected_affected_rows` acts as an optimistic safety check:

```gdscript
var result: Dictionary = await db.transaction_async([
    {
        "sql": "UPDATE wallets SET gold = gold - :amount WHERE id = :id AND gold >= :amount",
        "params": {"id": 1, "amount": 50},
        "expected_affected_rows": 1
    },
    {
        "sql": "UPDATE wallets SET gold = gold + :amount WHERE id = :id",
        "params": {"id": 2, "amount": 50},
        "expected_affected_rows": 1
    }
])

if not result.get("ok", false):
    if result.get("outcome_unknown", false):
        push_error("Commit outcome unknown; reconcile before retrying.")
    else:
        push_error(result.get("error", "Transaction failed"))
```

The batch rolls back on ordinary statement failures. A transport failure at **COMMIT** can leave its outcome unknown; don't blindly retry critical mutations.

## Signals or `await`?

Both APIs use the **same** completion mechanism. Choose whichever fits your code.

The `SociAsyncDatabase` wrapper converts the native `completed(result)` signal into an awaitable dictionary:

```gdscript
var result: Dictionary = await db.query_async("SELECT 1 AS value")
```

If you need the request object or explicit polling, use `SociQueryDispatcher`:

```gdscript
extends Node

var dispatcher := SociQueryDispatcher.new()

func _ready() -> void:
    if not dispatcher.start("sqlite3", ":memory:"):
        push_error(dispatcher.get_last_error())
        return
    var request: SociQueryRequest = dispatcher.query_async("SELECT 1 AS value")
    if request != null:
        request.completed.connect(_on_query_completed)

func _process(_delta: float) -> void:
    dispatcher.poll() # Dispatch completions on the main thread.

func _on_query_completed(result: Dictionary) -> void:
    print(result)

func _exit_tree() -> void:
    dispatcher.stop()
```

There are **no automatic `row_inserted` / `row_updated` / `row_deleted` signals**. This is an SQL query layer, not a change-tracking ORM: raw SQL, triggers and stored procedures make row-level events unreliable.

## Binary data

`SociBinary` supports an **explicit**, portable conversion between `PackedByteArray` and native SQLite `BLOB` / PostgreSQL `BYTEA` columns. The current version binds hex as text and uses database conversion functions; it is **not** transparent native binary parameter binding yet.

```gdscript
var bytes := PackedByteArray([0, 128, 255])
var expr := SociBinary.parameter_expression(backend, "payload")
var saved: Dictionary = await db.execute_async(
    "INSERT INTO files (data) VALUES (" + expr + ")",
    {"payload": SociBinary.to_hex(bytes)}
)
```

For reading bytes back, use `SociBinary.select_expression()` and `SociBinary.from_hex()`. See the [complete round-trip example](docs/API.md#portable-blobbytea-round-trip-godot-47). Hex conversion adds overhead; do not use it for large streaming payloads.

**TODO — native binary bindings (future optimization):** Replace the explicit hex helper with transparent `PackedByteArray` parameter/result mapping, e.g. `{"payload": bytes}` and `row["payload"] is PackedByteArray`. SOCI's `blob` maps to SQLite BLOB but PostgreSQL large objects (OID), **not** BYTEA; a correct implementation must handle both backends separately, including empty data, NUL bytes, and large payloads. The current bound hex approach reliably stores real BLOB/BYTEA values, at the cost of ~2× larger transferred parameter/result strings and encoding/decoding CPU. **Not a blocker** for the current addon or the MMO; revisit when real workloads justify optimizing binary storage.

## Examples and documentation

- [Backend-switch demo](demo/backend_switch.gd) — identical Godot API with SQLite or PostgreSQL.
- [SQLite demos](demo/sqlite/) — basic and threaded examples.
- [PostgreSQL demo](demo/postgresql/basic.gd) — connection and SQL.
- [API reference](docs/API.md) — native/wrapper methods, result types and failure modes.
- [Integration tests](docs/TESTING.md) — real SQLite/PostgreSQL on Linux and Windows.
- [Architecture](docs/ARCHITECTURE.md) — dispatcher and worker design.
- [Upstream dependencies](docs/UPSTREAM.md) — pinned versions and licenses.

## Limitations and safety

- **Only Windows/Linux x86_64 packages.** macOS, mobile, Web and other architectures require separate builds and tests.
- **Backend portability is API-level, not SQL-level.** Schema definitions, UPSERT syntax, migrations and database-specific types remain your responsibility.
- **One native worker/session per dispatcher.** No built-in pool, automatic reconnect, cancellation, query timeout or automatic retry.
- **`stop()` can block** while a database operation is running. Set PostgreSQL `connect_timeout`, `statement_timeout` and `lock_timeout`; configure SQLite `PRAGMA busy_timeout` per connection.
- **Large query results cost memory.** `max_rows` caps row count, not the size of each row.
- **No client-side PostgreSQL credentials.** Run this addon on the authoritative server when connecting to protected databases.

## Build from source

Requires CMake 3.23+, Python 3, Git, a C++17 toolchain, SQLite headers/libs and optionally PostgreSQL `libpq`. CMake fetches pinned `godot-cpp` and SOCI revisions.

```bash
sudo apt-get install -y build-essential cmake git python3 libsqlite3-dev libpq-dev libfmt-dev
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DGODOTCPP_API_VERSION=4.7 -DGODOT_SOCI_WITH_POSTGRESQL=ON
cmake --build build --parallel 4
```

GitHub Actions uses one [CI workflow](.github/workflows/ci.yml): pull requests
build and test Godot `template_debug` on both Linux and Windows; merges to
`main` additionally build `template_release`, smoke-test installable platform
ZIPs and assemble a downloadable `godot-soci-installable` artifact. The **same
native binaries** pass integration and package tests before publication.

[Publishing](.github/workflows/release.yml) is a separate, fast **artifact
promotion** workflow: after a successful `main` CI run, choose **Actions →
Publish tested Godot SOCI addon → Run workflow**, select `main`, and supply
a new version like `v0.4.1`. It finds the successful `main` CI artifact
for the **exact SHA** being released, creates the tag and GitHub prerelease,
and uploads the unchanged ZIP without recompiling it. Pushing a new `v*`
tag at an already-tested commit on `main` is also supported.
Artifacts expire after 90 days; if one is missing, run CI again on the
intended commit before publishing.

**Windows release guarantee:** Godot's `template_debug` and
`template_release` are distinct engine target variants, not CMake
Debug/Release library selections. CI builds both with
`CMAKE_BUILD_TYPE=Release` and `x64-windows-static-md`, validates the DLL
link command uses `vcpkg/installed/.../lib/sqlite3.lib` rather than
`debug/lib/sqlite3.lib`, and checks `sqlite_compileoption_used('SQLITE_DEBUG')`
in the real engine. No SOCI or worker-thread modifications are needed.

## License

The godot-soci wrapper is [MIT-licensed](LICENSE). SOCI uses Boost Software License 1.0, and `godot-cpp` uses MIT. Binary distributions include third-party notices and license texts.
