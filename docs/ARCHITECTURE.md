# Architecture (v0.1.x)

The native `GodotSociDatabase` is a synchronous, single-owner wrapper. Each instance owns one SOCI session. The public GDScript `SociDatabase` wrapper delegates to it without changing thread-affinity guarantees.

- Godot input is converted into typed SOCI parameters stored in a `std::deque` so bind addresses remain stable.
- `query()` copies at most `max_rows` records into Godot dictionaries and reports truncation separately.
- Duplicate output column names are rejected instead of silently overwriting a previous value. Use SQL aliases.
- The session tracks explicit transactions via `begin()`, `begin_immediate()`, `commit()`, and `rollback()`. Use these methods, not `execute("BEGIN")`, because arbitrary SQL is not parsed to synchronize the transaction flag.
- No implicit reconnects or automatic retries of transactions. A failed commit can have an unknown outcome.

## Layout

- `include/godot_soci/database.h` — native driver contract
- `src/database.cpp` — synchronous SOCI implementation
- `src/register_types.cpp` — Godot registration
- `addons/godot_soci/` — installable addon, optional GDScript wrapper
- `demo/sqlite/` and `demo/postgresql/` — manual demos, including a real Godot Thread example
- `tests/` — headless Godot integration tests against real DB engines in Linux CI

## v0.2: native async dispatcher

Do not introduce placeholder worker/request translation units. When implementing async, add `src/query_request.cpp`, `src/query_worker.cpp` and matching public headers, with a real, independently tested request lifecycle.

1. Convert input to plain C++ data *before* enqueueing; do not pass live Godot scene objects to worker threads.
2. Use a bounded request queue and long-lived DB workers, with one session owned per worker.
3. Deliver completions on Godot's main thread; expose a request object that retains completion state (not just a one-shot signal).
4. Handle shutdown, cancellation of queued work, DB timeouts, transaction/session affinity, and unknown commit outcomes.
5. Keep the synchronous driver available for tools, migration scripts and explicit off-thread use.

SOCI normalizes connection APIs, not SQL dialects. PostgreSQL and SQLite schema/locking behavior remains application-specific.
