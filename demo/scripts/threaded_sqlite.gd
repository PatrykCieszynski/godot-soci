extends SceneTree

# A real dedicated Godot Thread: all SQLite calls and connection lifecycle run there.
# This example uses a bounded one-shot request rather than an unbounded queue.
var worker := Thread.new()
var gate := Mutex.new()
var finished := false
var output: Dictionary = {}

func _initialize() -> void:
    call_deferred("_start")

func _start() -> void:
    var path := ProjectSettings.globalize_path("user://godot_soci_threaded.db")
    var error := worker.start(_work.bind(path))
    if error != OK:
        printerr("Worker start failed: ", error)
        quit(1)
        return
    _poll()

func _work(path: String) -> void:
    var db := GodotSociDatabase.new()
    var result: Dictionary
    if db.open("sqlite3", path):
        db.execute("PRAGMA busy_timeout=5000")
        var schema := db.execute("CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, text TEXT)")
        if schema.get("ok", false):
            db.execute("INSERT OR REPLACE INTO messages(id,text) VALUES (:id,:text)", {"id": 1, "text": "from a real thread"})
            result = db.query("SELECT text FROM messages WHERE id = :id", {"id": 1})
        else:
            result = schema
    else:
        result = {"ok": false, "error": db.get_last_error()}
    db.close()
    gate.lock()
    output = result.duplicate(true)
    finished = true
    gate.unlock()

func _poll() -> void:
    while true:
        gate.lock()
        var done := finished
        var result := output.duplicate(true)
        gate.unlock()
        if done:
            worker.wait_to_finish()
            if not result.get("ok", false) or result.get("rows", []).size() != 1:
                printerr("THREAD DEMO FAILED: ", result)
                quit(1)
                return
            print("THREAD DEMO PASS: ", result["rows"][0])
            quit(0)
            return
        await process_frame
