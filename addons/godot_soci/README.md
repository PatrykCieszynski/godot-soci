# godot-soci addon

Copy this directory into `res://addons/godot_soci/` and supply compiled native libraries in `bin/`.

Requires Godot **4.7+**. The `soci.gdextension` manifest loads automatically; no EditorPlugin needs activation.

Instantiate native `GodotSociDatabase` or the optional GDScript `SociDatabase` wrapper (`database.gd`). Both APIs are synchronous. Do not run slow SQL on a gameplay frame.

The PostgreSQL backend requires its runtime dependencies (`libpq` and related libraries) on the target machine. Never distribute database credentials with a multiplayer game client.
