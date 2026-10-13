extends SceneTree

# Run inside an otherwise empty project containing only the packaged addon.
func _initialize() -> void:
    call_deferred("_run")


func _failure(message: String) -> void:
    printerr("PACKAGED ADDON SMOKE FAILED: ", message)
    quit(1)


func _run() -> void:
    if not ClassDB.class_exists("GodotSociDatabase"):
        _failure("Native database class was not registered")
        return
    if not ClassDB.class_exists("SociQueryDispatcher"):
        _failure("Native dispatcher class was not registered")
        return

    var native_db := GodotSociDatabase.new()
    if not native_db.open("sqlite3", ":memory:"):
        _failure("Native SQLite open: " + native_db.get_last_error())
        return
    var native_result: Dictionary = native_db.query("SELECT 42 AS answer")
    if not native_result.get("ok", false) or int(native_result["rows"][0]["answer"]) != 42:
        _failure("Native SQL test: " + str(native_result))
        return
    native_db.close()

    var wrapper := SociAsyncDatabase.new()
    root.add_child(wrapper)
    if not wrapper.start("sqlite3", ":memory:"):
        _failure("Async database start: " + wrapper.get_last_error())
        return
    var result: Dictionary = await wrapper.query_async("SELECT 43 AS answer")
    if not result.get("ok", false) or int(result["rows"][0]["answer"]) != 43:
        _failure("Async SQL test: " + str(result))
        return

    var committed: Dictionary = await wrapper.transaction_async([
        {"sql": "CREATE TABLE ledger (id INTEGER PRIMARY KEY, balance INTEGER)"},
        {"sql": "INSERT INTO ledger (id,balance) VALUES (:id,:balance)",
         "params": {"id": 1, "balance": 50}, "expected_affected_rows": 1}
    ])
    if not committed.get("ok", false):
        _failure("Native atomic transaction: " + str(committed))
        return
    var balance: Dictionary = await wrapper.query_async("SELECT balance FROM ledger WHERE id=1")
    if not balance.get("ok", false) or int(balance["rows"][0]["balance"]) != 50:
        _failure("Database commit check: " + str(balance))
        return
    var raw := PackedByteArray([0, 42, 128, 255])
    var create_blob: Dictionary = await wrapper.execute_async(
        "CREATE TABLE binary_smoke (id INTEGER PRIMARY KEY, payload BLOB)"
    )
    var put_blob: Dictionary = await wrapper.execute_async(
        "INSERT INTO binary_smoke (id,payload) VALUES (1," + SociBinary.parameter_expression("sqlite3", "payload") + ")",
        {"payload": SociBinary.to_hex(raw)}
    )
    var get_blob: Dictionary = await wrapper.query_async(
        "SELECT " + SociBinary.select_expression("sqlite3", "payload") + " AS data FROM binary_smoke WHERE id=1"
    )
    if not create_blob.get("ok", false) or not put_blob.get("ok", false) or not get_blob.get("ok", false) or get_blob["rows"].size() != 1:
        _failure("Packaged binary query failed: " + str(create_blob) + str(put_blob) + str(get_blob))
        return
    if SociBinary.from_hex(get_blob["rows"][0]["data"]) != raw:
        _failure("Packed binary round-trip mismatch")
        return
    wrapper.stop()
    wrapper.queue_free()
    print("PACKAGED ADDON SMOKE PASS")
    quit(0)
