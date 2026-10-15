class_name SociAsyncDatabase
extends Node

## Native SQL requests run on a dedicated C++ worker.
## This node must be inside the SceneTree to dispatch completions.

signal connection_state_changed(state: String)

var _dispatcher: SociQueryDispatcher = SociQueryDispatcher.new()


func _init() -> void:
    _dispatcher.connection_state_changed.connect(_on_connection_state_changed)


func _on_connection_state_changed(state: String) -> void:
    connection_state_changed.emit(state)


func _process(_delta: float) -> void:
    _dispatcher.poll()


func _exit_tree() -> void:
    _dispatcher.stop()


func start(backend: String, connection_string: String, max_pending: int = 128) -> bool:
    return _dispatcher.start(backend, connection_string, max_pending)


func stop() -> void:
    _dispatcher.stop()


func is_started() -> bool:
    return _dispatcher.is_started()


func pending() -> int:
    return _dispatcher.pending()


func get_last_error() -> String:
    return _dispatcher.get_last_error()


func get_connection_state() -> String:
    return _dispatcher.get_connection_state()


func get_stats() -> Dictionary:
    return _dispatcher.get_stats()


func query_async(sql: String, params: Dictionary = {}, max_rows: int = 1000) -> Dictionary:
    var request := _dispatcher.query_async(sql, params, max_rows)
    if request == null:
        return {"ok": false, "error": _dispatcher.get_last_error(), "rows": [], "truncated": false}
    if request.is_done():
        return request.get_result()
    return await request.completed


func execute_async(sql: String, params: Dictionary = {}) -> Dictionary:
    var request := _dispatcher.execute_async(sql, params)
    if request == null:
        return {"ok": false, "error": _dispatcher.get_last_error(), "affected_rows": 0}
    if request.is_done():
        return request.get_result()
    return await request.completed


func transaction_async(statements: Array) -> Dictionary:
    var request := _dispatcher.transaction_async(statements)
    if request == null:
        return {"ok": false, "error": _dispatcher.get_last_error(), "outcome_unknown": false,
            "affected_rows": 0, "affected_rows_per_statement": []}
    if request.is_done():
        return request.get_result()
    return await request.completed
