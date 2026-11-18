#include "raft_server.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <chrono>

using clock_type = std::chrono::steady_clock;
/* core/ 의 자료형 구현.
 *
 * raft_state.h 와 raft_timings.h 는 **자료 정의**를 담고 core TU 16~17개가
 * 전부 읽는다. 그래서 그 헤더에는 한두 줄짜리 접근자만 남기고, 길거나
 * 락/할당을 만지는 본문은 여기로 내렸다:
 *   AlignedBuffer      posix_memalign / memcpy / free
 *   RingLog::configure Server 당 한 번
 *   ReplSink           mutex 획득
 *   derive_apply_timings  ApplyTimings 항등식 계산 (apply_timed 당 한 번)
 *   to_string          진단 출력용
 *
 * Server 자신의 워커 스레드 관련 메서드는 stop() 옆이 자연스러워
 * core/src/raft_lifecycle.cpp 에 있다. */

namespace nvmeof_raft {

AlignedBuffer::AlignedBuffer(size_t size, size_t align){
    resize(size, align);
}

AlignedBuffer::~AlignedBuffer(){ reset(); }

AlignedBuffer::AlignedBuffer(AlignedBuffer &&other) noexcept
: data_(other.data_), size_(other.size_), capacity_(other.capacity_) {
    other.data_ = nullptr;
    other.size_ = other.capacity_ = 0;
}

AlignedBuffer &AlignedBuffer::operator=(AlignedBuffer &&other) noexcept {
    if (this != &other) {
        reset();
        data_ = other.data_;
        size_ = other.size_;
        capacity_ = other.capacity_;
        other.data_ = nullptr;
        other.size_ = other.capacity_ = 0;
    }
    return *this;
}

void AlignedBuffer::resize(size_t new_size, size_t align){
    size_t old_size = size_;
    grow_uninit(new_size, align);
    if (new_size > old_size) {
        std::memset(static_cast<uint8_t *>(data_) + old_size, 0, new_size - old_size);
    }
}

void AlignedBuffer::grow_uninit(size_t new_size, size_t align){
    if (new_size > capacity_) {
        size_t aligned_cap = (new_size + align - 1) / align * align;
        void *new_raw = nullptr;
        if (posix_memalign(&new_raw, align, aligned_cap) != 0) {
            throw std::runtime_error("AlignedBuffer::grow_uninit: posix_memalign failed");
        }
        if (data_ != nullptr && size_ > 0) {
            std::memcpy(new_raw, data_, size_);       // 기존 데이터는 보존
        }
        if (data_ != nullptr) {
            free(data_);
        }
        data_ = new_raw;
        capacity_ = aligned_cap;
    }
    size_ = new_size;                                 // 0 채우기 없음
}

void AlignedBuffer::reset(){
    if (data_ != nullptr) {
        free(data_);
        data_ = nullptr;
    }
    size_ = capacity_ = 0;
}

void RingLog::configure(uint64_t pages){
    if (pages < 2) {
        pages = 2;   /* 헤더 1페이지 + 최소한의 링 */
    }
    num_pages = pages;
    total_slots = pages * SLOTS_PER_PAGE;
    ring_slots = total_slots - RING_OFFSET / SECTOR_SIZE;   /* 헤더 페이지만큼 뺀다 */
}

std::string to_string(LogEntryState st) {
    switch (st) {
    case LogEntryState::Free: return "FREE";
    case LogEntryState::Using: return "USING";
    default: return "UNKNOWN";
    }
}

std::string to_string(ServerState s) {
    switch (s) {
    case ServerState::Leader: return "leader";
    case ServerState::Follower: return "follower";
    case ServerState::Candidate: return "candidate";
    default: return "unknown";
    }
}

void ReplSink::push(const ReplSample &s) {
    std::lock_guard<std::mutex> lk(mu_);
    samples_.push_back(s);
}

void ReplSink::set_repl_start(clock_type::time_point t) {
    std::lock_guard<std::mutex> lk(mu_);
    repl_start_ = t;
    repl_start_set_ = true;
}

void ReplSink::note_push_end(int peer, clock_type::time_point t) {
    std::lock_guard<std::mutex> lk(mu_);
    for (auto &pe : push_end_) {
        if (pe.first == peer) {
            pe.second = t;
            return;
        }
    }
    push_end_.emplace_back(peer, t);
}

int64_t ReplSink::push_wait_ns(int peer) {
    std::lock_guard<std::mutex> lk(mu_);
    if (!repl_start_set_) {
        return 0;
    }
    for (const auto &pe : push_end_) {
        if (pe.first == peer) {
            return timings_clamp0(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                      pe.second - repl_start_).count());
        }
    }
    return 0;
}

std::pair<ReplSample, bool> ReplSink::quorum_sample(){
    std::lock_guard<std::mutex> lk(mu_);
    const size_t k = quorum_followers();
    if (k == 0 || samples_.size() < k) {
        return {ReplSample{}, false};
    }
    return {samples_[k - 1], true};
}

