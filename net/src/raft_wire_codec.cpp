#include "raft_wire_codec.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <string>

#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

/* net/include/raft_wire_codec.h 의 구현. 선언과 프레임 포맷 설명은 그 헤더를 볼 것.
 *
 * 이 파일은 **protobuf 도 core 도 모른다** -- body 를 opaque 바이트로만
 * 다룬다. 그래서 raft_node / raft_client / raft_blockcopy_server 세 바이너리가
 * 전부 이 하나를 공유한다 (WIRE 그룹). */

namespace nvmeof_raft {

namespace {

/* ---- TCP 수신 대기 정책 ----
 * net/src/raft_rdma_transport.cpp 의 kSpinServeUs / kSpinClientUs 와 **같은 의미,
 * 같은 값**이어야 한다 (11-13 결정: RDMA·TCP 둘 다 폴링, 대기·깨어남 비용은 관심
 * 밖이라 양쪽 모두 최소화). 한쪽을 바꾸면 다른 쪽도 바꿀 것. 근거(C-state 복귀
 * 지연, 서버 무한·클라이언트 유계인 이유)는 그 파일의 주석을 볼 것.
 *
 *   서버(serve_rpc_connection): 무한 스핀. 원래도 타임아웃 없이 블로킹 read 였으므로
 *     의미가 바뀌지 않는다. 대신 살아 있는 커넥션당 코어 하나를 상시 쓴다.
 *   클라이언트(rpc_invoke): 2000µs 스핀 후 블로킹 recv. 블로킹 쪽은 tcp_connect 가
 *     건 SO_RCVTIMEO(2s)를 그대로 따르므로 죽은 피어에서 영원히 돌지 않는다. */
constexpr int kTcpSpinServeUs  = -1;     /* 무한 */
constexpr int kTcpSpinClientUs = 2000;   /* 유계 */

}  /* anonymous namespace */

void wire_write_all(int fd, const uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = ::write(fd, buf + off, len - off);
        if (n < 0) {
            if (errno == EINTR) { continue; }
            throw std::runtime_error("wire_write_all: write failed");
        }
        off += static_cast<size_t>(n);
    }
}

void wire_writev_all(int fd, struct iovec *iov, int iovcnt) {
    /* 빈 구간은 미리 건너뛴다 (body 가 비면 iov_base 가 nullptr 일 수 있다) */
    while (iovcnt > 0 && iov->iov_len == 0) { ++iov; --iovcnt; }
    while (iovcnt > 0) {
        ssize_t n = ::writev(fd, iov, iovcnt);
        if (n < 0) {
            if (errno == EINTR) { continue; }
            throw std::runtime_error("wire_writev_all: writev failed");
        }
        size_t left = static_cast<size_t>(n);
        while (iovcnt > 0 && left >= iov->iov_len) {
            left -= iov->iov_len;
            ++iov;
            --iovcnt;
        }
        if (iovcnt > 0) {           /* 부분 쓰기: 이 구간의 남은 부분부터 */
            iov->iov_base = static_cast<uint8_t *>(iov->iov_base) + left;
            iov->iov_len -= left;
        }
    }
}

/* ============================================================
 * WireReader
 * ============================================================ */

WireReader::WireReader(int fd, int spin_us)
    : fd_(fd), spin_us_(spin_us), buf_(kWireReaderBufBytes) {}

