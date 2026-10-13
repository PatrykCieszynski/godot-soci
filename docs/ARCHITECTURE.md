# Design boundaries (v0.1)

The native `GodotSociDatabase` is a synchronous, single-owner session wrapper. Each instance owns one `soci::session` and uses SOCI's direct `sqlite3`/`postgresql` backend factories (not dynamically loaded SOCI plugins). No `SceneTree` or gameplay objects are accessed by the wrapper.

`execute`/`query` accept a dictionary of named typed bind parameters. Native values are kept in a `std::deque` so addresses remain stable throughout SOCI statement preparation, binding and execution. Prepared statements are short-lived within each method call. `query` reads a bounded number of rows and returns copied Godot values. The caller owns pagination, rate limits, caches and snapshots.

Transactions are explicit: no hidden reconnection or retry. The wrapper tracks `begin`/`begin_immediate` to avoid nested transactions and roll back an active transaction on `close()`. A failed `commit()` retains the active flag: higher layers must resolve an unknown outcome instead of replaying money/item mutations.

## Future v0.2 candidates

1. Add a native thread-safe job dispatcher with per-worker sessions, bounded queue and completion delivery on the Godot/main thread. Before that, validate one-worker semantics using `demo/scripts/threaded_sqlite.gd`.
2. Typed BLOB/byte-array support with explicit copy ownership, JSON casts, timestamp/date conversion and PostgreSQL-specific result types.
3. Connection pool, query timeouts and controlled shutdown semantics; result paging/streaming for huge data sets.
4. CI integration with an actual Godot editor and PostgreSQL service on Linux/Windows, plus sanitizer builds.
5. Generate installable prebuilt addon releases for Windows/Linux (each debug/release x86_64 binary and any runtime dependencies).

## Do not abstract away SQL dialects

The low-level transport is shared, but schema migrations, upserts, `BEGIN IMMEDIATE`, PostgreSQL row locks, JSON operations and triggers remain backend-specific. Write repository-level contracts in the application and test them separately for both engines.
