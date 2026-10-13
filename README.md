# godot-soci

A small **Godot GDExtension** backed by [SOCI](https://github.com/SOCI/soci), providing SQLite and PostgreSQL through a uniform API for Godot 4.x / GDScript. Based on the layout and registration pattern of [godot-cpp-template](https://github.com/godotengine/godot-cpp-template).

**Status: v0.1 source preview, not yet built or runtime-tested here.** Do not use for production payments/game economy without CI, integration testing and an audit. The ZIP is a complete *source* repository; it intentionally does not include binaries or third-party source. CMake fetches pinned upstream commits.

## Features

- `GodotSociDatabase` native `RefCounted`, instantiable directly in GDScript.
- Backends: `sqlite3`; `postgresql` by default (can disable at build time).
- Named SQL parameters via SOCI, with explicit type handling for null, booleans, 64-bit signed integers, floating-point values and UTF-8 strings.
- Read queries return `Dictionary { ok, error, rows, truncated }`, each row a `Dictionary`; default bounded 1,000 rows, maximum 100,000. Use `LIMIT` in SQL for real pagination.
- Mutations return `{ ok, error, affected_rows }`.
- `begin()`, SQLite-only `begin_immediate()`, `commit()`, `rollback()`.
- No database credentials are hard-coded in the project. Connection string passed at runtime.
- A **real threaded** SQLite example with worker-owned connection, plus SQLite/PostgreSQL transaction demos.
- `godot-soci` is a *synchronous driver*. Godot's `Thread` supplies concurrency; `await` / `call_deferred()` alone do not.

## Build (Linux x86_64)

Prerequisites: CMake >= 3.23, Git, Python 3, a C++17 compiler, development libraries for SQLite and `libpq`, a recent Godot 4 desktop/editor executable. CMake downloads `godot-cpp` and `SOCI` (including SOCI's fmt dependency submodule). Network access is required on first configure.

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake git python3 libsqlite3-dev libpq-dev libfmt-dev
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DGODOT_SOCI_WITH_POSTGRESQL=ON
cmake --build build --config Debug --parallel 4
# The native binary is written to addons/godot_soci/bin/linux/
```

On Windows, use Visual Studio 2022 or newer with CMake; install SQLite and PostgreSQL development libraries through vcpkg or another package manager. Pass `-DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake` as appropriate. **CI must verify Windows output names and runtime DLL dependencies before publishing prebuilt releases.**

The CMake file pins upstream commits to the versions inspected during this implementation. For Godot 4.7 and later, check your Godot executable/API compatibility with the pinned `godot-cpp` version. You can override `-DGODOT_SOCI_GODOT_CPP_REF=<tag-or-sha>` and `-DGODOT_SOCI_SOCI_REF=<tag-or-sha>` for an upgrade.

### Portable addon installation

Copy **`addons/godot_soci/`** into another Godot project's `res://addons/` folder. You must include the compiled libraries in `addons/godot_soci/bin/` for every platform/configuration you use. This plugin has no `EditorPlugin` to enable: the `.gdextension` is loaded automatically when its native binary exists.

## API example

```gdscript
var db := GodotSociDatabase.new()
if not db.open("sqlite3", ProjectSettings.globalize_path("user://example.db")):
    push_error(db.get_last_error())
    return

var created := db.execute("CREATE TABLE IF NOT EXISTS players (id BIGINT PRIMARY KEY, name TEXT)")
var inserted := db.execute("INSERT INTO players(id, name) VALUES (:id, :name)", {"id": 123, "name": "Archer"})
var result := db.query("SELECT id, name FROM players WHERE id = :id", {"id": 123}, 100)
if result["ok"]:
    print(result["rows"])
else:
    push_error(result["error"])
db.close()
```

Or connect to PostgreSQL using a libpq-style string such as `host=127.0.0.1 port=55432 dbname=godot_soci_demo user=demo password=demo` (example-only credentials).

### Transactions

```gdscript
if db.begin_immediate():  # sqlite3 only; db.begin() works on either backend
    var outcome := db.execute("UPDATE wallets SET yang = yang - :amount WHERE id = :id", {"amount": 10, "id": 123})
    if outcome["ok"] and outcome["affected_rows"] == 1:
        if not db.commit():
            push_error("Unknown commit outcome; reconcile before any retry")
    else:
        db.rollback()
```

**Do not** automatically retry failed commits; the transaction may have committed before the connection failed. For real economy operations implement durable command IDs and atomic receipts at the application layer. For SQLite `begin_immediate()` reserves the writer slot before the first mutation; regular `begin()` uses backend defaults. PostgreSQL has different locking and concurrency semantics; SOCI does **not** translate your SQL dialect or schema.

### Threading

Never use a single `GodotSociDatabase` instance from multiple threads concurrently. Instead create/open/use/close a separate instance *inside each worker thread*. The class intentionally does not advertise `query_async()` because the database operations are synchronous in the calling thread. See the working example `demo/scripts/threaded_sqlite.gd`.

## Run demos

The repository root is a Godot project (`project.godot`) containing the addon and demos.

```bash
# After building, with Godot installed:
export GODOT_BIN=godot
./scripts/run_demos.sh  # SQLite and a real threaded SQLite demo

# PostgreSQL demo with a temporary local database
# Requires Docker Compose:
docker compose -f demo/docker-compose.yml up -d --wait
export GODOT_SOCI_PG='host=127.0.0.1 port=55432 dbname=godot_soci_demo user=demo password=demo'
./scripts/run_demos.sh
# Then stop containers if desired:
docker compose -f demo/docker-compose.yml down -v
```

Or run a single test manually: `godot --headless --path . --script res://demo/scripts/postgres_demo.gd`.

For SQLite files in paths containing spaces, pass **the bare full path** to `open("sqlite3", path)` and set `PRAGMA` options explicitly, instead of concatenating `dbname=... timeout=...` into a space-delimited string.

Demo coverage: schema initialization, parameter binding, SQL escaping, 64-bit integers, UTF-8, NULL values, commit/rollback; SQLite WAL/FULL; and a threaded read/write example. PostgreSQL is optional if the connection env variable is absent.

## Limitations in v0.1

- Synchronous API. Thread scheduling, queueing, connection pools and cancellation are intentionally outside this generic driver. Don't invoke potentially slow SQL directly from a gameplay frame.
- `execute()` is for statements not returning rows. Use `query()` for `SELECT` or DML `RETURNING`.
- Supported binds: `null`, `bool`, `int`, `float`, `String`. Unsupported Godot Variants fail explicitly. Arrays, byte arrays, binary `BLOB`/`BYTEA`, JSON and typed time values need a separately designed API. Complex result columns can be cast to `TEXT` in SQL.
- No SQL dialect or migration translation. `CREATE TABLE`, triggers, `PRAGMA`, lock semantics and custom SQL functions can differ across backends.
- One connection per instance, caller must serialize access. Use explicit rollback on validation failures, then close connections before dropping their owning threads.
- `open` errors may contain server details despite basic `password=` redaction; keep detailed errors server-side and never expose SQL/DB errors directly to public clients.
- No query cancellation or query timeout abstraction yet. PostgreSQL connection/query timeouts may be specified at the server/connection level; SQLite `PRAGMA busy_timeout` controls busy wait.
- Binaries are server-side dependencies; don't distribute production database credentials or libpq-enabled server addon with an untrusted multiplayer game client.

## Repository structure

```text
addons/godot_soci/             Godot-installable addon (native binary generated by CMake)
src/                          C++ GDExtension (SOCI binding)
demo/scripts/sqlite_demo.gd    SQLite smoke + transactions
demo/scripts/postgres_demo.gd  PostgreSQL smoke + transactions
demo/scripts/threaded_sqlite.gd   Actual Godot worker thread demo
demo/docker-compose.yml       Local disposable PostgreSQL
docs/                          Design and testing notes
.github/workflows/             Linux source build check
```

## Upstream licenses

This wrapper is MIT-licensed (`LICENSE`). SOCI is distributed under Boost Software License 1.0; godot-cpp is MIT-licensed. Their original source files and license notices remain in their respective upstream dependencies obtained during the build. See `docs/UPSTREAM.md` for pinned revisions and attribution.
