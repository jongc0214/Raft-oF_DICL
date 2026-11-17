/* ============================================================
 * TCP 프레이밍(net/src/raft_wire_codec.cpp) 단위 테스트
 *
 * socketpair 위에서 WireReader(수신 버퍼 + 스핀 대기), wire_writev_all,
 * Client/Server 코덱의 왕복을 확인한다. 와이어 포맷은 바뀌지 않아야 하므로
 * 바이트를 직접 써서 코덱이 읽는지도 본다.
 *
 * raft_wire_codec.cpp 는 core 도 protobuf 도 모르므로 소스를 그대로 넣어도
 * isolation_raft_unit_tests 가 유지된다.
 * ============================================================ */
#include "third_party/doctest.h"

#include "raft_wire_codec.h"

#include <chrono>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

using namespace nvmeof_raft;

namespace {

struct SockPair {
    int a = -1, b = -1;
    SockPair() {
        int sv[2];
        REQUIRE(::socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
        a = sv[0]; b = sv[1];
    }
    ~SockPair() {
        if (a >= 0) ::close(a);
        if (b >= 0) ::close(b);
    }
    void close_a() { ::close(a); a = -1; }
};

void write_raw(int fd, const std::vector<uint8_t> &v) {
    wire_write_all(fd, v.data(), v.size());
}

/* 요청 프레임을 손으로 만든다: [mlen 2][method][seq 8][body_len 4][body] */
std::vector<uint8_t> make_request(const std::string &m, uint64_t seq, const std::vector<uint8_t> &body) {
    std::vector<uint8_t> out;
    uint16_t ml = htons(static_cast<uint16_t>(m.size()));
    out.insert(out.end(), reinterpret_cast<uint8_t *>(&ml), reinterpret_cast<uint8_t *>(&ml) + 2);
    out.insert(out.end(), m.begin(), m.end());
    uint64_t s = wire_htobe64(seq);
    out.insert(out.end(), reinterpret_cast<uint8_t *>(&s), reinterpret_cast<uint8_t *>(&s) + 8);
    uint32_t bl = htonl(static_cast<uint32_t>(body.size()));
    out.insert(out.end(), reinterpret_cast<uint8_t *>(&bl), reinterpret_cast<uint8_t *>(&bl) + 4);
    out.insert(out.end(), body.begin(), body.end());
    return out;
}

std::vector<uint8_t> pattern(size_t n, uint8_t seed) {
    std::vector<uint8_t> v(n);
    for (size_t i = 0; i < n; ++i) v[i] = static_cast<uint8_t>(seed + i * 7);
    return v;
}

}  /* namespace */

TEST_CASE("wire_writev_all: 부분 쓰기에서도 iov 전체를 순서대로 보낸다") {
    SockPair sp;
    /* 송신 버퍼를 작게 해서 writev 가 여러 번 부분 쓰기를 하게 만든다 */
    int small = 4096;
    ::setsockopt(sp.a, SOL_SOCKET, SO_SNDBUF, &small, sizeof(small));

    std::vector<uint8_t> h = pattern(13, 1), body = pattern(512 * 1024, 9);
    std::vector<uint8_t> got(h.size() + body.size());
    std::thread rd([&] {
        WireReader r(sp.b, 0);
        r.read_exact(got.data(), got.size());
    });
    struct iovec iov[3];
    iov[0] = {h.data(), h.size()};
    iov[1] = {nullptr, 0};                       /* 빈 구간은 건너뛴다 */
    iov[2] = {body.data(), body.size()};
    wire_writev_all(sp.a, iov, 3);
    rd.join();

    CHECK(std::memcmp(got.data(), h.data(), h.size()) == 0);
    CHECK(std::memcmp(got.data() + h.size(), body.data(), body.size()) == 0);
}

TEST_CASE("WireReader: 작은 프레임 여러 개가 recv 한 번에 온다") {
    SockPair sp;
    std::vector<uint8_t> all;
    for (int i = 0; i < 3; ++i) {
        auto f = make_request("Raft.AppendEntries", 100 + i, pattern(200, static_cast<uint8_t>(i)));
        all.insert(all.end(), f.begin(), f.end());
    }
    write_raw(sp.a, all);

    WireServerCodec srv(sp.b);
    for (int i = 0; i < 3; ++i) {
        auto hdr = srv.read_request_header();
        auto body = srv.read_request_body();
        CHECK(hdr.service_method == "Raft.AppendEntries");
        CHECK(hdr.seq == static_cast<uint64_t>(100 + i));
        CHECK(body == pattern(200, static_cast<uint8_t>(i)));
    }
    /* 세 프레임(<64KiB)이 이미 소켓에 있었으므로 recv 한 번이면 된다 (예전에는 15번) */
    CHECK(srv.reader().recv_calls() == 1);
    CHECK(srv.reader().buffered() == 0);
}

TEST_CASE("WireReader: 1바이트씩 쪼개 와도 프레임을 맞게 읽는다") {
    SockPair sp;
    auto f = make_request("BlockCopy.Copy", 7, pattern(300, 3));
    std::thread wr([&] {
        for (uint8_t c : f) {
            wire_write_all(sp.a, &c, 1);
            std::this_thread::sleep_for(std::chrono::microseconds(20));
        }
    });
    WireServerCodec srv(sp.b);
    auto hdr = srv.read_request_header();
    auto body = srv.read_request_body();
    wr.join();
    CHECK(hdr.service_method == "BlockCopy.Copy");
    CHECK(hdr.seq == 7);
    CHECK(body == pattern(300, 3));
}

TEST_CASE("WireReader: 64KiB 보다 큰 body 는 목적지로 직접 받는다") {
    SockPair sp;
    const size_t n = 4 * 1024 * 1024 + 123;
    auto body = pattern(n, 5);
    auto f = make_request("Raft.AppendEntries", 1, body);
    std::thread wr([&] { write_raw(sp.a, f); });

    WireServerCodec srv(sp.b);
    auto hdr = srv.read_request_header();
    auto got = srv.read_request_body();
    wr.join();
    CHECK(hdr.seq == 1);
    REQUIRE(got.size() == n);
    CHECK(got == body);
    CHECK(srv.reader().buffered() == 0);
}

TEST_CASE("코덱 왕복: 요청 -> 응답, 에러 응답, 빈 body") {
    SockPair sp;
    WireClientCodec cli(sp.a);
    WireServerCodec srv(sp.b);

    std::thread server([&] {
        for (int i = 0; i < 3; ++i) {
            auto hdr = srv.read_request_header();
            auto body = srv.read_request_body();
            if (hdr.service_method == "X.Fail") {
                srv.write_response(hdr.seq, "boom", {});
            } else if (hdr.service_method == "X.Empty") {
                srv.write_response(hdr.seq, "", {});
            } else {
                std::vector<uint8_t> rsp(body.rbegin(), body.rend());
                srv.write_response(hdr.seq, "", rsp);
            }
        }
    });

    auto req = pattern(70000, 2);
    cli.write_request("X.Echo", 11, req);
    auto h1 = cli.read_response_header();
    auto b1 = cli.read_response_body();
    CHECK(h1.seq == 11);
    CHECK(h1.service_method == "X.Echo");
    CHECK(h1.error.empty());
    CHECK(b1 == std::vector<uint8_t>(req.rbegin(), req.rend()));

    cli.write_request("X.Fail", 12, {1, 2, 3});
    auto h2 = cli.read_response_header();
    auto b2 = cli.read_response_body();
    CHECK(h2.seq == 12);
    CHECK(h2.error == "boom");
    CHECK(b2.empty());

    cli.write_request("X.Empty", 13, {});
    auto h3 = cli.read_response_header();
    CHECK(h3.seq == 13);
    CHECK(cli.read_response_body().empty());

    server.join();
}

TEST_CASE("WireReader: 연결 종료는 예외 (스핀 무한/유계/없음 모두)") {
    for (int spin : {-1, 2000, 0}) {
        CAPTURE(spin);
        SockPair sp;
        std::thread closer([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
            sp.close_a();
        });
        WireReader r(sp.b, spin);
        uint8_t x[4];
        CHECK_THROWS(r.read_exact(x, 4));
        closer.join();
    }
}

TEST_CASE("WireReader: 유계 스핀은 예산 뒤 블로킹으로 내려가 SO_RCVTIMEO 를 따른다") {
    SockPair sp;
    struct timeval tv{};
    tv.tv_usec = 50 * 1000;    /* 50ms */
    ::setsockopt(sp.b, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    WireReader r(sp.b, 2000);
    uint8_t x[4];
    auto t0 = std::chrono::steady_clock::now();
    CHECK_THROWS(r.read_exact(x, 4));
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                  std::chrono::steady_clock::now() - t0).count();
    CHECK(ms >= 40);           /* 2ms 스핀 + 50ms 블로킹 타임아웃 */
    CHECK(ms < 2000);
}

TEST_CASE("WireReader: 유계 스핀 예산 뒤 늦게 온 데이터도 블로킹에서 받는다") {
    SockPair sp;
    std::thread wr([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));   /* 2ms 예산보다 늦게 */
        write_raw(sp.a, {1, 2, 3, 4});
    });
    WireReader r(sp.b, 2000);
    uint8_t x[4] = {0};
    r.read_exact(x, 4);
    wr.join();
    CHECK(x[0] == 1);
    CHECK(x[3] == 4);
}

TEST_CASE("WireReader: 무한 스핀은 SO_RCVTIMEO 와 무관하게 데이터를 기다린다") {
    SockPair sp;
    struct timeval tv{};
    tv.tv_usec = 5 * 1000;     /* 블로킹이었다면 5ms 에 타임아웃 */
    ::setsockopt(sp.b, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    std::thread wr([&] {
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        write_raw(sp.a, {9, 8});
    });
    WireReader r(sp.b, -1);
    uint8_t x[2] = {0};
    r.read_exact(x, 2);
    wr.join();
    CHECK(x[0] == 9);
    CHECK(x[1] == 8);
}
