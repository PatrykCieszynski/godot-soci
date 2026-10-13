extends Control

# Open the scene in the Godot editor to see both connection examples.
func _ready() -> void:
    var label := Label.new()
    label.position = Vector2(24, 24)
    label.text = "godot-soci loaded. Run headless demos from the README.\n" + \
        "SQLite: res://demo/sqlite/basic.gd\n" + \
        "PostgreSQL: res://demo/postgresql/basic.gd\n" + \
        "Worker: res://demo/sqlite/threaded.gd"
    add_child(label)
