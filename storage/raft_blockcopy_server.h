#ifndef RAFT_BLOCKCOPY_SERVER_HPP
#define RAFT_BLOCKCOPY_SERVER_HPP

/* 페이지 크기만 쓴다. blockio/ 가 디바이스 기하값의 단일 출처이며,
 * 여기서 core/include/raft_constants.h 를 거치지 않으므로 **storage/ 는 core/ 를
 * 전혀 모른다** (의존 방향: net -> storage -> blockio). */
#include "block_geometry.h"

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <string>
#include <vector>
#include <mutex>
#include <atomic>
#include <stdexcept>
#include <algorithm>
#include <utility>
#include <climits>

#include <fcntl.h>
#include <unistd.h>
#include <time.h>

/* ============================================================
 * 스토리지(blockcopy) 노드의 서버 구현.
 *
 * 예전에는 core/ 에 있었는데, core/ 는 "Raft 알고리즘 자체"를 담는
 * 디렉터리이고 이 파일은 그것과 아무 관계가 없다 -- core/ 의 어느 파일도
 * 이걸 include하지 않으며(전수 확인), 쓰는 쪽은 net/ 와
 * raft_blockcopy_server 바이너리뿐이다. Go 원본 대응도 별도 프로그램
 * (~/RAFT/server_random)이다. 그래서 storage/ 로 분리했다.
 *
 * raft_constants.h에서 PAGE_SIZE만 쓴다 -- constexpr이므로
 * raft_constants.cpp 링크가 필요하지 않다 (이 바이너리는 core/를
 * 링크하지 않는다).
 * ============================================================ */

namespace nvmeof_raft {
namespace blockcopy {

/* O_DIRECT 버퍼 정렬. blockio가 소유하는 페이지 크기와 같은 값이다.
 * 예전에는 여기 4096 리터럴로 따로 정의돼 있었고, blockio 쪽 kAlign=512와
 * 이름은 같고 값은 다른 상태로 공존한 적이 있다. */
constexpr size_t kAlign = blockio::kPageSize;

/* 쓰기(겸 기본 읽기) fd: O_RDWR | O_DIRECT. */
int open_device(const std::string &path);

/* src 읽기 전용 fd (D24). path가 **일반 파일**이면 O_RDONLY(버퍼드)로 열어
 * 반환하고, 그 밖(블록 장치 등)이면 -1을 반환한다 -- 호출자는 -1이면 쓰기 fd를
 * 그대로 읽기에 쓴다(= 예전 동작, O_DIRECT 읽기).
 *
 * 왜 따로 여나: O_DIRECT는 fd 단위 속성이라 한 fd로 "읽기는 page cache, 쓰기는
 * O_DIRECT"를 할 수 없다. nvmet 파일 백엔드(buffered_io=1)로 내보낸 볼륨은
 * 리더가 NVMe-oF로 쓴 링이 그 파일의 page cache에 남아 있으므로, 같은 파일을
 * 버퍼드로 읽으면 SSD 읽기 없이 복사할 수 있다.
 *
 * 왜 블록 장치는 안 되나: nvmet bdev 백엔드의 쓰기는 bio로 바로 내려가 장치의
 * page cache를 무효화하지 않는다. 블록 장치를 버퍼드로 읽으면 링이 한 바퀴 돈 뒤
 * 옛 데이터를 에러 없이 읽는다. */
int open_device_for_read(const std::string &path);

/* ============================================================
 * AlignedBufPool
 *
 * WritePBABatch 처리에 쓰는 O_DIRECT 정렬 버퍼 풀.
 *
 * RPC 하나가 버퍼 하나(max_size)를 빌린다. 매번 posix_memalign/free를 하면
 * max_size가 MaxPBACopyChunkBytes(256MiB)까지 갈 수 있어 핫패스에서
 * page fault + munmap이 생긴다. 풀에 넣어 재사용하면 정상 상태에서는
 * 할당이 0이 된다. 연결마다 동시에 RPC가 오므로 버퍼는 연결 수만큼 쌓인다.
 *
 * acquire는 요청 크기보다 작은 버퍼를 받으면 키워서 돌려주므로,
 * 호출자는 항상 n바이트 이상을 보장받는다. 동시 RPC를 막지 않는다
 * (기존과 동일하게 여러 커넥션이 병렬로 처리될 수 있음).
 * ============================================================ */
class AlignedBufPool {
public:
    AlignedBufPool() = default;
    ~AlignedBufPool();
    AlignedBufPool(const AlignedBufPool &) = delete;
    AlignedBufPool &operator=(const AlignedBufPool &) = delete;

