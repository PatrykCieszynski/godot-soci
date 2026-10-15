extends SceneTree

# Verify observed connection state, bounded queue counters and failure paths.
var states: Array[String] = []


func _initialize() -> void:
    call_deferred("_run")


func _check(value: bool, message: String) -> bool:
    if not value:
        printerr("ASYNC OBSERVABILITY FAILED: ", message)
        quit(1)
        return false
    return true


func _on_state_changed(state: String) -> void:
    states.append(state)


func _run() -> void:
    var db := SociAsyncDatabase.new()
    root.add_child(db)
    db.connection_state_changed.connect(_on_state_changed)
    if not _check(db.start("sqlite3", ":memory:", 8), "SQLite worker start"):
        return
    var hello: Dictionary = await db.query_async("SELECT 42 AS answer")
    if not _check(hello.get("ok", false), "SQLite ready query: " + str(hello)):
        return
    if not _check(db.get_connection_state() == "connected" and states.has("connected"),
            "Connected state and signal: " + str(states)):
        return
    var basic: Dictionary = db.get_stats()
    if not _check(basic["submitted"] == 1 and basic["completed"] == 1 and
            basic["failed"] == 0 and basic["pending"] == 0 and
            basic["avg_execution_ms"] >= 0.0, "SQLite stats: " + str(basic)):
        return
    db.stop()
    if not _check(db.get_connection_state() == "stopped" and states.has("stopped"),
            "Stopped state and signal: " + str(states)):
        return
    db.queue_free()

    # A pending cap includes queued, executing and awaiting-poll requests.
    var bounded := SociQueryDispatcher.new()
    if not _check(bounded.start("sqlite3", ":memory:", 8), "Bounded worker start"):
        return
    var pending_requests: Array = []
    for i in 8:
        var request: SociQueryRequest = bounded.query_async("SELECT :n AS n", {"n": i})
        if not _check(request != null, "Submit query " + str(i)):
            return
        pending_requests.append(request)
    var rejected := bounded.query_async("SELECT 999 AS n")
    if not _check(rejected == null and bounded.get_last_error().contains("capacity"),
            "Backpressure must reject ninth request"):
        return
    var busy: Dictionary = bounded.get_stats()
    if not _check(busy["submitted"] == 8 and busy["rejected"] == 1 and busy["pending"] == 8 and
            busy["queued"] + busy["executing"] + busy["awaiting_poll"] == 8,
            "Backlog accounting: " + str(busy)):
        return

    var timeout := Time.get_ticks_msec() + 10000
    while Time.get_ticks_msec() < timeout:
        bounded.poll()
        var all_done := true
        for request in pending_requests:
            if not request.is_done():
                all_done = false
                break
        if all_done:
            break
        await process_frame
    for request in pending_requests:
        if not _check(request.is_done() and request.get_result().get("ok", false),
                "All accepted requests must complete"):
            return
    var after: Dictionary = bounded.get_stats()
    if not _check(after["completed"] == 8 and after["failed"] == 0 and after["rejected"] == 1 and
            after["pending"] == 0 and after["queued"] == 0 and after["executing"] == 0 and
            after["awaiting_poll"] == 0 and after["avg_queue_ms"] >= 0.0 and
            after["avg_delivery_ms"] >= 0.0, "Completed metrics: " + str(after)):
        return
    bounded.stop()

    # Repeated bursts exercise accounting across many poll/submit cycles,
    # without asserting CPU-dependent timing thresholds.
    var stress := SociQueryDispatcher.new()
    if not _check(stress.start("sqlite3", ":memory:", 32), "Stress worker start"):
        return
    for wave in 20:
        var wave_requests: Array = []
        for i in 24:
            var request: SociQueryRequest = stress.query_async(
                "SELECT CAST(:n AS INTEGER) AS n", {"n": wave * 24 + i}
            )
            if not _check(request != null, "Stress submission wave %d item %d" % [wave, i]):
                return
            wave_requests.append(request)
        var deadline := Time.get_ticks_msec() + 10000
        while Time.get_ticks_msec() < deadline:
            stress.poll(32)
            var wave_complete := true
            for request in wave_requests:
                if not request.is_done():
                    wave_complete = false
                    break
            if wave_complete:
                break
            await process_frame
        for i in wave_requests.size():
            var response: Dictionary = wave_requests[i].get_result()
            if not _check(wave_requests[i].is_done() and response.get("ok", false) and
                    int(response["rows"][0]["n"]) == wave * 24 + i,
                    "Stress response wave %d item %d: %s" % [wave, i, str(response)]):
                return
    var stress_stats: Dictionary = stress.get_stats()
    if not _check(stress_stats["submitted"] == 480 and stress_stats["completed"] == 480 and
            stress_stats["failed"] == 0 and stress_stats["rejected"] == 0 and
            stress_stats["pending"] == 0 and stress_stats["avg_queue_ms"] >= 0.0 and
            stress_stats["avg_execution_ms"] >= 0.0,
            "Stress accounting: " + str(stress_stats)):
        return

    # A SQL error is a completed failed request, not a rejected submission,
    # and must not mark an otherwise healthy SQLite connection disconnected.
    var invalid: SociQueryRequest = stress.execute_async("THIS IS NOT SQL")
    if not _check(invalid != null, "Invalid SQL is submitted"):
        return
    var invalid_deadline := Time.get_ticks_msec() + 5000
    while not invalid.is_done() and Time.get_ticks_msec() < invalid_deadline:
        stress.poll()
        await process_frame
    var errors: Dictionary = stress.get_stats()
    var native_sqlite_error: Dictionary = invalid.get_result()
    if not _check(native_sqlite_error.get("error_backend", "") == "sqlite3" and
            int(native_sqlite_error.get("backend_error_code", 0)) > 0 and
            native_sqlite_error.get("sqlstate", "") == "" and
            native_sqlite_error.has("error_category"),
            "SQLite native diagnostics: " + str(native_sqlite_error)):
        return
    if not _check(invalid.is_done() and not invalid.get_result().get("ok", true) and
            errors["submitted"] == 481 and errors["completed"] == 481 and
            errors["failed"] == 1 and errors["rejected"] == 0 and
            stress.get_connection_state() == "connected",
            "Failed query accounting: " + str(errors)):
        return
    stress.stop()
    if not _check(stress.get_stats()["completed"] == 481 and
            stress.get_stats()["pending"] == 0, "Stop must preserve completed counters"):
        return

    # Connection failure must be distinguishable from an active thread.
    var missing := SociAsyncDatabase.new()
    root.add_child(missing)
    if not _check(missing.start("postgresql",
            "host=127.0.0.1 port=1 dbname=absent user=none password=test connect_timeout=2"),
            "Failed PostgreSQL worker starts asynchronously"):
        return
    var failure: Dictionary = await missing.query_async("SELECT 1 AS n")
    if not _check(not failure.get("ok", true) and missing.get_connection_state() == "failed" and
            missing.is_started(), "Connection failed state: " + str(failure)):
        return
    missing.stop()
    missing.queue_free()

    # Terminate our own PostgreSQL backend: never automatically reconnect.
    var connection := OS.get_environment("GODOT_SOCI_PG")
    if not connection.is_empty():
        var pg := SociAsyncDatabase.new()
        root.add_child(pg)
        if not _check(pg.start("postgresql", connection), "PostgreSQL connection start"):
            return
        var ready: Dictionary = await pg.query_async("SELECT 1 AS n")
        if not _check(ready.get("ok", false) and pg.get_connection_state() == "connected",
                "PostgreSQL ready: " + str(ready)):
            return
        # Keep backend-native errors available without parsing message strings.
        var pg_invalid: Dictionary = await pg.execute_async("THIS IS NOT SQL")
        if not _check(not pg_invalid.get("ok", true) and
                pg_invalid.get("error_backend", "") == "postgresql" and
                pg_invalid.get("sqlstate", "") == "42601" and
                pg.get_connection_state() == "connected",
                "PostgreSQL SQLSTATE diagnostics: " + str(pg_invalid)):
            return
        var terminated: Dictionary = await pg.query_async(
            "SELECT pg_terminate_backend(pg_backend_pid()) AS terminated"
        )
        if not _check(not terminated.get("ok", true) and pg.get_connection_state() == "disconnected",
                "Backend termination should mark disconnect: " + str(terminated) +
                " state=" + pg.get_connection_state()):
            return
        var no_retry: Dictionary = await pg.query_async("SELECT 1 AS n")
        if not _check(not no_retry.get("ok", true), "Disconnect must not silently reconnect"):
            return
        pg.stop()
        pg.queue_free()
    print("ASYNC OBSERVABILITY PASS")
    quit(0)
