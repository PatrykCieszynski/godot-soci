#include "godot_soci/database.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/variant.hpp>

#ifdef GODOT_SOCI_WITH_POSTGRESQL
#include <soci/postgresql/soci-postgresql.h>
#endif
#include <soci/sqlite3/soci-sqlite3.h>

#include <cctype>
#include <cmath>
#include <ctime>
#include <cstdint>
#include <iomanip>
#include <limits>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>

namespace godot {

namespace {
std::string redact_secrets(const std::string &value) {
    static const std::regex password(R"((password\s*=\s*)([^\s]+))", std::regex::icase);
    return std::regex_replace(value, password, "$1[REDACTED]");
}

std::string checked_key(const String &key) {
    const CharString bytes = key.utf8();
    const std::string name(bytes.get_data(), bytes.length());
    if (name.empty() || !(std::isalpha(static_cast<unsigned char>(name.front())) || name.front() == '_')) {
        throw std::invalid_argument("Parameter keys must be SQL identifiers (without ':').");
    }
    for (char c : name) {
        if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_')) {
            throw std::invalid_argument("Parameter keys must contain only ASCII letters, digits or '_'.");
        }
    }
    return name;
}

Dictionary success_result() {
    Dictionary out;
    out["ok"] = true;
    out["error"] = "";
    return out;
}
} // namespace

GodotSociDatabase::~GodotSociDatabase() {
    close();
}

void GodotSociDatabase::_bind_methods() {
    ClassDB::bind_method(D_METHOD("open", "backend", "connection_string"), &GodotSociDatabase::open);
    ClassDB::bind_method(D_METHOD("close"), &GodotSociDatabase::close);
    ClassDB::bind_method(D_METHOD("is_open"), &GodotSociDatabase::is_open);
    ClassDB::bind_method(D_METHOD("get_backend"), &GodotSociDatabase::get_backend);
    ClassDB::bind_method(D_METHOD("get_last_error"), &GodotSociDatabase::get_last_error);
    ClassDB::bind_method(D_METHOD("execute", "sql", "params"), &GodotSociDatabase::execute, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("query", "sql", "params", "max_rows"), &GodotSociDatabase::query,
                         DEFVAL(Dictionary()), DEFVAL(1000));
    ClassDB::bind_method(D_METHOD("begin"), &GodotSociDatabase::begin);
    ClassDB::bind_method(D_METHOD("begin_immediate"), &GodotSociDatabase::begin_immediate);
    ClassDB::bind_method(D_METHOD("commit"), &GodotSociDatabase::commit);
    ClassDB::bind_method(D_METHOD("rollback"), &GodotSociDatabase::rollback);
    ClassDB::bind_method(D_METHOD("in_transaction"), &GodotSociDatabase::in_transaction);
}

std::string GodotSociDatabase::utf8(const String &value) {
    const CharString bytes = value.utf8();
    return std::string(bytes.get_data(), bytes.length());
}

String GodotSociDatabase::from_utf8(const std::string &value) {
    return String::utf8(value.data(), static_cast<int>(value.size()));
}

bool GodotSociDatabase::fail(const std::string &message) {
    last_error_ = from_utf8(redact_secrets(message));
    return false;
}

Dictionary GodotSociDatabase::failure_result(const std::string &message) {
    fail(message);
    Dictionary out;
    out["ok"] = false;
    out["error"] = last_error_;
    return out;
}

bool GodotSociDatabase::ensure_open() {
    if (!session_ || !session_->is_connected()) {
        return fail("Database connection is not open.");
    }
    return true;
}

bool GodotSociDatabase::open(const String &backend, const String &connection_string) {
    close();
    last_error_ = "";
    try {
        std::unique_ptr<soci::session> candidate;
        if (backend == "sqlite3") {
            candidate = std::make_unique<soci::session>(soci::sqlite3, utf8(connection_string));
        } else if (backend == "postgresql") {
#ifdef GODOT_SOCI_WITH_POSTGRESQL
            candidate = std::make_unique<soci::session>(soci::postgresql, utf8(connection_string));
#else
            return fail("PostgreSQL backend is not enabled in this build.");
#endif
        } else {
            return fail("Unknown backend. Use 'sqlite3' or 'postgresql'.");
        }
        session_ = std::move(candidate);
        backend_ = backend;
        in_transaction_ = false;
        return true;
    } catch (const std::exception &error) {
        return fail(error.what());
    }
}

