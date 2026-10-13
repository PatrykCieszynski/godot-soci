extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _check(result: Dictionary, label: String) -> bool:
    if result.get("ok", false):
        return true
    printerr(label, ": ", result.get("error", "Unknown SQL error"))
    quit(1)
    return false

func _run() -> void:
    var connection := OS.get_environment("GODOT_SOCI_PG")
    if connection.is_empty():
        printerr("Set GODOT_SOCI_PG to a libpq connection string. Example in README.")
        quit(2)
        return
    var db := GodotSociDatabase.new()
    if not db.open("postgresql", connection):
        printerr("PostgreSQL open failed: ", db.get_last_error())
        quit(1)
        return

    if not _check(db.execute("CREATE TABLE IF NOT EXISTS demo (id BIGINT PRIMARY KEY, label TEXT NOT NULL, quantity BIGINT NOT NULL, note TEXT NULL)"), "schema"):
        return
    if not db.begin():
        printerr(db.get_last_error())
        quit(1)
        return
    if not _check(db.execute("DELETE FROM demo WHERE id = :id", {"id": 1}), "delete"):
        db.rollback()
        return
    if not _check(db.execute("INSERT INTO demo(id, label, quantity, note) VALUES (:id, :label, :quantity, :note)",
        {"id": 1, "label": "O'Reilly 🌍", "quantity": 4000000000, "note": null}), "insert"):
        db.rollback()
        return
    if not db.commit():
        printerr("Commit failure (outcome may be unknown): ", db.get_last_error())
        quit(1)
        return
    var selected := db.query("SELECT id, label, quantity, note FROM demo WHERE id = :id", {"id": 1})
    if not _check(selected, "select"):
        return
    if selected["rows"].size() != 1 or selected["rows"][0]["quantity"] != 4000000000:
        printerr("PostgreSQL returned unexpected rows: ", selected)
        quit(1)
        return
    if selected["rows"][0]["label"] != "O'Reilly 🌍" or selected["rows"][0]["note"] != null:
        printerr("UTF-8/NULL roundtrip mismatch: ", selected)
        quit(1)
        return
    if not db.begin():
        printerr(db.get_last_error())
        quit(1)
        return
    if not _check(db.execute("UPDATE demo SET quantity = :q WHERE id = :id", {"q": 17, "id": 1}), "update"):
        db.rollback()
        return
    if not db.rollback():
        printerr(db.get_last_error())
        quit(1)
        return
    var after_rollback := db.query("SELECT quantity FROM demo WHERE id = :id", {"id": 1})
    if not _check(after_rollback, "rollback verification"):
        return
    if after_rollback["rows"][0]["quantity"] != 4000000000:
        printerr("PostgreSQL rollback failed")
        quit(1)
        return
    print("POSTGRES DEMO PASS: params, 64-bit, UTF-8, NULL, commit, rollback")
    db.close()
    quit(0)
