# API reference — godot-soci 0.3.1 (Godot 4.7+)

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

Complex types (BLOB, `PackedByteArray`, JSON/JSONB object mapping, UUID,
arrays) have no first-class mapping. Cast to a supported type where appropriate.
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
