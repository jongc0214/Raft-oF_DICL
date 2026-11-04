#ifndef RAFT_ENTRY_HPP
#define RAFT_ENTRY_HPP

#include "cached_fd.h"   /* Extent (blockio/cached_fd.h) -- push 모드 AE 응답이 싣는다 */

#include <cstdint>
#include <vector>
#include <string>
#include <functional>
#include <condition_variable>
#include <mutex>

namespace nvmeof_raft {

/* ============================================================
 * ApplyResult (raft.go 원본)
 * Go의 (Result []byte, Error error)를 C++로. Go는 error가 nil이면
 * 성공인 관례라, 여기서도 error 문자열이 비어있으면 성공으로 취급
 * ============================================================ */
struct ApplyResult {
    std::vector<uint8_t> result;
    std::string error;   /* 비어있으면 성공 (Go의 err == nil과 동일 관례) */
};

/* ============================================================
 * Entry (raft.go 원본 필드 그대로)
 *
 * 원본 주석: "Lazy loading (follower only): when Command is nil, the
 * entry data is on the ring device at ringSlot. Load via readEntryDirect
 * at apply time."
 *
 * Go의 chan ApplyResult, chan struct{}는 C++에 직접 대응 타입이 없어
 * condition_variable 기반으로 재현. committed는 원본이 cap=1 버퍼드
 * 채널이라 "이미 signaled면 다시 안 막힘"이 되도록 bool 플래그로 처리.
 *
 * 주의: Server::log가 std::vector<Entry>이고 append/재배치 시 Entry가
 * 복사/이동되어야 하는데, mutex/condition_variable은 복사도 이동도
 * 안 됨. 그래서 이 동기화 상태를 shared_ptr로 감싸 Entry 자체는
 * 이동 가능한 값 타입으로 유지한다. Go에서는 채널이 참조 타입이라
 * 이 문제가 애초에 없었음 -- 언어 차이에서 오는 포팅 이슈.
 * ============================================================ */
struct EntryCommitSignal {
    std::mutex mu;
    std::condition_variable cv;
    bool signaled = false;
};

struct Entry {
    std::vector<uint8_t> command;   /* nil 대응: command.empty() && ring_slot != 0 이면 미로드 상태 */
    uint64_t term = 0;

    /* Go: result chan ApplyResult -- 리더가 apply 결과를 클라이언트에게
     * 돌려주는 통로. 여기서는 콜백으로 단순화 (1주 스코프) */
    std::function<void(ApplyResult)> result_sink;

    /* Go: committed chan struct{}, cap=1 -- advanceCommitIndex가 이 엔트리를
     * 지나가면 signal. shared_ptr로 감싸서 Entry가 이동 가능하게 유지
     * (위 주석 참고) */
    std::shared_ptr<EntryCommitSignal> committed = std::make_shared<EntryCommitSignal>();

    void signal_committed() {
        std::lock_guard<std::mutex> lk(committed->mu);
        committed->signaled = true;
        committed->cv.notify_all();
    }

    /* Lazy loading (follower only). ring_slot == 0 이면 "미뤄지지 않음
     * (command가 이미 채워져 있음)" -- 원본 주석 그대로:
     * "0 = not deferred (Command is populated)" */
    uint64_t ring_slot = 0;
    uint64_t cmd_len = 0;   /* command가 nil일 때 slotsForEntry 계산에 필요 */
};

/* ============================================================
 * EntryMeta (raft.go 원본)
 * "lightweight entry metadata sent inline in AppendEntriesRequest.
 *  The follower uses this to build its in-memory log without the full
 *  command payload, deferring command loading to apply time."
 * ============================================================ */
struct EntryMeta {
    uint64_t term = 0;
    uint64_t cmd_len = 0;
    /* 정상경로(ReplicationMode::Normal)에서만 채운다: 명령 바이트 자체.
     * 블록 복사 모드에서는 비어 있다 -- 바이트는 PBA copy / push로 간다. */
    std::vector<uint8_t> command;
};

/* ============================================================
 * RPCMessage (raft.go 원본 -- 다른 RPC 메시지들이 embed하던 공통 필드)
 * Go의 struct embedding은 C++에 없으므로 명시적 멤버로 각 구조체에 포함
 * ============================================================ */
struct RPCMessage {
    uint64_t term = 0;
};

struct RequestVoteRequest {
    RPCMessage rpc;
    uint64_t candidate_id = 0;
    uint64_t last_log_index = 0;
    uint64_t last_log_term = 0;
};

struct RequestVoteResponse {
    RPCMessage rpc;
    bool vote_granted = false;
};

/* ============================================================
 * AppendEntriesRequest (raft.go 원본 필드 그대로 -- destination-side
 * metadata-only 설계의 핵심 구조체)
 * ============================================================ */
struct AppendEntriesRequest {
    RPCMessage rpc;
    uint64_t leader_id = 0;
    uint64_t prev_log_index = 0;
    uint64_t prev_log_term = 0;
    uint64_t leader_commit = 0;

