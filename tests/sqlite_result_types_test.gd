extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _check(ok: bool, message: String) -> bool:
    if not ok:
        printerr("SQLITE RESULT TYPES FAILED: ", message)
        quit(1)
    return ok

func _execute(db: Object, sql: String, params: Dictionary = {}) -> Dictionary:
    return await db.execute_async(sql, params) if db is SociAsyncDatabase else db.execute(sql, params)

func _query(db: Object, sql: String, params: Dictionary = {}, limit: int = 1000) -> Dictionary:
    return await db.query_async(sql, params, limit) if db is SociAsyncDatabase else db.query(sql, params, limit)

func _verify(db: Object, label: String) -> bool:
    var result: Dictionary = await _execute(db, "CREATE TABLE values_test (id INTEGER PRIMARY KEY, amount INTEGER, numeric_text TEXT, dynamic_value)")
    if not _check(result.get("ok", false), label + " schema " + str(result)): return false
    var values: Array = [null, 1, 4294967296, 9000000000000000, 9223372036854775807, -9223372036854775807 - 1, 1.25, "0000123", ""]
    for i in values.size():
        result = await _execute(db, "INSERT INTO values_test VALUES(:id, :amount, :text, :value)", {"id": i, "amount": 9000000000000000, "text": "0000123", "value": values[i]})
        if not _check(result.get("ok", false), label + " insert " + str(result)): return false
    result = await _query(db, "SELECT id, amount, numeric_text, dynamic_value FROM values_test ORDER BY id")
    if not _check(result.get("ok", false) and result.rows.size() == values.size(), label + " select " + str(result)): return false
    for i in values.size():
        var row: Dictionary = result.rows[i]
        if not _check(typeof(row.amount) == TYPE_INT and row.amount == 9000000000000000, label + " INTEGER must preserve int64"): return false
        if not _check(typeof(row.numeric_text) == TYPE_STRING and row.numeric_text == "0000123", label + " never guess the type of numeric TEXT"): return false
        if not _check(typeof(row.dynamic_value) == typeof(values[i]) and row.dynamic_value == values[i], label + " per-row storage class at " + str(i)): return false
    result = await _query(db, "SELECT COUNT(*) AS n, SUM(amount) AS total, MAX(amount) AS biggest FROM values_test")
    if not _check(result.get("ok", false) and typeof(result.rows[0].n) == TYPE_INT and result.rows[0].n == values.size() and typeof(result.rows[0].total) == TYPE_INT and result.rows[0].total == 81000000000000000, label + " aggregate types " + str(result)): return false
    result = await _query(db, "SELECT :value AS bound, 1 AS literal, 1.5 AS real_value, NULL AS empty, '00123' AS text_value", {"value": 9223372036854775807})
    if not _check(result.get("ok", false) and result.rows[0].bound == 9223372036854775807 and typeof(result.rows[0].literal) == TYPE_INT and typeof(result.rows[0].real_value) == TYPE_FLOAT and result.rows[0].empty == null and typeof(result.rows[0].text_value) == TYPE_STRING, label + " expression types " + str(result)): return false
    result = await _query(db, "SELECT amount FROM values_test WHERE id < 0")
    if not _check(result.get("ok", false) and result.rows.is_empty() and not result.truncated, label + " empty result"): return false
    result = await _query(db, "SELECT amount FROM values_test ORDER BY id", {}, 2)
    if not _check(result.get("ok", false) and result.rows.size() == 2 and result.truncated, label + " bounded fetch"): return false
    result = await _query(db, "SELECT 1 AS duplicate, 2 AS duplicate")
    if not _check(not result.get("ok", true), label + " duplicate names rejected"): return false
    result = await _query(db, "SELECT X'0102' AS binary_value")
    if not _check(not result.get("ok", true), label + " unsupported BLOB remains explicit"): return false
    result = await _execute(db, "CREATE TABLE eval_once (value WEIRD)")
    if not _check(result.get("ok", false), label + " custom declaration schema"): return false
    result = await _query(db, "INSERT INTO eval_once VALUES(7) RETURNING value")
    if not _check(result.get("ok", false) and result.rows.size() == 1 and typeof(result.rows[0].value) == TYPE_INT and result.rows[0].value == 7, label + " returning " + str(result)): return false
    result = await _query(db, "SELECT COUNT(*) AS n FROM eval_once")
    return _check(result.get("ok", false) and result.rows[0].n == 1, label + " do not execute SQL to discover a type " + str(result))

func _run() -> void:
    var sync_db := GodotSociDatabase.new()
    if not _check(sync_db.open("sqlite3", ":memory:"), "sync open"): return
    if not await _verify(sync_db, "sync"): return
    sync_db.close()
    var async_db := SociAsyncDatabase.new()
    root.add_child(async_db)
    if not _check(async_db.start("sqlite3", ":memory:", 8), "async start"): return
    if not await _verify(async_db, "async"): return
    async_db.stop()
    async_db.queue_free()
    print("SQLITE RESULT TYPES PASS")
    quit()
