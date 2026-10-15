# API reference — godot-soci 0.5 (unreleased, Godot 4.7+)

This documents the **current public API**, not planned connection-pool features.
Native classes are registered by `soci.gdextension`; `SociDatabase` and
`SociAsyncDatabase` are optional GDScript wrappers. Install the complete
`addons/godot_soci/` directory (including the compiled binary for the OS).

## Supported input and output types

| GDScript parameter | SQL bind type | Returned value |
|---|---|---|
| `null` | SQL NULL | `null` |
| `bool` | integer 0/1 | integer |
| `int` | signed 64-bit integer | `int` |
| `float` | double, finite only in async | `float` |
| `String` | UTF-8 text | `String` |
| date/time columns | backend-dependent | timestamp string, not DateTime object |

Complex native types (`PackedByteArray`, JSON/JSONB object mapping, UUID,
arrays) have no first-class bind mapping in the SOCI session. For portable
BLOB/BYTEA storage, use the `SociBinary` helper documented below. Other
complex values should be cast to a supported SQL type where appropriate.
Use named SQL parameters (`:id` in SQL with `{"id": 42}`), not string interpolation.
Duplicate SELECT column names are rejected: use SQL `AS` aliases.

## `GodotSociDatabase` (native, `RefCounted`, synchronous)

| Method | Return | Contract |
|---|---|---|
| `open(backend: String, connection_string: String)` | `bool` | Opens `"sqlite3"` or `"postgresql"`; blocking. |
| `close()` | `void` | Closes owned session. |
| `is_open()` | `bool` | True if SOCI reports an open connection. |
| `get_backend()` | `String` | Selected backend. |
| `get_last_error()` | `String` | Last driver failure string. |
| `execute(sql: String, params: Dictionary = {})` | `Dictionary` | Non-row-returning SQL. |
| `query(sql: String, params: Dictionary = {}, max_rows: int = 1000)` | `Dictionary` | Fetches at most `max_rows` rows; allowed 1–100000. |
| `begin()` | `bool` | Start explicit transaction. |
| `begin_immediate()` | `bool` | SQLite immediate transaction (SQLite only). |
| `commit()` | `bool` | Attempt commit. |
| `rollback()` | `bool` | Attempt rollback. |
| `in_transaction()` | `bool` | State of explicit transaction API, not a SQL parser. |

`SociDatabase.new()` provides the same methods by delegation. Both are
**synchronous** and can block the Godot main thread. If used on another thread,
create/open/use/close the instance on that thread. Do not share one session
concurrently.

**Query result:**
`{"ok": bool, "error": String, "rows": Array[Dictionary], "truncated": bool}`.

**Execute result:**
`{"ok": bool, "error": String, "affected_rows": int}`.

Check `ok` before accessing optional success fields. `truncated=true`
means results exceeded the cap: use pagination for big datasets. A `max_rows`
cap does *not* limit row size/memory usage.

Always use `begin()/commit()/rollback()` to manage explicit transactions
rather than `execute("BEGIN")`; bypassing the public API can desynchronize
the internal transaction flag.

## `SociQueryDispatcher` (native, `RefCounted`, asynchronous)

| Method | Return | Contract |
|---|---|---|
| `start(backend, connection_string, max_pending=128)` | `bool` | Starts one native worker thread. **Not a connection-success check**. `max_pending`: 1–10000. |
| `query_async(sql, params={}, max_rows=1000)` | `SociQueryRequest` or `null` | Schedules SELECT/row query. |
| `execute_async(sql, params={})` | `SociQueryRequest` or `null` | Schedules a non-returning statement. |
| `transaction_async(statements: Array)` | `SociQueryRequest` or `null` | Schedules an atomic batch of 1–128 statements. |
| `poll(max_completions=64)` | `int` | **Main-thread only.** Converts queued native results into Godot objects and emits completion signals. |
| `pending()` | `int` | All not-yet-delivered requests (queued + executing + waiting for poll). |
| `get_last_error()` | `String` | Most recent scheduling/configuration error. |
| `is_started()` | `bool` | Worker was started, *not* proof of a live SQL session. |
| `get_connection_state()` | `String` | Native worker state: stopped, connecting, connected, failed, disconnected. |
| `get_stats()` | `Dictionary` | Request backlog and average queue/execution/delivery times in ms. |
| `connection_state_changed(state)` | signal | Main-thread notification for observed changes; may skip brief states. |
| `stop()` | `void` | Drops queued tasks, joins worker and resolves outstanding requests; **may block**. |

