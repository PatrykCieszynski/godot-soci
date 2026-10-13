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
    var db := GodotSociDatabase.new()
    var path := ProjectSettings.globalize_path("user://godot_soci_demo.db")
    if not db.open("sqlite3", path):
        printerr("SQLite open failed: ", db.get_last_error())
        quit(1)
        return

    if not _check(db.execute("PRAGMA busy_timeout=5000"), "busy timeout"):
        return
    if not _check(db.execute("PRAGMA foreign_keys=ON"), "foreign keys"):
        return
    if not _check(db.query("PRAGMA journal_mode=WAL"), "WAL"):
        return
    if not _check(db.execute("PRAGMA synchronous=FULL"), "synchronous"):
        return
    if not _check(db.execute("CREATE TABLE IF NOT EXISTS demo (id INTEGER PRIMARY KEY, label TEXT NOT NULL, quantity BIGINT NOT NULL, note TEXT NULL)"), "schema"):
        return

    # Parameter values are bound, never concatenated into SQL.
    if not db.begin_immediate():
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
        printerr("SQLite returned unexpected rows: ", selected)
        quit(1)
        return
    if selected["rows"][0]["note"] != null or selected["rows"][0]["label"] != "O'Reilly 🌍":
        printerr("Null/UTF-8 roundtrip mismatch: ", selected)
        quit(1)
        return

    if not db.begin():
        printerr(db.get_last_error())
        quit(1)
        return
    if not _check(db.execute("UPDATE demo SET quantity = :new_quantity WHERE id = :id", {"new_quantity": 1, "id": 1}), "update"):
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
        printerr("Rollback failed")
        quit(1)
        return

    print("SQLITE DEMO PASS: WAL/FULL, params, 64-bit, UTF-8, NULL, commit, rollback")
    db.close()
    quit(0)
