# Integration, packages and release testing

CI uses **Godot 4.7.2**, with real SQLite and PostgreSQL on Windows and Linux
x86_64. The only build/test workflow is [ci.yml](../.github/workflows/ci.yml).
[release.yml](../.github/workflows/release.yml) only promotes an existing
artifact; it never compiles any C++.

## CI pipeline

| Event | Linux (Ubuntu 22.04) | Windows (2022) | Final artifact |
|---|---|---|---|
| Pull request | Build template_debug, real SQLite/PostgreSQL tests | Build template_debug, real SQLite/PostgreSQL tests | No installable ZIP; fast feedback |
| Push to main | Build template_debug, test, build template_release, package + smoke | Build template_debug, test, build template_release, package + smoke | One cross-platform `godot-soci-installable.zip` |
| Manual release or version tag | **No rebuild** | **No rebuild** | Download and publish successful `main` CI artifact for exact SHA |

Each OS builds its library once per template variant. PostgreSQL runs as a
service container on Linux; Windows uses PostgreSQL 14 preinstalled on
`windows-2022`. CI reuses pinned vcpkg package caches and compiler object
caches. Native Windows and Linux build configurations differ deliberately:
Windows uses `CMAKE_BUILD_TYPE=Release` for both Godot template ABIs to use
optimized vcpkg `lib/` and the redistributable MSVC `/MD` runtime. Linux
uses CMake Debug/Release for the corresponding variants.

## Windows optimized SQLite regression guard

The build runs `scripts/check_windows_sqlite_link.py` against the actual
Ninja DLL link command of each template. It requires
`vcpkg/installed/x64-windows-static-md/lib/sqlite3.lib`, rejects
`debug/lib/sqlite3.lib`, and checks `CMAKE_BUILD_TYPE=Release`.
A real-engine SQL test additionally checks
`sqlite_compileoption_used('SQLITE_DEBUG') = 0`, including in the packaged
Windows smoke project. This checks the shipped SQLite implementation rather
than assuming a successful linker invocation means optimized SQLite.

We do not patch upstream SOCI, alter the async dispatcher, or force arbitrary
linker flags to hide Debug/Release mismatches.

## Release security / provenance

The promotion workflow requires an existing successful **push-to-main**
`ci.yml` run for the exact `GITHUB_SHA`; it verifies the run's SHA,
completion state, conclusion, event and branch through the GitHub API,
then downloads `godot-soci-installable` from **that specific run ID**.
It refuses a missing, failed or stale run. Manual release refuses to publish
if `main` advanced during promotion. All assets are built and smoke-tested
before publication; the release ZIP is a byte-for-byte copy of the CI ZIP.
Artifacts are retained for 90 days, and the release workflow uses
`actions: read` and `contents: write` permissions.

## Local integration tests

Linux, with a locally built extension and Godot executable in PATH:

```bash
docker compose -f demo/postgresql/docker-compose.yml up -d --wait
export GODOT_SOCI_PG='host=127.0.0.1 port=55432 dbname=godot_soci_demo user=demo password=demo connect_timeout=3'
export GODOT_BIN=godot
bash scripts/run_tests.sh
docker compose -f demo/postgresql/docker-compose.yml down -v
```

Windows uses `scripts/run_windows_tests.ps1 -Godot <godot_console.exe>`,
which copies the addon and test resources to a temporary Godot project.
The PostgreSQL credentials in CI are **test-only** and must never be
distributed with a game client.

## SQLite result storage classes

`sqlite_result_types_test.gd` runs through both synchronous and asynchronous
queries in both OS integration runners. It covers INTEGER int64 bounds, COUNT /
SUM and bound expressions, numeric-looking TEXT, NULL-first and mixed-type rows,
empty/truncated results, duplicate column rejection and unsupported BLOB errors.
A custom declaration with INSERT RETURNING checks that type discovery cannot
execute a statement twice. This is a driver contract, not game balance evidence.

## Diagnosing Windows Godot/native crashes

The Windows integration runner saves stdout, stderr and an exit-code summary
for each Godot test in `$env:RUNNER_TEMP/godot-soci-diagnostics/logs/`.
The CI `template_debug` build enables `GODOT_SOCI_CI_DIAGNOSTICS=ON`
to generate a matching GDExtension PDB without changing the /MD runtime
used by vcpkg's release libraries. It disables function folding and inlining
to make native crash stack traces easier to interpret.

If a Godot test terminates with a native Windows exception, CI retries **only
that test** under Microsoft's CDB debugger, attached to the **actual Godot
engine** rather than the console launcher. CDB captures the exception record,
registers, stack frames and a minidump (when the crash reproduces).
The original failure remains a failure even if the debugger replay behaves
differently.

On job failure, GitHub Actions uploads the
`windows-native-diagnostics-attempt-*` artifact, including test logs,
CDB transcripts, available minidumps and matching PDBs, retained for **3 days**.
The minidumps can contain process-memory values: use disposable test
credentials and never upload dumps from production databases.

For a crash such as `0xC0000005` (access violation), check the
`CDB native crash replay` job-log section and the matching `*.cdb.log` for
`GODOT_SOCI_NATIVE_ACCESS_VIOLATION`. Open a `*.cdb.dmp` in WinDbg with
the matching PDB for more detail (`!analyze -v`, `kv`).
If the replay doesn't reproduce the crash, the original per-test logs remain.

On MSVC, `godot-cpp` must not propagate `_HAS_EXCEPTIONS=0` into
`godot-soci`: SOCI requires exceptions, and inconsistent C++ STL settings
can break native virtual dispatch. CMake enforces the compatible
`GODOTCPP_DISABLE_EXCEPTIONS=OFF` configuration on Windows.

## Test matrix

| Test | What it verifies |
|---|---|
| `sqlite_test.gd` | Synchronous binding, rollback, no `SQLITE_DEBUG` on Windows |
| `postgresql_test.gd` | Sync behavior against PostgreSQL |
| `async_sqlite_test.gd` | Awaitable completions, queue capacity and atomic batches |
| `async_postgresql_test.gd` | PostgreSQL async operations and transactions |
| `backend_parity_test.gd` | Shared type contracts and BLOB/BYTEA conversion |
| `sqlite_wal_concurrency_test.gd` | WAL contention across separate connections |
| `async_failure_test.gd` | Connection failures, backpressure, shutdown behavior |
| `release_smoke.gd` | Packaged addon loads and operates in a clean Godot project |
| `test_package_addon.py` | Reproducible cross-platform ZIP merging |
| `test_windows_sqlite_link.py` | Reject Debug SQLite path / incorrect MSVC CMake config |

Tests intentionally use disposable local data. They are not throughput
benchmarks and do not establish crash consistency during power loss,
exactly-once delivery under network partitions or production-economy safety.
For MMO money/items use database constraints, operation IDs, reconciliation
and representative concurrent load tests.
