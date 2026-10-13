# godot-soci addon

Copy this directory into `res://addons/godot_soci/` and supply compiled native libraries in `bin/`.

Requires Godot **4.7+**. The `soci.gdextension` manifest loads automatically; no EditorPlugin needs activation.

Instantiate native `GodotSociDatabase` or the optional GDScript `SociDatabase` wrapper (`database.gd`). Both APIs are synchronous. Do not run slow SQL on a gameplay frame.

For asynchronous SQL, add a `SociAsyncDatabase` node (`async_database.gd`) to the SceneTree. It wraps the native `SociQueryDispatcher` and delivers requests through `await db.query_async(...)` or `await db.execute_async(...)`. The v0.3 implementation has one native worker and bounded pending requests. `await db.transaction_async([...])` executes an atomic batch with optional `expected_affected_rows` guards; long-lived interactive transaction handles are not supported.

The PostgreSQL backend requires its runtime dependencies (`libpq` and related libraries) on the target machine. Never distribute database credentials with a multiplayer game client.

## Binary distributions

Download the installable ZIP from GitHub Releases (not GitHub's source-code ZIP).
Unzip the `addons/godot_soci/` directory into your project. It includes
the native debug/release binaries for Windows and Linux x86_64, their third-party
license notices and the optional GDScript convenience wrappers. No compilation
or EditorPlugin activation is necessary.

Use only in server-side code when connecting to a protected PostgreSQL database.
`SociAsyncDatabase` should be added to the SceneTree for automatic dispatch.

Full API method signatures, result dictionaries and supported types: [API reference](docs/API.md).

For native SQLite `BLOB` and PostgreSQL `BYTEA`, use the optional
`SociBinary` hexadecimal conversion helper in `binary.gd` and the
[API reference](docs/API.md) (not transparent direct `PackedByteArray` binding).

The official Asset Library submission is a separate process from GitHub
Releases; see the [publishing guide](docs/ASSET_LIBRARY.md) in the repository.
