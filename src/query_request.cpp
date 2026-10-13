#include "godot_soci/query_request.h"

#include <godot_cpp/core/class_db.hpp>

namespace godot {

void SociQueryRequest::_bind_methods() {
    ClassDB::bind_method(D_METHOD("is_done"), &SociQueryRequest::is_done);
    ClassDB::bind_method(D_METHOD("get_result"), &SociQueryRequest::get_result);
    ADD_SIGNAL(MethodInfo("completed", PropertyInfo(Variant::DICTIONARY, "result")));
}

bool SociQueryRequest::is_done() const {
    return done_;
}

Dictionary SociQueryRequest::get_result() const {
    return result_;
}

void SociQueryRequest::resolve(const Dictionary &result) {
    if (done_) return;
    result_ = result;
    done_ = true;
    emit_signal("completed", result_);
}

} // namespace godot
