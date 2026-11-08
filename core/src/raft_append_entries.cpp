#include "raft_server.h"
#include "raft_constants.h"
#include "raft_basics.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <algorithm>
#include <iostream>
#include <sstream>
#include <stdexcept>

namespace nvmeof_raft {

/* 전송은 Server::transport(core/include/raft_transport.h)로만 한다. TCP 구현은
 * net/src/raft_rpc_client.cpp, 테스트용 fake는 tests/fake_transport.h.
 * 이 파일의 로직(Lock B/C, EntryMeta 빌드, backoff 계산)은 전송 구현과
 * 무관하다. */

/* ============================================================
 * appendEntries (raft.go 원본, 로직 그대로 포팅)
 *
 * 병렬화 완료: 팔로워마다 std::thread를 띄워 append_entries_worker를
 * 실행. 원본 goroutine의 fire-and-forget과 동일하게, append_entries
 * 자체는 스레드를 다 띄운 뒤 즉시 리턴한다 (완료를 기다리지 않음).
 * 스레드 생명주기는 Server::spawn_replication_thread /
 * join_all_replication_threads로 관리 (raft_server.h 참고,
 * use-after-free 방지를 위해 join도 detach도 아닌 절충안).
 * ============================================================ */

// [TMP MUTEX]
static std::mutex diag_ae_rpc_mu;
// [TMP MUTEX]

namespace {
struct AeCycStat {
    std::atomic<uint64_t> n{0}, entries{0};
    std::atomic<int64_t> b_wait{0}, b_held{0}, copy{0}, rpc{0}, c_wait{0}, c_held{0}, cycle{0};
    std::atomic<int64_t> t0{0};
};
AeCycStat g_aecyc;

void aecyc_record(size_t followers, uint64_t entries, int64_t b_wait, int64_t b_held,
                  int64_t copy, int64_t rpc, int64_t c_wait, int64_t c_held, int64_t cycle) {
    auto rel = std::memory_order_relaxed;
    g_aecyc.n.fetch_add(1, rel);
    g_aecyc.entries.fetch_add(entries, rel);
    g_aecyc.b_wait.fetch_add(b_wait, rel);
    g_aecyc.b_held.fetch_add(b_held, rel);
    g_aecyc.copy.fetch_add(copy, rel);
    g_aecyc.rpc.fetch_add(rpc, rel);
    g_aecyc.c_wait.fetch_add(c_wait, rel);
    g_aecyc.c_held.fetch_add(c_held, rel);
    g_aecyc.cycle.fetch_add(cycle, rel);

    const int64_t now = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    int64_t t0 = g_aecyc.t0.load(rel);
    if (t0 == 0) {
        g_aecyc.t0.compare_exchange_strong(t0, now);
        return;
    }
    const int64_t el = now - t0;
    if (el < 5'000'000'000LL || !g_aecyc.t0.compare_exchange_strong(t0, now)) {
        return;   /* 5초 전이거나 다른 스레드가 이미 출력 담당 */
    }
    const uint64_t cnt = g_aecyc.n.exchange(0);
    const uint64_t ent = g_aecyc.entries.exchange(0);
    const double bw = g_aecyc.b_wait.exchange(0), bh = g_aecyc.b_held.exchange(0),
                 cp = g_aecyc.copy.exchange(0), rp = g_aecyc.rpc.exchange(0),
                 cw = g_aecyc.c_wait.exchange(0), ch = g_aecyc.c_held.exchange(0),
                 cy = g_aecyc.cycle.exchange(0);
    if (cnt == 0) {
        return;
    }
    const double us = 1e-3 / cnt;
    std::fprintf(stderr,
        "[AECYC] ae/s=%.0f entries/ae=%.1f period/follower=%.0fus cycle=%.0fus | "
        "b_wait=%.0f b_held=%.0f copy=%.0f rpc=%.0f c_wait=%.0f c_held=%.0f (us) | "
        "mu util: B=%.1f%% C=%.1f%%\n",
        cnt * 1e9 / el, (double)ent / cnt, (double)el * followers / 1e3 / cnt, cy * us,
        bw * us, bh * us, cp * us, rp * us, cw * us, ch * us,
        100.0 * bh / el, 100.0 * ch / el);
}
}  // namespace

void Server::append_entries(std::shared_ptr<ReplSink> sink, bool heartbeat) {
    for (size_t i = 0; i < raft.cluster.size(); i++) {
        int fi = static_cast<int>(i);
        if (fi == raft.cluster_index) {
            continue;   /* "Don't need to send message to self" */
        }
        trigger_ae_worker(fi, sink, heartbeat);
    }
}

/* [Push Integration] trigger_ae_worker: 팔로워 fi 의 상시 AE 워커 **하나만** 깨운다.
 * append_entries 가 팔로워마다 부르고, push job 은 자기 대상의 쓰기가 끝났을 때
 * 그 대상에 대해서만 부른다 (finish_push_job). 원래 append_entries 의 루프 본문을
 * 그대로 옮긴 것이고, heartbeat 표시만 추가했다. mu 를 잡지 않는다 -- 워커의 자체
 * 락만 잡는다. */
void Server::trigger_ae_worker(int fi, std::shared_ptr<ReplSink> sink, bool heartbeat) {
    size_t i = static_cast<size_t>(fi);
    /* start() 를 거치지 않은 하네스(유닛 테스트)에는 워커가 없다 */
    if (fi < 0 || i >= workers.ae_workers.size() || !workers.ae_workers[i]) {
        return;
    }
    auto &w = *workers.ae_workers[i];
    {
        std::lock_guard<std::mutex> lk(w.mu);
        w.pending = true;
        if (heartbeat) {
            w.heartbeat_due = true;
        }
        /* sink 를 값으로 캡처해 워커가 살아 있는 동안 ReplSink 도 살아 있게 한다 */
        if (sink != nullptr) {
            w.sink = sink;
        }
    }
    w.cv.notify_one();
}

/* append_entries_worker: 팔로워 한 명에 대한 처리 로직.
 * 원본 append_entries의 go func(fi) {...} 본문 그대로 (로직 변경 없음,
 * 감싸는 함수만 분리) */
void Server::append_entries_worker(int fi, ReplSink *sink, bool heartbeat_due) {
    {
        /* ---- 4-1. waitLockB ---- */
        auto t_b = clock_type::now();
        mu.lock();
        auto t_b_held_start = clock_type::now();
        int64_t mutex_b = elapsed_ns(t_b);

        /* ---- 4-2. logValid ---- */
        uint64_t next = raft.cluster[static_cast<size_t>(fi)].next_index;
        uint64_t last = std::min(ring.tail_log_index - 1, durable_last_index_locked());
        // uint64_t last = ring.tail_log_index - 1;
        uint64_t oldest = oldest_log_index();

        /* "follower가 leader보다 앞서있을 때 -> last+1로 변경 (예외처리)" */
        if (next > last + 1) {
            next = last + 1;
            raft.cluster[static_cast<size_t>(fi)].next_index = next;
        }

        /* push 관문 (DECISIONS.md D20). 배치를 자르는 다른 단계보다 먼저 한다.
         * pushing이면 next가 이 팔로워에게 맡긴 엔트리이고, last는 이 팔로워
         * 볼륨에 쓰기와 flush까지 끝난 데로 잘려 있다.
         *   - 남은 게 있으면 그만큼 보내고 아래에서 data_already_copied를 세운다.
         *   - 남은 게 없으면(last < next) 나머지는 쓰는 중이다 -- 엔트리를 보내지
         *     않는다. 그 push job이 끝나면 이 워커를 다시 깨운다(finish_push_job).
         *     이번 회차를 하트비트 타이머가 깨웠으면 빈 AE를 보내 팔로워가 선거를
         *     시작하지 않게 하고(last < next라 배치가 빈다), 아니면 RPC 없이
         *     돌아간다 -- 매번 보내면 그 RPC가 오가는 동안 push가 끝났을 때 진짜
         *     AE가 한 왕복 늦어진다.
         * pushing이 아니면 지금 동작 그대로 (통째로 pull).
         * 깨우기를 잃지 않는다: 완료는 mu 아래에서 기록한 뒤 깨우므로, 여기서
         * 돌아간 뒤의 완료가 반드시 다시 깨운다. */
        bool pushing = push_gate(fi, next, last);
        if (pushing && last < next && !heartbeat_due) {
            mu.unlock();
            return;
        }
        // => 불필요한 예외처리 아닌가?
        //    Claude: fast backoff를 되살리거나 로그 truncation을 도입하면 필요

        // /* "Clamp: if next fell below what we have in memory, reset to
        //  * oldest -> follower에게 보내야 할 entry가 ring에서 해제됐을 때
        //  * oldest로 옮겨서 살아있는 가장 오래된 entry부터 전송" */
        // if (next < oldest) {
        //     next = oldest;
        //     raft.cluster[static_cast<size_t>(fi)].next_index = next;
        // }
        // => 불가능한 경로, next는 minMatch보다 뒤로 갈 수 없음.

        /* Raft Consistency check */
        uint64_t prev_log_index = 0;
        uint64_t prev_log_term = 0;
        if (next > 0) {
            prev_log_index = next - 1;
            if (prev_log_index >= oldest && prev_log_index < ring.tail_log_index) {
                prev_log_term = raft.log[log_slice(prev_log_index)].term;
            }
        }

        uint64_t len_entries = 0;
        if (last >= next) {
            /* "Skip if a prior data-bearing RPC is still in-flight...
             * Heartbeats (0 entries) still go through." */
            if (raft.cluster[static_cast<size_t>(fi)].inflight) {
                mu.unlock();
                return;
            }
            len_entries = last - next + 1;
            if (len_entries > max_ae_batch) {
                len_entries = max_ae_batch;
            }
        }

        uint64_t total_slots = 0;
        uint64_t slots_per_entry = 0;
        uint64_t start_slot = 0;
        int64_t ae_sub_slot_map_ns = 0;
        int64_t ae_sub_mark_slots_ns = 0;

        /* ---- 4-3. slotMapLookup (원본 raft.go:2475-2554 그대로 포팅) ----
         * "Get start slot from first entry's slot map. If missing (or
         *  already GC'd), the slot was freed -- PBA copy would read
         *  stale data. Send heartbeat only." */
        auto t_slot_map_lookup = clock_type::now();
        // fast-backoff 또는 follower restart -> next <= GC구간인 경우 예외처리
        // 이 분기 빼고 실험해보기
        if (len_entries > 0) {
            /* gcUpTo fast path: 이미 GC된 인덱스면 조회 스킵.
             * gc_has_run이 false면(GC를 아직 한 번도 안 돌린 상태)
             * 이 fast path 자체를 건너뛴다 -- 안 그러면 next=0,
             * gc_up_to=0(원본 초기값)일 때 0<=0이 참이 되어 GC된 적
             * 없는 index 0을 "이미 GC됨"으로 오판한다 (실제 재현 확인). */
            auto it = ring.log_slot_map.find(next);
            if (ring.gc_has_run && next <= ring.gc_up_to) {
                // log_skip_pba_diag(fi, next, last, prev_log_index);
                len_entries = 0;
            } else if (it != ring.log_slot_map.end()) {
                start_slot = it->second.start;
            } else {
                // log_skip_pba_diag(fi, next, last, prev_log_index);
                len_entries = 0;
            }
        }

        if (len_entries > 0) {
            /* "Accumulate slots across entries, clamping at the per-round
             *  byte cap. entry를 하나씩 추가하면서 누적 바이트가
             *  MaxAppendEntriesBatchBytes를 넘으면 그 직전에서 자름" */
            uint64_t accepted = 0;
            for (uint64_t k = 0; k < len_entries; k++) {
                uint64_t log_idx = next + k;
                uint64_t needed = slots_for_log_index(log_idx);
                /* "Byte cap: break once cumulative bytes would exceed the
                 *  round ceiling. Always accept at least one entry so a
                 *  single oversized entry still makes progress." */
                if (accepted > 0 && (total_slots + needed) * SECTOR_SIZE > max_ae_batch_bytes) {
                    break;
                }
                total_slots += needed;
                accepted++;
            }
            len_entries = accepted;
            slots_per_entry = (total_slots + len_entries - 1) / len_entries;

            /* "Limit batch at ring wrap-around for contiguous FIEMAP" */
            uint64_t slots_until_end = ring.ring_slots - start_slot;
            if (total_slots > slots_until_end) {
                total_slots = 0;
                len_entries = 0;
                for (uint64_t k = 0; ; k++) {
                    uint64_t log_idx = next + k;
                    if (log_idx > last) {
                        break;
                    }
                    uint64_t needed = slots_for_log_index(log_idx);
                    if (total_slots + needed > slots_until_end) {
                        break;
                    }
                    /* "Byte cap applies equally on the wrap-clamped path." */
                    if (len_entries > 0 &&
                        (total_slots + needed) * SECTOR_SIZE > max_ae_batch_bytes) {
                        break;
                    }
                    total_slots += needed;
                    len_entries++;
                }
                if (len_entries > 0) {
                    slots_per_entry = (total_slots + len_entries - 1) / len_entries;
                }
            }
        }
        ae_sub_slot_map_ns = elapsed_ns(t_slot_map_lookup);

        /* PBALookup (원본 raft.go:2564-2613 그대로 포팅) */
        uint64_t leader_pba_src = 0;
        uint64_t log_block_length = 0;
        /* timer */ auto t_pba_lookup = clock_type::now();
        if (len_entries > 0) {
            PbaRangeResult r = leader_pba_for_range(start_slot, total_slots);
            leader_pba_src = r.pba_src;
            /* "actualBytes가 핵심, extent cache가 반환하는 실제로 연속된
             *  물리 블록의 바이트 수. 요청한 범위 전체가 하나의 extent
             *  안에 있으면 actualBytes == totalSlots*SECTOR_SIZE, extent
             *  경계에 걸리면 actualBytes < totalSlots*SECTOR_SIZE" */
            uint64_t actual_bytes = r.nbytes;

            /* "Clamp batch if FIEMAP extent doesn't cover the full range." */
            uint64_t actual_slots = actual_bytes / SECTOR_SIZE;
            if (actual_slots < total_slots) {
                len_entries = 0;
                uint64_t counted = 0;
                for (uint64_t k = 0; ; k++) {
                    uint64_t log_idx = next + k;
                    if (log_idx > last) {
                        break;
                    }
                    uint64_t needed = slots_for_log_index(log_idx);
                    if (counted + needed > actual_slots) {
                        break;
                    }
                    counted += needed;
                    len_entries++;
                }
                total_slots = counted;
            }
            log_block_length = total_slots;
        }
        int64_t ae_sub_pba_lookup_ns = elapsed_ns(t_pba_lookup);

        uint64_t sent_next = next;
        bool has_entries = len_entries > 0;

        /* ---- 4-6. MetaBuild ----
         * "Send lightweight entry metadata so follower can build its
         *  in-memory log without readback. Command payload is on the
         *  device via PBA copy; follower loads it lazily at apply time." */
        const bool normal_mode = (replication_mode == ReplicationMode::Normal);
        std::vector<EntryMeta> metas;
        int64_t ae_sub_meta_build_ns = 0;
        if (len_entries > 0) {
            auto t_mb = clock_type::now();
            try {
                metas = build_entry_metas_locked(next, len_entries, normal_mode);
            } catch (const std::exception &) {
                /* 정상경로에서 자기 링 읽기(read_entry_direct)가 실패했다. Leader-Side
                 * 복사 실패와 같은 fail-soft: 이번 회차는 버리고 다음 라운드에 재시도.
                 * inflight는 아직 세우지 않았다. */
                mu.unlock();
                return;
            }
            ae_sub_meta_build_ns = elapsed_ns(t_mb);
        }

        if (has_entries) {
            raft.cluster[static_cast<size_t>(fi)].inflight = true;
        }

        AppendEntriesRequest req;
        req.rpc.term = raft.current_term;
        req.leader_id = raft.cluster[static_cast<size_t>(raft.cluster_index)].id;
        req.prev_log_index = prev_log_index;
        req.prev_log_term = prev_log_term;
        req.leader_commit = raft.commit_index;
        req.leader_pba_src = leader_pba_src;
        req.log_block_length = log_block_length;
        req.num_entries = len_entries;
        req.slots_per_entry = slots_per_entry;
        req.start_slot = start_slot;
        req.leader_dev_index = raft.cluster_index;
        req.entry_metas = std::move(metas);
        if (normal_mode) {
            /* 정상경로 (DECISIONS.md D22): 바이트는 entry_metas[i].command로 간다.
             * 위 extent clamp로 정한 len_entries/start_slot은 그대로 쓴다 -- 리더가
             * extent 경계에서 슬롯을 건너뛰므로 팔로워가 start_slot부터 차례로
             * 놓으려면 그 clamp가 필요하다. PBA 필드만 비운다. */
            req.inline_entries = has_entries;
            req.leader_pba_src = 0;
            req.log_block_length = 0;
        }
        /* push 모드: 이 팔로워의 맵을 아직 안 받았거나 팔로워가 알린 해시가
         * 받아 둔 맵과 다르면 응답에 맵을 실어 달라고 한다 (DECISIONS.md D20).
         * heartbeat에도 실린다 -- 맵은 엔트리와 무관하다. */
        req.need_extent_map = needs_extent_map(fi);

        /* push 모드: 관문을 pushing으로 지났고 최종 배치도 끝난 구간 안이면 팔로워는
         * pull(do_pba_copy)을 건너뛴다. len_entries는 위의 바이트 상한, wrap,
         * extent clamp를 다 거친 최종값이다 -- 배치가 리더 extent 하나 안에
         * 있고 wrap하지 않으므로 슬롯이 연속이고, 팔로워가 start_slot부터
         * 차례로 계산하는 슬롯이 리더가 push한 위치와 같다.
         * 끝난 구간은 그 팔로워의 push 쓰기와 flush가 끝난 뒤에만 늘어나므로
         * 이 AE 자체가 "네 볼륨에 내구성 있게 썼다"는 OK다 (A안, DECISIONS.md D20). */
        /* skip/pull 계수(-debug)는 push 대상일 때만 센다 -- 대상이 아닌
         * 팔로워의 pull까지 세면 "대상인데도 pull로 간 배치"를 못 본다. */
        if (has_entries && is_push_target(fi)) {
            ClusterMember &pm = raft.cluster[static_cast<size_t>(fi)];
            if (pushing && push_covers(fi, next, next + len_entries - 1)) {
                req.data_already_copied = true;
                pm.push_ae_skipped++;
            } else {
                pm.push_ae_pulled++;
            }
        }

        int64_t ae_lock_b_held = elapsed_ns(t_b_held_start);
        mu.unlock();   /* "lockB Finish" */

        /* ---- Leader-Side replication (Server::ReplicationMode::LeaderSide,
         *  hpdc15dare 3.1.2와 동일 정책) ----
         * Destination-Side(기본)에서는 follower의 handle_append_entries_
         * request 안에서 do_pba_copy가 실행된다. Leader-Side에서는 그
         * 대신 여기서 -- RPC를 보내기 *전에* -- leader 자신의 storage
         * node(Server::blockcopy)에게 "내 로그를 follower(dst_dev=fi) 볼륨에
         * 직접 써라"라고 지시한다. 복사가 실패하면 이 배치는 스킵하고
         * (다음 heartbeat에서 재시도), 성공하면 data_already_copied=true로
         * 표시해 follower가 do_pba_copy를 다시 하지 않도록 한다. */
        DoPbaCopyResult leader_side_copy{};
        bool leader_side_copy_failed = false;
        if (has_entries && replication_mode == ReplicationMode::LeaderSide) {
            try {
                leader_side_copy = do_pba_copy(leader_pba_src, log_block_length,
                                                start_slot, raft.cluster_index, fi);
                req.data_already_copied = true;
            } catch (const std::exception &) {
                leader_side_copy_failed = true;
            }
        }
        if (leader_side_copy_failed) {
            /* "복사 실패 -- 이번 배치는 건너뛰고 다음 AppendEntries
             *  라운드(heartbeat)에서 재시도" (destination-side가
             *  do_pba_copy 실패 시 finalize()로 조용히 리턴하는 것과
             *  동일한 fail-soft 정책). inflight를 반드시 되돌려야
             *  다음 append_entries_worker 호출이 이 팔로워를 계속
             *  건너뛰지 않는다 (Lock C 블록의 정상 실패 경로와 동일). */
            if (has_entries) {
                mu.lock();
                raft.cluster[static_cast<size_t>(fi)].inflight = false;
                mu.unlock();
            }
            return;
        }

        /* REPLICATION LATENCY */
        if (has_entries) {
            prof.ae_count.fetch_add(1);
            prof.ae_entries.fetch_add(len_entries);
        }

        AppendEntriesResponse rsp;
        // bool ok = false;
        // int64_t rt_ns = 0;
        // {
        //     // 임시로 Global Lock 잡고 PW에서 Serial AE 효과 확인
        //     std::lock_guard<std::mutex> diag_lk(diag_ae_rpc_mu);

        //     auto t_rep = clock_type::now();
        //     /* transport가 없으면(주입 안 된 하네스) 전송 실패와 동일하게 다룬다 */
        //     ok = (transport != nullptr) && transport->append_entries(fi, req, rsp);

        //     rt_ns = elapsed_ns(t_rep);
        // }

        auto t_rep = clock_type::now();

        /* transport 가 없으면(주입 안 된 하네스) 전송 실패와 동일하게 다룬다 */
        bool ok = (transport != nullptr) && transport->append_entries(fi, req, rsp);

        int64_t rt_ns = elapsed_ns(t_rep);

        /* ---- Lock C: post-RPC bookkeeping ---- */
        std::vector<std::shared_ptr<EntryCommitSignal>> sig;

        auto t_c = clock_type::now();
        mu.lock();
        int64_t mutex_c = elapsed_ns(t_c);
        auto t_c_held_start = clock_type::now();   /* [AECYC] */

        if (has_entries) {
            raft.cluster[static_cast<size_t>(fi)].inflight = false;
        }

        if (!ok) {
            mu.unlock();
            return;
        }

        /* [Push Integration] push 후보 기록과 맵 설치. term 검사보다 앞에 둔다 --
         * 거절 응답이어도 그 팔로워의 모드, 맵 해시, 맵은 유효하다. */
        note_push_response(fi, rsp);

        /* 응답의 term이 더 높으면 이 라운드를 버린다.
         *
         * 주의: 원본 raft.go는 여기서 s.updateTerm(rsp.RPCMessage)를 불러
         * **팔로워로 강등까지** 한다. 이 포팅은 강등하지 않고 그냥 중단한다.
         * 실질 차이는 크지 않다 -- 그 팔로워가 더 높은 term의 리더를 알고
         * 있다면 그 리더가 곧 우리에게 AppendEntries를 보내고
         * handle_append_entries_request가 update_term으로 강등시킨다.
         * 다만 그만큼 강등이 늦는다. 원본과 맞추려면 update_term(rsp.rpc.term)
         * 을 부르면 되지만, 그건 동작 변경이므로 이번 리팩토링 범위 밖이다. */
        if (update_term(rsp.rpc.term)) {
            mu.unlock();
            return;
        }
        if (rsp.rpc.term != req.rpc.term && raft.state == ServerState::Leader) {
            mu.unlock();
            return;
        }

        /* 샘플 수집은 sink 유무와 무관하게 한다.
         *
         * ProfilingSink의 sample_* 는 apply_timed가 "이 Apply 안에서
         * data-bearing AE를 못 잡았을 때" 쓰는 폴백이다. 그 상황이
         * 발생하는 이유가 **바로 직전 하트비트가 이미 복제를 끝냈기
         * 때문**이므로(하트비트는 sink == nullptr), 폴백 값을 남기는
         * 코드가 sink 가드 안에 있으면 영원히 채워지지 않는다.
         * 실제로 그랬다 -- store가 0건이어서 폴백이 항상 0을 읽었다
         * (DECISIONS.md U4). 그래서 가드는 push에만 건다. */
        if (rsp.success && has_entries) {
            ReplSample sample;
            // [Diag]
            sample.peer_index = fi;
            // [Diag]
            sample.leader_side = (replication_mode == ReplicationMode::LeaderSide);
            sample.r2_ns = rsp.handler_duration_ns;
            /* Leader-Side: 팔로워는 do_pba_copy를 안 돌리므로
             * rsp.write_pba_rt_ns/storage_copy_ns는 0 -- 대신 leader가
             * RPC 전에 직접 측정한 leader_side_copy 값을 기록해야
             * Destination-Side와 동일한 지표로 비교 가능하다. */
            /* [Push Integration] push 된 배치: 팔로워는 pull 하지 않았다. 대신 Lock A 가
             * 끝난 뒤에도 남았던 push 대기(이 팔로워의 push 가 끝난 시각 - Lock A 종료)를
             * Leader-Side 의 "AE 전 복사" 자리에 넣는다. */
            sample.pushed = (replication_mode == ReplicationMode::Push && req.data_already_copied);
            if (replication_mode == ReplicationMode::LeaderSide) {
                sample.write_pba_rt_ns = leader_side_copy.write_pba_rt_ns;
                sample.storage_copy_ns = leader_side_copy.storage_copy_ns;
            } else if (sample.pushed) {
                int64_t wait_ns = (sink != nullptr) ? sink->push_wait_ns(fi) : 0;
                sample.write_pba_rt_ns = wait_ns;
                sample.storage_copy_ns = wait_ns;
            } else {
                sample.write_pba_rt_ns = rsp.write_pba_rt_ns;
                sample.storage_copy_ns = rsp.storage_copy_ns;
            }
            /* sink가 없으면 Apply가 아니므로 Lock A 대기도 없다 */
            sample.mutex_ns = (sink != nullptr ? sink->mutex_a_ns() : 0) + mutex_b + mutex_c;
            sample.mutex_c_ns = mutex_c;
            sample.mutex_b_ns = mutex_b;
            sample.ae_rt_ns = rt_ns;
            sample.lock_b_held_ns = ae_lock_b_held;
            sample.slot_map_ns = ae_sub_slot_map_ns;
            sample.mark_slots_ns = ae_sub_mark_slots_ns;
            sample.pba_lookup_ns = ae_sub_pba_lookup_ns;
            sample.meta_build_ns = ae_sub_meta_build_ns;
            sample.handle_ae_lock_wait_ns = rsp.handle_ae_lock_wait_ns;
            sample.handle_ae_pre_ns = rsp.handle_ae_pre_ns;
            sample.handle_ae_lock_wait2_ns = rsp.handle_ae_lock_wait2_ns;
            sample.handle_ae_persist_ns = rsp.handle_ae_persist_ns;
            sample.handle_ae_post_ns = rsp.handle_ae_post_ns;

            /* 폴백용 "최근 값". prof.enabled로 게이팅하지 않는다 --
             * apply_timed의 항등식 7항은 -profile 없이도 동작해야 한다. */
            prof.sample_ae_rt_ns.store(sample.ae_rt_ns);
            prof.sample_r2_ns.store(sample.r2_ns);
            prof.sample_write_pba_rt_ns.store(sample.write_pba_rt_ns);
            prof.sample_storage_copy_ns.store(sample.storage_copy_ns);
            prof.sample_mutex_ns.store(sample.mutex_ns);
            prof.sample_mutex_c_ns.store(sample.mutex_c_ns);

            if (sink != nullptr) {
                sink->push(sample);
            }
        }

        /* 성공/실패 처리는 각각 별도 메서드로 뽑아 뒀다 -- 둘 다 순수하게
         * cluster[fi]와 log만 만지는 산술이라 단위 테스트가 붙는다
         * (tests/test_ae_bookkeeping.cpp). 호출 시 mu를 보유해야 한다. */
        if (rsp.success) {
            apply_ae_success(fi, next, len_entries, has_entries);
            advance_commit_index_locked(&sig);
        } else {
            if (!apply_ae_failure_backoff(fi, req.prev_log_index, rsp.conflict_term,
                                          rsp.conflict_index, sent_next)) {
                /* stale failure -- 다른 워커가 이미 next_index를 전진시켰다 */
                mu.unlock();
                return;
            }
        }

        /* Lock C 보유 시간을 재놓고 버린다. ReplSample::lock_c_held_ns와
         * ProfilingSink::… 둘 다 기록하는 코드가 없어서, ApplyTimings의
         * post_rpc_ns가 항상 0으로 남고 wg_scheduling_ns 역산이 부정확하다
         * -- DECISIONS.md U4 (계측 배선 미완, 리팩토링 범위 밖). */
        const int64_t aecyc_c_held = elapsed_ns(t_c_held_start);   /* [AECYC] mu 보유 중 */
        mu.unlock();
        if (has_entries && rsp.success) {
            /* 스토리지 복사 시간: leader 모드면 리더가 잰 값, destination 모드면 팔로워가 응답에 실어 준 값 */
            const int64_t copy_ns = (replication_mode == ReplicationMode::LeaderSide)
                                        ? leader_side_copy.storage_copy_ns
                                        : rsp.storage_copy_ns;
            aecyc_record(raft.cluster.size() - 1, len_entries, mutex_b, ae_lock_b_held,
                         copy_ns, rt_ns, mutex_c, aecyc_c_held, elapsed_ns(t_b));
        }
        signal_committed_batch(sig);
    }
}

void Server::append_entries_loop(int fi, AppendEntriesWorkerState *w) {
    while (!done.load()) {
        std::shared_ptr<ReplSink> sink;
        bool heartbeat_due = false;   /* [Push Integration] 하트비트 타이머가 깨운 회차인가 */
        {
            std::unique_lock<std::mutex> lk(w->mu);

            w->cv.wait(lk, [&] {
                return done.load() || w->pending;
            });

            if (done.load())
                break;

            w->pending = false;

            sink = std::move(w->sink);
            heartbeat_due = w->heartbeat_due;   /* 가져가며 내린다 */
            w->heartbeat_due = false;
        }

        append_entries_worker(fi, sink.get(), heartbeat_due);
    }
}

/* ============================================================
 * apply_ae_success / apply_ae_failure_backoff
 *
 * append_entries_worker가 RPC 응답을 받은 뒤 Lock C 안에서 하는
 * 기록 갱신. 원본 raft.go에서는 appendEntries 고루틴 본문에 인라인으로
 * 들어 있으나, 여기서는 (1) 워커 함수가 417줄이었고 (2) 이 두 블록이
 * 파일 I/O도 네트워크도 만지지 않는 순수 산술이라 단위 테스트를 붙일
 * 수 있는 유일한 지점이어서 분리했다. 로직은 한 줄도 바꾸지 않았다.
 *
 * 둘 다 **호출자가 mu를 보유한 상태**로 불러야 한다.
 * ============================================================ */

/* build_entry_metas_locked: AE에 실을 엔트리 메타 [next, next+len).
 *
 * 블록 복사 모드(with_payload=false)는 예전 MetaBuild 그대로다 -- term과
 * cmd_len만 싣는다. 주의: 이 경로는 apply가 비운 엔트리(command 비움,
 * ring_slot 0, cmd_len만 남음)에 cl=0을 싣는다. 느린 팔로워에게 다중 슬롯
 * 엔트리를 보낼 때 슬롯 계산이 어긋날 수 있는 기존 동작이며 여기서는
 * 바꾸지 않는다 -- DECISIONS.md U12.
 *
 * 정상경로(with_payload=true)는 명령 바이트를 채운다:
 *   1. 메모리에 있으면 복사
 *   2. deferred(ring_slot != 0)면 그 슬롯에서 read_entry_direct
 *   3. apply가 비운 엔트리(cmd_len > 0)면 log_slot_map의 시작 슬롯에서
 *      read_entry_direct -- 느린 팔로워 catch-up 경로. 보낼 엔트리는
 *      next > match_index >= min_match 라 do_slot_gc가 아직 해제하지 않았다
 *   4. 아니면 no-op (빈 명령)
 * cmd_len은 실제로 실은 명령 길이다. 호출자가 mu를 보유한다. */
std::vector<EntryMeta> Server::build_entry_metas_locked(uint64_t next, uint64_t len,
                                                        bool with_payload) {
    std::vector<EntryMeta> metas(len);
    for (uint64_t k = 0; k < len; k++) {
        const uint64_t idx = next + k;
        Entry &e = raft.log[log_slice(idx)];
        EntryMeta &m = metas[k];
        m.term = e.term;
        if (!with_payload) {
            uint64_t cl = e.command.size();
            if (e.command.empty() && e.ring_slot != 0) {
                cl = e.cmd_len;   /* deferred entry: use stored cmdLen */
            }
            m.cmd_len = cl;
            continue;
        }
        if (!e.command.empty()) {
            m.command = e.command;   /* 버퍼 공유 (참조 카운트만, 바이트 복사 없음 -- CommandBytes) */
        } else if (e.ring_slot != 0) {
            m.command = read_entry_direct(e.ring_slot).entry.command;
        } else if (e.cmd_len > 0) {
            auto it = ring.log_slot_map.find(idx);
            if (it == ring.log_slot_map.end()) {
                throw std::runtime_error("build_entry_metas_locked: no slot for applied entry " +
                                         std::to_string(idx));
            }
            m.command = read_entry_direct(it->second.start).entry.command;
        }
        m.cmd_len = m.command.size();
    }
    return metas;
}

/* AppendEntries가 성공했을 때 next_index/match_index를 전진시키고,
 * 팔로워에게 아직 보낼 엔트리가 남았으면 다음 하트비트를 즉시 만료시킨다.
 *   fi           : cluster 인덱스
 *   next         : 이 배치의 첫 엔트리 인덱스 (전송 시점의 next_index)
 *   len_entries  : 이 배치에 실제로 실어 보낸 엔트리 수
 *   has_entries  : 데이터가 실린 AE였는가 (순수 하트비트면 false) */
void Server::apply_ae_success(int fi, uint64_t next, uint64_t len_entries,
                               bool has_entries) {

        /* 수정: 원본 공식(prev_log_index + len_entries + 1)은
         * prev_log_index=0이 "index 0 자체"인지 "이전 엔트리 없음
         * (1-based의 관례적 0)"인지 구분 못 해 0-based 시스템에서
         * off-by-one이 남. next는 이 배치의 첫 엔트리 index 그
         * 자체이므로(모호함 없음), new_next = next + len_entries가
         * 정확하다. 실제 3노드 e2e 테스트에서 next=0일 때
         * (팔로워가 아직 아무 엔트리도 없을 때) 이 어긋남이 실제로
         * 재현되어 확인됨. */
        uint64_t new_next = std::max(next + len_entries, uint64_t{1});
        if (new_next > raft.cluster[static_cast<size_t>(fi)].next_index) {
            raft.cluster[static_cast<size_t>(fi)].next_index = new_next;
        }
        raft.cluster[static_cast<size_t>(fi)].match_index =
            raft.cluster[static_cast<size_t>(fi)].next_index - 1;

        /* "If this follower still has pending entries... schedule the
         *  next heartbeat immediately" -- heartbeat_timeout을 즉시
         * 만료시켜 다음 루프에서 바로 재전송되게 함 */
        if (has_entries && raft.state == ServerState::Leader &&
            ring.tail_log_index - 1 >= raft.cluster[static_cast<size_t>(fi)].next_index) {
            raft.heartbeat_timeout = std::chrono::steady_clock::time_point{};
        }
}

/* AppendEntries가 거절됐을 때 next_index를 되감는다 (fast log backoff).
 *   prev_log_index : 방금 보낸 요청의 prev_log_index
 *   conflict_term  : 팔로워가 준 힌트 (0 = 힌트 없음)
 *   conflict_index : 팔로워가 준 힌트
 *   sent_next      : 요청을 보낼 때의 next_index (stale 응답 판별용)
 *
 * 반환: false면 **stale failure**다 -- 이 요청을 보낸 뒤 다른 워커가 이미
 * next_index를 전진시켰으므로 되감기를 적용하면 그 진전을 되돌린다.
 * 호출자는 아무것도 하지 않고 빠져나가야 한다. */
bool Server::apply_ae_failure_backoff(int fi, uint64_t prev_log_index,
                                       uint64_t conflict_term, uint64_t conflict_index,
                                       uint64_t sent_next) {
        /* "실패 시 -> follower 로그가 안 맞으니 되감기 (거의 호출되지 않음)" */

        /* "Stale failure guard: if nextIndex has moved since we sent
         *  this request, a concurrent goroutine has already updated
         *  it... Applying this stale failure would undo that progress." */
        if (raft.cluster[static_cast<size_t>(fi)].next_index != sent_next) {
            return false;
        }

        uint64_t prev = raft.cluster[static_cast<size_t>(fi)].next_index;
        uint64_t new_next = prev;

        if (conflict_term == 0 && conflict_index == 0) {
            /* "No hint (rejection from non-follower or stale term)." */
            new_next = raft.cluster[static_cast<size_t>(fi)].next_index - 1;
        } else if (conflict_term == 0) {
            /* "Follower's log is shorter than PrevLogIndex." */
            new_next = conflict_index;
        } else {
            /* "Search leader's log for ConflictTerm. If found, set
             *  nextIndex just past the last entry of that term.
             *  Otherwise jump to follower's conflictIndex." */
            new_next = conflict_index;
            uint64_t oldest3 = oldest_log_index();
            for (uint64_t j = prev_log_index; j >= 1 && j >= oldest3; j--) {
                if (raft.log[log_slice(j)].term == conflict_term) {
                    new_next = j + 1;
                    break;
                }
                if (raft.log[log_slice(j)].term < conflict_term) {
                    break;
                }
                if (j == oldest3) {
                    break;   /* uint64 underflow 방지: j-- 전에 탈출 */
                }
            }
        }

        /* "Ensure we always make progress."
         * [수정-12] prev == 0에서 prev - 1의 uint64 언더플로를 막는다
         * -- DECISIONS.md D12 */
        if (new_next >= prev) {
            new_next = (prev > 0) ? prev - 1 : 0;
        }
        /* "Never back off past matchIndex+1: the follower already
         *  confirmed entries up to matchIndex, and those PBA slots
         *  may have been freed by tier 1." */
        uint64_t floor = raft.cluster[static_cast<size_t>(fi)].match_index + 1;
        raft.cluster[static_cast<size_t>(fi)].next_index =
            std::max(std::max(new_next, uint64_t{1}), floor);

    return true;
}

} /* namespace nvmeof_raft */