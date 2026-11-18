#ifndef RAFT_TIMINGS_HPP
#define RAFT_TIMINGS_HPP

#include <cstdint>
#include <atomic>
#include <mutex>
#include <vector>
#include <utility>
#include <chrono>

using clock_type = std::chrono::steady_clock;

namespace nvmeof_raft {

/* ============================================================
 * ProfilingSink -- Raft 로직과 무관한 계측 상태를 한 곳에 모은다.
 *
 * 남은 계측은 apply-timed 분해(아래 ApplyTimings)를 만드는 값뿐이다
 * (2026-11-18 정리: ACI 서브스테이지, Lock A/B/C 대기·보유, CommitWait,
 * 팔로워 핸들러 서브스테이지, 5초 집계 로그, -profile 플래그를 걷어냈다).
 * 그래서 켜고 끄는 스위치가 없다 -- 분해 항은 항상 측정된다.
 *
 * sample_*는 ReplSink가 이번 요청의 샘플을 못 잡았을 때의 폴백이다.
 * append_entries_worker가 data-bearing AE마다 sink 가드 **밖**에서 채운다
 * -- 폴백이 노리는 상황이 바로 하트비트(sink == nullptr)이기 때문이다.
 * ============================================================ */
struct ProfilingSink {
    /* --- AE 배치 통계 (리더 측). raft_client의 -op ae-stats가 읽는다 --- */
    std::atomic<uint64_t> ae_count{0};    /* 데이터가 실린 AE를 보낸 횟수 */
    std::atomic<uint64_t> ae_entries{0};  /* 그 AE들에 실린 엔트리 수의 합 */

    /* --- ReplSink가 샘플을 못 잡았을 때의 폴백 --- */
    std::atomic<int64_t> sample_ae_rt_ns{0};
    std::atomic<int64_t> sample_r2_ns{0};
    std::atomic<int64_t> sample_write_pba_rt_ns{0};
    std::atomic<int64_t> sample_storage_copy_ns{0};
    std::atomic<int64_t> sample_storage_read_ns{0};
    std::atomic<int64_t> sample_storage_write_ns{0};
    std::atomic<int64_t> sample_storage_sync_ns{0};

    std::atomic<bool> sample_leader_side{false};
};

/* ============================================================
 * ApplyTimings (raft.go 원본, 필드/주석 그대로 포팅)
 *
 * Identity (rawft):
 *   Total ~= LHandler + LPersist + AENet + FHandler + ReplNet + StorageIO + QuorumWait
 * Identity (goraft baseline):
 *   Total ~= LHandler + LPersist + AENet + FHandler + StorageIO + QuorumWait   (ReplNet = 0)
 *
 * 원본의 Mutex / CommitWait / PostRPC / WgScheduling / ACI 서브스테이지와
 * 보정값은 2026-11-18에 걷어냈다. 남은 것은 항등식 7항 + Total + 진단용
 * SRead/SWrite/SSync 이다.
 * time.Duration(int64 나노초 래퍼) -> int64_t 나노초로 대응.
 * ============================================================ */
struct ApplyTimings {
    /* Total: ApplyTimed 호출 전체의 wall time. 위 항등식의 좌변("Total")에
     * 해당하는데 원본 필드 목록을 옮길 때 빠져 있었다 (proto의
     * ClientApplyTimedResponse에는 total_nanos가 있어서 채울 값이 필요하다). */
    int64_t total_ns = 0;

    /* Leader-local handler vs persist split. */
    int64_t l_handler_ns = 0;   /* apply 진입 -> AE 발사 중 persist 를 뺀 전부:
                                 * 그룹 커밋 큐 대기 + mu 대기 + 인메모리 부기(인코딩 포함) */
    int64_t l_persist_ns = 0;   /* leader O_DIRECT WriteAtFile + Fdatasync */

    /* AENet = AE_RT - R2, clamp >= 0. Strict L<->F encode+transit+decode. */
    int64_t ae_net_ns = 0;

    /* FHandler = R2 - F_storage_wall, clamp >= 0. Follower handler
     * bookkeeping outside the storage block I/O (lock+checks+log
     * truncate/append+header persist).
     *   rawft: F_storage_wall = WritePBA_RT
     *   goraft: F_storage_wall = follower s.persist(...) wall */
    int64_t f_handler_ns = 0;

    /* ReplNet = WritePBA_RT - StorageIO, clamp >= 0. F<->S RPC
     * codec+transit+decode. Always 0 for goraft (no F->S RPC; follower
     * writes locally inside its own handler). */
    int64_t repl_net_ns = 0;

    /* StorageIO = the actual storage-block I/O wall.
     *   rawft: storage-server pread + pwrite
     *   goraft: follower's s.persist NVMe write+fdatasync wall */
    int64_t storage_io_ns = 0;

    /* StorageIO 를 스토리지 서버가 나눠 보고한 pread / pwrite 합. 진단용이라
     * 항등식에 들어가지 않는다. StorageIO - (둘의 합) = 서버의 배치 처리 중
     * 디스크 밖에서 쓴 시간 (워커가 하나일 때). push 된 배치는 SRead=SWrite=0. */
    int64_t storage_read_ns = 0;
    int64_t storage_write_ns = 0;
    int64_t storage_sync_ns = 0;   /* StorageIO 중 fdatasync. push 된 배치는 팔로워의 장치 flush (= StorageIO) */

