extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _check(condition: bool, label: String) -> bool:
    if not condition:
        printerr("ASYNC POSTGRESQL FAILED: ", label)
        quit(1)
        return false
    return true


func _run() -> void:
    var connection := OS.get_environment("GODOT_SOCI_PG")
    if not _check(not connection.is_empty(), "GODOT_SOCI_PG required"):
        return
    var db := SociAsyncDatabase.new()
    root.add_child(db)
    if not _check(db.start("postgresql", connection), "start"):
        return
    var schema: Dictionary = await db.execute_async(
        "CREATE TABLE IF NOT EXISTS async_test (id BIGINT PRIMARY KEY, label TEXT)"
    )
    if not _check(schema.get("ok", false), "schema " + str(schema)):
        return
    var inserted: Dictionary = await db.execute_async(
        "INSERT INTO async_test(id,label) VALUES (:id,:label) ON CONFLICT(id) DO UPDATE SET label=EXCLUDED.label",
        {"id": 4000000000, "label": "O'Reilly 🌍"}
    )
    if not _check(inserted.get("ok", false), "upsert " + str(inserted)):
        return
    var selected: Dictionary = await db.query_async(
        "SELECT id,label FROM async_test WHERE id=:id", {"id": 4000000000}
    )
    if not _check(selected.get("ok", false) and selected["rows"].size() == 1, "select " + str(selected)):
        return
    if not _check(selected["rows"][0]["label"] == "O'Reilly 🌍", "UTF-8 value"):
        return
    db.stop()
    db.queue_free()
    print("ASYNC POSTGRESQL PASS")
    quit(0)
