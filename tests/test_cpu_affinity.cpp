/* raft_cpu_affinity.h -- -io-cpus / -push-cpus 목록 해석과 스레드 고정 */
#include "third_party/doctest.h"

#include "raft_cpu_affinity.h"

#include <thread>

using namespace nvmeof_raft;

TEST_CASE("parse_cpu_list: 쉼표와 범위") {
    std::vector<int> v;
    REQUIRE(parse_cpu_list("9,22,25-29", &v));
    CHECK(v == std::vector<int>{9, 22, 25, 26, 27, 28, 29});
    CHECK(format_cpu_list(v) == "9,22,25,26,27,28,29");
    REQUIRE(parse_cpu_list("0", &v));
    CHECK(v == std::vector<int>{0});
}

TEST_CASE("parse_cpu_list: 틀린 형식은 거절") {
    std::vector<int> v;
    CHECK_FALSE(parse_cpu_list("", &v));
    CHECK_FALSE(parse_cpu_list("a", &v));
    CHECK_FALSE(parse_cpu_list("3-1", &v));
    CHECK_FALSE(parse_cpu_list("1-", &v));
    CHECK_FALSE(parse_cpu_list("-1", &v));
    CHECK_FALSE(parse_cpu_list("1x", &v));
    CHECK_FALSE(parse_cpu_list("99999", &v));
}

TEST_CASE("pin_current_thread: 고정하면 그 CPU 에서 돈다") {
    CHECK(pin_current_thread({}) == 0);   /* 비면 아무것도 안 함 */
    int cpu_seen = -1;
    std::thread t([&]() {
        if (pin_current_thread({0}) == 0) { cpu_seen = sched_getcpu(); }
    });
    t.join();
    CHECK(cpu_seen == 0);
}
