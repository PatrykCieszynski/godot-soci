class_name SociBinary
extends RefCounted

## Portable binary values for SQLite BLOB and PostgreSQL BYTEA.
##
## SOCI's native blob semantics differ by backend. Instead of pretending that
## PackedByteArray binds directly, encode the bytes as a bound hex string and
## decode them inside SQL. Query back via HEX/ENCODE and decode in Godot.
## The stored SQL column is still real BLOB/BYTEA, not TEXT.


static func to_hex(data: PackedByteArray) -> String:
    return data.hex_encode()


static func from_hex(value: String) -> PackedByteArray:
    return value.hex_decode()


## SQL expression for a named hex-string parameter. Only identifier names
## are allowed (never interpolate untrusted identifiers into SQL).
static func parameter_expression(backend: String, name: String) -> String:
    if not _identifier_ok(name):
        push_error("SociBinary parameter name must be a simple SQL identifier.")
        return ""
    match backend:
        "sqlite3":
            return "unhex(:" + name + ")"
        "postgresql":
            return "decode(:" + name + ", 'hex')"
        _:
            push_error("SociBinary backend must be sqlite3 or postgresql.")
            return ""


## SQL expression selecting the binary column as hexadecimal TEXT.
## The result can be converted to PackedByteArray with from_hex().
static func select_expression(backend: String, column: String) -> String:
    if not _identifier_ok(column):
        push_error("SociBinary column must be a simple SQL identifier.")
        return ""
    match backend:
        "sqlite3":
            return "hex(" + column + ")"
        "postgresql":
            return "encode(" + column + ", 'hex')"
        _:
            push_error("SociBinary backend must be sqlite3 or postgresql.")
            return ""


static func _identifier_ok(value: String) -> bool:
    if value.is_empty():
        return false
    for i in value.length():
        var c := value.unicode_at(i)
        if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95:
            continue
        if i > 0 and c >= 48 and c <= 57:
            continue
        return false
    return true
