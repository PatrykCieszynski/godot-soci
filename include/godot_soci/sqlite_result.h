#pragma once

#include "godot_soci/query_worker.h"

namespace soci { class statement; }

namespace godot_soci {
// Caller owns a live SQLite SOCI statement positioned on a row. No Godot objects
// are created here, so the worker uses exactly the same conversion as sync SQL.
Row read_sqlite_row(soci::statement &statement);
bool fetch_sqlite_row(soci::statement &statement);
}
