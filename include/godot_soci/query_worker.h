#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace soci { class session; }

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

struct Job {
    uint64_t id = 0;
    bool query = false;
    int max_rows = 1000;
    std::string sql;
    std::vector<Parameter> params;
};

using Row = std::vector<std::pair<std::string, Value>>;

struct Completion {
    uint64_t id = 0;
    bool query = false;
    bool ok = false;
    bool truncated = false;
    int64_t affected_rows = 0;
    std::string error;
    std::vector<Row> rows;
};

class QueryWorker final {
public:
    static Completion run(const Job &job, soci::session &session);
};

} // namespace godot_soci
