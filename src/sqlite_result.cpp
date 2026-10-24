#include "godot_soci/sqlite_result.h"

#include <soci/soci.h>
#include <soci/sqlite3/soci-sqlite3.h>
#include <sqlite3.h>

#include <stdexcept>
#include <unordered_set>

namespace godot_soci {
bool fetch_sqlite_row(soci::statement &statement) {
    // There are intentionally no into(row) bindings: they force declaration-
    // based conversion. SOCI's scalar backend fetch preserves its error path
    // and cursor while leaving the current SQLite value types untouched.
    return statement.get_backend()->fetch(1) == soci::details::statement_backend::ef_success;
}
Row read_sqlite_row(soci::statement &statement) {
    // SOCI forward-declares SQLite's opaque C type inside sqlite_api. This is
    // the very same statement owned by its pinned backend, not another session.
    auto *backend = static_cast<soci::sqlite3_statement_backend *>(statement.get_backend());
    auto *native = reinterpret_cast<::sqlite3_stmt *>(backend->stmt_);
    Row row;
    std::unordered_set<std::string> names;
    for (int i = 0; i < sqlite3_column_count(native); ++i) {
        std::string name = sqlite3_column_name(native, i);
        if (!names.insert(name).second) {
            throw std::runtime_error("Duplicate SQL result column name: " + name + ". Use SQL aliases.");
        }
        Value value;
        // SQLite types belong to each runtime value. Declared INTEGER is not
        // int32, and expressions/aggregates do not have declared column types.
        switch (sqlite3_column_type(native, i)) {
            case SQLITE_NULL: break;
            case SQLITE_INTEGER:
                value.kind = ValueKind::Integer;
                value.integer = sqlite3_column_int64(native, i);
                break;
            case SQLITE_FLOAT:
                value.kind = ValueKind::Real;
                value.real = sqlite3_column_double(native, i);
                break;
            case SQLITE_TEXT: {
                value.kind = ValueKind::Text;
                const auto *text = sqlite3_column_text(native, i);
                value.text.assign(reinterpret_cast<const char *>(text), sqlite3_column_bytes(native, i));
                break;
            }
            default:
                throw std::runtime_error("Unsupported SQLite BLOB result; CAST it to TEXT or use the binary helper.");
        }
        row.emplace_back(std::move(name), std::move(value));
    }
    return row;
}
}