    /* Raw Block Copy Metadata (원본 주석 그대로) */
    uint64_t leader_pba_src = 0;     /* physical block address on leader's ring */
    uint64_t log_block_length = 0;   /* number of 512B blocks to copy */
    uint64_t num_entries = 0;        /* how many log entries this batch contains */
    uint64_t slots_per_entry = 0;    /* average slots per entry (follower pointer advance) */
    uint64_t start_slot = 0;         /* ring slot where first entry starts (wrap alignment) */
    int leader_dev_index = 0;        /* leader's cluster_index = storage device index */

    /* data_already_copied: Leader-Side 복제(Server::ReplicationMode::
     * LeaderSide, hpdc15dare §3.1.2와 동일 정책)에서 true. leader의
     * storage node가 AppendEntries를 보내기 *전에* 이미 자기 로그를
     * follower의 볼륨에 직접 써넣었다는 뜻이므로, follower의
     * handle_append_entries_request는 do_pba_copy를 스킵하고 바로
     * in-memory log를 빌드한다 (Destination-Side에선 항상 false --
     * follower 자신이 do_pba_copy로 복사를 수행). */
    bool data_already_copied = false;

    /* need_extent_map: push 모드 리더가 이 팔로워의 링 extent 맵을 응답에
     * 실어 달라고 요청한다 (DECISIONS.md D20). 리더가 맵을 아직 갖고 있지
     * 않거나 팔로워가 알린 해시가 받아 둔 맵과 다를 때만 true다
     * (Server::needs_extent_map). */
    bool need_extent_map = false;

    /* inline_entries: 정상경로(ReplicationMode::Normal). entry_metas[i].command에
     * 명령 바이트가 실려 있고, 팔로워는 그것을 자기 링의 start_slot부터 직접
     * 써서(pwrite + fdatasync) 내구화한다. PBA 필드(leader_pba_src /
     * log_block_length)는 0이다 (DECISIONS.md D22). */
    bool inline_entries = false;

    /* Inline entry metadata: follower builds in-memory log from these
     * (Term + CmdLen only, no command payload). Command is loaded lazily
     * from the device at apply time. Avoids O_DIRECT readback on
     * replication path. */
    std::vector<EntryMeta> entry_metas;
};

/* ============================================================
 * AppendEntriesResponse (raft.go 원본 필드 그대로 -- ApplyTimings의
 * WritePBARtNanos/StorageCopyNanos 등 서브스테이지 계측 필드 포함)
 * ============================================================ */
struct AppendEntriesResponse {
    RPCMessage rpc;
    bool success = false;

    /* Fast log backoff (원본 주석): follower가 거절 시 어디서부터 재시도할지
     * 알려줘서, leader가 nextIndex를 1씩 감소시키는 대신 바로 건너뜀 */
    uint64_t conflict_term = 0;
    uint64_t conflict_index = 0;

    /* HandlerDuration: follower가 HandleAppendEntriesRequest 안에서 보낸
     * 시간 (진입~반환), sanity check용 */
    int64_t handler_duration_ns = 0;

    /* WritePBARtNanos: follower가 측정한 WritePBA(Batch) RPC의 왕복 시간
     * (스토리지 노드로의 동기 block copy).
     * StorageCopyNanos: 스토리지 서버가 보고하는 내부 pread+pwrite 시간.
     * 둘 다 heartbeat/실패 시 0. 리더는 이 값들로 AENet, WritePBANet,
     * DoPBACopy를 역산 */
    int64_t write_pba_rt_ns = 0;
    int64_t storage_copy_ns = 0;
    /* storage_copy_ns 중 pread / pwrite 만 더한 값 (스토리지 서버가 보고).
     * storage_copy_ns 는 서버의 배치 wall 이라 그 차이가 서버 쪽 대기다. */
    int64_t storage_read_ns = 0;
    int64_t storage_write_ns = 0;

