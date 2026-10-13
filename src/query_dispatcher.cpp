#include "godot_soci/query_dispatcher.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <soci/soci.h>
#include <soci/sqlite3/soci-sqlite3.h>
#ifdef GODOT_SOCI_WITH_POSTGRESQL
#include <soci/postgresql/soci-postgresql.h>
#endif

#include <cctype>
#include <cmath>
#include <exception>
#include <memory>
#include <regex>
#include <stdexcept>
#include <utility>

namespace godot {
namespace {

std::string utf8(const String &value) {
    CharString bytes = value.utf8();
    return std::string(bytes.get_data(), bytes.length());
}

String to_godot(const std::string &value) {
    return String::utf8(value.data(), static_cast<int>(value.size()));
}

std::string checked_key(const String &key) {
    std::string name = utf8(key);
    if (name.empty() || !(std::isalpha(static_cast<unsigned char>(name.front())) || name.front() == '_')) {
        throw std::invalid_argument("SQL bind names must be identifiers without ':'.");
    }
    for (char ch : name) {
        if (!(std::isalnum(static_cast<unsigned char>(ch)) || ch == '_')) {
            throw std::invalid_argument("SQL bind names support ASCII letters, digits and '_'.");
        }
    }
    return name;
}

std::string redact(const std::string &message) {
    static const std::regex password(R"((password\s*=\s*)([^\s]+))", std::regex::icase);
    return std::regex_replace(message, password, "$1[REDACTED]");
}

godot_soci::Value copy_parameter(const Variant &value) {
    godot_soci::Value result;
    switch (value.get_type()) {
        case Variant::NIL:
            break;
        case Variant::BOOL:
            result.kind = godot_soci::ValueKind::Integer;
            result.integer = static_cast<bool>(value) ? 1 : 0;
            break;
        case Variant::INT:
            result.kind = godot_soci::ValueKind::Integer;
            result.integer = static_cast<int64_t>(value);
            break;
        case Variant::FLOAT:
            result.kind = godot_soci::ValueKind::Real;
            result.real = static_cast<double>(value);
            if (!std::isfinite(result.real)) throw std::invalid_argument("NaN/Infinity SQL parameters are not supported.");
            break;
        case Variant::STRING:
            result.kind = godot_soci::ValueKind::Text;
            result.text = utf8(static_cast<String>(value));
            break;
        default:
            throw std::invalid_argument("Unsupported bind type (use null, bool, int, float, String).");
    }
    return result;
}

Variant to_variant(const godot_soci::Value &value) {
    switch (value.kind) {
        case godot_soci::ValueKind::Null:
            return Variant();
        case godot_soci::ValueKind::Integer:
            return Variant(value.integer);
        case godot_soci::ValueKind::Real:
            return Variant(value.real);
        case godot_soci::ValueKind::Text:
            return Variant(to_godot(value.text));
    }
    return Variant();
}

Dictionary as_dictionary(const godot_soci::Completion &completed) {
    Dictionary result;
    result["ok"] = completed.ok;
    result["error"] = to_godot(completed.error);
    if (completed.query) {
        Array rows;
        for (const auto &record : completed.rows) {
            Dictionary row;
            for (const auto &column : record) row[to_godot(column.first)] = to_variant(column.second);
            rows.append(row);
        }
        result["rows"] = rows;
        result["truncated"] = completed.truncated;
    } else {
        result["affected_rows"] = completed.affected_rows;
    }
    return result;
}

} // namespace

void SociQueryDispatcher::_bind_methods() {
    ClassDB::bind_method(D_METHOD("start", "backend", "connection_string", "max_pending"),
                         &SociQueryDispatcher::start, DEFVAL(128));
    ClassDB::bind_method(D_METHOD("stop"), &SociQueryDispatcher::stop);
    ClassDB::bind_method(D_METHOD("is_started"), &SociQueryDispatcher::is_started);
    ClassDB::bind_method(D_METHOD("pending"), &SociQueryDispatcher::pending);
    ClassDB::bind_method(D_METHOD("get_last_error"), &SociQueryDispatcher::get_last_error);
    ClassDB::bind_method(D_METHOD("query_async", "sql", "params", "max_rows"),
                         &SociQueryDispatcher::query_async, DEFVAL(Dictionary()), DEFVAL(1000));
    ClassDB::bind_method(D_METHOD("execute_async", "sql", "params"),
                         &SociQueryDispatcher::execute_async, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("poll", "max_completions"), &SociQueryDispatcher::poll, DEFVAL(64));
}

SociQueryDispatcher::~SociQueryDispatcher() {
    stop();
}

bool SociQueryDispatcher::start(const String &backend, const String &connection, int max_pending) {
    if (started_ || worker_.joinable() || stopping_) {
        last_error_ = "Dispatcher is already started.";
        return false;
    }
    if (backend != "sqlite3" && backend != "postgresql") {
        last_error_ = "Unknown backend; expected 'sqlite3' or 'postgresql'.";
        return false;
    }
#ifndef GODOT_SOCI_WITH_POSTGRESQL
    if (backend == "postgresql") {
        last_error_ = "PostgreSQL backend is disabled in this build.";
        return false;
    }
#endif
    if (max_pending < 1 || max_pending > 10000) {
        last_error_ = "max_pending must be between 1 and 10000.";
        return false;
    }
    max_pending_ = static_cast<size_t>(max_pending);
    stopping_ = false;
    last_error_ = "";
    try {
        worker_ = std::thread(&SociQueryDispatcher::worker_main, this, utf8(backend), utf8(connection));
        started_ = true;
        return true;
    } catch (const std::exception &error) {
        last_error_ = to_godot(redact(error.what()));
        return false;
    }
}

bool SociQueryDispatcher::is_started() const { return started_; }
int SociQueryDispatcher::pending() const { return static_cast<int>(requests_.size()); }
String SociQueryDispatcher::get_last_error() const { return last_error_; }

Ref<SociQueryRequest> SociQueryDispatcher::submit(bool query, const String &sql,
                                                   const Dictionary &params, int max_rows) {
    if (!started_) {
        last_error_ = "Dispatcher is not started.";
        return {};
    }
    if (requests_.size() >= max_pending_) {
        last_error_ = "Async dispatcher capacity exceeded (backpressure).";
        return {};
    }
    if (query && (max_rows < 1 || max_rows > 100000)) {
        last_error_ = "max_rows must be between 1 and 100000.";
        return {};
    }
    godot_soci::Job job;
    job.id = next_id_++;
    job.query = query;
    job.sql = utf8(sql);
    job.max_rows = max_rows;
    try {
        Array keys = params.keys();
        for (int i = 0; i < keys.size(); ++i) {
            if (keys[i].get_type() != Variant::STRING) throw std::invalid_argument("SQL bind keys must be strings.");
            godot_soci::Parameter param;
            param.name = checked_key(static_cast<String>(keys[i]));
            param.value = copy_parameter(params[keys[i]]);
            job.params.push_back(std::move(param));
        }
    } catch (const std::exception &error) {
        last_error_ = to_godot(error.what());
        return {};
    }

    Ref<SociQueryRequest> request;
    request.instantiate();
    requests_.emplace(job.id, request);
    {
        std::lock_guard<std::mutex> lock(mutex_);
        queue_.push_back(std::move(job));
    }
    wake_.notify_one();
    last_error_ = "";
    return request;
}

Ref<SociQueryRequest> SociQueryDispatcher::query_async(const String &sql,
                                                       const Dictionary &params, int max_rows) {
    return submit(true, sql, params, max_rows);
}

Ref<SociQueryRequest> SociQueryDispatcher::execute_async(const String &sql, const Dictionary &params) {
    return submit(false, sql, params, 0);
}

void SociQueryDispatcher::worker_main(std::string backend, std::string connection) {
    std::unique_ptr<soci::session> session;
    std::string connection_error;
    try {
        if (backend == "sqlite3") {
            session = std::make_unique<soci::session>(soci::sqlite3, connection);
        } else {
#ifdef GODOT_SOCI_WITH_POSTGRESQL
            session = std::make_unique<soci::session>(soci::postgresql, connection);
#endif
        }
    } catch (const std::exception &error) {
        connection_error = "Failed to open database: " + redact(error.what());
    }

    for (;;) {
        godot_soci::Job job;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
            if (stopping_) return;
            job = std::move(queue_.front());
            queue_.pop_front();
        }

        godot_soci::Completion completed;
        if (session) {
            completed = godot_soci::QueryWorker::run(job, *session);
        } else {
            completed.id = job.id;
            completed.query = job.query;
            completed.error = connection_error.empty() ? "Database unavailable." : connection_error;
        }
        {
            std::lock_guard<std::mutex> lock(mutex_);
            completions_.push_back(std::move(completed));
        }
    }
}

