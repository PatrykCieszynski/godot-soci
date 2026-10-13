extends SceneTree

# Run against both backends in CI to check shared Godot Variant contracts.
func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    var backends := [{"name": "sqlite3", "connection": ":memory:"}]
    var pg := OS.get_environment("GODOT_SOCI_PG")
    if not pg.is_empty():
        backends.append({"name": "postgresql", "connection": pg})
    for backend in backends:
        var db := SociAsyncDatabase.new()
        root.add_child(db)
        if not db.start(backend["name"], backend["connection"]):
            printerr("BACKEND PARITY FAILED: start ", backend["name"])
            quit(1)
            return

        var schema: Dictionary = await db.execute_async(
            "CREATE TABLE IF NOT EXISTS soci_type_parity (id BIGINT PRIMARY KEY, amount DOUBLE PRECISION, label TEXT, optional TEXT)"
        )
        if not schema.get("ok", false):
            printerr("BACKEND PARITY FAILED: schema ", schema)
            quit(1)
            return
        var cleaned: Dictionary = await db.execute_async("DELETE FROM soci_type_parity WHERE id=:id", {"id": 4000000000})
        if not cleaned.get("ok", false):
            printerr("BACKEND PARITY FAILED: delete ", cleaned)
            quit(1)
            return
        var inserted: Dictionary = await db.execute_async(
            "INSERT INTO soci_type_parity (id,amount,label,optional) VALUES (:id,:amount,:label,:optional)",
            {"id": 4000000000, "amount": 2.5, "label": "Hero 🌍", "optional": null}
        )
        var result: Dictionary = await db.query_async(
            "SELECT id,amount,label,optional FROM soci_type_parity WHERE id=:id", {"id": 4000000000}
        )
        if not inserted.get("ok", false) or not result.get("ok", false) or result["rows"].size() != 1:
            printerr("BACKEND PARITY FAILED: SQL ", inserted, result)
            quit(1)
            return
        var row: Dictionary = result["rows"][0]
        if typeof(row["id"]) != TYPE_INT or row["id"] != 4000000000:
            printerr("BACKEND PARITY FAILED: integer type: ", backend["name"], " ", row)
            quit(1)
            return
        if typeof(row["amount"]) != TYPE_FLOAT or abs(row["amount"] - 2.5) > 0.00001:
            printerr("BACKEND PARITY FAILED: float type: ", backend["name"], " ", row)
            quit(1)
            return
        if typeof(row["label"]) != TYPE_STRING or row["label"] != "Hero 🌍" or row["optional"] != null:
            printerr("BACKEND PARITY FAILED: text/null type: ", backend["name"], " ", row)
            quit(1)
            return
        # Both backends store native binary data. The SQL expressions differ,
        # but the GDScript API and PackedByteArray result stay the same.
        var binary_type := "BLOB" if backend["name"] == "sqlite3" else "BYTEA"
        var blob_table: Dictionary = await db.execute_async(
            "CREATE TABLE IF NOT EXISTS soci_blob_parity (id BIGINT PRIMARY KEY, payload " + binary_type + ")"
        )
        if not blob_table.get("ok", false):
            printerr("BACKEND PARITY FAILED: blob table ", blob_table)
            quit(1)
            return
        var cleared: Dictionary = await db.execute_async(
            "DELETE FROM soci_blob_parity WHERE id=:id", {"id": 4000000000}
        )
        if not cleared.get("ok", false):
            printerr("BACKEND PARITY FAILED: blob delete ", cleared)
            quit(1)
            return
        var bytes := PackedByteArray([0, 1, 42, 127, 128, 254, 255])
        var placeholder := SociBinary.parameter_expression(backend["name"], "payload")
        var blob_insert: Dictionary = await db.execute_async(
            "INSERT INTO soci_blob_parity (id,payload) VALUES (:id," + placeholder + ")",
            {"id": 4000000000, "payload": SociBinary.to_hex(bytes)}
        )
        var select_blob := SociBinary.select_expression(backend["name"], "payload")
        var blob_query: Dictionary = await db.query_async(
            "SELECT " + select_blob + " AS payload_hex FROM soci_blob_parity WHERE id=:id",
            {"id": 4000000000}
        )
        if not blob_insert.get("ok", false) or not blob_query.get("ok", false) or blob_query["rows"].size() != 1:
            printerr("BACKEND PARITY FAILED: blob SQL ", blob_insert, blob_query)
            quit(1)
            return
        var returned: PackedByteArray = SociBinary.from_hex(blob_query["rows"][0]["payload_hex"])
        if returned != bytes:
            printerr("BACKEND PARITY FAILED: blob round trip ", backend["name"], " ", returned)
            quit(1)
            return
        db.stop()
        db.queue_free()
        print("BACKEND PARITY: ", backend["name"], " PASS")
    print("BACKEND TYPE PARITY PASS")
    quit(0)
