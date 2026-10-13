class_name SociDatabase
extends RefCounted

## Synchronous convenience API. Use a dedicated thread for slow SQL operations.

var _driver: GodotSociDatabase = GodotSociDatabase.new()


func open(backend: String, connection_string: String) -> bool:
    return _driver.open(backend, connection_string)


func close() -> void:
    _driver.close()


func is_open() -> bool:
    return _driver.is_open()


func get_last_error() -> String:
    return _driver.get_last_error()


func get_backend() -> String:
    return _driver.get_backend()


func execute(sql: String, params: Dictionary = {}) -> Dictionary:
    return _driver.execute(sql, params)


func query(sql: String, params: Dictionary = {}, max_rows: int = 1000) -> Dictionary:
    return _driver.query(sql, params, max_rows)


func begin() -> bool:
    return _driver.begin()


func begin_immediate() -> bool:
    return _driver.begin_immediate()


func commit() -> bool:
    return _driver.commit()


func rollback() -> bool:
    return _driver.rollback()


func in_transaction() -> bool:
    return _driver.in_transaction()
