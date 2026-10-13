#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <soci/soci.h>

#include <cstdint>
#include <deque>
#include <memory>
#include <string>

namespace godot {

class GodotSociDatabase final : public RefCounted {
    GDCLASS(GodotSociDatabase, RefCounted)

    std::unique_ptr<soci::session> session_;
    String backend_;
    String last_error_;
    bool in_transaction_ = false;

    struct BindParameter {
        std::string name;
        int64_t integer = 0;
        double real = 0;
        std::string text;
        soci::indicator indicator = soci::i_ok;
        enum class Type { Integer, Real, Text } type = Type::Text;
    };

    bool fail(const std::string &message);
    Dictionary failure_result(const std::string &message);
    static std::string utf8(const String &value);
    static String from_utf8(const std::string &value);
    static void bind_arguments(soci::statement &statement, const Dictionary &params, std::deque<BindParameter> &storage);
    static Dictionary row_to_dictionary(const soci::row &row);
    bool ensure_open();

protected:
    static void _bind_methods();

public:
    GodotSociDatabase() = default;
    ~GodotSociDatabase() override;

    bool open(const String &backend, const String &connection_string);
    void close();
    bool is_open() const;
    String get_backend() const;
    String get_last_error() const;

    Dictionary execute(const String &sql, const Dictionary &params);
    Dictionary query(const String &sql, const Dictionary &params, int max_rows);
    bool begin();
    bool begin_immediate();
    bool commit();
    bool rollback();
    bool in_transaction() const;
};

} // namespace godot