    /* QuorumWait = replicate - AE_RT (pre-AE 복사가 있으면 그 왕복도 뺀다),
     * clamp >= 0. 리더의 AE 후 부기 + 리더 fdatasync + 커밋 전진 + 결과 대기. */
    int64_t quorum_wait_ns = 0;
};

/* ============================================================
 * replSample (raft.go 원본)
 * "carries per-RPC measurement walls for one in-flight AE on this
 *  Apply's critical path. AENet/FHandler/ReplNet/Replication are
 *  derived from these on the leader side."
 * ============================================================ */
struct ReplSample {
    // [Diag]
    int peer_index = -1;
    // [Diag]
    int64_t ae_rt_ns = 0;         /* leader rpcCall wall */
    int64_t r2_ns = 0;            /* follower handler wall (HandlerDuration) */
    int64_t write_pba_rt_ns = 0;  /* follower WritePBA wall (= R2 - FHandler) */
    int64_t storage_copy_ns = 0;  /* S internal pread+pwrite (Replication) */
    int64_t storage_read_ns = 0;  /* storage_copy_ns 중 pread 합 (destination 만) */
    int64_t storage_write_ns = 0; /* storage_copy_ns 중 pwrite 합 (destination 만) */
    int64_t storage_sync_ns = 0;  /* storage_copy_ns 중 fdatasync */
    bool leader_side = false;
    /* push 모드에서 팔로워가 pull을 건너뛴 배치 (DECISIONS.md D20). 이때
     * write_pba_rt_ns / storage_copy_ns는 push 대기(Lock A 종료 -> 그 팔로워의
     * push 끝)이고, derive_apply_timings는 Leader-Side와 같은 "AE 전 복사"
     * 분기로 계산한다. */
    bool pushed = false;
};

/* ============================================================
 * replSink (raft.go 원본)
 * "collects per-RPC samples from in-flight appendEntries goroutines for
 *  a single Apply call. Allocated per-Apply by ApplyTimed; non-timed
 *  Apply passes nil and goroutines skip the push."
 * ============================================================ */
class ReplSink {
public:
    explicit ReplSink(size_t n_followers = 2) : n_followers_(n_followers) {}

    void push(const ReplSample &s);

    /* firstSample: "returns the first sample (the quorum-completing
     * follower's timings in a 3-node cluster with self-ACK) and
     * whether one was recorded." */
    std::pair<ReplSample, bool> quorum_sample();

    /* push 대기 측정 (DECISIONS.md D20).
     * set_repl_start: Lock A가 끝나는 시각. apply_internal이 mu를 놓기 전에 남긴다.
     * note_push_end: 팔로워 peer의 push(쓰기 + flush)가 끝난 시각. push job이 남긴다.
     * push_wait_ns: 그 팔로워의 push가 Lock A 뒤로 삐져나온 시간 (0 이상).
     *   기준점이나 끝난 시각이 없으면 0. */
    void set_repl_start(clock_type::time_point t);
    void note_push_end(int peer, clock_type::time_point t);
    int64_t push_wait_ns(int peer);
private:
    std::mutex mu_;
    bool repl_start_set_ = false;
    clock_type::time_point repl_start_{};
    std::vector<std::pair<int, clock_type::time_point>> push_end_;
    std::vector<ReplSample> samples_;
    size_t n_followers_;
    size_t quorum_followers() const { return (n_followers_ + 1) / 2; }
};

/* clamp0: 음수를 0으로. 파생값이 클럭 해상도 때문에 음수가 나올 수 있어
 * 항등식 항들은 전부 이걸 통과한다 (원본 raft.go도 동일). */
inline int64_t timings_clamp0(int64_t v) { return v < 0 ? 0 : v; }

/* ============================================================
 * ApplyTimed가 측정한 wall 시간들. derive_apply_timings의 입력.
 * ============================================================ */
struct ApplyWalls {
    int64_t nvme_ns = 0;         /* persist_circular가 O_DIRECT write+fdatasync에 쓴 시간 */
    int64_t pre_repl_ns = 0;     /* apply 진입 -> AE 발사 직전. 큐/mu 대기 + 부기 + persist */
    int64_t replicate_ns = 0;    /* 리더 -> 쿼럼 전체 wall */
};

/* ============================================================
 * derive_apply_timings: 측정한 wall 시간과 ReplSample로부터
 * ApplyTimings의 모든 파생값을 계산한다.
 *
 * 항등식은 raft_timings.h 주석 그대로:
 *   Total ~= LHandler + LPersist + AENet + FHandler + ReplNet
 *            + StorageIO + QuorumWait
 *
 * 원본 raft.go에서는 ApplyTimed 본문에 인라인으로 들어 있었고 이 포팅도
 * 그랬다. apply_internal이 242줄이었던 이유의 일부가 이 40줄이며, 파일
 * I/O도 락도 만지지 않는 순수 산술이라 로직에서 떼어냈다.
 * (total_ns는 호출자가 apply_timed에서 채운다.)
 * ============================================================ */
void derive_apply_timings(const ApplyWalls &w, ReplSink *sink, const ProfilingSink &prof, ApplyTimings &t);

} /* namespace nvmeof_raft */

#endif /* RAFT_TIMINGS_HPP */