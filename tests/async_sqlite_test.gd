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
    print("ASYNC SQLITE TRACE: begin test")
    var path := ProjectSettings.globalize_path("user://godot_soci_async_test.db")
    print("ASYNC SQLITE TRACE: instantiate wrapper")
    var db := SociAsyncDatabase.new()
    print("ASYNC SQLITE TRACE: wrapper created")
    print("ASYNC SQLITE TRACE: add wrapper to tree")
    root.add_child(db)
    print("ASYNC SQLITE TRACE: wrapper in tree")
    print("ASYNC SQLITE TRACE: start dispatcher")
    if not _check(db.start("sqlite3", path, 8), "start"):
        return
    print("ASYNC SQLITE TRACE: dispatcher started; await schema")
    var schema: Dictionary = await db.execute_async("CREATE TABLE IF NOT EXISTS async_test (id BIGINT PRIMARY KEY, label TEXT NULL)")
    print("ASYNC SQLITE TRACE: schema returned")
    if not _check(schema.get("ok", false), "schema " + str(schema)):
        return
    print("ASYNC SQLITE TRACE: await insert")
    var inserted: Dictionary = await db.execute_async(
        "INSERT OR REPLACE INTO async_test(id,label) VALUES (:id,:label)",
        {"id": 4000000000, "label": "O'Reilly 🌍"}
    )
    if not _check(inserted.get("ok", false), "insert " + str(inserted)):
        return
    print("ASYNC SQLITE TRACE: await query")
    var selected: Dictionary = await db.query_async("SELECT id, label FROM async_test WHERE id=:id", {"id": 4000000000})
    if not _check(selected.get("ok", false) and selected["rows"].size() == 1, "select " + str(selected)):
        return
    if not _check(selected["rows"][0]["id"] == 4000000000 and selected["rows"][0]["label"] == "O'Reilly 🌍", "values"):
        return
    print("ASYNC SQLITE TRACE: await duplicate-column query")
    var bad: Dictionary = await db.query_async("SELECT 1 AS x, 2 AS x")
    if not _check(not bad.get("ok", true), "duplicate column rejection"):
        return
    print("ASYNC SQLITE TRACE: await invalid SQL")
    var invalid: Dictionary = await db.execute_async("NOT VALID SQL")
    if not _check(not invalid.get("ok", true), "invalid SQL error"):
        return

    print("ASYNC SQLITE TRACE: await transaction table")
    var table: Dictionary = await db.execute_async(
        "CREATE TABLE IF NOT EXISTS async_tx_test (id BIGINT PRIMARY KEY, coins INTEGER NOT NULL)"
    )
    if not _check(table.get("ok", false), "transaction table"):
        return
    if not _check((await db.execute_async("DELETE FROM async_tx_test")).get("ok", false), "transaction reset"):
        return
    print("ASYNC SQLITE TRACE: await committed batch")
    var committed: Dictionary = await db.transaction_async([
        {"sql": "INSERT INTO async_tx_test (id,coins) VALUES (:id,:coins)",
            "params": {"id": 21, "coins": 100}, "expected_affected_rows": 1},
        {"sql": "UPDATE async_tx_test SET coins=coins+:delta WHERE id=:id",
            "params": {"id": 21, "delta": 50}, "expected_affected_rows": 1}
    ])
    if not _check(committed.get("ok", false) and committed.get("affected_rows", 0) == 2,
            "transaction commit " + str(committed)):
        return
    print("ASYNC SQLITE TRACE: await rolled-back batch")
    var rejected: Dictionary = await db.transaction_async([
        {"sql": "UPDATE async_tx_test SET coins=coins+:delta WHERE id=:id",
            "params": {"id": 21, "delta": 900}, "expected_affected_rows": 1},
        {"sql": "UPDATE async_tx_test SET coins=0 WHERE id=:id",
            "params": {"id": 999}, "expected_affected_rows": 1}
    ])
    if not _check(not rejected.get("ok", true) and not rejected.get("outcome_unknown", true),
            "failed transaction rolls back " + str(rejected)):
        return
    var balance: Dictionary = await db.query_async("SELECT coins FROM async_tx_test WHERE id=:id", {"id": 21})
    if not _check(balance.get("ok", false) and balance["rows"][0]["coins"] == 150,
            "atomic rollback verified " + str(balance)):
        return

    print("ASYNC SQLITE TRACE: raw dispatcher")
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

    print("ASYNC SQLITE TRACE: stop with pending requests")
    var shutdown_dispatcher := SociQueryDispatcher.new()
    if not _check(shutdown_dispatcher.start("sqlite3", path), "shutdown dispatcher start"):
        return
    var shutdown_request: SociQueryRequest = shutdown_dispatcher.query_async("SELECT 1 AS value")
    if not _check(shutdown_request != null, "shutdown request created"):
        return
    shutdown_dispatcher.stop()
    if not _check(shutdown_request.is_done(), "shutdown settles outstanding requests"):
        return
    var shutdown_result: Dictionary = shutdown_request.get_result()
    if not _check(shutdown_result.has("ok"), "shutdown retained result"):
        return

    print("ASYNC SQLITE TRACE: shutdown wrapper")
    db.stop()
    if not _check(db.pending() == 0, "clean shutdown"):
        return
    db.queue_free()
    print("ASYNC SQLITE PASS")
    quit(0)
