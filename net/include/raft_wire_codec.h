#ifndef RAFT_WIRE_CODEC_HPP
#define RAFT_WIRE_CODEC_HPP

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <mutex>
#include <unordered_map>
#include <stdexcept>
#include <arpa/inet.h>   /* htons/ntohs/htonl/ntohl -- big-endian 변환 */
#include <sys/uio.h>     /* struct iovec */
#include <unistd.h>

namespace nvmeof_raft {

/* ============================================================
 * Wire framing (proto_codec.go의 writeAll/readFull 및 프레임 포맷
 * 그대로 포팅)
 *
 * 요청 프레임: [method_len(2B, BE)][method][seq(8B, BE)][body_len(4B, BE)][body]
 * 응답 프레임: [seq(8B, BE)][error_len(2B, BE)][error][body_len(4B, BE)][body]
 *
 * Go의 io.Writer/io.Reader 인터페이스는 fd 기반 read/write로 대응.
 * 이 레이어는 protobuf와 독립적이다 -- body 바이트를 그대로 옮기기만
 * 하고, 그 안의 직렬화 방식(protobuf)은 상위 계층(raft_proto_conv.h)
 * 책임이다.
 * ============================================================ */

void wire_write_all(int fd, const uint8_t *buf, size_t len);

/* iov 전체를 보낸다 (부분 쓰기면 남은 구간부터 다시). iov 는 진행하면서 고쳐 쓴다.
 * preamble 과 body 를 한 시스템 호출로 보내 호출마다 하던 할당과 body memcpy 를 없앤다. */
void wire_writev_all(int fd, struct iovec *iov, int iovcnt);

/* ============================================================
 * WireReader: 커넥션 하나의 수신 버퍼 + 스핀 대기
 *
 * 예전에는 프레임 필드마다 read() 를 불러 요청 하나에 시스템 호출이 5번
 * (서버) / 3~4번(클라이언트) 들었다. 커넥션마다 kWireReaderBufBytes 버퍼를
 * 두고 한 번에 받아 그 안에서 필드를 꺼낸다 -- 작은 AE 는 recv 1번.
 * 버퍼보다 큰 body 는 버퍼를 거치지 않고 목적지로 직접 받는다.
 *
 * spin_us: 데이터가 없을 때 recv(MSG_DONTWAIT) 로 바쁘게 기다리는 시간.
 *   < 0  무한 스핀 (서버)
 *   = 0  스핀 없이 바로 블로킹 recv (예전 동작)
 *   > 0  그만큼 스핀한 뒤 블로킹 recv 로 내려간다 (클라이언트). 블로킹 쪽은
 *        소켓의 SO_RCVTIMEO 를 그대로 따른다.
 * 값의 근거는 raft_wire_codec.cpp 의 kTcpSpin* 주석 (RDMA 와 같은 정책).
 * ============================================================ */
constexpr size_t kWireReaderBufBytes = 64 * 1024;

class WireReader {
public:
    WireReader(int fd, int spin_us);

    /* len 바이트를 정확히 채운다. 연결 종료/에러/타임아웃이면 예외. */
    void read_exact(void *dst, size_t len);

    /* 버퍼에 남아 있는(아직 꺼내지 않은) 바이트 수 -- 테스트용 */
    size_t buffered() const { return tail_ - head_; }

    /* recv 시스템 호출 수 (스핀 중 EAGAIN 은 세지 않는다) -- 테스트용 */
    uint64_t recv_calls() const { return recv_calls_; }

private:
    size_t recv_some(uint8_t *dst, size_t len);

    int fd_;
    int spin_us_;
    std::vector<uint8_t> buf_;
    size_t head_ = 0;
    size_t tail_ = 0;
    uint64_t recv_calls_ = 0;
};

inline uint64_t wire_htobe64(uint64_t v) {
    uint32_t hi = htonl(static_cast<uint32_t>(v >> 32));
    uint32_t lo = htonl(static_cast<uint32_t>(v & 0xFFFFFFFFu));
    return (static_cast<uint64_t>(lo) << 32) | hi;
}
inline uint64_t wire_be64toh(uint64_t v) { return wire_htobe64(v); /* 대칭 연산 */ }

/* ============================================================
 * ClientCodec (protoClientCodec 원본 그대로 포팅)
 * ============================================================ */

class WireClientCodec {
public:
    explicit WireClientCodec(int fd);

    void write_request(const std::string &service_method, uint64_t seq, const std::vector<uint8_t> &body);

    struct ResponseHeader {
        uint64_t seq;
        std::string service_method;
        std::string error;
    };
    ResponseHeader read_response_header();

    std::vector<uint8_t> read_response_body();

    /* 테스트용: 응답을 읽는 리더 */
    const WireReader &reader() const { return rd_; }

private:
    int fd_;
    WireReader rd_;                  /* kTcpSpinClientUs */
    std::vector<uint8_t> wbuf_;      /* 요청 preamble (write_mu_ 아래에서 재사용) */
    std::mutex write_mu_;
    std::mutex pending_mu_;
    std::unordered_map<uint64_t, std::string> pending_table_;
    uint32_t pending_body_len_ = 0;
    std::string pending_method_;
};

/* ============================================================
 * ServerCodec (protoServerCodec 원본 그대로 포팅)
 * ============================================================ */

class WireServerCodec {
public:
    explicit WireServerCodec(int fd);

    struct RequestHeader {
        std::string service_method;
        uint64_t seq;
    };

    RequestHeader read_request_header();

    std::vector<uint8_t> read_request_body();

    void write_response(uint64_t seq, const std::string &error, const std::vector<uint8_t> &body);

    /* 테스트용: 요청을 읽는 리더 */
    const WireReader &reader() const { return rd_; }

private:
    int fd_;
    WireReader rd_;                  /* kTcpSpinServeUs */
    std::vector<uint8_t> wbuf_;      /* 응답 preamble (write_mu_ 아래에서 재사용) */
    std::mutex write_mu_;
    std::mutex pending_mu_;
    uint32_t pending_body_len_ = 0;
    std::string pending_method_;
};

} /* namespace nvmeof_raft */

#endif /* RAFT_WIRE_CODEC_HPP */