size_t WireReader::recv_some(uint8_t *dst, size_t len) {
    /* ---- 1) 스핀 ----
     * spin_us_ < 0 이면 끝이 없다 (데이터·종료·에러로만 나간다). */
    if (spin_us_ != 0) {
        using clk = std::chrono::steady_clock;
        const auto spin_end = clk::now() + std::chrono::microseconds(spin_us_ > 0 ? spin_us_ : 0);
        for (;;) {
            ssize_t n = ::recv(fd_, dst, len, MSG_DONTWAIT);
            if (n > 0) { ++recv_calls_; return static_cast<size_t>(n); }
            if (n == 0) { throw std::runtime_error("wire: connection closed"); }
            if (errno == EINTR) { continue; }
            if (errno != EAGAIN && errno != EWOULDBLOCK) {
                throw std::runtime_error(std::string("wire: recv failed: ") + std::strerror(errno));
            }
            if (spin_us_ > 0 && clk::now() >= spin_end) { break; }
            __builtin_ia32_pause();   /* SMT 형제 스레드에 발행 슬롯을 양보 (RDMA 스핀과 같다) */
        }
    }

    /* ---- 2) 블로킹 폴백 (SO_RCVTIMEO 를 따른다) ---- */
    for (;;) {
        ssize_t n = ::recv(fd_, dst, len, 0);
        if (n > 0) { ++recv_calls_; return static_cast<size_t>(n); }
        if (n == 0) { throw std::runtime_error("wire: connection closed"); }
        if (errno == EINTR) { continue; }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            throw std::runtime_error("wire: recv timed out");
        }
        throw std::runtime_error(std::string("wire: recv failed: ") + std::strerror(errno));
    }
}

void WireReader::read_exact(void *dst, size_t len) {
    uint8_t *out = static_cast<uint8_t *>(dst);

    /* 버퍼에 있는 것부터 */
    size_t take = std::min(tail_ - head_, len);
    if (take > 0) {
        std::memcpy(out, buf_.data() + head_, take);
        head_ += take; out += take; len -= take;
    }

    while (len > 0) {
        /* 여기서는 버퍼가 비어 있다 */
        head_ = tail_ = 0;
        if (len >= buf_.size()) {
            /* 큰 body: 버퍼를 거치지 않고 목적지로 직접 */
            size_t n = recv_some(out, len);
            out += n; len -= n;
            continue;
        }
        tail_ = recv_some(buf_.data(), buf_.size());
        take = std::min(tail_, len);
        std::memcpy(out, buf_.data(), take);
        head_ = take; out += take; len -= take;
    }
    if (head_ == tail_) { head_ = tail_ = 0; }
}

namespace {

uint32_t read_be32(WireReader &rd) {
    uint32_t v;
    rd.read_exact(&v, 4);
    return ntohl(v);
}

uint64_t read_be64(WireReader &rd) {
    uint64_t v;
    rd.read_exact(&v, 8);
    return wire_be64toh(v);
}

uint16_t read_be16(WireReader &rd) {
    uint16_t v;
    rd.read_exact(&v, 2);
    return ntohs(v);
}

void put_bytes(std::vector<uint8_t> &b, const void *p, size_t n) {
    const uint8_t *s = static_cast<const uint8_t *>(p);
    b.insert(b.end(), s, s + n);
}

}  /* anonymous namespace */

/* ============================================================
 * ClientCodec
 * ============================================================ */

WireClientCodec::WireClientCodec(int fd) : fd_(fd), rd_(fd, kTcpSpinClientUs) {}

void WireClientCodec::write_request(const std::string &service_method, uint64_t seq,
                                    const std::vector<uint8_t> &body) {
    if (service_method.size() > 0xFFFF) {
        throw std::runtime_error("wire: method name too long");
    }
    std::lock_guard<std::mutex> lk(write_mu_);
    {
        std::lock_guard<std::mutex> lk2(pending_mu_);
        pending_table_[seq] = service_method;
    }

    /* [mlen 2][method][seq 8][body_len 4] -- preamble 만 멤버 버퍼에, body 는 그대로 */
    wbuf_.clear();
    uint16_t mlen = htons(static_cast<uint16_t>(service_method.size()));
    put_bytes(wbuf_, &mlen, 2);
    put_bytes(wbuf_, service_method.data(), service_method.size());
    uint64_t seq_be = wire_htobe64(seq);
    put_bytes(wbuf_, &seq_be, 8);
    uint32_t body_len_be = htonl(static_cast<uint32_t>(body.size()));
    put_bytes(wbuf_, &body_len_be, 4);

    struct iovec iov[2];
    iov[0].iov_base = wbuf_.data();
    iov[0].iov_len = wbuf_.size();
    iov[1].iov_base = const_cast<uint8_t *>(body.data());
    iov[1].iov_len = body.size();
    wire_writev_all(fd_, iov, 2);
}

