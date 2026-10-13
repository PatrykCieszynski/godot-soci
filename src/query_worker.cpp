#include "godot_soci/query_worker.h"

#include <soci/soci.h>

#include <cmath>
#include <cstdint>
#include <ctime>
#include <deque>
#include <iomanip>
#include <limits>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>

namespace godot_soci {
namespace {

struct Binding {
    std::string name;
    int64_t integer = 0;
    double real = 0;
    std::string text;
    soci::indicator indicator = soci::i_ok;
    ValueKind kind = ValueKind::Null;
};

std::string redact(const std::string &message) {
    static const std::regex password(R"((password\s*=\s*)([^\s]+))", std::regex::icase);
    return std::regex_replace(message, password, "$1[REDACTED]");
}

void bind_arguments(soci::statement &statement, const std::vector<Parameter> &params,
                    std::deque<Binding> &bindings) {
    for (const Parameter &parameter : params) {
        Binding bind;
        bind.name = parameter.name;
        bind.kind = parameter.value.kind;
        bind.integer = parameter.value.integer;
        bind.real = parameter.value.real;
        bind.text = parameter.value.text;
        if (bind.kind == ValueKind::Null) bind.indicator = soci::i_null;
        bindings.push_back(std::move(bind));
        Binding &arg = bindings.back();
        switch (arg.kind) {
            case ValueKind::Integer:
                statement.exchange(soci::use(arg.integer, arg.indicator, arg.name));
                break;
            case ValueKind::Real:
                statement.exchange(soci::use(arg.real, arg.indicator, arg.name));
                break;
            case ValueKind::Text:
            case ValueKind::Null:
                statement.exchange(soci::use(arg.text, arg.indicator, arg.name));
                break;
        }
    }
}

Value get_value(const soci::row &record, size_t index) {
    Value value;
    if (record.get_indicator(index) == soci::i_null) return value;
    switch (record.get_properties(index).get_db_type()) {
        case soci::db_string:
            value.kind = ValueKind::Text;
            value.text = record.get<std::string>(index);
            break;
        case soci::db_double:
            value.kind = ValueKind::Real;
            value.real = record.get<double>(index);
            break;
        case soci::db_int8:
            value.kind = ValueKind::Integer;
            value.integer = record.get<int8_t>(index);
            break;
        case soci::db_uint8:
            value.kind = ValueKind::Integer;
            value.integer = record.get<uint8_t>(index);
            break;
        case soci::db_int16:
            value.kind = ValueKind::Integer;
            value.integer = record.get<int16_t>(index);
            break;
        case soci::db_uint16:
            value.kind = ValueKind::Integer;
            value.integer = record.get<uint16_t>(index);
            break;
        case soci::db_int32:
            value.kind = ValueKind::Integer;
            value.integer = record.get<int32_t>(index);
            break;
        case soci::db_uint32:
            value.kind = ValueKind::Integer;
            value.integer = record.get<uint32_t>(index);
            break;
        case soci::db_int64:
            value.kind = ValueKind::Integer;
            value.integer = record.get<int64_t>(index);
            break;
        case soci::db_uint64: {
            uint64_t number = record.get<uint64_t>(index);
            if (number > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
                throw std::range_error("Unsigned BIGINT exceeds Godot int64 range.");
            }
            value.kind = ValueKind::Integer;
            value.integer = static_cast<int64_t>(number);
            break;
        }
        case soci::db_date: {
            std::tm date = record.get<std::tm>(index);
            std::ostringstream stream;
            stream << std::put_time(&date, "%Y-%m-%d %H:%M:%S");
            value.kind = ValueKind::Text;
            value.text = stream.str();
            break;
        }
        default:
            throw std::runtime_error("Unsupported SQL column type; CAST complex/blob values to TEXT.");
    }
    return value;
}

Row copy_row(const soci::row &record) {
    Row row;
    for (size_t i = 0; i < record.size(); ++i) {
        std::string name = record.get_properties(i).get_name();
        for (const auto &column : row) {
            if (column.first == name) {
                throw std::runtime_error("Duplicate SQL result column name: " + name + ". Use SQL aliases.");
            }
        }
        row.emplace_back(std::move(name), get_value(record, i));
    }
    return row;
}

} // namespace

Completion QueryWorker::run(const Job &job, soci::session &session) {
    Completion result;
    result.id = job.id;
    result.query = job.query;
    try {
        if (job.transaction) {
            result.transaction = true;
            soci::transaction tx(session);
            for (size_t index = 0; index < job.statements.size(); ++index) {
                const BatchStatement &command = job.statements[index];
                std::deque<Binding> stored;
                soci::statement statement(session);
                statement.alloc();
                statement.prepare(command.sql);
                bind_arguments(statement, command.params, stored);
                statement.define_and_bind();
                statement.execute(true);
                const int64_t affected = static_cast<int64_t>(statement.get_affected_rows());
                if (command.expected_affected_rows >= 0 && affected != command.expected_affected_rows) {
                    throw std::runtime_error("Affected-row precondition failed at transaction statement " +
                                             std::to_string(index) + ".");
                }
                result.affected_rows += affected;
                result.affected_rows_per_statement.push_back(affected);
            }
            try {
                tx.commit();
            } catch (...) {
                // Commit may have reached the database before the transport failed.
                result.outcome_unknown = true;
                throw;
            }
            result.ok = true;
            return result;
        }
        std::deque<Binding> bindings;
        soci::row record;
        soci::statement statement(session);
        statement.alloc();
        statement.prepare(job.sql);
        if (job.query) statement.exchange(soci::into(record));
        bind_arguments(statement, job.params, bindings);
        statement.define_and_bind();

        if (job.query) {
            statement.execute();
            while (static_cast<int>(result.rows.size()) < job.max_rows && statement.fetch()) {
                result.rows.push_back(copy_row(record));
            }
            result.truncated = static_cast<int>(result.rows.size()) == job.max_rows && statement.fetch();
        } else {
            statement.execute(true);
            result.affected_rows = static_cast<int64_t>(statement.get_affected_rows());
        }
        result.ok = true;
    } catch (const std::exception &error) {
        if (job.transaction && !result.outcome_unknown) {
            // An uncommitted batch rolled back; do not report provisional row counts.
            result.affected_rows = 0;
            result.affected_rows_per_statement.clear();
        }
        result.error = redact(error.what());
    }
    return result;
}

} // namespace godot_soci