void GodotSociDatabase::close() {
    if (session_ && in_transaction_) {
        try {
            session_->rollback();
        } catch (const std::exception &) {
            // Closing a broken connection must not throw from a destructor.
        }
    }
    in_transaction_ = false;
    session_.reset();
    backend_ = "";
}

bool GodotSociDatabase::is_open() const { return session_ && session_->is_connected(); }
String GodotSociDatabase::get_backend() const { return backend_; }
String GodotSociDatabase::get_last_error() const { return last_error_; }
bool GodotSociDatabase::in_transaction() const { return in_transaction_; }

void GodotSociDatabase::bind_arguments(soci::statement &statement, const Dictionary &params,
                                       std::deque<BindParameter> &storage) {
    const Array keys = params.keys();
    for (int i = 0; i < keys.size(); ++i) {
        if (keys[i].get_type() != Variant::STRING) {
            throw std::invalid_argument("Parameter keys must be strings.");
        }
        BindParameter binding;
        binding.name = checked_key(static_cast<String>(keys[i]));
        const Variant value = params[keys[i]];
        switch (value.get_type()) {
            case Variant::NIL:
                binding.type = BindParameter::Type::Text;
                binding.indicator = soci::i_null;
                break;
            case Variant::BOOL:
                binding.type = BindParameter::Type::Integer;
                binding.integer = static_cast<bool>(value) ? 1 : 0;
                break;
            case Variant::INT:
                binding.type = BindParameter::Type::Integer;
                binding.integer = static_cast<int64_t>(value);
                break;
            case Variant::FLOAT:
                binding.type = BindParameter::Type::Real;
                binding.real = static_cast<double>(value);
                if (!std::isfinite(binding.real)) {
                    throw std::invalid_argument("NaN and infinity are not valid SQL parameters.");
                }
                break;
            case Variant::STRING:
                binding.type = BindParameter::Type::Text;
                binding.text = utf8(static_cast<String>(value));
                break;
            default:
                throw std::invalid_argument("Unsupported SQL parameter type (use null, bool, int, float or String).");
        }
        storage.push_back(std::move(binding));
        auto &arg = storage.back();
        switch (arg.type) {
            case BindParameter::Type::Integer:
                statement.exchange(soci::use(arg.integer, arg.indicator, arg.name));
                break;
            case BindParameter::Type::Real:
                statement.exchange(soci::use(arg.real, arg.indicator, arg.name));
                break;
            case BindParameter::Type::Text:
                statement.exchange(soci::use(arg.text, arg.indicator, arg.name));
                break;
        }
    }
}

Dictionary GodotSociDatabase::row_to_dictionary(const soci::row &row) {
    Dictionary out;
    for (std::size_t i = 0; i < row.size(); ++i) {
        const auto &column = row.get_properties(i);
        const String name = from_utf8(column.get_name());
        if (out.has(name)) {
            throw std::runtime_error("Duplicate SQL result column name: " + utf8(name) + ". Use explicit SQL aliases.");
        }
        if (row.get_indicator(i) == soci::i_null) {
            out[name] = Variant();
            continue;
        }
        switch (column.get_db_type()) {
            case soci::db_string:
                out[name] = from_utf8(row.get<std::string>(i));
                break;
            case soci::db_double:
                out[name] = row.get<double>(i);
                break;
            case soci::db_int8:
                out[name] = static_cast<int64_t>(row.get<int8_t>(i));
                break;
            case soci::db_uint8:
                out[name] = static_cast<int64_t>(row.get<uint8_t>(i));
                break;
            case soci::db_int16:
                out[name] = static_cast<int64_t>(row.get<int16_t>(i));
                break;
            case soci::db_uint16:
                out[name] = static_cast<int64_t>(row.get<uint16_t>(i));
                break;
            case soci::db_int32:
                out[name] = static_cast<int64_t>(row.get<int32_t>(i));
                break;
            case soci::db_uint32:
                out[name] = static_cast<int64_t>(row.get<uint32_t>(i));
                break;
            case soci::db_int64:
                out[name] = row.get<int64_t>(i);
                break;
            case soci::db_uint64: {
                const uint64_t number = row.get<uint64_t>(i);
                if (number > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
                    throw std::range_error("Unsigned BIGINT exceeds Godot's signed 64-bit integer range.");
                }
                out[name] = static_cast<int64_t>(number);
                break;
            }
            case soci::db_date: {
                const std::tm when = row.get<std::tm>(i);
                std::ostringstream formatted;
                formatted << std::put_time(&when, "%Y-%m-%d %H:%M:%S");
                out[name] = from_utf8(formatted.str());
                break;
            }
            default:
                throw std::runtime_error("Unsupported result column type; CAST complex/blob values to TEXT in SQL.");
        }
    }
    return out;
}

