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
    var tx_table: Dictionary = await db.execute_async(
        "CREATE TABLE IF NOT EXISTS async_tx_test (id BIGINT PRIMARY KEY, coins INTEGER NOT NULL)"
    )
    if not _check(tx_table.get("ok", false), "transaction table"):
        return
    if not _check((await db.execute_async("DELETE FROM async_tx_test")).get("ok", false), "transaction reset"):
        return
    var committed: Dictionary = await db.transaction_async([
        {"sql": "INSERT INTO async_tx_test (id,coins) VALUES (:id,:coins)",
            "params": {"id": 21, "coins": 100}, "expected_affected_rows": 1},
        {"sql": "UPDATE async_tx_test SET coins=coins+:delta WHERE id=:id",
            "params": {"id": 21, "delta": 50}, "expected_affected_rows": 1}
    ])
    if not _check(committed.get("ok", false) and committed.get("affected_rows", 0) == 2,
            "transaction commit " + str(committed)):
        return
    var rejected: Dictionary = await db.transaction_async([
        {"sql": "UPDATE async_tx_test SET coins=coins+:delta WHERE id=:id",
            "params": {"id": 21, "delta": 900}, "expected_affected_rows": 1},
        {"sql": "UPDATE async_tx_test SET coins=0 WHERE id=:id",
            "params": {"id": 999}, "expected_affected_rows": 1}
    ])
    if not _check(not rejected.get("ok", true) and not rejected.get("outcome_unknown", true),
            "failed transaction rollback " + str(rejected)):
        return
    var balance: Dictionary = await db.query_async("SELECT coins FROM async_tx_test WHERE id=:id", {"id": 21})
    if not _check(balance.get("ok", false) and balance["rows"][0]["coins"] == 150,
            "atomic rollback verified " + str(balance)):
        return
    db.stop()
    db.queue_free()
    print("ASYNC POSTGRESQL PASS")
    quit(0)
