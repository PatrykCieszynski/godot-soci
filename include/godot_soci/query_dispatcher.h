#pragma once

#include "godot_soci/query_request.h"
#include "godot_soci/query_worker.h"

#include <godot_cpp/classes/ref.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <atomic>
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

    enum class ConnectionState : uint8_t { Stopped, Connecting, Connected, Failed, Disconnected };
    std::atomic<ConnectionState> connection_state_{ConnectionState::Stopped};
    ConnectionState announced_state_ = ConnectionState::Stopped;
    // The SQL worker only stores an enum; Godot signals are emitted on the main thread.
    static String state_name(ConnectionState state);
    void announce_connection_change();

    // Only accessed from the Godot main thread.
    std::unordered_map<uint64_t, Ref<SociQueryRequest>> requests_;
    uint64_t next_id_ = 1;
    size_t max_pending_ = 128;
    bool started_ = false;
    bool stopping_ = false;
    String last_error_;
    uint64_t submitted_count_ = 0;
    uint64_t completed_count_ = 0;  // Delivered results, success or failure.
    uint64_t failed_count_ = 0;
    uint64_t rejected_count_ = 0;
    uint64_t canceled_count_ = 0;
    double total_queue_ms_ = 0;
    double total_execution_ms_ = 0;
    double total_delivery_ms_ = 0;
    // Protected by mutex_; the request map and cumulative counters are main-thread only.
    size_t executing_ = 0;

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
    String get_connection_state() const;
    Dictionary get_stats();

    Ref<SociQueryRequest> query_async(const String &sql, const Dictionary &params, int max_rows);
    Ref<SociQueryRequest> execute_async(const String &sql, const Dictionary &params);
    Ref<SociQueryRequest> transaction_async(const Array &statements);
    int poll(int max_completions = 64);
};

} // namespace godot