    /* HandleAppendEntriesRequest follower 서브스테이지 계측 */
    int64_t handle_ae_lock_wait_ns = 0;   /* entry -> mu.Lock() 획득 */
    int64_t handle_ae_pre_ns = 0;         /* lock 이후 -> doPBACopy 전 unlock */
    int64_t handle_ae_lock_wait2_ns = 0;  /* doPBACopy 반환 후 재lock 대기 */
    int64_t handle_ae_post_ns = 0;        /* 재lock -> 반환, persistCircular 제외 */
    int64_t handle_ae_persist_ns = 0;     /* persistCircular (header-only) 시간 */

    /* push_map_hash: 팔로워가 push 모드면 자기 링의 extent 맵 해시, 아니면 0.
     * 리더는 이 값으로 push 후보를 알아보고, 나중에 받아 둔 맵이 아직
     * 유효한지 확인한다 (DECISIONS.md D20). 성공/거절과 무관하게 실린다. */
    uint64_t push_map_hash = 0;

    /* extent_map / volume_wwid: 요청에 need_extent_map이 있고 이 팔로워가
     * push 모드일 때만 채운다. 리더는 맵을 이 팔로워 장치 핸들에 설치하기
     * 전에, volume_wwid를 자기 호스트에서 매핑한 장치의 wwid와 대조해
     * -push-devices가 엉뚱한 볼륨을 가리키지 않는지 확인한다. */
    std::vector<Extent> extent_map;
    std::string volume_wwid;
};

/* ============================================================
 * Client-facing RPC 구조체 (rpcproto.proto의 Client* 메시지 대응,
 * proto_codec.go의 Client*Request/Response 구조체 그대로 포팅)
 * ============================================================ */

struct ClientApplyRequest {
    std::vector<std::vector<uint8_t>> commands;
};

struct ClientApplyResponse {
    std::string error;
    bool busy = false;
    int retry_after_ms = 0;
    int64_t latency_ns = 0;
};

struct ClientApplyTimedRequest {
    std::vector<std::vector<uint8_t>> commands;
};

/* ClientApplyTimedResponse: ApplyTimings의 클라이언트 응답 버전.
 * raft_timings.h의 ApplyTimings와 필드가 거의 겹치지만, RPC로 오가는
 * 것이라 별도 구조체(원본도 별도 타입) */
struct ClientApplyTimedResponse {
    std::string error;
    int64_t l_handler_ns = 0;
    int64_t l_persist_ns = 0;
    int64_t ae_net_ns = 0;
    int64_t f_handler_ns = 0;
    int64_t repl_net_ns = 0;
    int64_t replication_ns = 0;
    int64_t quorum_wait_ns = 0;
    int64_t mutex_ns = 0;
    int64_t mutex_a_ns = 0;
    int64_t mutex_b_ns = 0;
    int64_t mutex_c_ns = 0;
    int64_t total_ns = 0;
    bool busy = false;
    int retry_after_ms = 0;
    int64_t post_rpc_ns = 0;
    int64_t commit_wait_ns = 0;
    int64_t wg_scheduling_ns = 0;
    int64_t storage_read_ns = 0;    /* StorageIO 중 pread 합 */
    int64_t storage_write_ns = 0;   /* StorageIO 중 pwrite 합 */
};

struct ClientEchoRequest {
    std::vector<std::vector<uint8_t>> commands;
};

struct ClientEchoResponse {
    int64_t n = 0;
};

struct ClientGetCommitIndexRequest {};

struct ClientGetCommitIndexResponse {
    uint64_t commit_index = 0;
    std::string error;
};

struct ClientGetHashRequest {
    uint64_t at_count = 0;
};

struct ClientGetHashResponse {
    std::string hash;
    uint64_t count = 0;
    std::string error;
};

struct ClientGetAEBatchStatsRequest {};

struct ClientGetAEBatchStatsResponse {
    uint64_t ae_count = 0;
    uint64_t ae_entries = 0;
    std::string error;
};

} /* namespace nvmeof_raft */

#endif /* RAFT_ENTRY_HPP */