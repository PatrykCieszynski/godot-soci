extends SceneTree

# Real concurrent SQLite WAL smoke/stress: 2 native writer threads + 1 reader.
# Queries are issued before waiting, so the three independent SOCI sessions
# overlap; no Godot objects are ever touched by the C++ workers.

const WRITES_PER_WORKER := 48

func _initialize() -> void:
    call_deferred("_run")


func _assert(value: bool, message: String) -> bool:
    if not value:
        printerr("SQLITE WAL TEST FAILED: ", message)
        quit(1)
        return false
    return true


func _wait_all(dispatchers: Array, requests: Array, timeout_ms: int = 30000) -> bool:
    var deadline := Time.get_ticks_msec() + timeout_ms
    while Time.get_ticks_msec() < deadline:
        for dispatcher in dispatchers:
            dispatcher.poll(256)
        var all_done := true
        for request in requests:
            if not request.is_done():
                all_done = false
                break
        if all_done:
            return true
        await process_frame
    return false


func _run() -> void:
    var db_path := ProjectSettings.globalize_path("user://soci_wal_concurrency.db")
    var setup := GodotSociDatabase.new()
    if not _assert(setup.open("sqlite3", db_path), "open: " + setup.get_last_error()):
        return
    var journal := setup.query("PRAGMA journal_mode=WAL")
    if not _assert(journal.get("ok", false) and
            str(journal["rows"][0]["journal_mode"]).to_lower() == "wal",
            "WAL mode: " + str(journal)):
        return
    if not _assert(setup.execute("CREATE TABLE IF NOT EXISTS wal_test (id INTEGER PRIMARY KEY, data TEXT NOT NULL)").get("ok", false), "create table"):
        return
    if not _assert(setup.execute("DELETE FROM wal_test").get("ok", false), "clean table"):
        return
    setup.close()

    var a := SociQueryDispatcher.new()
    var b := SociQueryDispatcher.new()
    var reader := SociQueryDispatcher.new()
    var dispatchers := [a, b, reader]
    for dispatcher in dispatchers:
        if not _assert(dispatcher.start("sqlite3", db_path, 128), "start"):
            return

    # Each SQLite connection needs its own lock wait timeout.
    var settings: Array = []
    for dispatcher in dispatchers:
        settings.append(dispatcher.query_async("PRAGMA busy_timeout=10000"))
    if not _assert(await _wait_all(dispatchers, settings), "busy_timeout setup timed out"):
        return
    for request in settings:
        if not _assert(request.get_result().get("ok", false), "busy_timeout result: " + str(request.get_result())):
            return

    var writes: Array = []
    var reads: Array = []
    for i in WRITES_PER_WORKER:
        writes.append(a.execute_async(
            "INSERT INTO wal_test (id, data) VALUES (:id, :data)",
            {"id": i + 1, "data": "a-%d" % i}
        ))
        writes.append(b.execute_async(
            "INSERT INTO wal_test (id, data) VALUES (:id, :data)",
            {"id": 1000 + i, "data": "b-%d" % i}
        ))
        if i % 2 == 0:
            reads.append(reader.query_async("SELECT COUNT(*) AS total FROM wal_test"))

    var all_requests := writes + reads
    if not _assert(await _wait_all(dispatchers, all_requests, 30000), "parallel work timed out"):
        return
    for request in writes:
        if not _assert(request != null and request.get_result().get("ok", false),
                "writer failed: " + str(request.get_result())):
            return
    for request in reads:
        if not _assert(request != null and request.get_result().get("ok", false),
                "reader failed: " + str(request.get_result())):
            return

    var final_count := reader.query_async("SELECT COUNT(*) AS total, COUNT(DISTINCT id) AS distinct_total FROM wal_test")
    if not _assert(await _wait_all(dispatchers, [final_count]), "final count timed out"):
        return
    var result: Dictionary = final_count.get_result()
    var expected := WRITES_PER_WORKER * 2
    if not _assert(result.get("ok", false) and
            result["rows"][0]["total"] == expected and
            result["rows"][0]["distinct_total"] == expected,
            "missing/duplicate writes: " + str(result)):
        return

    for dispatcher in dispatchers:
        dispatcher.stop()
    print("SQLITE WAL CONCURRENCY PASS: ", expected, " committed writes + ", reads.size(), " reads")
    quit(0)
