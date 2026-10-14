extends SceneTree

# Run: godot --headless --path . --script res://demo/backend_switch.gd
# Default: SQLite; set GODOT_SOCI_BACKEND=postgresql and GODOT_SOCI_PG to switch.
func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var backend := OS.get_environment("GODOT_SOCI_BACKEND")
    if backend.is_empty():
        backend = "sqlite3"
    var connection := ProjectSettings.globalize_path("user://godot_soci_backend_demo.db")
    if backend == "postgresql":
        connection = OS.get_environment("GODOT_SOCI_PG")
        if connection.is_empty():
            printerr("Set GODOT_SOCI_PG for PostgreSQL")
            quit(1)
            return
    elif backend != "sqlite3":
        printerr("Choose sqlite3 or postgresql")
        quit(1)
        return

    var db := SociAsyncDatabase.new()
    root.add_child(db)
    if not db.start(backend, connection):
        printerr("Start failed: ", db.get_last_error())
        quit(1)
        return

    var schema: Dictionary = await db.execute_async(
        "CREATE TABLE IF NOT EXISTS soci_backend_demo (id BIGINT PRIMARY KEY, name TEXT)"
    )
    if not schema.get("ok", false):
        printerr("Create table: ", schema)
        quit(1)
        return
    var deleted: Dictionary = await db.execute_async(
        "DELETE FROM soci_backend_demo WHERE id=:id", {"id": 17}
    )
    if not deleted.get("ok", false):
        printerr("Delete: ", deleted)
        quit(1)
        return
    var inserted: Dictionary = await db.execute_async(
        "INSERT INTO soci_backend_demo (id,name) VALUES (:id,:name)",
        {"id": 17, "name": "Hero 🌍"}
    )
    var selected: Dictionary = await db.query_async(
        "SELECT id,name FROM soci_backend_demo WHERE id=:id", {"id": 17}
    )
    if not inserted.get("ok", false) or not selected.get("ok", false) or selected["rows"].size() != 1:
        printerr("Query failed: ", inserted, selected)
        quit(1)
        return
    print("Backend: ", backend, " | Player: ", selected["rows"][0])
    db.stop()
    db.queue_free()
    print("BACKEND SWITCH DEMO PASS")
    quit(0)
