extends SceneTree

func _initialize() -> void:
    call_deferred("_run")

func _check(condition: bool, label: String) -> bool:
    if not condition:
        printerr("NATIVE ERROR TEST FAILED: ", label)
        quit(1)
    return condition

func _state(result: Dictionary, expected: String) -> bool:
    return not result.get("ok", true) and result.get("sqlstate", "")==expected and result.get("error_backend", "")=="postgresql" and not result.get("error", "").is_empty()

func _run() -> void:
    var connection:=OS.get_environment("GODOT_SOCI_PG")
    if not _check(not connection.is_empty(), "GODOT_SOCI_PG must point to a disposable fixture"): return
    var db:=GodotSociDatabase.new()
    var other:=GodotSociDatabase.new()
    if not _check(db.open("postgresql", connection) and other.open("postgresql", connection), "open"): return
    if not _check(db.execute("DROP TABLE IF EXISTS soci_error_fixture").ok and db.execute("CREATE TABLE soci_error_fixture(id BIGINT PRIMARY KEY,value BIGINT NOT NULL)").ok and db.execute("INSERT INTO soci_error_fixture VALUES(1,0),(2,0)").ok,"fixture"): return
    var duplicate:=db.execute("INSERT INTO soci_error_fixture VALUES(1,9)")
    if not _check(_state(duplicate,"23505") and duplicate.error_category=="constraint_violation", "unique violation metadata"): return
    var copied:=db.get_last_error_details()
    copied.sqlstate="mutated"
    if not _check(db.get_last_error_details().sqlstate=="23505", "returned details are isolated"): return
    if not _check(db.query("SELECT 1 AS value").ok and db.get_last_error_details().is_empty() and db.get_last_error().is_empty(), "success resets diagnostics"): return
    if not _check(_state(db.query("SELECT FROM"),"42601"), "query syntax metadata"): return
    var invalid:=db.query("SELECT 1 AS value",{},0)
    if not _check(not invalid.ok and invalid.sqlstate=="" and invalid.error_category=="unknown", "local validation cannot reuse old SQLSTATE"): return
    if not _check(db.begin() and db.query("SELECT * FROM soci_error_fixture WHERE id=1 FOR UPDATE").ok and other.begin() and other.execute("SET LOCAL lock_timeout='40ms'").ok,"lock setup"): return
    if not _check(_state(other.execute("UPDATE soci_error_fixture SET value=1 WHERE id=1"),"55P03"), "lock timeout"): return
    if not _check(other.rollback() and other.get_last_error_details().is_empty() and db.rollback(), "rollback clears previous details"): return
    if not _check(other.begin() and other.execute("SET LOCAL statement_timeout='20ms'").ok and _state(other.query("SELECT pg_sleep(0.1)"),"57014") and other.rollback(), "statement cancellation"): return
    if not _check(db.begin() and db.execute("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ").ok and db.query("SELECT value FROM soci_error_fixture WHERE id=2").ok,"serialization setup"): return
    if not _check(other.execute("UPDATE soci_error_fixture SET value=value+1 WHERE id=2").ok and _state(db.execute("UPDATE soci_error_fixture SET value=value+1 WHERE id=2"),"40001") and db.rollback(),"actual serialization failure"): return
    if not _check(_deadlock(db,connection), "actual deadlock SQLSTATE"): return
    # A statement error leaves PostgreSQL's transaction aborted, while the local
    # flag still owns cleanup. A later statement must report 25P02 until rollback.
    if not _check(db.begin() and db.execute("UPDATE soci_error_fixture SET value=77 WHERE id=1").ok, "statement-failure setup"): return
    var statement_error:=db.execute("INSERT INTO soci_error_fixture VALUES(1,9)")
    if not _check(_state(statement_error,"23505") and db.in_transaction() and _state(db.query("SELECT 1 AS value"),"25P02"), "failed transaction remains aborted"): return
    if not _check(db.rollback() and not db.in_transaction() and db.get_last_error_details().is_empty() and int(other.query("SELECT value FROM soci_error_fixture WHERE id=1").rows[0].value)==0, "rollback restores provisional writes"): return
    # PostgreSQL accepts COMMIT on an already aborted transaction as ROLLBACK.
    # The legacy bool acknowledges command success, not all-or-nothing write success.
    if not _check(db.begin() and db.execute("UPDATE soci_error_fixture SET value=88 WHERE id=1").ok and _state(db.execute("INSERT INTO soci_error_fixture VALUES(1,9)"),"23505") and db.commit() and not db.in_transaction(), "aborted COMMIT is accepted as rollback"): return
    if not _check(int(other.query("SELECT value FROM soci_error_fixture WHERE id=1").rows[0].value)==0, "accepted aborted COMMIT did not persist writes"): return
    if not _check(db.execute("CREATE TEMP TABLE soci_error_parent(id BIGINT PRIMARY KEY)").ok and db.execute("CREATE TEMP TABLE soci_error_child(id BIGINT REFERENCES soci_error_parent(id) DEFERRABLE INITIALLY DEFERRED)").ok,"deferred fixture"): return
    if not _check(db.begin() and db.execute("UPDATE soci_error_fixture SET value=66 WHERE id=1").ok and db.execute("INSERT INTO soci_error_child VALUES(42)").ok and not db.commit(),"failed COMMIT stays bool"): return
    var commit_error:=db.get_last_error_details()
    if not _check(commit_error.sqlstate=="23503" and db.in_transaction(),"COMMIT details available before cleanup"): return
    # The server has already ended this transaction: SELECT succeeds (no 25P02)
    # and sees the old value, even though the local lifecycle flag is still true.
    var after_commit:=db.query("SELECT value FROM soci_error_fixture WHERE id=1")
    if not _check(after_commit.ok and int(after_commit.rows[0].value)==0 and db.in_transaction() and db.get_last_error_details().is_empty() and commit_error.sqlstate=="23503", "local flag does not assert server transaction state"): return
    if not _check(db.rollback() and not db.in_transaction(), "explicit cleanup after server-ended transaction"): return
    if not _check(db.begin() and db.execute("INSERT INTO soci_error_child VALUES(43)").ok and not db.commit(), "second deferred COMMIT"): return
    commit_error=db.get_last_error_details()
    db.close()
    if not _check(db.get_last_error_details()==commit_error and not db.in_transaction() and db.open("postgresql",connection) and db.get_last_error_details().is_empty(),"close retains diagnostics; reopen resets"): return
    var pid: int=int(db.query("SELECT pg_backend_pid() AS pid").rows[0].pid)
    if not _check(db.begin() and db.execute("UPDATE soci_error_fixture SET value=99 WHERE id=1").ok and other.query("SELECT pg_terminate_backend(:pid)",{"pid":pid}).ok,"disconnect fixture"): return
    if not _check(not db.commit() and db.in_transaction() and db.get_last_error_details().get("sqlstate","") not in ["40001","40P01"],"connection loss never looks like retryable transaction abort"): return
    db.close()
    if not _check(db.open("postgresql",connection) and int(db.query("SELECT value FROM soci_error_fixture WHERE id=1").rows[0].value)==0,"lost transaction rolled back"): return
    db.close()
    other.close()
    var local:=GodotSociDatabase.new()
    if not _check(local.open("sqlite3",":memory:") and local.execute("CREATE TABLE t(id INTEGER PRIMARY KEY)").ok and local.execute("INSERT INTO t VALUES(1)").ok,"SQLite setup"): return
    var failure:=local.execute("INSERT INTO t VALUES(1)")
    if not _check(not failure.ok and failure.sqlstate=="" and failure.error_backend=="sqlite3" and int(failure.backend_error_code)!=0,"SQLite errors never acquire PG SQLSTATE"): return
    local.close()
    var wrapper=preload("res://addons/godot_soci/database.gd").new()
    if not _check(wrapper.open("sqlite3",":memory:") and not wrapper.query("SELECT missing_table").ok and wrapper.get_last_error_details().error_backend=="sqlite3", "wrapper exposes diagnostics"): return
    wrapper.close()
    print("NATIVE ERROR INTEGRATION PASS")
    quit(0)