Every dispatcher owns **one** long-lived SOCI worker/session and has a bounded
pending count. It does not provide a multi-connection pool or concurrent SQL
execution *within that dispatcher*. Multiple independent dispatchers can run
simultaneously on independent sessions.

If the dispatcher is not started, backpressure is exceeded, or a parameter
is invalid, scheduling returns `null`; inspect `get_last_error()`.
If connecting to PostgreSQL fails **after** `start()`, requests resolve with
`ok=false` and an error rather than `start()` returning false.

`SociQueryRequest` exposes:
- `is_done() -> bool`;
- `get_result() -> Dictionary` (inspect only when done);
- `completed(result: Dictionary)` signal (delivered on the polling thread).

Keep requests alive until completed, and check `is_done()` before awaiting a
signal if the request may already have completed.

## `SociAsyncDatabase` (GDScript `Node` convenience wrapper)

Create the node **and add it to the SceneTree**. It calls `poll()` each frame
and returns a `Dictionary` from awaitable methods:

```gdscript
var db := SociAsyncDatabase.new()
add_child(db)
if not db.start("sqlite3", ProjectSettings.globalize_path("user://players.db")):
    push_error(db.get_last_error())
    return

var result: Dictionary = await db.query_async(
    "SELECT id, name FROM players WHERE id = :id", {"id": 42}
)
if result.get("ok", false):
    print(result["rows"])

db.stop()
db.queue_free()
```

The wrapper supports `start/stop/is_started/pending/get_last_error`,
`query_async`, `execute_async` and `transaction_async`. If the native queue
rejects a request, the wrapper yields no result and instead returns an immediate
`{"ok": false, "error": "..."}` dictionary of the same basic shape.

## Async observability (v0.5)

`SociAsyncDatabase` forwards the native `get_connection_state()`,
`get_stats()` and `connection_state_changed(state: String)`.

```gdscript
db.connection_state_changed.connect(func(state: String):
    print("Database: ", state))
print(db.get_stats())
```

The statistics dictionary contains `connection_state`, `pending`,
`queued`, `executing`, `awaiting_poll`, `submitted`, `completed`,
`failed`, `rejected`, `canceled`, `avg_queue_ms`,
`avg_execution_ms`, and `avg_delivery_ms`. Completed includes failed
SQL responses, but not operations canceled before they ran. Counters
reset at start; averages are zero until the first delivered completion.

An asynchronous initial connection failure sets `failed`; a query
failure with a failed SOCI liveness check sets `disconnected`.
The worker does **not** automatically reconnect or retry. State
notifications are delivered only on the main thread, so very short
intermediate states may be skipped. For ambiguous financial or item
updates, reconcile using application operation IDs before retrying.

## Atomic asynchronous batches

```gdscript
var transfer: Dictionary = await db.transaction_async([
    {
        "sql": "UPDATE wallets SET gold = gold - :amount WHERE id=:id AND gold >= :amount",
        "params": {"id": 1, "amount": 50},
        "expected_affected_rows": 1
    },
    {
        "sql": "UPDATE wallets SET gold = gold + :amount WHERE id=:id",
        "params": {"id": 2, "amount": 50},
        "expected_affected_rows": 1
    }
])
if not transfer.get("ok", false):
    if transfer.get("outcome_unknown", false):
        push_error("Commit may have happened. Reconcile; never blindly retry.")
    else:
        push_error(transfer.get("error", "Unknown transaction failure"))
```

Batch item schema: `{"sql": String, "params": Dictionary = {},
"expected_affected_rows": int?}`. The optional expected count must be
non-negative. A mismatch aborts the batch and rolls back the transaction.
Use non-row-returning SQL, no `RETURNING`, and **do not issue your own
transaction-control SQL** within the batch.

Successful and failed batch results include
`ok: bool`, `error: String`, `affected_rows: int`,
`affected_rows_per_statement: Array[int]`, and `outcome_unknown: bool`.
`outcome_unknown=true` indicates a commit exception, which can leave the
database result undetermined. Statement-level failures normally roll back, but
network failures and disconnected sessions still require reconciliation.
A transaction in SQL is atomic **only for SQL data**, not in-memory Godot state
or already-sent RPCs.

