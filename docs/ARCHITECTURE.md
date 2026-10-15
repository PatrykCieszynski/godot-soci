# Architecture (v0.5)

`GodotSociDatabase` remains the synchronous, single-owner SOCI connection. It is unchanged and supports explicit transactions.

## Native async pipeline

```text
SociAsyncDatabase (Node, GDScript wrapper)
  ├─ query_async()/execute_async() -> awaitable Dictionary
  └─ _process() -> SociQueryDispatcher.poll()
                       │ main thread
                       ▼
SociQueryDispatcher (RefCounted, native)
  ├─ request table (retains SociQueryRequest until completion)
  ├─ bounded queue of copied C++ Job structs
  └─ std::thread + condition_variable
                       │ background thread
                       ▼
QueryWorker (C++) -> soci::session -> SQLite/PostgreSQL
                       │
                       ▼
Completion queue (copied C++ rows and scalars)
                       │ main thread polling
                       ▼
SociQueryRequest.resolve(Dictionary) -> completed(result)
```

One worker owns one SOCI session. No Godot objects or Variants pass from the main thread to the worker; only std::string and plain C++ values cross the boundary.

`start()` launches the worker but connection setup runs asynchronously. If the connection cannot open, queued jobs resolve with errors. `pending()` counts running, queued and completed-but-not-delivered requests. When `max_pending` is reached, native `query_async()` / `execute_async()` return null and set `get_last_error()`. The GDScript wrapper translates this into an error Dictionary without yielding.

`SociQueryRequest` retains its `done` status and result for late inspection. The `completed` signal is emitted only when `poll()` runs on the main thread. A user who keeps a reference after completion should inspect `is_done()` before awaiting the signal. The convenience node handles normal immediate-await usage.

Stopping is **blocking**: it drops queued work and waits for an in-flight SOCI call to return before joining the thread. Completed requests retain their true database results even during shutdown; queued requests that never executed are resolved with a cancellation error on the main thread. A driver error during an in-flight mutation may still have an unknown database outcome: never blindly retry currency/item operations. This ensures sessions are destroyed on their owning worker but is not yet a solution for indefinitely hung network operations; configure database/driver timeouts.

## Atomic transaction batches (v0.3 increment)

A batch request contains immutable C++ statements with copied parameter values.
The worker uses a single `soci::transaction`, executing each non-returning
statement in order. Optional `expected_affected_rows` guards can abort before
commit if a conditional balance/item update affected fewer rows than expected.
The transaction destructor handles rollback on ordinary statement errors.
`outcome_unknown=true` is reserved for an exception when attempting to commit;
the client must reconcile rather than retry an economy mutation.

This avoids session-affinity problems from interleaving a long-lived transaction
with unrelated jobs. Long-lived interactive transactions remain unsupported.

## Connection state and worker statistics (v0.5)

The SOCI session remains entirely worker-owned. An atomic native enum
carries only its observed state: `stopped`, `connecting`, `connected`,
`failed`, or `disconnected`. Godot reads the state and emits
`connection_state_changed(state)` **only on the main thread**.
Because workers change state between frames, short intermediate states
may be skipped by polling.

After failed SQL operations, the worker invokes SOCI's `is_connected()`;
it never pings for each successful SQL call. Initial connection failures
set `failed`; confirmed session loss sets `disconnected`. Neither
condition causes silent SQL retries or reconnects. Restart is explicit;
ambiguous mutations require application-level reconciliation.

`get_stats()` snapshots pending/queued/executing/awaiting-poll operations
and cumulative submitted/completed/failed/rejected/canceled counts. Its
queue-wait, SQL-execution and completion-to-delivery averages measure
observed durations in milliseconds. The pending cap includes finished
but undelivered requests; it is a *count* limit, not a byte limit.
Counters reset when a new worker starts and remain readable after stop.
No SQL or credentials are stored in these metrics.

Failed native async completions may also include the original SOCI error
category, backend name, SQLite error code and PostgreSQL SQLSTATE. Those are
captured as plain C++ scalars on the worker and converted to Godot Variants
only during main-thread delivery. The connector does not translate every
database error into an invented driver-neutral taxonomy.

## Deliberate v0.5 limitations

- Single worker per dispatcher, no parallel SQL within one dispatcher.
- Supports atomic async batches, but not long-lived interactive transactions or session-pinned transaction handles. The synchronous driver remains available for complex transactional operations on an explicitly owned connection.
- No driver-independent SQL cancellation, reconnect/retry, or query timeout.
- Results are bounded by `max_rows`, but individual row sizes are not capped.
- SQL dialects, migrations and isolation levels remain backend-specific.

## Next phase

Before implementing a multi-worker pool, define the API for transaction/session affinity (e.g. a transaction handle pinned to one worker), driver-specific cancellation/timeouts and controlled shutdown. Add stress tests for concurrent producer requests, abandoned awaiters, per-worker connection failures and DB disconnects. Do not assume adding worker threads alone makes a correct connection pool.