Dictionary GodotSociDatabase::execute(const String &sql, const Dictionary &params) {
    if (!ensure_open()) return failure_result(utf8(last_error_));
    try {
        std::deque<BindParameter> bindings;
        soci::statement statement(*session_);
        statement.alloc();
        statement.prepare(utf8(sql));
        bind_arguments(statement, params, bindings);
        statement.define_and_bind();
        statement.execute(true);
        Dictionary result = success_result();
        result["affected_rows"] = static_cast<int64_t>(statement.get_affected_rows());
        last_error_ = "";
        return result;
    } catch (const std::exception &error) {
        return failure_result(error.what());
    } catch (...) {
        // Keep unexpected native exceptions from escaping into the Godot ABI.
        // This also identifies an error path that is not a std::exception.
        return failure_result("SQL execution failed with a non-standard C++ exception.");
    }
}

Dictionary GodotSociDatabase::query(const String &sql, const Dictionary &params, int max_rows) {
    if (!ensure_open()) return failure_result(utf8(last_error_));
    if (max_rows < 1 || max_rows > 100000) {
        return failure_result("max_rows must be between 1 and 100000.");
    }
    try {
        std::deque<BindParameter> bindings;
        soci::row record;
        soci::statement statement(*session_);
        statement.alloc();
        statement.prepare(utf8(sql));
        statement.exchange(soci::into(record));
        bind_arguments(statement, params, bindings);
        statement.define_and_bind();
        statement.execute();
        Array rows;
        while (rows.size() < max_rows && statement.fetch()) {
            rows.append(row_to_dictionary(record));
        }
        // Read one extra row so callers can detect truncation at a page boundary.
        const bool truncated = rows.size() == max_rows && statement.fetch();
        Dictionary result = success_result();
        result["rows"] = rows;
        result["truncated"] = truncated;
        last_error_ = "";
        return result;
    } catch (const std::exception &error) {
        return failure_result(error.what());
    }
}

bool GodotSociDatabase::begin() {
    if (!ensure_open()) return false;
    if (in_transaction_) return fail("A transaction is already active.");
    try {
        session_->begin();
        in_transaction_ = true;
        last_error_ = "";
        return true;
    } catch (const std::exception &error) { return fail(error.what()); }
}

bool GodotSociDatabase::begin_immediate() {
    if (!ensure_open()) return false;
    if (backend_ != "sqlite3") return fail("BEGIN IMMEDIATE is only available with SQLite.");
    if (in_transaction_) return fail("A transaction is already active.");
    try {
        session_->once << "BEGIN IMMEDIATE";
        in_transaction_ = true;
        last_error_ = "";
        return true;
    } catch (const std::exception &error) { return fail(error.what()); }
}

bool GodotSociDatabase::commit() {
    if (!ensure_open()) return false;
    if (!in_transaction_) return fail("No transaction is active.");
    try {
        session_->commit();
        in_transaction_ = false;
        last_error_ = "";
        return true;
    } catch (const std::exception &error) { return fail(error.what()); }
}

bool GodotSociDatabase::rollback() {
    if (!ensure_open()) return false;
    if (!in_transaction_) return fail("No transaction is active.");
    try {
        session_->rollback();
        in_transaction_ = false;
        last_error_ = "";
        return true;
    } catch (const std::exception &error) { return fail(error.what()); }
}

} // namespace godot
