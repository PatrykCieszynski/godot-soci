# godot-soci addon

Copy this directory into `res://addons/godot_soci/` and supply compiled native libraries in `bin/`.

Requires Godot **4.7+**. The `soci.gdextension` manifest loads automatically; no EditorPlugin needs activation.

Instantiate native `GodotSociDatabase` or the optional GDScript `SociDatabase` wrapper (`database.gd`). Both APIs are synchronous. Do not run slow SQL on a gameplay frame.

For asynchronous SQL, add a `SociAsyncDatabase` node (`async_database.gd`) to the SceneTree. It wraps the native `SociQueryDispatcher` and delivers requests through `await db.query_async(...)` or `await db.execute_async(...)`. The initial v0.2 implementation has one native worker, bounded pending requests and no transaction API.

The PostgreSQL backend requires its runtime dependencies (`libpq` and related libraries) on the target machine. Never distribute database credentials with a multiplayer game client.
