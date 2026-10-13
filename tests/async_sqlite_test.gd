extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _check(condition: bool, label: String) -> bool:
    if not condition:
        printerr("ASYNC SQLITE FAILED: ", label)
        quit(1)
        return false
    return true


func _run() -> void:
    var path := ProjectSettings.globalize_path("user://godot_soci_async_test.db")
    var db := SociAsyncDatabase.new()
    root.add_child(db)
    if not _check(db.start("sqlite3", path, 8), "start"):
        return
    var schema: Dictionary = await db.execute_async("CREATE TABLE IF NOT EXISTS async_test (id BIGINT PRIMARY KEY, label TEXT NULL)")
    if not _check(schema.get("ok", false), "schema " + str(schema)):
        return
    var inserted: Dictionary = await db.execute_async(
        "INSERT OR REPLACE INTO async_test(id,label) VALUES (:id,:label)",
        {"id": 4000000000, "label": "O'Reilly 🌍"}
    )
    if not _check(inserted.get("ok", false), "insert " + str(inserted)):
        return
    var selected: Dictionary = await db.query_async("SELECT id, label FROM async_test WHERE id=:id", {"id": 4000000000})
    if not _check(selected.get("ok", false) and selected["rows"].size() == 1, "select " + str(selected)):
        return
    if not _check(selected["rows"][0]["id"] == 4000000000 and selected["rows"][0]["label"] == "O'Reilly 🌍", "values"):
        return
    var bad: Dictionary = await db.query_async("SELECT 1 AS x, 2 AS x")
    if not _check(not bad.get("ok", true), "duplicate column rejection"):
        return
    var invalid: Dictionary = await db.execute_async("NOT VALID SQL")
    if not _check(not invalid.get("ok", true), "invalid SQL error"):
        return

    var raw := SociQueryDispatcher.new()
    if not _check(raw.start("sqlite3", path, 1), "raw dispatcher start"):
        return
    var request: SociQueryRequest = raw.query_async("SELECT label FROM async_test")
    if not _check(request != null, "initial request"):
        return
    var denied := raw.query_async("SELECT 1")
    if not _check(denied == null and raw.get_last_error().contains("capacity"), "bounded pending requests"):
        return
    var deadline := Time.get_ticks_msec() + 5000
    while not request.is_done() and Time.get_ticks_msec() < deadline:
        raw.poll()
        await process_frame
    if not _check(request.is_done() and request.get_result().get("ok", false), "manual poll and retained completion"):
        return
    raw.stop()
    db.stop()
    if not _check(db.pending() == 0, "clean shutdown"):
        return
    db.queue_free()
    print("ASYNC SQLITE PASS")
    quit(0)