int SociQueryDispatcher::poll(int max_completions) {
    if (max_completions <= 0) return 0;
    std::deque<godot_soci::Completion> delivered;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        while (!completions_.empty() && static_cast<int>(delivered.size()) < max_completions) {
            delivered.push_back(std::move(completions_.front()));
            completions_.pop_front();
        }
    }
    int count = 0;
    for (const auto &completed : delivered) {
        auto it = requests_.find(completed.id);
        if (it == requests_.end()) continue;
        Ref<SociQueryRequest> request = it->second;
        requests_.erase(it);
        request->resolve(as_dictionary(completed));
        ++count;
    }
    return count;
}

void SociQueryDispatcher::stop() {
    if (stopping_ || (!started_ && !worker_.joinable())) return;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        queue_.clear();
    }
    wake_.notify_all();

    // A running database operation must finish before its session is destroyed.
    // This can block when a driver has no configured query/network timeout.
    if (worker_.joinable()) worker_.join();
    started_ = false;

    std::deque<godot_soci::Completion> finished;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        finished.swap(completions_);
    }

    // Preserve real outcomes of finished requests, especially mutations.
    // Dropping a committed INSERT/UPDATE result here could cause unsafe retries.
    for (const auto &completed : finished) {
        auto it = requests_.find(completed.id);
        if (it == requests_.end()) continue;
        Ref<SociQueryRequest> request = it->second;
        requests_.erase(it);
        request->resolve(as_dictionary(completed));
    }

    // Requests that never finished are canceled. Their statements were not
    // executed, except for a driver operation interrupted by external failure.
    auto outstanding = std::move(requests_);
    requests_.clear();
    Dictionary cancelled;
    cancelled["ok"] = false;
    cancelled["error"] = "Async database dispatcher stopped before request completion.";
    for (auto &entry : outstanding) entry.second->resolve(cancelled);
    stopping_ = false;
}

} // namespace godot
