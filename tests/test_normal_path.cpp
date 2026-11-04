/* ============================================================
 * 정상경로(ReplicationMode::Normal) 단위 테스트 -- DECISIONS.md D22
 *
 * 정상경로의 핵심 계약은 "팔로워가 직접 쓴 링 바이트가 리더의 persist와
 * 같다"이다. 그래야 승격 시 deferred 로드(read_entry_direct)가 PBA로 복사된
 * 링과 똑같이 읽는다. 그래서 같은 엔트리를
 *   - 리더 쪽: persist_circular(true, n)
 *   - 팔로워 쪽: handle_append_entries_request(inline_entries)
 * 로 각자 링 파일에 쓰게 하고 바이트 단위로 비교한다.
 *
 * read_entry_direct 자체는 FIEMAP 물리 주소로 블록 장치를 읽으므로 /tmp의
 * 가짜 장치 파일로는 검증할 수 없다 -- 그 경로(승격 후 로드, 리더의 링 읽기)는
 * 실클러스터 e2e가 담당한다.
 * ============================================================ */
#include "third_party/doctest.h"

#include "raft_server.h"
#include "raft_constants.h"
#include "cached_fd.h"

#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace nvmeof_raft;

namespace {

struct RingFixture {
    std::string dir, meta, dev;
    std::unique_ptr<Server> s;

    RingFixture(const char *tag, ServerState state) {
        char tmpl[] = "/tmp/normal_path_XXXXXX";
        REQUIRE(::mkdtemp(tmpl) != nullptr);
        dir = tmpl;
        meta = dir + "/" + tag + ".ring";
        dev = dir + "/" + tag + ".dev";

        s = std::make_unique<Server>();
        s->ring.configure(64);
        uint64_t want = s->ring.file_size_bytes();
        create_ring_file(meta, want);
        {
            FILE *f = std::fopen(dev.c_str(), "wb");
            REQUIRE(f != nullptr);
            std::fclose(f);
            REQUIRE(::truncate(dev.c_str(), static_cast<off_t>(want)) == 0);
        }
        auto cfd = std::make_shared<CachedFD>(CachedFD::open(meta, dev));
        /* 단일 extent로 고정한다. /tmp 파일이 여러 extent로 나뉘면 리더 persist가
         * 경계에서 슬롯을 건너뛰는데, 실제 리더는 그 지점에서 AE 배치를 끊는다
         * (append_entries_worker의 extent clamp). 이 테스트는 그 clamp를 거치지
         * 않고 배치를 만들므로, 건너뛰기가 생기지 않는 배치로 고정해 둔다. */
        cfd->set_extents(ExtentCache::from_extents({Extent{0, 1u << 20, want}}));
        s->io.cached_fd = cfd;

        s->raft.id = 1;
        s->raft.cluster.resize(3);
        for (size_t i = 0; i < 3; i++) s->raft.cluster[i].id = static_cast<uint64_t>(i + 1);
        s->raft.cluster_index = 0;
        s->raft.state = state;
        s->raft.current_term = 3;
        s->raft.heartbeat_ms = 100;   /* reset_election_timeout의 난수 범위 */
        s->ring.persisted_init = true;
        s->ring.persisted_term = 3;
        s->ring.persisted_voted_for = s->get_voted_for();
        s->raft.log.clear();
        s->raft.log.push_back(Entry{});   /* sentinel */
        s->ring.tail_log_index = 1;
        s->replication_mode = Server::ReplicationMode::Normal;
    }
    ~RingFixture() {
        s.reset();
        std::remove(meta.c_str());
        std::remove(dev.c_str());
        ::rmdir(dir.c_str());
    }
    std::vector<uint8_t> ring_bytes() const {
        const size_t sz = static_cast<size_t>(s->ring.file_size_bytes());
        return s->io.cached_fd->read_at_file(sz, 0);
    }
};

std::vector<uint8_t> make_cmd(size_t sz, size_t seed) {
    std::vector<uint8_t> c(sz);
    for (size_t k = 0; k < sz; k++) c[k] = static_cast<uint8_t>(k * 31 + seed);
    return c;
}

/* 경계 크기 섞기 (D13 / selftest T1과 같은 값) */
const std::vector<size_t> kSizes = {0, 1, 479, 480, 481, 512, 4064, 4065, 9000};

/* 리더 로그에 엔트리를 붙이고 persist한 뒤, 같은 엔트리를 실은 inline AE 요청을 만든다 */
AppendEntriesRequest leader_persist_and_build(RingFixture &L, uint64_t prev, size_t first,
                                              size_t count) {
    const uint64_t start_slot = L.s->ring.tail_slot;
    for (size_t i = first; i < first + count; i++) {
        Entry e;
        e.term = 3;
        e.command = make_cmd(kSizes[i % kSizes.size()], i);
        L.s->raft.log.push_back(std::move(e));
        L.s->ring.tail_log_index++;
    }
    L.s->persist_circular(true, static_cast<int>(count));

    AppendEntriesRequest req;
    req.rpc.term = 3;
    req.leader_id = 1;
    req.prev_log_index = prev;
    req.prev_log_term = prev == 0 ? 0 : 3;
    req.num_entries = count;
    req.start_slot = start_slot;
    req.inline_entries = true;
    req.entry_metas = L.s->build_entry_metas_locked(prev + 1, count, /*with_payload=*/true);
    return req;
}

}  /* namespace */

