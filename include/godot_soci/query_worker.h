#pragma once

#include <chrono>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace soci { class session; class soci_error; }

namespace godot_soci {

enum class ValueKind { Null, Integer, Real, Text };

struct Value {
    ValueKind kind = ValueKind::Null;
    int64_t integer = 0;
    double real = 0;
    std::string text;
};

struct Parameter {
    std::string name;
    Value value;
};

struct BatchStatement {
    std::string sql;
    std::vector<Parameter> params;
    int64_t expected_affected_rows = -1;
};

struct Job {
    bool transaction = false;
    std::vector<BatchStatement> statements;
    uint64_t id = 0;
    std::chrono::steady_clock::time_point enqueued_at{};
    bool query = false;
    int max_rows = 1000;
    std::string sql;
    std::vector<Parameter> params;
};

using Row = std::vector<std::pair<std::string, Value>>;

// Portable SOCI error classification plus optional backend-native details.
struct NativeError {
    std::string category = "unknown";
    std::string backend;
    int64_t backend_code = 0;
    std::string sqlstate;
};

struct Completion {
    bool transaction = false;
    bool outcome_unknown = false;
    std::vector<int64_t> affected_rows_per_statement;
    uint64_t id = 0;
    bool query = false;
    bool ok = false;
    double queue_ms = 0;
    double execution_ms = 0;
    std::chrono::steady_clock::time_point finished_at{};
    bool truncated = false;
    int64_t affected_rows = 0;
    std::string error;
    NativeError native_error;
    std::vector<Row> rows;
};

class QueryWorker final {
public:
    static Completion run(const Job &job, soci::session &session);
    static NativeError describe_error(const soci::soci_error &error);
};

} // namespace godot_soci
