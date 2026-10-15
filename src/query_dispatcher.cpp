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

#include <chrono>
#include <cctype>
#include <cmath>
#include <exception>
#include <memory>
#include <regex>
#include <stdexcept>
#include <utility>
#include <vector>

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
    if (completed.transaction) {
        Array counts;
        for (int64_t value : completed.affected_rows_per_statement) counts.append(value);
        result["affected_rows"] = completed.affected_rows;
        result["affected_rows_per_statement"] = counts;
        result["outcome_unknown"] = completed.outcome_unknown;
    } else if (completed.query) {
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
    ClassDB::bind_method(D_METHOD("get_connection_state"), &SociQueryDispatcher::get_connection_state);
    ClassDB::bind_method(D_METHOD("get_stats"), &SociQueryDispatcher::get_stats);
    ADD_SIGNAL(MethodInfo("connection_state_changed", PropertyInfo(Variant::STRING, "state")));
    ClassDB::bind_method(D_METHOD("query_async", "sql", "params", "max_rows"),
                         &SociQueryDispatcher::query_async, DEFVAL(Dictionary()), DEFVAL(1000));
    ClassDB::bind_method(D_METHOD("execute_async", "sql", "params"),
                         &SociQueryDispatcher::execute_async, DEFVAL(Dictionary()));
    ClassDB::bind_method(D_METHOD("transaction_async", "statements"),
                         &SociQueryDispatcher::transaction_async);
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
    submitted_count_ = completed_count_ = failed_count_ = rejected_count_ = canceled_count_ = 0;
    total_queue_ms_ = total_execution_ms_ = total_delivery_ms_ = 0;
    connection_state_.store(ConnectionState::Connecting);
    stopping_ = false;
    last_error_ = "";
    try {
        worker_ = std::thread(&SociQueryDispatcher::worker_main, this, utf8(backend), utf8(connection));
        started_ = true;
        announce_connection_change();
        return true;
    } catch (const std::exception &error) {
        last_error_ = to_godot(redact(error.what()));
        connection_state_.store(ConnectionState::Stopped);
        return false;
    }
}

bool SociQueryDispatcher::is_started() const { return started_; }
int SociQueryDispatcher::pending() const { return static_cast<int>(requests_.size()); }
String SociQueryDispatcher::get_last_error() const { return last_error_; }

String SociQueryDispatcher::state_name(ConnectionState state) {
    switch (state) {
        case ConnectionState::Connecting: return "connecting";
        case ConnectionState::Connected: return "connected";
        case ConnectionState::Failed: return "failed";
        case ConnectionState::Disconnected: return "disconnected";
        case ConnectionState::Stopped: return "stopped";
    }
    return "stopped";
}

String SociQueryDispatcher::get_connection_state() const {
    return state_name(connection_state_.load());
}

void SociQueryDispatcher::announce_connection_change() {
    const ConnectionState current = connection_state_.load();
    if (current == announced_state_) return;
    // Use the same atomic snapshot for bookkeeping AND the payload. The
    // worker can change the connection state between these two operations.
    announced_state_ = current;
    emit_signal("connection_state_changed", state_name(current));
}

Dictionary SociQueryDispatcher::get_stats() {
    // Called on the Godot main thread only. Do not inspect Godot objects from
    // the worker thread, and never hold the mutex while creating Variants.
    size_t queued = 0, awaiting_poll = 0, executing = 0;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        queued = queue_.size();
        awaiting_poll = completions_.size();
        executing = executing_;
    }
    Dictionary stats;
    stats["connection_state"] = get_connection_state();
    stats["pending"] = static_cast<int64_t>(requests_.size());
    stats["queued"] = static_cast<int64_t>(queued);
    stats["executing"] = static_cast<int64_t>(executing);
    stats["awaiting_poll"] = static_cast<int64_t>(awaiting_poll);
    stats["submitted"] = static_cast<int64_t>(submitted_count_);
    stats["completed"] = static_cast<int64_t>(completed_count_);
    stats["failed"] = static_cast<int64_t>(failed_count_);
    stats["rejected"] = static_cast<int64_t>(rejected_count_);
    stats["canceled"] = static_cast<int64_t>(canceled_count_);
    const double n = completed_count_ ? static_cast<double>(completed_count_) : 1.0;
    stats["avg_queue_ms"] = total_queue_ms_ / n;
    stats["avg_execution_ms"] = total_execution_ms_ / n;
    stats["avg_delivery_ms"] = total_delivery_ms_ / n;
    return stats;
}