WireClientCodec::ResponseHeader WireClientCodec::read_response_header() {
    uint64_t seq = read_be64(rd_);
    uint16_t err_len = read_be16(rd_);

    std::string err_buf;
    if (err_len > 0) {
        err_buf.resize(err_len);
        rd_.read_exact(err_buf.data(), err_len);
    }

    uint32_t body_len = read_be32(rd_);

    std::string method;
    {
        std::lock_guard<std::mutex> lk(pending_mu_);
        auto it = pending_table_.find(seq);
        if (it != pending_table_.end()) {
            method = it->second;
            pending_table_.erase(it);
        }
        pending_body_len_ = body_len;
        pending_method_ = method;
    }

    return {seq, method, err_buf};
}

std::vector<uint8_t> WireClientCodec::read_response_body() {
    uint32_t body_len;
    {
        std::lock_guard<std::mutex> lk(pending_mu_);
        body_len = pending_body_len_;
        pending_body_len_ = 0;
        pending_method_.clear();
    }
    if (body_len == 0) {
        return {};
    }
    std::vector<uint8_t> body(body_len);
    rd_.read_exact(body.data(), body_len);
    return body;
}

/* ============================================================
 * ServerCodec
 * ============================================================ */

WireServerCodec::WireServerCodec(int fd) : fd_(fd), rd_(fd, kTcpSpinServeUs) {}

WireServerCodec::RequestHeader WireServerCodec::read_request_header() {
    uint16_t mlen = read_be16(rd_);
    if (mlen == 0) {
        throw std::runtime_error("wire: empty method name");
    }
    std::string method(mlen, '\0');
    rd_.read_exact(method.data(), mlen);

    uint64_t seq = read_be64(rd_);
    uint32_t body_len = read_be32(rd_);

    {
        std::lock_guard<std::mutex> lk(pending_mu_);
        pending_body_len_ = body_len;
        pending_method_ = method;
    }
    return {method, seq};
}

std::vector<uint8_t> WireServerCodec::read_request_body() {
    uint32_t body_len;
    {
        std::lock_guard<std::mutex> lk(pending_mu_);
        body_len = pending_body_len_;
        pending_body_len_ = 0;
        pending_method_.clear();
    }
    if (body_len == 0) {
        return {};
    }
    std::vector<uint8_t> body(body_len);
    rd_.read_exact(body.data(), body_len);
    return body;
}

void WireServerCodec::write_response(uint64_t seq, const std::string &error,
                                     const std::vector<uint8_t> &body) {
    if (error.size() > 0xFFFF) {
        throw std::runtime_error("wire: error string too long");
    }
    std::lock_guard<std::mutex> lk(write_mu_);

    /* [seq 8][err_len 2][err][body_len 4] -- preamble 만 멤버 버퍼에, body 는 그대로 */
    wbuf_.clear();
    uint64_t seq_be = wire_htobe64(seq);
    put_bytes(wbuf_, &seq_be, 8);
    uint16_t err_len_be = htons(static_cast<uint16_t>(error.size()));
    put_bytes(wbuf_, &err_len_be, 2);
    put_bytes(wbuf_, error.data(), error.size());
    uint32_t body_len_be = htonl(static_cast<uint32_t>(body.size()));
    put_bytes(wbuf_, &body_len_be, 4);

    struct iovec iov[2];
    iov[0].iov_base = wbuf_.data();
    iov[0].iov_len = wbuf_.size();
    iov[1].iov_base = const_cast<uint8_t *>(body.data());
    iov[1].iov_len = body.size();
    wire_writev_all(fd_, iov, 2);
}

} /* namespace nvmeof_raft */
