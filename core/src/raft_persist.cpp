#include "raft_server.h"
#include "raft_constants.h"
#include "raft_basics.h"
#include "cached_fd.h"   /* CachedFD 역참조 */

#include <atomic>
#include <chrono>
#include <cstring>
#include <cstdio>
#include <string>

namespace nvmeof_raft {

/* ============================================================
 * persistCircular (raft.go 원본, 로직 그대로 포팅)
 *
 * "writes Raft metadata and new log entries directly to the NVMe-oF
 *  storage device, bypassing the filesystem layer entirely. Log entries
 *  are written via DirectWrite at the FIEMAP-resolved device PBA...
 *  Returns nvmeNs: total wall time spent inside O_DIRECT WriteAtFile +
 *  Fdatasync syscalls (the actual NVMe-oF traffic)."
 * ============================================================ */
int64_t Server::persist_circular(bool write_log, int n_new_entries,
                                 std::shared_ptr<ReplSink> sink) {
    /* [push 통합] 이 경로(헤더 쓰기가 필요한 호출)는 push 를 제출하지 않는다.
     * push 하지 않은 배치는 push_gate 가 false 를 돌려 기존 pull 경로로 가므로
     * 정확성은 유지되고, 성능 이득만 이 호출에서 빠진다. sink 는 헤더 선언과
     * 맞추기 위해 받기만 한다. */
    (void)sink;
    if (n_new_entries == 0 && write_log) {
        n_new_entries = static_cast<int>(raft.log.size()) - 1;
    }

    int64_t nvme_ns = 0;
    int flush_count = 0;

    if (write_log && n_new_entries > 0) {
        int start = static_cast<int>(raft.log.size()) - n_new_entries;
        if (start < 1) {
            start = 1;
        }

        size_t est_size = 0;
        for (int k = start; k < static_cast<int>(raft.log.size()); k++) {
            est_size += static_cast<size_t>(
                slots_for_entry(raft.log[static_cast<size_t>(k)].command.size())) * SECTOR_SIZE;
        }
        if (ring.run_buf.capacity() < est_size) {
            /* 원본: makeAlignedBlock(estSize)[:0]. AlignedBuffer는
             * posix_memalign 메모리를 복사 없이 그대로 소유하므로
             * O_DIRECT 정렬이 항상 유지됨 (std::vector 버그 수정) */
            ring.run_buf.resize(est_size, SECTOR_SIZE);
            ring.run_buf.clear();   /* capacity는 유지, size만 0 (Go의 [:0] 슬라이싱과 동일 의도) */
        }

        AlignedBuffer &run_buffer = ring.run_buf;   /* 원본 runBuf 별칭, s.runBuf[:0] 대응 */
        run_buffer.clear();
        int64_t run_off = 0;

        /* flushRun (원본 클로저 -> 람다)
         * "write the buffered runBuf to the metadata file at the current
         *  runOff via O_DIRECT WriteAtFile... One pwrite per flushRun
         *  call regardless of extent count" */
        auto flush_run = [&]() {
            if (run_buffer.empty()) {
                return;
            }
            auto t_io = clock_type::now();
            flush_count++;
            io.cached_fd->write_at_file(run_buffer.data(), run_buffer.size(), run_off);
            nvme_ns += elapsed_ns(t_io);
            run_off += static_cast<int64_t>(run_buffer.size());
            run_buffer.clear();
        };

        /* FIEMAP extent layout: contiguous fast-path bypass + per-entry
         * extent hint (원본 주석 그대로) */
        bool contiguous = io.cached_fd->is_contiguous();
        int ext_hint = 0;

        for (int i = start; i < static_cast<int>(raft.log.size()); i++) {
            uint64_t log_idx = ring.tail_log_index - static_cast<uint64_t>(raft.log.size() - static_cast<size_t>(i));
            const Entry &e = raft.log[static_cast<size_t>(i)];
            uint64_t needed = slots_for_entry(e.command.size());

            if (ring.tail_slot + needed > ring.ring_slots) {
                flush_run();
                ring.tail_slot = 0;
            }

            /* Per-entry extent skip (원본 주석 그대로)
             * "WriteAtFile can straddle FIEMAP extents on the persist
             *  side (kernel handles it), but the replication side
             *  cannot: each WritePBA carries one (PBA, length) tuple
             *  per source range, so an entry that spans two extents
             *  cannot be PBA-copied atomically." */
            if (!contiguous) {
                int64_t entry_off = slot_offset(ring.tail_slot);
                uint64_t entry_bytes = needed * SECTOR_SIZE;
                auto [rem, new_hint] = io.cached_fd->remaining_at(entry_off, ext_hint);
                ext_hint = new_hint;
                if (rem < entry_bytes) {
                    flush_run();
                    uint64_t skip_slots = rem / SECTOR_SIZE;
                    ring.tail_slot += skip_slots;
                    if (ring.tail_slot + needed > ring.ring_slots) {
                        ring.tail_slot = 0;
                    }
                    /* 건너뛴 뒤의 extent 힌트를 다시 잡는다. rem2는 쓰지
                     * 않지만 remaining_at은 힌트 갱신을 위해 불러야 한다. */
                    auto [rem2, hint2] = io.cached_fd->remaining_at(slot_offset(ring.tail_slot), ext_hint);
                    (void)rem2;
                    ext_hint = hint2;
                }
            }

            if (run_buffer.empty()) {
                run_off = slot_offset(ring.tail_slot);
            }

            size_t entry_bytes = static_cast<size_t>(needed) * SECTOR_SIZE;
            size_t off = run_buffer.size();
            run_buffer.grow_uninit(off + entry_bytes);
            uint8_t *region = run_buffer.data() + off;

            /* Entry 헤더 레이아웃 (raft.go 원본 그대로):
             *   [0:8)   Term
             *   [8:16)  cmdLen
             *   [16:24) needed (numSlots)
             *   [24:32) logIdx
             *   [32:..) Command 바이트 (ENTRY_META_SIZE = 32부터 시작) */
            put_u64_le(region + entry_hdr::kOffTerm, e.term);
            put_u64_le(region + entry_hdr::kOffCmdLen, e.command.size());
            put_u64_le(region + entry_hdr::kOffNumSlots, needed);
            put_u64_le(region + entry_hdr::kOffLogIndex, log_idx);
            if (!e.command.empty()) {
                /* no-op 엔트리는 command가 비어 있고 vector::data()가
                 * nullptr이다. memcpy(dst, nullptr, 0)은 형식상 UB라
                 * UBSan이 잡는다 (동작은 무해했음). */
                std::memcpy(region + ENTRY_META_SIZE, e.command.data(), e.command.size());
            }

            /* 원본 주석: "Zero only the trailing pad between
             * (header+command) and the slot boundary. Matches
             * goraft/raft.go:599-601 exactly... s.runBuf is reused...
             * without this clear stale tail bytes from prior calls
             * would leak onto the device." */
            size_t pad_start = ENTRY_META_SIZE + e.command.size();

            if (entry_bytes > pad_start) {
                std::memset(region + pad_start, 0, entry_bytes - pad_start);
            }

            uint64_t start_slot = ring.tail_slot;
            ring.tail_slot += needed;

            if (raft.state == ServerState::Leader) {
                ring.log_slot_map[log_idx] = SlotRecord{start_slot, needed, LogEntryState::Using};
                trace_slot_map('I', log_idx);
            }
        }

        /* flushRun -> pwrite + fdatasync (3. persistI/O) */
        flush_run();
        /* state는 엔트리별 logSlotMap insert 시점에 이미 설정되므로
         * 배치 후 markSlots 불필요 (원본 주석 그대로) */
    }

    /* conditional header write (원본 주석 그대로: "no calculate in
     * normal operation") */
    uint64_t cur_term = raft.current_term;
    uint64_t cur_vote = get_voted_for();
    bool write_header = !ring.persisted_init ||
                         cur_term != ring.persisted_term ||
                         cur_vote != ring.persisted_voted_for;

    if (write_header) {
        /* Aligned allocation: WriteAtFile은 O_DIRECT pwrite라 버퍼
         * 포인터가 섹터 정렬이어야 함 (원본 주석 그대로).
         * AlignedBuffer는 posix_memalign 메모리를 복사 없이 소유하므로
         * std::vector와 달리 정렬이 실제로 보장됨 */
        AlignedBuffer header(HEADER_SIZE, SECTOR_SIZE);

        /* File header layout (512B), 원본 주석 그대로:
         *   [ 0: 7] currentTerm
         *   [ 8:15] votedFor
         *   [16:23] tailLogIndex
         *   [24:31] tailSlot
         *   [32:39] commitIndex
         *   [40:47] lastApplied */
        put_u64_le(header.data() + file_hdr::kOffCurrentTerm, cur_term);
        put_u64_le(header.data() + file_hdr::kOffVotedFor, cur_vote);
        put_u64_le(header.data() + file_hdr::kOffTailLogIndex, ring.tail_log_index);
        put_u64_le(header.data() + file_hdr::kOffTailSlot, ring.tail_slot);
        put_u64_le(header.data() + file_hdr::kOffCommitIndex, raft.commit_index);
        put_u64_le(header.data() + file_hdr::kOffLastApplied, raft.last_applied);

        /* Header lives at logical offset 0 (RING_OFFSET == HEADER_SIZE
         * -- ring slot 0은 헤더 다음부터 시작, 원본 주석 그대로) */
        auto t_hdr_io = clock_type::now();
        io.cached_fd->write_at_file(header.data(), header.size(), 0);
        nvme_ns += elapsed_ns(t_hdr_io);   /* header 작성 시 writeI/O에 추가 */

        ring.persisted_init = true;
        ring.persisted_term = cur_term;
        ring.persisted_voted_for = cur_vote;
    }

    if ((write_log && n_new_entries > 0) || write_header) {
        /* 3-2. fdatasync */
        auto t_sync_io = clock_type::now();
        io.cached_fd->fdatasync();
        nvme_ns += elapsed_ns(t_sync_io);
    }

    return nvme_ns;
}

/* persist_circular의 "로그 쓰기" 부분과 인코딩/슬롯 로직은 그대로 두고, 디스크 I/O만 뒤로 미룬다.
 * flush_run이 하던 일(pwrite 한 번)은 쓸 목록(PersistWrite)에 기록만 하고, 실제 pwrite와 fdatasync는
 * persist_io가 한다. run_buf는 구간마다 비우지 않고 배치 전체를 이어 붙인다.
 * ============================================================ */
void Server::wait_persist_idle_locked() {
    if (!persist_inflight) {
        return;
    }
    /* 호출자가 어떤 방식(raw lock, lock_guard, unique_lock)으로 mu를 쥐었든 소유권은 그대로 두고
     * 이 함수 안에서만 조건변수 대기에 쓴다 (adopt_lock으로 감싸고 release로 풀어 준다). */
    std::unique_lock<std::mutex> ul(mu, std::adopt_lock);
    persist_cv.wait(ul, [&] { return !persist_inflight; });
    ul.release();
}

bool Server::persist_needs_header() {
    return !ring.persisted_init ||
           raft.current_term != ring.persisted_term ||
           get_voted_for() != ring.persisted_voted_for;
}

Server::PersistPlan Server::persist_prepare_locked(int n_new_entries,
                                                     std::shared_ptr<ReplSink> sink) {
    PersistPlan plan;
    if (n_new_entries <= 0) {
        return plan;
    }

    int start = static_cast<int>(raft.log.size()) - n_new_entries;
    if (start < 1) {
        start = 1;
    }

    size_t est_size = 0;
    for (int k = start; k < static_cast<int>(raft.log.size()); k++) {
        est_size += static_cast<size_t>(
            slots_for_entry(raft.log[static_cast<size_t>(k)].command.size())) * SECTOR_SIZE;
    }
    /* [push 통합 1] push 대상과 이번 호출이 쓰는 로그 인덱스 구간.
     * 아래 루프의 log_idx 와 같은 식이다 (i = start 일 때가 push_first,
     * 마지막 엔트리가 push_last). prepare 시점에 tail_log_index 는 이미 새
     * 엔트리를 포함한다. push_write_targets 는 이 노드가 push 모드의 리더가
     * 아니면 빈 목록을 돌려준다 (팔로워 경로는 영향 없음). */
    const std::vector<int> push_fis = push_write_targets(clock_type::now());
    const uint64_t push_first =
        ring.tail_log_index - static_cast<uint64_t>(raft.log.size() - static_cast<size_t>(start));
    const uint64_t push_last = ring.tail_log_index - 1;

    /* [push 통합 2] push 대상이 있으면 ring.run_buf 대신 공유 버퍼 풀의 버퍼에
     * 인코딩한다. push job 은 persist_io 가 끝난 뒤에도 이 버퍼를 읽는데,
     * ring.run_buf 는 다음 묶음이 곧바로 덮어쓰기 때문이다. 대상이 없으면
     * 기존과 똑같이 ring.run_buf 를 쓴다 (동작 불변). */
    std::shared_ptr<AlignedBuffer> push_buf;
    if (!push_fis.empty()) {
        push_buf = acquire_push_buffer(est_size);
    } else if (ring.run_buf.capacity() < est_size) {
        ring.run_buf.resize(est_size, SECTOR_SIZE);
        ring.run_buf.clear();
    }
    plan.push_buf = push_buf;   /* persist_io 가 어느 버퍼에서 쓸지 알려 준다 */

    AlignedBuffer &run_buffer = push_buf ? *push_buf : ring.run_buf;
    run_buffer.clear();
    int64_t write_dev_off = 0;
    size_t write_buf_start = 0;

    /* 지금까지 쌓인 구간을 목록에 확정한다 (원래 flush_run의 pwrite 자리) */
    auto end_write = [&]() {
        const size_t len = run_buffer.size() - write_buf_start;
        if (len == 0) {
            return;
        }
        plan.writes.push_back(PersistWrite{write_dev_off, write_buf_start, len});
        write_buf_start = run_buffer.size();
    };

    bool contiguous = io.cached_fd->is_contiguous();
    int ext_hint = 0;

    for (int i = start; i < static_cast<int>(raft.log.size()); i++) {
        uint64_t log_idx = ring.tail_log_index - static_cast<uint64_t>(raft.log.size() - static_cast<size_t>(i));
        const Entry &e = raft.log[static_cast<size_t>(i)];
        uint64_t needed = slots_for_entry(e.command.size());

        if (ring.tail_slot + needed > ring.ring_slots) {
            end_write();
            ring.tail_slot = 0;
        }

        if (!contiguous) {
            int64_t entry_off = slot_offset(ring.tail_slot);
            uint64_t entry_bytes = needed * SECTOR_SIZE;
            auto [rem, new_hint] = io.cached_fd->remaining_at(entry_off, ext_hint);
            ext_hint = new_hint;
            if (rem < entry_bytes) {
                end_write();
                uint64_t skip_slots = rem / SECTOR_SIZE;
                ring.tail_slot += skip_slots;
                if (ring.tail_slot + needed > ring.ring_slots) {
                    ring.tail_slot = 0;
                }
                auto [rem2, hint2] = io.cached_fd->remaining_at(slot_offset(ring.tail_slot), ext_hint);
                (void)rem2;
                ext_hint = hint2;
            }
        }

        if (run_buffer.size() == write_buf_start) {
            write_dev_off = slot_offset(ring.tail_slot);
        }

        size_t entry_bytes = static_cast<size_t>(needed) * SECTOR_SIZE;
        size_t off = run_buffer.size();
        run_buffer.grow_uninit(off + entry_bytes);
        uint8_t *region = run_buffer.data() + off;

        put_u64_le(region + entry_hdr::kOffTerm, e.term);
        put_u64_le(region + entry_hdr::kOffCmdLen, e.command.size());
        put_u64_le(region + entry_hdr::kOffNumSlots, needed);
        put_u64_le(region + entry_hdr::kOffLogIndex, log_idx);
        if (!e.command.empty()) {
            std::memcpy(region + ENTRY_META_SIZE, e.command.data(), e.command.size());
        }

        size_t pad_start = ENTRY_META_SIZE + e.command.size();
        if (entry_bytes > pad_start) {
            std::memset(region + pad_start, 0, entry_bytes - pad_start);
        }

        uint64_t start_slot = ring.tail_slot;
        ring.tail_slot += needed;

        if (raft.state == ServerState::Leader) {
            ring.log_slot_map[log_idx] = SlotRecord{start_slot, needed, LogEntryState::Using};
            trace_slot_map('I', log_idx);
        }
    }

    end_write();

    /* [push 통합 3] 대상마다 job 하나를 맡긴다 (mu 보유 중).
     * 여기서 시작시켜야 leader 자신의 persist_io (mu 밖, 이 함수 반환 뒤)와
     * follower 쪽 쓰기가 겹친다. job 은 모든 run 을 쓰고 flush 한 뒤 결과를
     * 기록하고 그 대상의 AE 워커를 깨운다. 기다리지 않는다.
     * run 은 plan.writes 와 같은 (논리 오프셋 dev_off, 버퍼 위치 buf_off, 길이)다. */
    if (push_buf && !plan.writes.empty()) {
        for (int fi : push_fis) {
            const size_t i = static_cast<size_t>(fi);
            IoWorker *w = push_worker(fi);
            std::shared_ptr<CachedFD> pfd = (i < io.push_fds.size()) ? io.push_fds[i] : nullptr;
            /* 맡길 때의 세대 번호. 그 사이 구간이 비워지면(롤백, 리더 교체, 링 교체,
             * 실패) 끝났을 때 결과를 버린다 */
            const uint64_t epoch = raft.cluster[i].push_epoch;
            bool queued = false;
            if (w != nullptr && pfd != nullptr) {
                std::vector<PersistWrite> runs = plan.writes;   /* job 이 값으로 들고 간다 */
                queued = w->submit([this, fi, pfd, push_buf, runs, epoch, push_first, push_last, sink]() {
                    /* IoWorker 스레드, mu 없이. */
                    std::string err;
                    try {
                        for (const PersistWrite &r : runs) {
                            pfd->write_at_logical(push_buf->data() + r.buf_off, r.len, r.dev_off);
                        }
                        /* 블록 장치 flush 까지 끝나야 "팔로워 볼륨에 내구성 있게 있다" */
                        pfd->fdatasync_device();
                    } catch (const std::exception &e) {
                        err = e.what();
                    }
                    /* sink: 묶음 대표 요청의 측정 상자. 측정하지 않는 호출은 nullptr.
                     * push 가 끝난 시각을 여기 남기고 그 대상의 AE 워커를 깨울 때 같은 상자를 넘긴다. */
                    finish_push_job(fi, epoch, push_first, push_last, err, sink);
                });
            }
            if (queued) {
                note_push_submitted(fi, push_first, push_last);
            } else {
                /* 워커가 없거나 큐가 꽉 찼다 -> 한동안 쉬고 그동안은 pull 로 간다 */
                note_push_failure(fi, (w == nullptr || pfd == nullptr)
                                          ? "no push worker" : "push queue full");
            }
        }
    }
    return plan;
}

int64_t Server::persist_io(const PersistPlan &plan) {
    int64_t nvme_ns = 0;
    /* prepare 가 push 버퍼에 인코딩했으면 그 버퍼에서, 아니면 ring.run_buf 에서 쓴다 */
    AlignedBuffer &buf = plan.push_buf ? *plan.push_buf : ring.run_buf;
    for (const PersistWrite &w : plan.writes) {
        auto t_io = clock_type::now();
        io.cached_fd->write_at_file(buf.data() + w.buf_off, w.len, w.dev_off);
        nvme_ns += elapsed_ns(t_io);
    }
    if (!plan.writes.empty()) {
        auto t_sync = clock_type::now();
        io.cached_fd->fdatasync();
        nvme_ns += elapsed_ns(t_sync);
    }
    return nvme_ns;
}

/* [push 통합 4] jongc 에서 그대로 가져온 버퍼 풀 (mu 보유 중 호출) */
std::shared_ptr<AlignedBuffer> Server::acquire_push_buffer(size_t capacity) {
    for (auto &b : ring.push_bufs) {
        /* 풀만 들고 있다 = 이 버퍼를 읽는 push job이 없다 */
        if (b.use_count() == 1) {
            /* use_count()는 relaxed로 읽힌다. job이 참조를 놓은 것(release)과
             * 짝을 맞춰, job의 읽기가 아래 덮어쓰기보다 먼저 끝났음을 보장한다 */
            std::atomic_thread_fence(std::memory_order_acquire);
            if (b->capacity() < capacity) {
                b->resize(capacity, SECTOR_SIZE);
            }
            b->clear();
            return b;
        }
    }
    auto b = std::make_shared<AlignedBuffer>(capacity, SECTOR_SIZE);
    b->clear();
    ring.push_bufs.push_back(b);
    return b;
}

} /* namespace nvmeof_raft */