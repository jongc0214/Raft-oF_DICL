#ifndef RAFT_EVENT_LOG_H
#define RAFT_EVENT_LOG_H

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <ctime>

/* ============================================================
 * 선거 이벤트 로그 -- term/state/리더가 바뀌는 순간을 한 줄씩 남긴다.
 *
 *   [elect 12:34:56.123456 n5] became leader term=7 votes=2/3 in 412 ms
 *
 * -debug 와 무관하게 항상 켜져 있다. 선거는 드물게(장애 때만) 일어나므로
 * 정상 측정 구간에서는 한 줄도 찍히지 않는다. 호스트 간 순서를 맞출 수
 * 있도록 벽시계(CLOCK_REALTIME, µs)를 쓴다.
 *
 * stderr 로 쓴다 -- 버퍼링이 없어서 노드가 곧바로 죽어도 줄이 남는다
 * (start_node.sh 는 stdout/stderr 를 같은 로그 파일로 보낸다).
 * 호출자가 mu 를 쥐고 있어도 된다 (fprintf 한 번이고 드물다).
 * ============================================================ */
namespace nvmeof_raft {

__attribute__((format(printf, 2, 3)))
inline void election_log(uint64_t self_id, const char *fmt, ...) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tm;
    localtime_r(&ts.tv_sec, &tm);

    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    std::vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    std::fprintf(stderr, "[elect %02d:%02d:%02d.%06ld n%llu] %s\n",
                 tm.tm_hour, tm.tm_min, tm.tm_sec, ts.tv_nsec / 1000,
                 static_cast<unsigned long long>(self_id), msg);
}

} /* namespace nvmeof_raft */

#endif /* RAFT_EVENT_LOG_H */