Ref<SociQueryRequest> SociQueryDispatcher::submit(bool query, const String &sql,
                                                   const Dictionary &params, int max_rows) {
    if (!started_) {
        last_error_ = "Dispatcher is not started.";
        ++rejected_count_;
        return {};
    }
    if (requests_.size() >= max_pending_) {
        last_error_ = "Async dispatcher capacity exceeded (backpressure).";
        ++rejected_count_;
        return {};
    }
    if (query && (max_rows < 1 || max_rows > 100000)) {
        last_error_ = "max_rows must be between 1 and 100000.";
        ++rejected_count_;
        return {};
    }
    godot_soci::Job job;
    job.id = next_id_++;
    job.enqueued_at = std::chrono::steady_clock::now();
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
        ++rejected_count_;
        return {};
    }

    Ref<SociQueryRequest> request;
    request.instantiate();
    requests_.emplace(job.id, request);
    ++submitted_count_;
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

Ref<SociQueryRequest> SociQueryDispatcher::transaction_async(const Array &statements) {
    if (!started_) {
        last_error_ = "Dispatcher is not started.";
        ++rejected_count_;
        return {};
    }
    if (requests_.size() >= max_pending_) {
        last_error_ = "Async dispatcher capacity exceeded (backpressure).";
        ++rejected_count_;
        return {};
    }
    if (statements.is_empty() || statements.size() > 128) {
        last_error_ = "Transaction requires between 1 and 128 statements.";
        ++rejected_count_;
        return {};
    }

    godot_soci::Job job;
    job.id = next_id_++;
    job.enqueued_at = std::chrono::steady_clock::now();
    job.transaction = true;
    try {
        for (int index = 0; index < statements.size(); ++index) {
            const Variant item = statements[index];
            if (item.get_type() != Variant::DICTIONARY) {
                throw std::invalid_argument("Transaction statements must be dictionaries.");
            }
            Dictionary descriptor = item;
            if (!descriptor.has("sql") || descriptor["sql"].get_type() != Variant::STRING) {
                throw std::invalid_argument("Each transaction statement requires an SQL string.");
            }

            godot_soci::BatchStatement command;
            command.sql = utf8(static_cast<String>(descriptor["sql"]));
            if (command.sql.empty()) {
                throw std::invalid_argument("Transaction SQL must not be empty.");
            }
            // Transaction boundaries belong to the native batch, not user SQL.
            const auto first = command.sql.find_first_not_of(" \t\r\n");
            if (first == std::string::npos) throw std::invalid_argument("Transaction SQL must not be blank.");
            std::string prefix = command.sql.substr(first, command.sql.find_first_of(" \t\r\n;(", first) - first);
            for (char &ch : prefix) ch = static_cast<char>(std::toupper(static_cast<unsigned char>(ch)));
            if (prefix == "BEGIN" || prefix == "COMMIT" || prefix == "ROLLBACK" ||
                prefix == "SAVEPOINT" || prefix == "RELEASE" || prefix == "START") {
                throw std::invalid_argument("Transaction-control SQL is not allowed inside a batch.");
            }

            if (descriptor.has("expected_affected_rows")) {
                if (descriptor["expected_affected_rows"].get_type() != Variant::INT) {
                    throw std::invalid_argument("expected_affected_rows must be an integer.");
                }
                command.expected_affected_rows = static_cast<int64_t>(descriptor["expected_affected_rows"]);
                if (command.expected_affected_rows < 0) {
                    throw std::invalid_argument("expected_affected_rows must be non-negative.");
                }
            }

            const Variant parameters = descriptor.get("params", Dictionary());
            if (parameters.get_type() != Variant::DICTIONARY) {
                throw std::invalid_argument("Transaction params must be a Dictionary.");
            }
            Dictionary params = parameters;
            Array keys = params.keys();
            for (int p = 0; p < keys.size(); ++p) {
                if (keys[p].get_type() != Variant::STRING) {
                    throw std::invalid_argument("SQL bind keys must be strings.");
                }
                godot_soci::Parameter parameter;
                parameter.name = checked_key(static_cast<String>(keys[p]));
                parameter.value = copy_parameter(params[keys[p]]);
                command.params.push_back(std::move(parameter));
            }
            job.statements.push_back(std::move(command));
        }
    } catch (const std::exception &error) {
        last_error_ = to_godot(error.what());
        ++rejected_count_;
        return {};
    }

    Ref<SociQueryRequest> request;
    request.instantiate();
    requests_.emplace(job.id, request);
    ++submitted_count_;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        queue_.push_back(std::move(job));
    }
    wake_.notify_one();
    last_error_ = "";
    return request;
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
        connection_state_.store(ConnectionState::Connected);
    } catch (const std::exception &error) {
        connection_error = "Failed to open database: " + redact(error.what());
        connection_state_.store(ConnectionState::Failed);
    } catch (...) {
        connection_error = "Failed to open database: non-standard native exception.";
        connection_state_.store(ConnectionState::Failed);
    }

    for (;;) {
        godot_soci::Job job;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            wake_.wait(lock, [this] { return stopping_ || !queue_.empty(); });
            if (stopping_) return;
            job = std::move(queue_.front());
            queue_.pop_front();
            executing_ = 1;
        }

        const auto started_at = std::chrono::steady_clock::now();
        godot_soci::Completion completed;
        if (session && connection_state_.load() == ConnectionState::Connected) {
            completed = godot_soci::QueryWorker::run(job, *session);
            // SOCI owns the PostgreSQL ping and backend-specific connection
            // health check. Run it on *failure only*, never on every query.
            if (!completed.ok && !session->is_connected()) {
                connection_state_.store(ConnectionState::Disconnected);
            }
        } else {
            completed.id = job.id;
            completed.query = job.query;
            completed.transaction = job.transaction;
            completed.error = connection_state_.load() == ConnectionState::Disconnected
                ? "Database connection was lost; stop and start a new session."
                : (connection_error.empty() ? "Database unavailable." : connection_error);
        }
        completed.finished_at = std::chrono::steady_clock::now();
        completed.queue_ms = std::chrono::duration<double, std::milli>(
            started_at - job.enqueued_at).count();
        completed.execution_ms = std::chrono::duration<double, std::milli>(
            completed.finished_at - started_at).count();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            executing_ = 0;
            completions_.push_back(std::move(completed));
        }
    }
}

