#include "raft_blockcopy_server.h"

#include <algorithm>
#include <climits>
#include <cstring>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>

#include <liburing.h>   // 파일 위쪽
/**
 *
 */

/* storage/raft_blockcopy_server.h 의 구현. 선언은 그 헤더를 볼 것.
 *
 * ns_diff / write_pba_copy_buf / write_pba_copy 는 이 파일 밖에서 쓰이지
 * 않으므로 익명 namespace 에 둔다 -- 예전에는 헤더에 inline 으로 노출돼 있어
 * 이 헤더를 include 하는 4개 TU 가 pread/pwrite 루프를 매번 컴파일했다. */

/* RAFT_TIMING: apply-timed 분해 타이머의 컴파일 스위치 (SRead/SWrite/SSync/
 * StorageIO). 끄면 응답의 *_nanos 가 0이다. storage/ 는 core/ 를 include
 * 하지 않으므로 core/include/raft_basics.h 와 같은 기본값을 여기 한 번 더
 * 둔다 -- 둘을 같이 바꿀 것. */
#ifndef RAFT_TIMING
#define RAFT_TIMING 1
#endif

namespace nvmeof_raft {
namespace blockcopy {

namespace {

#if RAFT_TIMING
uint64_t ns_diff(const struct timespec &a, const struct timespec &b) {
    return static_cast<uint64_t>(b.tv_sec - a.tv_sec) * 1000000000ull +
           static_cast<uint64_t>(b.tv_nsec - a.tv_nsec);
}
#endif

int write_pba_copy_buf(int src_fd, int dst_fd,
                               int64_t pba_src, int64_t pba_dst,
                               int nbytes, void *buf,
                               uint64_t *read_ns, uint64_t *write_ns) {
#if RAFT_TIMING
    struct timespec t0{}, t1{};

    clock_gettime(CLOCK_MONOTONIC_RAW, &t0);
#endif
    ssize_t r = pread(src_fd, buf, static_cast<size_t>(nbytes), pba_src);
#if RAFT_TIMING
    clock_gettime(CLOCK_MONOTONIC_RAW, &t1);
    *read_ns = ns_diff(t0, t1);
#else
    *read_ns = 0;
#endif
    if (r != nbytes) {
        return -1;
    }

#if RAFT_TIMING
    clock_gettime(CLOCK_MONOTONIC_RAW, &t0);
#endif
    struct Ring { io_uring r; Ring() { io_uring_queue_init(8, &r, 0); } ~Ring() { io_uring_queue_exit(&r); } };
    static thread_local Ring ring;   // 스레드마다 한 번만 만들고, 스레드 끝날 때 정리

    io_uring_sqe *sqe = io_uring_get_sqe(&ring.r);
    io_uring_prep_write(sqe, dst_fd, buf, static_cast<unsigned>(nbytes), pba_dst);
    sqe->rw_flags = RWF_DSYNC;       // 이 쓰기만 영속화 (FUA)
    io_uring_submit(&ring.r);

    io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring.r, &cqe);
    ssize_t w = cqe->res;            // 성공 시 쓴 바이트 수, 실패 시 -errno
    io_uring_cqe_seen(&ring.r, cqe);

#if RAFT_TIMING
    clock_gettime(CLOCK_MONOTONIC_RAW, &t1);
    *write_ns = ns_diff(t0, t1);
#else
    *write_ns = 0;
#endif
    if (w != nbytes) {
        return -1;
    }
    return 0;
}

int write_pba_copy(int src_fd, int dst_fd,
                           int64_t pba_src, int64_t pba_dst,
                           int nbytes, uint64_t *read_ns, uint64_t *write_ns) {
    void *buf = nullptr;
    if (posix_memalign(&buf, kAlign, static_cast<size_t>(nbytes)) != 0) {
        return -1;
    }
    int rc = write_pba_copy_buf(src_fd, dst_fd, pba_src, pba_dst, nbytes, buf,
                                 read_ns, write_ns);
    free(buf);
    return rc;
}

}  /* anonymous namespace */

int open_device(const std::string &path) {
    return ::open(path.c_str(), O_RDWR | O_DIRECT);
}

int open_device_for_read(const std::string &path) {
    struct stat st{};
    if (::stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
        return -1;   /* 블록 장치 등: 버퍼드로 읽으면 안 된다 (헤더 주석) */
    }
    return ::open(path.c_str(), O_RDONLY);
}

AlignedBufPool::~AlignedBufPool(){
        for (auto &b : free_) {
            free(b.first);
        }
    }

std::pair<void *, size_t> AlignedBufPool::acquire(size_t n){
        void *p = nullptr;
        size_t cap = 0;
        {
            std::lock_guard<std::mutex> lk(mu_);
            if (!free_.empty()) {
                p = free_.back().first;
                cap = free_.back().second;
                free_.pop_back();
            }
        }
        /* 풀에서 꺼낸 버퍼가 n바이트를 담을 수 있으면 그대로 쓰고, 작으면
         * 버린 뒤 아래에서 새로 잡는다. 이 else가 없던 시절에는 free(p) 후
         * 그 **해제된** 포인터를 옛 capacity와 함께 반환해서, 워커가 해제된
         * 메모리에 n바이트를 pread/pwrite했다 (use-after-free + heap overflow).
         * 청크 크기가 균일한 동안에는 cap < n 분기 자체가 안 잡혀 드러나지
         * 않고, 크기를 키워가며 호출하는 순간 터진다 -- blkcopy 벤치의
         * 청크 스윕이 정확히 그 순서다. */
        if (p != nullptr) {
            if (cap >= n) return {p, cap};
            else free(p);   /* 너무 작으면 버리고 새로 잡는다 */
        }

        void *np = nullptr;
        size_t ncap = (n + kAlign - 1) / kAlign * kAlign;
        if (posix_memalign(&np, kAlign, ncap) != 0) {
            return {nullptr, 0};
        }
        return {np, ncap};
    }

void AlignedBufPool::release(void *p, size_t cap){
        if (p == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> lk(mu_);
        free_.push_back({p, cap});
    }

BlockCopyServer::BlockCopyServer(std::vector<int> fds, std::vector<std::string> paths,
                                 std::vector<int> read_fds)
        : fds_(std::move(fds)), read_fds_(std::move(read_fds)), paths_(std::move(paths)) {
    read_fds_.resize(fds_.size(), -1);
}

BlockCopyServer::~BlockCopyServer(){
        for (size_t i = 0; i < fds_.size(); i++) {
            int rfd = read_fds_[i];
            if (rfd >= 0 && rfd != fds_[i]) {
                ::close(rfd);
            }
        }
        for (int fd : fds_) {
            if (fd >= 0) {
                ::close(fd);
            }
        }
    }

WritePBARsp BlockCopyServer::handle_write_pba(const WritePBAReq &req){
        WritePBARsp rsp;
        int src_fd, dst_fd;
        if (!get_read_fd(req.src_dev, src_fd) || !get_fd(req.dst_dev, dst_fd)) {
            rsp.error = "device index out of range";
            return rsp;
        }

        uint64_t read_ns = 0, write_ns = 0;
        int rc = write_pba_copy(src_fd, dst_fd,
                                 static_cast<int64_t>(req.pba_src),
                                 static_cast<int64_t>(req.pba_dst),
                                 static_cast<int>(req.nbytes), &read_ns, &write_ns);
        if (rc != 0) {
            rsp.error = "write_pba_copy failed (src_dev=" + std::to_string(req.src_dev) +
                        " dst_dev=" + std::to_string(req.dst_dev) +
                        " nbytes=" + std::to_string(req.nbytes) + ")";
            return rsp;
        }

        rsp.copy_nanos = static_cast<int64_t>(read_ns + write_ns);
        return rsp;
    }

WritePBABatchRsp BlockCopyServer::handle_write_pba_batch(const WritePBABatchReq &req){
        WritePBABatchRsp rsp;
        size_t count = req.pba_srcs.size();
        if (count == 0) {
            return rsp;
        }
        if (count != req.pba_dsts.size()) {
            rsp.error = "PbaSrcs and PbaDsts length mismatch";
            return rsp;
        }

        int src_fd, dst_fd;
        if (!get_read_fd(req.src_dev, src_fd) || !get_fd(req.dst_dev, dst_fd)) {
            rsp.error = "device index out of range";
            return rsp;
        }

        std::vector<uint64_t> sizes = req.nbytes;
        if (sizes.empty()) {
            if (req.block_size == 0) {
                rsp.error = "WritePBABatch: neither Nbytes nor BlockSize provided";
                return rsp;
            }
            sizes.assign(count, req.block_size);
        } else if (sizes.size() != count) {
            rsp.error = "Nbytes length " + std::to_string(sizes.size()) +
                        " != PbaSrcs length " + std::to_string(count);
            return rsp;
        }

        uint64_t max_size = 0;
        for (uint64_t sz : sizes) {
            max_size = std::max(max_size, sz);
        }
        if (max_size == 0) {
            rsp.error = "WritePBABatch: all entries have zero size";
            return rsp;
        }
        /* write_pba_copy_buf의 nbytes 파라미터가 int라서 2GiB 이상은
         * 조용히 음수로 잘린다. 현재 호출부(do_pba_copy)는
         * MaxPBACopyChunkBytes(256MiB)로 이미 clamp하므로 도달하지
         * 않지만, 그 상수를 올렸을 때 데이터가 조용히 깨지는 대신
         * 여기서 명시적으로 거절하게 한다. */
        if (max_size > static_cast<uint64_t>(INT_MAX)) {
            rsp.error = "WritePBABatch: chunk size " + std::to_string(max_size) +
                        " exceeds INT_MAX (lower MaxPBACopyChunkBytes)";
            return rsp;
        }

        /* 버퍼는 풀에서 하나 빌린다 (RPC마다 posix_memalign/free를 반복하면
         * max_size가 256MiB까지 갈 수 있다). 정상 상태에서는 재사용되어 할당 0. */
        auto got = buf_pool_.acquire(static_cast<size_t>(max_size));
        void *buf = got.first;
        const size_t buf_cap = got.second;
        if (buf == nullptr) {
            rsp.error = "posix_memalign for copy buffer failed";
            return rsp;
        }

        uint64_t total_read_ns = 0, total_write_ns = 0;

#if RAFT_TIMING
        struct timespec batch_t0{}, batch_t1{};
        clock_gettime(CLOCK_MONOTONIC_RAW, &batch_t0);
#endif

        /* 청크를 이 연결 스레드에서 순서대로 복사한다. 청크는 보통 1개이고
         * 링 wrap / extent 경계에서만 2개가 되므로, 요청마다 워커 스레드를
         * 만들고 join 하는 비용(20~30us)이 병렬로 얻는 겹침보다 크다. */
        for (size_t i = 0; i < count; i++) {
            uint64_t r = 0, wr = 0;
            int rc = write_pba_copy_buf(
                src_fd, dst_fd,
                static_cast<int64_t>(req.pba_srcs[i]),
                static_cast<int64_t>(req.pba_dsts[i]),
                static_cast<int>(sizes[i]), buf, &r, &wr);
            if (rc != 0) {
                buf_pool_.release(buf, buf_cap);
                rsp.error = "entry " + std::to_string(i) + " failed";
                return rsp;
            }
            total_read_ns += r;
            total_write_ns += wr;
        }

#if RAFT_TIMING
        struct timespec sync_t0{}, sync_t1{};
        clock_gettime(CLOCK_MONOTONIC_RAW, &sync_t0);
#endif
        // const int sync_rc = ::fdatasync(dst_fd);
#if RAFT_TIMING
        clock_gettime(CLOCK_MONOTONIC_RAW, &sync_t1);
#endif
        // if (sync_rc != 0) {
        //     buf_pool_.release(buf, buf_cap);
        //     rsp.error = "fdatasync destination failed";
        //     return rsp;
        // }

#if RAFT_TIMING
        clock_gettime(CLOCK_MONOTONIC_RAW, &batch_t1);
#endif

        buf_pool_.release(buf, buf_cap);

        rsp.read_nanos = static_cast<int64_t>(total_read_ns);
        rsp.write_nanos = static_cast<int64_t>(total_write_ns);
#if RAFT_TIMING
        rsp.sync_nanos = static_cast<int64_t>(ns_diff(sync_t0, sync_t1));
        rsp.copy_nanos = static_cast<int64_t>(ns_diff(batch_t0, batch_t1));
#endif
        return rsp;
    }

bool BlockCopyServer::get_fd(int dev_idx, int &out_fd) const{
        if (dev_idx < 0 || static_cast<size_t>(dev_idx) >= fds_.size()) {
            return false;
        }
        out_fd = fds_[static_cast<size_t>(dev_idx)];
        return true;
    }

bool BlockCopyServer::get_read_fd(int dev_idx, int &out_fd) const{
        if (!get_fd(dev_idx, out_fd)) {
            return false;
        }
        int rfd = read_fds_[static_cast<size_t>(dev_idx)];
        if (rfd >= 0) {
            out_fd = rfd;
        }
        return true;
    }

} /* namespace blockcopy */
} /* namespace nvmeof_raft */
