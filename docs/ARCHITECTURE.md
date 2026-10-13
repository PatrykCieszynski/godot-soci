# Architecture (v0.2)

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

Stopping is **blocking**: it drops queued work and waits for an in-flight SOCI call to return before joining the thread. Outstanding request objects are resolved with a cancellation error on the main thread. This ensures sessions are destroyed on their owning worker but is not yet a solution for indefinitely hung network operations; configure database/driver timeouts.

## Deliberate v0.2 limitations

- Single worker per dispatcher, no parallel SQL within one dispatcher.
- No async transaction commands or session-pinned transaction handles. The synchronous driver remains available for transactional operations on an explicitly owned connection.
- No driver-independent SQL cancellation, reconnect/retry, or query timeout.
- Results are bounded by `max_rows`, but individual row sizes are not capped.
- SQL dialects, migrations and isolation levels remain backend-specific.

## Next phase

Before implementing a multi-worker pool, define the API for transaction/session affinity (e.g. a transaction handle pinned to one worker), driver-specific cancellation/timeouts and controlled shutdown. Add stress tests for concurrent producer requests, abandoned awaiters, per-worker connection failures and DB disconnects. Do not assume adding worker threads alone makes a correct connection pool.
