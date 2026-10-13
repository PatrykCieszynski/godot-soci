# Integration and release testing

**CI coverage:** Godot 4.7.2 and real SQLite/PostgreSQL on Linux and Windows
x86_64. Static C++ builds alone are *not* sufficient proof of functionality.

## Linux

The Linux integration workflow starts a PostgreSQL service container, compiles
the debug extension and runs `scripts/run_tests.sh`. Locally:

```bash
docker compose -f demo/postgresql/docker-compose.yml up -d --wait
export GODOT_SOCI_PG='host=127.0.0.1 port=55432 dbname=godot_soci_demo user=demo password=demo connect_timeout=3'
export GODOT_BIN=godot
bash scripts/run_tests.sh
docker compose -f demo/postgresql/docker-compose.yml down -v
```

## Windows

The independent **`Godot 4.7 integration (Windows)`** workflow
(`.github/workflows/windows-integration.yml`) runs on `windows-2022`
on every pull request and push to `main`, completely independently of the
release packaging workflow. It compiles a native `template_debug` DLL using
MSVC and pinned vcpkg `x64-windows-static-md`. It starts the runner's
**preinstalled PostgreSQL 14 service**, then runs all six headless integration
scripts against real SQLite and PostgreSQL using `scripts/run_windows_tests.ps1`.

The release workflow still builds both debug and release binaries, runs an
isolated packaged-addon smoke test and assembles ZIPs. It does not substitute
for the Windows integration workflow. Both CI workflows must pass before
publishing an addon. The PostgreSQL user/password are test-only defaults of
the ephemeral hosted Windows runner.

The Windows service is runner-specific. On your own machine, configure
`GODOT_SOCI_PG` to a disposable local PostgreSQL database and adjust
service setup in the PowerShell script.

## Test matrix

| Test | What it asserts |
|---|---|
| `sqlite_test.gd` | Synchronous bind/round-trip, transactions and rollback |
| `postgresql_test.gd` | Same against PostgreSQL |
| `async_sqlite_test.gd` | Async request completion, bounded capacity, transaction batches |
| `async_postgresql_test.gd` | Async PostgreSQL and atomic transaction batches |
| `sqlite_wal_concurrency_test.gd` | Two native writer dispatchers and one reader using separate WAL-enabled SQLite connections, exact final row count, no duplicate IDs |
| `async_failure_test.gd` | Failed PostgreSQL connection, rejection at queue capacity, shutdown resolving queued requests |
| `release_smoke.gd` | Installable addon ZIP works inside a clean Godot project |

Tests intentionally use disposable local data. They are not benchmarks and do
not measure maximum transactions per second. WAL lets readers and one writer
proceed concurrently but **does not allow multiple simultaneous SQLite
writers**; a busy timeout handles ordinary write contention.

## What CI still cannot guarantee

A green job does not prove crash consistency under power loss, malicious input
resilience, network partitions during COMMIT, real-world concurrency scale, or
that all distributions have compatible native system libraries. Windows/Linux
packaging verifies the supported x86_64 build variants only.

For game currency/items use database constraints, operation identifiers,
state reconciliation and separate load tests.