# Each session holds its first row before either attempts the opposite row.
# Semaphores establish the cycle without a 500ms pg_stat_activity observation.
# Test-only local budgets allow default PostgreSQL deadlock detection plus CI slack.
func _deadlock(db: GodotSociDatabase, connection: String) -> bool:
    if not db.begin() or not _deadlock_budgets(db) or not db.query("SELECT * FROM soci_error_fixture WHERE id=1 FOR UPDATE").ok:
        return false
    var ready:=Semaphore.new()
    var cross:=Semaphore.new()
    var thread:=Thread.new()
    if thread.start(_deadlock_worker.bind(connection+" application_name=native-deadlock",ready,cross))!=OK:
        db.rollback()
        return false
    ready.wait()
    cross.post()
    var result:=db.execute("UPDATE soci_error_fixture SET value=value+1 WHERE id=2")
    var cleaned: bool=db.rollback()
    var worker: Dictionary=thread.wait_to_finish()
    return cleaned and int(result.ok)+int(worker.ok)==1 and (_state(result,"40P01") or _state(worker,"40P01"))

func _deadlock_budgets(db: GodotSociDatabase) -> bool:
    return db.execute("SET LOCAL statement_timeout='10s'").ok and db.execute("SET LOCAL lock_timeout='5s'").ok and db.execute("SET LOCAL idle_in_transaction_session_timeout='10s'").ok

func _deadlock_worker(connection: String, ready: Semaphore, cross: Semaphore) -> Dictionary:
    var db:=GodotSociDatabase.new()
    var valid: bool=db.open("postgresql",connection) and db.begin() and _deadlock_budgets(db) and db.query("SELECT * FROM soci_error_fixture WHERE id=2 FOR UPDATE").ok
    ready.post()
    if not valid:
        db.close()
        return {"ok":false,"error":"worker setup"}
    cross.wait()
    var result:=db.execute("UPDATE soci_error_fixture SET value=value+1 WHERE id=1")
    if not db.rollback(): result={"ok":false,"error":"worker cleanup"}
    db.close()
    return result