void derive_apply_timings(const ApplyWalls &w, ReplSink *sink,
                          const ProfilingSink &prof, ApplyTimings &t) {
    t.l_persist_ns = w.nvme_ns;
    /* LHandler = AE 발사 전까지 리더가 쓴 시간 - 자기 묶음의 persist.
     * 그룹 커밋 큐 대기와 mu 대기가 여기 들어간다 (예전 a_held 기준에서는 residual). */
    t.l_handler_ns =
        timings_clamp0(w.pre_repl_ns - w.nvme_ns);
 
    auto [sample, have] = sink->quorum_sample();
 
    if (!have) {
        /*
         * TODO(profiling):
         * global prof.sample_* fallback is not request-correlated.
         * Under concurrent ApplyTimed calls, another Apply/heartbeat may
         * overwrite these values.
         */
        sample.ae_rt_ns = prof.sample_ae_rt_ns.load();
        sample.r2_ns = prof.sample_r2_ns.load();
        sample.write_pba_rt_ns =
            prof.sample_write_pba_rt_ns.load();
        sample.storage_copy_ns =
            prof.sample_storage_copy_ns.load();
        sample.storage_read_ns =
            prof.sample_storage_read_ns.load();
        sample.storage_write_ns =
            prof.sample_storage_write_ns.load();
        sample.storage_sync_ns =
            prof.sample_storage_sync_ns.load();
 
        /*
         * fallback을 유지하려면 이것도 같이 있어야 함.
         * ProfilingSink에 sample_leader_side가 추가되어 있다는 전제.
         */
        sample.leader_side =
            prof.sample_leader_side.load();
    }
 
    /*
     * AE network 자체는 두 mode 모두 동일:
     *
     * AE_RT = AENet + follower handler(R2)
     */
    t.ae_net_ns =
        timings_clamp0(
            sample.ae_rt_ns -
            sample.r2_ns);
 
    /*
     * WritePBABatch 자체도 두 mode 모두:
     *
     * WritePBA_RT = ReplNet + StorageIO
     */
    t.repl_net_ns =
        timings_clamp0(
            sample.write_pba_rt_ns -
            sample.storage_copy_ns);
 
    /* push 된 배치: storage_copy_ns 는 push 대기라 LPersist 로 보내고, StorageIO 는
     * 팔로워가 AE 핸들러 안에서 한 장치 flush(storage_sync_ns)다. */
    if (sample.pushed) {
        t.l_persist_ns += sample.storage_copy_ns;
        t.storage_io_ns = sample.storage_sync_ns;
    }
    else t.storage_io_ns = sample.storage_copy_ns;
    
    /* 진단용 분리값 (항등식 밖). push 된 배치는 SRead=SWrite=0, SSync=StorageIO(팔로워 flush) */
    t.storage_read_ns = sample.storage_read_ns;
    t.storage_write_ns = sample.storage_write_ns;
    t.storage_sync_ns = sample.storage_sync_ns;

 
    /* [Push Integration] push 된 배치도 Leader-side 와 같은 모양이다: AE 전에 push 대기
     * (write_pba_rt = storage_copy)가 있고, 팔로워는 복사를 하지 않는다. 다만 팔로워가
     * 핸들러 안에서 장치 flush 를 하는 지연은 StorageIO 다. */
    const bool pre_ae_copy = sample.leader_side || sample.pushed;
 
    if (pre_ae_copy) {
        /*
         * Leader-side:
         *
         * WritePBABatch가 AppendEntries RPC보다 먼저 일어남.
         *
         * Replicate:
         *
         *   WritePBA_RT
         *     ├─ ReplNet
         *     └─ StorageIO
         *
         *   AE_RT
         *     ├─ AENet
         *     └─ FHandler (= R2)
         *
         *   QuorumWait
         */
 
        /*
         * follower에서는 block copy를 하지 않으므로
         * follower handler 전체가 FHandler.
         */
        t.f_handler_ns =
            sample.pushed
                ? timings_clamp0(sample.r2_ns - sample.storage_sync_ns)
                : sample.r2_ns;
 
        /*
         * leader-side copy와 AE RPC가 둘 다 replicate_ns에 포함되므로
         * 둘 다 빼야 실제 이후 quorum wait가 남음.
         */
        t.quorum_wait_ns =
            timings_clamp0(
                w.replicate_ns
                - sample.write_pba_rt_ns
                - sample.ae_rt_ns);
    } else {
        /*
         * Destination-side:
         *
         * AE_RT
         *   ├─ AENet
         *   └─ R2
         *       ├─ FHandler
         *       └─ WritePBA_RT
         *           ├─ ReplNet
         *           └─ StorageIO
         *
         * 이후 QuorumWait
         */
 
        t.f_handler_ns =
            timings_clamp0(
                sample.r2_ns -
                sample.write_pba_rt_ns);
 
        t.quorum_wait_ns =
            timings_clamp0(
                w.replicate_ns -
                sample.ae_rt_ns);
    }
}

} /* namespace nvmeof_raft */
