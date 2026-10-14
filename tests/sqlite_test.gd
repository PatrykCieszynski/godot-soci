extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _check(condition: bool, label: String) -> bool:
    if not condition:
        printerr("SQLITE TEST FAILED: ", label)
        quit(1)
        return false
    return true


func _run() -> void:
    print("SQLITE TRACE: create native object")
    var db := GodotSociDatabase.new()
    var path := ProjectSettings.globalize_path("user://godot_soci_integration_test.db")
    print("SQLITE TRACE: open SQLite")
    if not _check(db.open("sqlite3", path), db.get_last_error()):
        return
    # Windows CI must use release-built vcpkg SQLite even for Godot's
    # template_debug binary. template_debug is an ABI target, not MSVC Debug.
    if OS.get_name() == "Windows":
        var options: Dictionary = db.query("SELECT sqlite_compileoption_used('SQLITE_DEBUG') AS enabled")
        if not _check(options.get("ok", false) and options["rows"].size() == 1,
                "SQLite build-flag introspection"):
            return
        if not _check(int(options["rows"][0]["enabled"]) == 0, "SQLite must not contain SQLITE_DEBUG"):
            return
    print("SQLITE TRACE: drop table")
    if not _check(db.execute("DROP TABLE IF EXISTS soci_integration")["ok"], "drop"):
        return
    print("SQLITE TRACE: create table")
    if not _check(db.execute("CREATE TABLE soci_integration (id BIGINT PRIMARY KEY, label TEXT NOT NULL, note TEXT)")["ok"], "create"):
        return
    print("SQLITE TRACE: begin immediate")
    if not _check(db.begin_immediate(), "begin immediate"):
        return
    if not _check(not db.begin(), "nested transaction must be rejected"):
        return
    print("SQLITE TRACE: execute bound insert")
    var inserted := db.execute(
        "INSERT INTO soci_integration (id, label, note) VALUES (:id, :label, :note)",
        {"id": 4000000000, "label": "O'Reilly 🌍", "note": null}
    )
    if not _check(inserted.get("ok", false) and inserted.get("affected_rows", 0) == 1, "insert"):
        return
    print("SQLITE TRACE: commit")
    if not _check(db.commit(), "commit"):
        return
    print("SQLITE TRACE: query bound rows")
    var result := db.query("SELECT id, label, note FROM soci_integration WHERE id = :id", {"id": 4000000000})
    if not _check(result.get("ok", false) and result["rows"].size() == 1, "select"):
        return
    var row: Dictionary = result["rows"][0]
    if not _check(row["id"] == 4000000000 and row["label"] == "O'Reilly 🌍" and row["note"] == null, "typed value round-trip"):
        return
    print("SQLITE TRACE: duplicate column error")
    if not _check(not db.query("SELECT 1 AS duplicated, 2 AS duplicated").get("ok", true), "duplicate columns must fail"):
        return
    print("SQLITE TRACE: invalid SQL error")
    if not _check(not db.execute("THIS IS NOT SQL").get("ok", true), "invalid SQL must fail"):
        return
    print("SQLITE TRACE: second transaction")
    if not _check(db.begin(), "begin"):
        return
    if not _check(db.execute("UPDATE soci_integration SET label = 'changed'")["ok"], "update"):
        return
    if not _check(db.rollback(), "rollback"):
        return
    if not _check(not db.commit(), "commit without active transaction must fail"):
        return
    var restored := db.query("SELECT label FROM soci_integration WHERE id = :id", {"id": 4000000000})
    if not _check(restored.get("ok", false) and restored["rows"][0]["label"] == "O'Reilly 🌍", "rollback verification"):
        return
    print("SQLITE TRACE: close connection")
    db.close()
    if not _check(not db.is_open(), "closed connection"):
        return
    print("SQLITE INTEGRATION PASS")
    quit(0)
