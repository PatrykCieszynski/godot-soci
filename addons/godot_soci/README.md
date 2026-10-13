# godot-soci addon

Place this directory at `res://addons/godot_soci/` in a **Godot 4.x** project. Build native libraries first (see repository root README); the source ZIP intentionally does not ship native binaries.

The native class `GodotSociDatabase` supports PostgreSQL and SQLite depending on build options.

> This v0.1 API is synchronous. For nonblocking gameplay, run each connection on a dedicated Godot `Thread` and return plain copied data to the main thread. See `demo/scripts/threaded_sqlite.gd`.