int SociQueryDispatcher::poll(int max_completions) {
    announce_connection_change();
    if (max_completions <= 0) return 0;
    std::deque<godot_soci::Completion> delivered;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        while (!completions_.empty() && static_cast<int>(delivered.size()) < max_completions) {
            delivered.push_back(std::move(completions_.front()));
            completions_.pop_front();
        }
    }
    // Remove all completed requests before emitting signals. A callback can
    // re-enter stop(), and must never cancel another already-finished request.
    std::vector<std::pair<Ref<SociQueryRequest>, Dictionary>> ready;
    ready.reserve(delivered.size());
    for (const auto &completed : delivered) {
        auto it = requests_.find(completed.id);
        if (it == requests_.end()) continue;
        Ref<SociQueryRequest> request = it->second;
        requests_.erase(it);
        ++completed_count_;
        if (!completed.ok) ++failed_count_;
        total_queue_ms_ += completed.queue_ms;
        total_execution_ms_ += completed.execution_ms;
        total_delivery_ms_ += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - completed.finished_at).count();
        ready.emplace_back(request, as_dictionary(completed));
    }
    for (auto &entry : ready) entry.first->resolve(entry.second);
    return static_cast<int>(ready.size());
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
        ++completed_count_;
        if (!completed.ok) ++failed_count_;
        total_queue_ms_ += completed.queue_ms;
        total_execution_ms_ += completed.execution_ms;
        total_delivery_ms_ += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - completed.finished_at).count();
        request->resolve(as_dictionary(completed));
    }

    // Requests that never finished are canceled. Their statements were not
    // executed, except for a driver operation interrupted by external failure.
    auto outstanding = std::move(requests_);
    requests_.clear();
    Dictionary cancelled;
    cancelled["ok"] = false;
    cancelled["error"] = "Async database dispatcher stopped before request completion.";
    cancelled["outcome_unknown"] = false;
    cancelled["affected_rows"] = int64_t(0);
    cancelled["affected_rows_per_statement"] = Array();
    cancelled["rows"] = Array();
    cancelled["truncated"] = false;
    canceled_count_ += outstanding.size();
    for (auto &entry : outstanding) entry.second->resolve(cancelled);
    stopping_ = false;
    connection_state_.store(ConnectionState::Stopped);
    announce_connection_change();
}

} // namespace godot