    /* 반환: {버퍼, 실제 capacity}. 실패 시 {nullptr, 0} */
    std::pair<void *, size_t> acquire(size_t n);

    void release(void *p, size_t cap);

private:
    std::mutex mu_;
    std::vector<std::pair<void *, size_t>> free_;
};

struct WritePBAReq { uint64_t pba_src, pba_dst, nbytes; int src_dev, dst_dev; };
struct WritePBARsp { std::string error; int64_t copy_nanos = 0; };

struct WritePBABatchReq {
    std::vector<uint64_t> pba_srcs, pba_dsts, nbytes;
    uint64_t block_size = 0;
    int src_dev = 0, dst_dev = 0;
};
/* copy_nanos 는 배치 wall 이다: 청크별 pread/pwrite 를 순서대로 -> fdatasync.
 * read_nanos / write_nanos 는 청크별 pread / pwrite 시간의 합, sync_nanos 는
 * 마지막 fdatasync(dst) 하나의 시간이다. 복사는 호출(연결) 스레드에서 직렬로
 * 하므로 copy_nanos - (read + write + sync) = 타이머 등 소량의 기타.
 * 방향별로 나누는 이유: 로컬 PCIe 복사와 NVMe-oF attach 볼륨 복사의 지연 차이가
 * pread 쪽인지 pwrite 쪽인지는 합계만으로는 알 수 없다 (blkcopy 벤치가 묻는 질문). */
struct WritePBABatchRsp {
    std::string error;
    int64_t copy_nanos = 0;
    int64_t read_nanos = 0, write_nanos = 0;
    int64_t sync_nanos = 0;
};

struct GetTimeRsp { uint64_t read_nanos = 0, write_nanos = 0, other_nanos = 0; };

/* ============================================================
 * BlockCopyServer
 *
 * pread/pwrite를 통해 데이터 블럭을 주소 단위로 복사하는 메서드가 담겨있는 클래스
 * ============================================================ */
class BlockCopyServer {
public:
    /* fds: 장치별 쓰기 fd (dst). read_fds: 장치별 src 읽기 fd -- 비었거나 항목이
     * -1이면 그 장치는 쓰기 fd로 읽는다. 두 벡터의 fd 모두 서버가 소유하고 닫는다. */
    BlockCopyServer(std::vector<int> fds, std::vector<std::string> paths,
                    std::vector<int> read_fds = {});

    ~BlockCopyServer();

    WritePBARsp handle_write_pba(const WritePBAReq &req);

    WritePBABatchRsp handle_write_pba_batch(const WritePBABatchReq &req);

    GetTimeRsp handle_get_time();

    void handle_reset_time();

private:
    bool get_fd(int dev_idx, int &out_fd) const;
    bool get_read_fd(int dev_idx, int &out_fd) const;   /* src 전용: read_fds_ 우선 */

    std::vector<int> fds_;
    std::vector<int> read_fds_;   /* fds_와 같은 길이, -1 = fds_ 사용 */
    std::vector<std::string> paths_;

    AlignedBufPool buf_pool_;   /* WritePBABatch 복사 버퍼 재사용 풀 */

    std::mutex mu_;
    uint64_t read_ns_ = 0, write_ns_ = 0, other_ns_ = 0;
};

} /* namespace blockcopy */
} /* namespace nvmeof_raft */

#endif /* RAFT_BLOCKCOPY_SERVER_HPP */