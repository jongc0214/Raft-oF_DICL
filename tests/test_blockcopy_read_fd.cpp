/* ============================================================
 * BlockCopyServer src 읽기 fd 분리 단위 테스트 (D24)
 *
 * WritePBABatch는 src를 장치의 **읽기 fd**(있으면)로, dst를 **쓰기 fd**로
 * 다룬다. 읽기 fd와 쓰기 fd에 서로 다른 내용의 파일을 줘서, dst에 들어간
 * 바이트로 어느 fd에서 읽었는지 판별한다. 또 open_device_for_read가 일반
 * 파일만 버퍼드로 열고 그 밖에는 -1(쓰기 fd 재사용)을 주는지 고정한다.
 * ============================================================ */
#include "third_party/doctest.h"

#include "raft_blockcopy_server.h"

#include <cstdlib>
#include <string>
#include <vector>

#include <fcntl.h>
#include <unistd.h>

using namespace nvmeof_raft::blockcopy;

namespace {

constexpr size_t kBytes = 64 * 1024;

std::string temp_dir() {
    const char *dir = std::getenv("TMPDIR");
    return dir != nullptr ? dir : "/tmp";
}

/* 이름 있는 임시 파일을 fill로 채운다. 반환: 경로 (호출자가 unlink) */
std::string make_file(unsigned char fill) {
    std::string path = temp_dir() + "/raft_bc_rfd_XXXXXX";
    std::vector<char> buf(path.begin(), path.end());
    buf.push_back('\0');
    int fd = ::mkstemp(buf.data());
    REQUIRE(fd >= 0);
    std::vector<unsigned char> data(kBytes, fill);
    REQUIRE(::pwrite(fd, data.data(), data.size(), 0) == static_cast<ssize_t>(data.size()));
    ::close(fd);
    return std::string(buf.data());
}

int open_rw(const std::string &path) {
    int fd = ::open(path.c_str(), O_RDWR);
    REQUIRE(fd >= 0);
    return fd;
}

std::vector<unsigned char> read_all(const std::string &path) {
    std::vector<unsigned char> out(kBytes, 0);
    int fd = ::open(path.c_str(), O_RDONLY);
    REQUIRE(fd >= 0);
    REQUIRE(::pread(fd, out.data(), out.size(), 0) == static_cast<ssize_t>(out.size()));
    ::close(fd);
    return out;
}

WritePBABatchReq one_chunk_req(uint64_t nbytes) {
    WritePBABatchReq req;
    req.pba_srcs = {4096};
    req.pba_dsts = {8192};
    req.nbytes = {nbytes};
    req.src_dev = 0;
    req.dst_dev = 1;
    return req;
}

}  /* namespace */

TEST_CASE("open_device_for_read: 일반 파일만 버퍼드로, 그 밖은 -1") {
    std::string f = make_file(0x11);
    int rfd = open_device_for_read(f);
    REQUIRE(rfd >= 0);
    int flags = ::fcntl(rfd, F_GETFL);
    CHECK((flags & O_DIRECT) == 0);
    CHECK((flags & O_ACCMODE) == O_RDONLY);
    ::close(rfd);
    ::unlink(f.c_str());

    /* 문자 장치/없는 경로: 버퍼드로 열지 않는다 (블록 장치도 같은 분기) */
    CHECK(open_device_for_read("/dev/null") == -1);
    CHECK(open_device_for_read(temp_dir() + "/raft_bc_rfd_no_such_file") == -1);
}

TEST_CASE("WritePBABatch: src는 읽기 fd에서, dst는 쓰기 fd로") {
    std::string src_w = make_file(0xAA);   /* 장치 0의 쓰기 fd가 가리키는 파일 */
    std::string src_r = make_file(0x5C);   /* 장치 0의 읽기 fd가 가리키는 파일 */
    std::string dst   = make_file(0xEE);   /* 장치 1 */

    {
        BlockCopyServer server({open_rw(src_w), open_rw(dst)}, {src_w, dst}, 1,
                               {::open(src_r.c_str(), O_RDONLY), -1});
        WritePBABatchRsp rsp = server.handle_write_pba_batch(one_chunk_req(4096));
        REQUIRE(rsp.error.empty());
    }   /* 소멸자가 fd 전부를 닫는다 */

    std::vector<unsigned char> got = read_all(dst);
    for (size_t i = 0; i < kBytes; i++) {
        unsigned char want = (i >= 8192 && i < 8192 + 4096) ? 0x5C : 0xEE;
        if (got[i] != want) {
            FAIL_CHECK("dst byte " << i << " = " << int(got[i]) << ", want " << int(want));
            break;
        }
    }
    ::unlink(src_w.c_str());
    ::unlink(src_r.c_str());
    ::unlink(dst.c_str());
}

TEST_CASE("WritePBABatch: 읽기 fd가 없으면 쓰기 fd로 읽는다 (블록 장치 = 예전 동작)") {
    std::string src = make_file(0xAA);
    std::string dst = make_file(0xEE);
    {
        BlockCopyServer server({open_rw(src), open_rw(dst)}, {src, dst}, 1);
        WritePBABatchRsp rsp = server.handle_write_pba_batch(one_chunk_req(4096));
        REQUIRE(rsp.error.empty());
    }
    std::vector<unsigned char> got = read_all(dst);
    CHECK(got[8192] == 0xAA);
    CHECK(got[8192 + 4095] == 0xAA);
    CHECK(got[8191] == 0xEE);
    CHECK(got[8192 + 4096] == 0xEE);
    ::unlink(src.c_str());
    ::unlink(dst.c_str());
}

TEST_CASE("WritePBABatch: src 장치 번호가 범위 밖이면 에러") {
    std::string a = make_file(0x01);
    BlockCopyServer server({open_rw(a)}, {a}, 1, {-1});
    WritePBABatchReq req = one_chunk_req(4096);
    req.dst_dev = 0;
    req.src_dev = 3;
    CHECK_FALSE(server.handle_write_pba_batch(req).error.empty());
    ::unlink(a.c_str());
}
