#pragma once

#include "godot_soci/query_request.h"
#include "godot_soci/query_worker.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>

#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

namespace godot {

class SociQueryDispatcher final : public RefCounted {
    GDCLASS(SociQueryDispatcher, RefCounted)

    std::thread worker_;
    std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<godot_soci::Job> queue_;
    std::deque<godot_soci::Completion> completions_;

    // Only accessed from the Godot main thread.
    std::unordered_map<uint64_t, Ref<SociQueryRequest>> requests_;
    uint64_t next_id_ = 1;
    size_t max_pending_ = 128;
    bool started_ = false;
    bool stopping_ = false;
    String last_error_;

    Ref<SociQueryRequest> submit(bool query, const String &sql,
                                 const Dictionary &params, int max_rows);
    void worker_main(std::string backend, std::string connection);

protected:
    static void _bind_methods();

public:
    ~SociQueryDispatcher() override;

    bool start(const String &backend, const String &connection, int max_pending = 128);
    void stop();
    bool is_started() const;
    int pending() const;
    String get_last_error() const;

    Ref<SociQueryRequest> query_async(const String &sql, const Dictionary &params, int max_rows);
    Ref<SociQueryRequest> execute_async(const String &sql, const Dictionary &params);
    int poll(int max_completions = 64);
};

} // namespace godot