TEST_CASE("build_entry_metas_locked: 블록 복사 모드는 명령을 싣지 않고 정상경로는 싣는다") {
    RingFixture L("meta", ServerState::Leader);
    for (size_t i = 0; i < 3; i++) {
        Entry e;
        e.term = 3;
        e.command = make_cmd(kSizes[i + 1], i);
        L.s->raft.log.push_back(std::move(e));
        L.s->ring.tail_log_index++;
    }
    Entry noop;
    noop.term = 3;
    L.s->raft.log.push_back(std::move(noop));
    L.s->ring.tail_log_index++;

    auto pba = L.s->build_entry_metas_locked(1, 4, false);
    auto inl = L.s->build_entry_metas_locked(1, 4, true);
    REQUIRE(pba.size() == 4);
    REQUIRE(inl.size() == 4);
    for (size_t i = 0; i < 3; i++) {
        CHECK(pba[i].command.empty());
        CHECK(pba[i].cmd_len == kSizes[i + 1]);
        CHECK(inl[i].command == make_cmd(kSizes[i + 1], i));
        CHECK(inl[i].cmd_len == kSizes[i + 1]);
        CHECK(inl[i].term == 3);
    }
    CHECK(inl[3].command.empty());   /* no-op */
    CHECK(inl[3].cmd_len == 0);
}

TEST_CASE("정상경로: 팔로워가 직접 쓴 링 바이트가 리더 persist와 같다") {
    RingFixture L("leader", ServerState::Leader);
    RingFixture F("follower", ServerState::Follower);

    AppendEntriesRequest req = leader_persist_and_build(L, 0, 0, kSizes.size());
    AppendEntriesResponse rsp;
    F.s->handle_append_entries_request(req, rsp);

    REQUIRE(rsp.success);
    CHECK(rsp.storage_copy_ns > 0);   /* 로컬 pwrite + fdatasync 시간을 보고한다 */
    CHECK(F.s->ring.tail_slot == L.s->ring.tail_slot);
    CHECK(F.s->ring.tail_log_index == L.s->ring.tail_log_index);
    CHECK(F.ring_bytes() == L.ring_bytes());

    /* in-memory 로그는 destination 경로와 같은 deferred 엔트리다 */
    REQUIRE(F.s->raft.log.size() == 1 + kSizes.size());
    for (size_t i = 1; i < F.s->raft.log.size(); i++) {
        const Entry &e = F.s->raft.log[i];
        CHECK(e.term == 3);
        CHECK(e.cmd_len == kSizes[(i - 1) % kSizes.size()]);
        CHECK(e.ring_slot == L.s->ring.log_slot_map[i].start);
    }
}

TEST_CASE("정상경로: 슬롯 0에 놓인 엔트리는 명령을 메모리에 남긴다") {
    RingFixture L("leader0", ServerState::Leader);
    RingFixture F("follower0", ServerState::Follower);

    AppendEntriesRequest req = leader_persist_and_build(L, 0, 1, 2);   /* 크기 1, 479 */
    REQUIRE(req.start_slot == 0);
    AppendEntriesResponse rsp;
    F.s->handle_append_entries_request(req, rsp);
    REQUIRE(rsp.success);

    const Entry &first = F.s->raft.log[1];
    CHECK(first.ring_slot == 0);
    CHECK(first.command == make_cmd(kSizes[1], 1));   /* 비우면 승격 때 빈 명령으로 apply된다 */
    const Entry &second = F.s->raft.log[2];
    CHECK(second.ring_slot != 0);
    CHECK(second.command.empty());                     /* 나머지는 deferred */
}

TEST_CASE("정상경로: 이미 가진 앞부분은 건너뛰되 슬롯은 전진한다 (D11)") {
    RingFixture L("leaderS", ServerState::Leader);
    RingFixture F("followerS", ServerState::Follower);

    /* 1차: 엔트리 1..3 */
    AppendEntriesRequest r1 = leader_persist_and_build(L, 0, 2, 3);
    AppendEntriesResponse rsp1;
    F.s->handle_append_entries_request(r1, rsp1);
    REQUIRE(rsp1.success);

    /* 2차: 리더가 2..5를 다시 보낸다 (팔로워는 2,3을 이미 가짐) */
    leader_persist_and_build(L, 3, 5, 2);   /* 리더 로그에 4,5 추가 */
    AppendEntriesRequest r2;
    r2.rpc.term = 3;
    r2.leader_id = 1;
    r2.prev_log_index = 1;
    r2.prev_log_term = 3;
    r2.num_entries = 4;
    r2.start_slot = L.s->ring.log_slot_map[2].start;
    r2.inline_entries = true;
    r2.entry_metas = L.s->build_entry_metas_locked(2, 4, true);

    AppendEntriesResponse rsp2;
    F.s->handle_append_entries_request(r2, rsp2);
    REQUIRE(rsp2.success);

    CHECK(F.s->raft.log.size() == 6);   /* sentinel + 1..5, 중복 없음 */
    CHECK(F.s->ring.tail_log_index == 6);
    CHECK(F.s->ring.tail_slot == L.s->ring.tail_slot);
    CHECK(F.s->raft.log[4].ring_slot == L.s->ring.log_slot_map[4].start);
    CHECK(F.s->raft.log[5].ring_slot == L.s->ring.log_slot_map[5].start);
    CHECK(F.ring_bytes() == L.ring_bytes());
}

TEST_CASE("persist_follower_entries: 링 끝을 넘는 배치는 거절한다") {
    RingFixture F("followerW", ServerState::Follower);
    AppendEntriesRequest req;
    req.inline_entries = true;
    req.num_entries = 1;
    EntryMeta m;
    m.term = 3;
    m.command = make_cmd(4000, 0);   /* 8 슬롯 */
    m.cmd_len = m.command.size();
    req.entry_metas.push_back(m);
    CHECK_THROWS(F.s->persist_follower_entries(F.s->ring.ring_slots - 2, req));
}
