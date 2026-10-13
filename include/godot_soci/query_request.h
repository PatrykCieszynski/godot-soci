#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class SociQueryRequest final : public RefCounted {
    GDCLASS(SociQueryRequest, RefCounted)

    bool done_ = false;
    Dictionary result_;

protected:
    static void _bind_methods();

public:
    bool is_done() const;
    Dictionary get_result() const;

    // Only call on Godot's main thread.
    void resolve(const Dictionary &result);
};

} // namespace godot
