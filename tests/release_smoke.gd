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
    wrapper.stop()
    wrapper.queue_free()
    print("PACKAGED ADDON SMOKE PASS")
    quit(0)
