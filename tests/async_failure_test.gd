extends SceneTree

func _initialize() -> void:
    call_deferred("_run")


func _check(value: bool, message: String) -> bool:
    if not value:
        printerr("ASYNC FAILURE TEST FAILED: ", message)
        quit(1)
        return false
    return true


func _wait(dispatcher: SociQueryDispatcher, requests: Array, timeout_ms: int = 10000) -> bool:
    var until := Time.get_ticks_msec() + timeout_ms
    while Time.get_ticks_msec() < until:
        dispatcher.poll(128)
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
    var path := ProjectSettings.globalize_path("user://soci_failure_tests.db")
    var db := GodotSociDatabase.new()
    if not _check(db.open("sqlite3", path), "sqlite open"):
        return
    if not _check(db.execute("CREATE TABLE IF NOT EXISTS failure_test (n INTEGER)").get("ok", false), "create"):
        return
    db.close()

    # start() means the thread was launched, NOT that a DB connection succeeded.
    var unavailable := SociQueryDispatcher.new()
    if not _check(unavailable.start("postgresql",
            "host=127.0.0.1 port=1 dbname=missing user=nobody password=test connect_timeout=2"),
            "invalid PG startup"):
        return
    var pg_req := unavailable.query_async("SELECT 1 AS value")
    if not _check(pg_req != null, "bad PG request created"):
        return
    var pg_done: bool = await _wait(unavailable, [pg_req])
    if not _check(pg_done, "bad PG wait"):
        return
    var pg_result: Dictionary = pg_req.get_result()
    if not _check(not pg_result.get("ok", true) and not str(pg_result.get("error", "")).is_empty(),
            "bad PG must return an error: " + str(pg_result)):
        return
    if not _check(not str(pg_result["error"]).contains("password=test"),
            "PostgreSQL password leaked into error"):
        return
    unavailable.stop()

    # A running request is counted toward max_pending; excess is rejected.
    var bounded := SociQueryDispatcher.new()
    if not _check(bounded.start("sqlite3", path, 1), "bounded start"):
        return
    var first := bounded.query_async("SELECT 1 AS value")
    var excess := bounded.query_async("SELECT 2 AS value")
    if not _check(first != null and excess == null and
            bounded.get_last_error().contains("capacity"), "queue backpressure"):
        return
    var first_done: bool = await _wait(bounded, [first])
    if not _check(first_done, "first query timed out"):
        return
    if not _check(first.get_result().get("ok", false), "first query failed"):
        return
    bounded.stop()

    # Stopping settles queued requests and preserves completed results; no waiter hangs.
    var stopping := SociQueryDispatcher.new()
    if not _check(stopping.start("sqlite3", path, 32), "shutdown start"):
        return
    var pending_requests: Array = []
    for i in 24:
        var request := stopping.execute_async("INSERT INTO failure_test(n) VALUES (:n)", {"n": i})
        if not _check(request != null, "create request %d" % i):
            return
        pending_requests.append(request)
    stopping.stop()
    if not _check(stopping.pending() == 0, "pending count after shutdown"):
        return
    var completed := 0
    var canceled := 0
    for request in pending_requests:
        if not _check(request.is_done(), "stop must resolve every request"):
            return
        var result: Dictionary = request.get_result()
        if result.get("ok", false):
            completed += 1
        else:
            canceled += 1
            if not _check(not str(result.get("error", "")).is_empty(), "canceled without reason"):
                return

    # Check no successes were reported for mutations absent from durable state.
    if not _check(db.open("sqlite3", path), "verification reopen"):
        return
    var persisted: Dictionary = db.query("SELECT COUNT(*) AS total FROM failure_test")
    if not _check(persisted.get("ok", false), "verification query"):
        return
    if not _check(persisted["rows"][0]["total"] >= completed,
            "committed operations missing: " + str(persisted)):
        return
    db.close()
    print("ASYNC FAILURE PATHS PASS: ", completed, " completed; ", canceled, " canceled")
    quit(0)