## Guarantees, caveats and explicitly unsupported features

**Provided:**
- Parameter binding; single-owner per worker; bounded pending request capacity.
- In-order execution on one dispatcher worker; callbacks delivered by
  `poll()` on the calling thread.
- Explicit SQL transaction batches commit all or roll back ordinary SQL errors,
  with optional affected-row preconditions.
- `stop()` settles pending requests and preserves outcomes already completed.

**Not guaranteed:**
- Automatic retries, automatic reconnect, or exactly-once RPC/gameplay effects.
- Driver-independent connect/query/lock timeout or safe nonblocking shutdown.
  `stop()` joins the worker and may block indefinitely without DB timeouts.
- Full atomicity across Godot SceneTree changes and SQL transactions.
- A connection pool; long-lived interactive async transactions; cancellation
  of an already-running SQL statement; streaming big query results.
- All SQL dialects behaving identically or any ORM/migration facility.
- Portability outside packaged platforms or direct Postgres access from
  untrusted multiplayer clients.

Configure PostgreSQL `connect_timeout`, database `statement_timeout`, and
`lock_timeout`; for SQLite set `PRAGMA busy_timeout` **per connection**.
These reduce common hangs but do not provide a general query deadline.
If `ok=false` for a critical mutation, reconcile against the durable state
and use idempotency keys before retries.

See [Testing](TESTING.md), [Architecture](ARCHITECTURE.md) and the
[project README](../README.md).

## Built-in editor documentation

The debug native GDExtension embeds the Godot class-reference XML for
`GodotSociDatabase`, `SociQueryDispatcher` and `SociQueryRequest`.
Use the editor Help / Search Help to inspect methods. The high-level
`SociAsyncDatabase` wrapper uses GDScript doc comments.

## SQLite → PostgreSQL parity demo

Run the same code against both backends:

```bash
godot --headless --path . --script res://demo/backend_switch.gd
GODOT_SOCI_BACKEND=postgresql GODOT_SOCI_PG='host=127.0.0.1 port=5432 dbname=game user=game password=example' \
  godot --headless --path . --script res://demo/backend_switch.gd
```

See `tests/backend_parity_test.gd` for cross-backend checks of int64,
double, UTF-8 text and NULL values. Driver-dependent SQL features and
schema migrations are **not** automatically translated.

## Portable BLOB/BYTEA round-trip (Godot 4.7+)

`SociBinary` encodes `PackedByteArray` to lowercase hexadecimal TEXT and
provides a backend-specific SQL expression that writes it into a *native*
SQLite `BLOB` or PostgreSQL `BYTEA`. Returned BLOBs are fetched through
`hex()`/`encode()` and decoded back to `PackedByteArray`.
This avoids SOCI's different SQLite/PostgreSQL native `blob` vs large-object
semantics. The hex string **must still be bound**, never interpolated.
This is an explicit conversion helper, not transparent native binary binding.

```gdscript
# SQLite: CREATE TABLE files(id BIGINT PRIMARY KEY, payload BLOB)
# PostgreSQL: CREATE TABLE files(id BIGINT PRIMARY KEY, payload BYTEA)
var bytes := PackedByteArray([0, 1, 127, 255])
var expr := SociBinary.parameter_expression(backend, "payload")
var write: Dictionary = await db.execute_async(
    "INSERT INTO files(id,payload) VALUES (:id," + expr + ")",
    {"id": 1, "payload": SociBinary.to_hex(bytes)}
)
var encoded_expr := SociBinary.select_expression(backend, "payload")
var read: Dictionary = await db.query_async(
    "SELECT " + encoded_expr + " AS payload_hex FROM files WHERE id=:id",
    {"id": 1}
)
if read.get("ok", false) and read["rows"].size() == 1:
    var result: PackedByteArray = SociBinary.from_hex(read["rows"][0]["payload_hex"])
```

Hex encoding increases bind/result payload sizes; use smaller payloads
(icons, compressed configuration, snapshots), not large streaming video. Both
SQL expressions validate that their identifier argument is a simple SQL name.
Binary support requires SQLite's built-in `unhex()` function (SQLite >= 3.44).
Tests verify NUL and non-ASCII octets round-trip through both backends.
