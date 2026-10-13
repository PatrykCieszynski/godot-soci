extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _check(condition: bool, label: String) -> bool:
    if not condition:
        printerr("POSTGRESQL TEST FAILED: ", label)
        quit(1)
        return false
    return true


func _run() -> void:
    var connection := OS.get_environment("GODOT_SOCI_PG")
    if not _check(not connection.is_empty(), "GODOT_SOCI_PG must be set"):
        return
    var db := GodotSociDatabase.new()
    if not _check(db.open("postgresql", connection), db.get_last_error()):
        return
    if not _check(db.execute("DROP TABLE IF EXISTS soci_integration")["ok"], "drop"):
        return
    if not _check(db.execute("CREATE TABLE soci_integration (id BIGINT PRIMARY KEY, label TEXT NOT NULL, note TEXT NULL)")["ok"], "create"):
        return
    if not _check(db.begin(), "begin"):
        return
    var inserted := db.execute(
        "INSERT INTO soci_integration(id, label, note) VALUES (:id, :label, :note)",
        {"id": 4000000000, "label": "O'Reilly 🌍", "note": null}
    )
    if not _check(inserted.get("ok", false) and inserted.get("affected_rows", 0) == 1, "insert"):
        return
    if not _check(db.commit(), "commit"):
        return
    var selected := db.query("SELECT id, label, note FROM soci_integration WHERE id = :id", {"id": 4000000000})
    if not _check(selected.get("ok", false) and selected["rows"].size() == 1, "select"):
        return
    var row: Dictionary = selected["rows"][0]
    if not _check(row["id"] == 4000000000 and row["label"] == "O'Reilly 🌍" and row["note"] == null, "typed value round-trip"):
        return
    if not _check(not db.query("SELECT 1 AS duplicated, 2 AS duplicated").get("ok", true), "duplicate columns must fail"):
        return
    if not _check(db.begin(), "begin for rollback"):
        return
    if not _check(db.execute("UPDATE soci_integration SET label = 'changed'")["ok"], "update"):
        return
    if not _check(db.rollback(), "rollback"):
        return
    var restored := db.query("SELECT label FROM soci_integration")
    if not _check(restored.get("ok", false) and restored["rows"][0]["label"] == "O'Reilly 🌍", "rollback verification"):
        return
    db.close()
    print("POSTGRESQL INTEGRATION PASS")
    quit(0)
