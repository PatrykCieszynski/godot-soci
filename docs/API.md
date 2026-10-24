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

SQLite results use each value's runtime storage class, including expressions,
aggregates and mixed-type columns: INTEGER becomes a Godot `int` (signed int64),
REAL a `float`, TEXT a `String`, and NULL `null`. Numeric-looking TEXT is never
inferred to be a number. This does not depend on declaring a column `BIGINT`:
SQLite `INTEGER` also holds the complete signed int64 range. BLOB remains an
explicit unsupported result type; use the existing binary helper. The same
conversion runs in synchronous and asynchronous queries. Queries are not executed
again to discover result types.

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

## Native diagnostics for failed async SQL

For failures that reach the native worker, the async result retains the existing
`ok=false` and `error` fields, and additionally provides:

| Field | Type | Meaning |
|---|---|---|
| `error_category` | `String` | SOCI category: `connection_error`, `invalid_statement`, `no_privilege`, `no_data`, `constraint_violation`, `unknown_transaction_state`, `system_error` or `unknown`. |
| `error_backend` | `String` | SOCI backend, usually `sqlite3` or `postgresql`; empty for non-backend failures. |
| `backend_error_code` | `int` | SQLite native error code (possibly extended); `0` if unavailable. |
| `sqlstate` | `String` | PostgreSQL five-character SQLSTATE; empty if unavailable. |

These values are provided by SOCI, not by parsing the error message. A category
of `unknown` is valid: backend coverage is incomplete. A driver-neutral
application must not depend on SQLite error codes or PostgreSQL SQLSTATE being
present. Native errors are still redacted before being returned; SQL text and
bound values are not copied into the diagnostic fields.

This extension applies to failures processed by the worker, including native
connection-open failures. Immediate request rejection by the GDScript wrapper
and cancellations generated by `stop()` retain their existing result shape.
This is **diagnostic metadata, not an automatic retry policy**; an ambiguous
write result still requires application-level reconciliation.

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

## Synchronous structured failures

Native `GodotSociDatabase` and wrapper `SociDatabase` expose
`get_last_error_details() -> Dictionary`. Failed `execute`/`query` also return the
same fields with `ok: false`: `error` (redacted text), `error_category`, `error_backend`,
`backend_error_code` (integer), and `sqlstate`. Classification is shared with the
async dispatcher, including the `error_backend` key. Existing return types and `get_last_error()` remain unchanged.

`open`, `begin`, `begin_immediate`, `commit` and `rollback` remain boolean. Capture
error details immediately after failure, before cleanup: successful operations
clear text/details. `close()` preserves the previous error for inspection; a new
`open()` resets it before trying the connection. Returned dictionaries are copies.

Local validation and non-SOCI exceptions have category `unknown`, code 0 and empty
SQLSTATE, never a stale code from a previous SQL error. SQLite may provide its own
backend code but has no PostgreSQL SQLSTATE. Metadata does not assert whether an
operation committed and does not trigger retries.

An application may consider a **whole** transaction retry for SQLSTATE `40001` or
`40P01` only after its transaction owner confirms rollback and preserves the
original operation identity. Capture the failing phase; a failed/ambiguous COMMIT
or connection loss requires outcome discovery, not a blind retry. Do not classify
retryability by error-message text. This API adds no retry/executor/pool policy.

`tests/native_error_test.gd` uses disposable PostgreSQL data through `GODOT_SOCI_PG`
to exercise unique/syntax errors, lock timeout, statement cancellation, real
serialization and two-session deadlock, deferred COMMIT, terminated connection,
cleanup/reset/copy semantics and SQLite fallback. Deadlock synchronization uses
semaphores: both sessions hold their first row before attempting opposite rows;
there is no 500ms observation deadline. Only this case uses transaction-local
10s statement/5s lock/10s idle budgets for default deadlock detection and CI slack,
not as a throughput or latency gate.

### Transaction lifecycle is not server state or commit outcome

`in_transaction()` is the driver's local explicit-transaction ownership flag.
It is not `PQtransactionStatus()`. A failed COMMIT keeps it true conservatively,
but PostgreSQL may already have rolled back and ended that transaction; after
connection loss the server state may be unavailable. Capture diagnostics before
cleanup, then explicitly roll back or close/discard the session. Successful
cleanup clears the local flag, not a reconstructed durable business outcome.

After an ordinary statement error in an explicit PostgreSQL transaction, further
statements normally fail with `25P02` until rollback. Roll back on that first error;
do not continue the business use case or attempt to commit its earlier writes.
PostgreSQL can accept COMMIT on an already aborted transaction as ROLLBACK: the
legacy boolean can be true while none of those provisional writes persisted.
A deferred constraint failure at COMMIT can instead return false and leave the
local flag true after the server has already ended the transaction. Tests cover
both cases; this PR deliberately preserves existing flag/boolean semantics.

A `40001` retry must rerun the complete transaction, including decisions selecting
SQL and values; `40P01` may also warrant a whole-transaction retry. SQLSTATE alone
does not establish application retry safety: preserve business identity, record
the failure phase, confirm cleanup, bound attempts and re-run the original use
case. Ambiguous COMMIT/connection loss requires durable outcome discovery first.
See [PostgreSQL serialization failure handling](https://www.postgresql.org/docs/current/mvcc-serialization-failure-handling.html)
and [libpq transaction status](https://www.postgresql.org/docs/current/libpq-status.html).
