# godot-soci

Godot **4.7+ GDExtension** exposing [SOCI](https://github.com/SOCI/soci)
SQLite and PostgreSQL backends through native C++ and GDScript APIs.

**Status:** v0.3.1 pre-release. Linux and Windows x86_64 packaging/real-DB
integration checks are required before publication. This is not yet a
production-certified persistence layer for a multiplayer game economy.

[API reference](docs/API.md) · [Integration test matrix](docs/TESTING.md) ·
[Architecture](docs/ARCHITECTURE.md)

## Installation

Download the **installable ZIP** from [GitHub Releases](https://github.com/PatrykCieszynski/godot-soci/releases)
(after the release workflow succeeds). Extract the included
`addons/godot_soci/` directory into your Godot project:

```text
res://
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

The ZIP contains **Debug and Release** GDExtension variants for Linux and
Windows x86_64. There is no `plugin.cfg`, EditorPlugin toggle, or requirement
for users to compile C++.

The Windows binaries are designed to use the redistributable MSVC **/MD**
runtime, rather than the Visual Studio Debug CRT. The workflow checks that
PostgreSQL/SQLite native dependencies are statically linked; Windows and Linux
packaging must pass real-engine smoke tests before release. Linux builds
target Ubuntu 22.04-era glibc or newer.

Godot's auto-downloaded GitHub *source-code* ZIP is **not** the addon ZIP: it
does not contain compiled native libraries.

## Quick start

The high-level async API lives in `SociAsyncDatabase`. Add it to the
SceneTree so it can deliver completions on the main thread:

```gdscript
var db := SociAsyncDatabase.new()
add_child(db)

if not db.start("sqlite3", ProjectSettings.globalize_path("user://game.db")):
    push_error(db.get_last_error())
    return

var schema: Dictionary = await db.execute_async(
    "CREATE TABLE IF NOT EXISTS players (id INTEGER PRIMARY KEY, name TEXT)"
)
var inserted: Dictionary = await db.execute_async(
    "INSERT INTO players (id, name) VALUES (:id, :name)",
    {"id": 42, "name": "Hero"}
)
var selected: Dictionary = await db.query_async(
    "SELECT id, name FROM players WHERE id = :id", {"id": 42}
)
if selected.get("ok", false):
    print(selected["rows"])

db.stop()
db.queue_free()
```

`start()` means the worker launched; it does **not** guarantee that a
connection has been established. Check returned `ok` and `error` fields.
The native `SociQueryDispatcher` returns a `SociQueryRequest` object or
`null` when scheduling is rejected; the GDScript convenience wrapper returns
an error dictionary for immediate rejection.

Synchronous API: `GodotSociDatabase.new()` (native) or
`SociDatabase.new()` (GDScript). Use synchronous methods only where blocking
is acceptable. See the [API reference](docs/API.md).

## Atomic SQL batches

```gdscript
var result: Dictionary = await db.transaction_async([
    {
        "sql": "UPDATE wallets SET gold=gold-:sum WHERE id=:id AND gold>=:sum",
        "params": {"id": 1, "sum": 50},
        "expected_affected_rows": 1
    },
    {
        "sql": "UPDATE wallets SET gold=gold+:sum WHERE id=:id",
        "params": {"id": 2, "sum": 50},
        "expected_affected_rows": 1
    }
])
if not result.get("ok", false):
    if result.get("outcome_unknown", false):
        push_error("Commit result is unknown: reconcile before retrying")
    else:
        push_error(result.get("error", "Transaction failed"))
```

The statements run on **one session inside one SQL transaction**. On a normal
statement error or affected-row precondition failure, the batch rolls back.
If COMMIT fails, the operation may already have been committed; callers must
use durable operation IDs and state reconciliation rather than blindly retrying.

A SQL transaction does **not** atomically change Godot in-memory state or
already-delivered RPCs.

## Guarantees and deliberate limitations

| Guaranteed by the current API | Not provided / not guaranteed |
|---|---|
| Named parameters for basic types (null/bool/int/float/String) | ORM, migrations, schema portability, automatic SQL dialect translation |
| One session per native dispatcher worker | Connection pool, simultaneous SQL within one dispatcher |
| Bounded pending requests and explicit rejection | Automatic retry, reconnect, or exactly-once effects |
| Completed results via main-thread `poll()` | Automatic engine-independent timeout or in-flight cancellation |
| Atomic SQL statement batches with row-count guards | Interactive long-lived async transactions |
| Shutdown resolves waiting requests after joining worker | Nonblocking shutdown if a database call hangs |
| Linux/Windows x86_64 build targets with packaged licenses | macOS, mobile, other CPU architectures |
| Explicit `ok`/`error` result dictionaries | All SQL types (BLOB, typed JSONB, arrays, UUIDs) |

**Important:** results capped by `max_rows` are not memory-bounded.
`stop()` can block indefinitely during a hung driver call unless connection
and SQL timeouts are configured externally. Errors after a network failure do
not prove whether a standalone mutation was committed. Transaction batches
expose `outcome_unknown` for a failure at COMMIT.

For production PostgreSQL, configure `connect_timeout` and database
`statement_timeout`/`lock_timeout`. For concurrent SQLite connections,
enable WAL and configure `PRAGMA busy_timeout` separately **per connection**.
WAL supports concurrent readers with a writer, *not multiple writers
executing simultaneously*.

**Never put database credentials in an untrusted Godot multiplayer client.**
Use this addon in the authoritative server process.

## Build from source

Prerequisites: CMake 3.23+, C++17 toolchain, Git, Python 3, SQLite development
libraries and (for PostgreSQL) `libpq` development libraries. CMake fetches
pinned SOCI and `godot-cpp` source revisions.

```bash
sudo apt-get install -y build-essential cmake git python3 libsqlite3-dev libpq-dev libfmt-dev
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug -DGODOTCPP_API_VERSION=4.7 -DGODOT_SOCI_WITH_POSTGRESQL=ON
cmake --build build --parallel 4
```

The release workflow (`.github/workflows/release.yml`) uses pinned vcpkg
dependencies to produce statically linked SQL libraries for Linux and Windows,
with Godot 4.7.2 package smoke tests. It generates a combined addon ZIP. After
merging, pushing a tag like `v0.3.1` triggers a **prerelease** only when both
platform builds and checks pass.

Run [integration tests](docs/TESTING.md) before proposing a release. Linux CI
tests against PostgreSQL in Docker; **independent Windows CI** builds a
native DLL and runs the same SQLite/PostgreSQL tests directly on
`windows-2022`, using the runner's preinstalled PostgreSQL service.
Release packaging and runtime integration are separate checks.

## License

The GDExtension wrapper is MIT-licensed ([LICENSE](LICENSE)). SOCI uses the
Boost Software License 1.0 and `godot-cpp` uses MIT. The installable archive
includes relevant third-party license notices and source licensing remains
documented in [docs/UPSTREAM.md](docs/UPSTREAM.md).

## Manual release from GitHub Actions

After merging and checking that CI is green, open
**Actions → Package Godot 4.7 addon → Run workflow**, choose **main**,
and type a semver tag such as `v0.3.2` in the `version` input.
The workflow validates the version, builds and smoke-tests both platform ZIPs,
assembles a cross-platform ZIP, and only then creates the release tag
at the tested commit and publishes a GitHub **prerelease**.
This is equivalent to pushing a `v*` tag; no local Git command is needed.
Do not reuse an existing release tag.

## Backend-switch example

`demo/backend_switch.gd` demonstrates the same API on SQLite locally
or PostgreSQL when `GODOT_SOCI_BACKEND=postgresql` and
`GODOT_SOCI_PG` are set. CI runs `tests/backend_parity_test.gd`
against both databases for basic types. Use PostgreSQL credentials only
in a trusted server process.

## Binary data (SQLite BLOB / PostgreSQL BYTEA)

Use `SociBinary.to_hex()`, `parameter_expression()`, `select_expression()`
and `from_hex()` to transfer `PackedByteArray` into native binary columns
without injecting untrusted values into SQL. This explicit conversion is
portable but incurs hex encoding overhead; it is not direct native blob binding.
See [binary usage](docs/API.md#portable-blobbytea-round-trip-godot-47).

