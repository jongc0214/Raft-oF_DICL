#pragma once
/* ============================================================
 * raft_cpu_affinity.h -- 스토리지 I/O 를 하는 스레드를 정해진 CPU 에 고정한다.
 *
 * 왜 (2026-11-08 측정):
 *   NVMe-oF 쓰기는 **보내는 스레드가 그 순간 있는 CPU** 의 큐(hctx)로 나간다.
 *   큐마다 스토리지 쪽 nvmet-rdma 큐가 따로 있고, 그 완료 IRQ 가 스토리지의
 *   반대 소켓 CPU 에 걸려 있으면 1MiB 쓰기가 ~75us 느리다 (745 vs 830us).
 *   어느 CPU 에서 persist 하느냐에 따라 LPersist/StorageIO 가 실행마다 갈렸다.
 *   빠른 큐의 CPU 는 scripts/probe_io_queues.sh 가 찾는다.
 *
 * 쓰는 곳:
 *   - io_cpus (StorageIo): raft RPC 를 처리하는 연결 스레드. 리더의 Apply ->
 *     persist_io 와 normal 팔로워의 persist_follower_entries 가 이 스레드에서
 *     돈다. dispatch_raft_method 가 스레드마다 첫 RPC 에서 한 번 고정한다.
 *   - push_cpus (ClusterMember): 그 멤버 볼륨에 쓰는 push IoWorker.
 *   비어 있으면 고정하지 않는다 (예전 동작 그대로).
 * ============================================================ */
#include <pthread.h>
#include <sched.h>

#include <cerrno>
#include <cstdlib>
#include <string>
#include <vector>

namespace nvmeof_raft {

/* "9,22,25-29" -> {9,22,25,26,27,28,29}. 형식이 틀리면 false. */
inline bool parse_cpu_list(const std::string &s, std::vector<int> *out) {
    out->clear();
    size_t i = 0;
    while (i < s.size()) {
        size_t j = s.find(',', i);
        if (j == std::string::npos) { j = s.size(); }
        std::string item = s.substr(i, j - i);
        i = j + 1;
        if (item.empty()) { continue; }
        size_t dash = item.find('-');
        char *end = nullptr;
        long a = std::strtol(item.c_str(), &end, 10);
        long b = a;
        if (dash == std::string::npos) {
            if (*end != '\0') { return false; }
        } else {
            if (end != item.c_str() + dash) { return false; }
            const char *bs = item.c_str() + dash + 1;
            b = std::strtol(bs, &end, 10);
            if (end == bs || *end != '\0') { return false; }
        }
        if (a < 0 || b < a || b >= CPU_SETSIZE) { return false; }
        for (long c = a; c <= b; c++) { out->push_back(static_cast<int>(c)); }
    }
    return !out->empty();
}

inline std::string format_cpu_list(const std::vector<int> &cpus) {
    std::string r;
    for (int c : cpus) {
        if (!r.empty()) { r += ","; }
        r += std::to_string(c);
    }
    return r;
}

/* 호출한 스레드를 cpus 에 고정한다. 성공 0, 실패 errno. cpus 가 비면 아무것도 하지 않는다. */
inline int pin_current_thread(const std::vector<int> &cpus) {
    if (cpus.empty()) { return 0; }
    cpu_set_t set;
    CPU_ZERO(&set);
    for (int c : cpus) { CPU_SET(c, &set); }
    return pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}

}  /* namespace nvmeof_raft */
