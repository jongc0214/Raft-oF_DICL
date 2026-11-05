#!/usr/bin/env bash
#
# size_latency_sweep.sh -- 엔트리 크기를 64B 부터 4배씩 1MiB 까지 키우며
#                          3-node Raft 의 end-to-end apply 지연을 잰다
#                          (breakdown 없음)
#
# 묻는 것: **엔트리 하나가 커질 때 서버가 명령 하나를 커밋·apply 하는 데
# 걸리는 시간이 어떻게 늘어나는가.**
# apply_latency_sweep.sh 와 달리 항별 분해(ApplyTimings)는 보지 않는다.
# -op apply (apply-timed 아님) 로 돌린다.
#
# **지점 값은 서버 쪽 시계다.** 리더의 dispatch_client_method 가
# server->apply() 한 번을 steady_clock 으로 재서 ClientApplyResponse.latency_nanos
# 로 돌려주고 (net/src/raft_tcp_server.cpp), 클라이언트가 성공한 RPC 마다 모아
# "plain apply internal latency summary" 줄로 찍는다. 그 avg 를 지점 값으로 쓴다.
#   들어가는 것: 리더가 요청을 받은 뒤 persist·복제·커밋·apply 까지
#   빠지는 것  : 클라이언트↔리더 네트워크, proto 파싱/직렬화, busy 재시도 대기
#                (busy 응답은 표본을 남기지 않는다)
# 비교용으로 클라이언트 벽시계 us/command = wall / N 도 client_* 컬럼에 남긴다.
# 그쪽에는 위에서 빠진 것들이 전부 들어간다.
#
# **서버는 이미 떠 있다고 가정한다.** 노드를 띄우지도 죽이지도 않고, 노드가
# 어떤 -mode (push / destination) 로 떠 있는지도 모른다 -- 클라이언트만
# 돌린다. push / pull 비교는 노드를 다시 띄운 뒤 출력 디렉터리를 달리해서
# 두 번 돌릴 것.
#
# 사용법:
#   ./scripts/size_latency_sweep.sh rdma|tcp [출력디렉터리]
#
#   rdma|tcp  클라이언트 전송. **노드를 띄운 -transport 와 같아야 한다**
#             (다르면 commit-index preflight 에서 붙지 못하고 끝난다)
#
# 환경변수:
#   ADDRS        -addrs 주소 목록 (기본 10.0.0.4:6001,10.0.0.5:6001,10.0.0.6:6001)
#                **IPoIB 주소여야 한다** -- rdma_cm 이 IP 로 장치를 찾는다
#   SIZES        **엔트리** 바이트 목록, 32B 엔트리 헤더(ENTRY_META_SIZE) 포함
#                (기본 64 256 1K 4K 16K 64K 256K 1M). 클라이언트에는 헤더를 뺀
#                명령 크기 (size - 32) 를 -size 로 넘긴다. 예: 4096 이면 명령
#                4064B, 링에서 정확히 8 슬롯 = 4KiB 페이지 하나.
#                32 이하는 명령이 비므로 건너뛴다
#   N            지점당 명령 수 (기본 10000)
#   REPS         지점당 반복 횟수 (기본 3). summary.csv 는 반복의 평균이다
#   TIMEOUT_S    리더 탐색 타임아웃 (기본 15)
#   BIN          바이너리 디렉터리 (기본 <repo>/build)
#   RDMA_MAX     RDMA 프레임 상한 바이트 (기본 4194304 = 4MiB). kRdmaMaxMessageBytes 를
#                올려서 다시 빌드했다면 여기도 맞출 것
#   RING_BYTES   노드의 링 크기 = -ring-pages × 4096 (기본 16MiB).
#                워밍업 분량을 여기서 유도한다 -- 노드를 다른 -ring-pages 로
#                띄웠다면 **반드시 맞춰줄 것**
#   WARMUP       1 이면 시작 시 워밍업 1회 (기본 1). 결과는 버린다
#   WARMUP_SIZE / WARMUP_BATCH   워밍업 파라미터 (기본 4096 / 10).
#                WARMUP_SIZE 도 헤더 포함 엔트리 크기다
#   WARMUP_N     워밍업 명령 수 (기본: RING_BYTES 에서 링 1.2 바퀴로 유도)
#   BUSY_WARN    busy_retries 가 이 값을 넘으면 경고 (기본 100)
#
# 출력:
#   size_bytes 는 어느 CSV 에서나 헤더 포함 엔트리 크기다 (명령 = size_bytes - 32).
#   raw.csv      transport,size_bytes,rep,n,srv_samples,srv_avg_us,srv_p50_us,
#                srv_p95_us,srv_p99_us,wall_ms,client_us_per_cmd,busy_retries
#   summary.csv  transport,size_bytes,size_label,reps,mean_us,min_us,max_us,stdev_us,
#                p50_us,p99_us,client_mean_us,busy_total
#                mean/min/max/stdev = 반복별 srv_avg_us 의 통계,
#                p50_us/p99_us = 반복별 srv_p50/srv_p99 의 평균,
#                client_mean_us = 반복별 client_us_per_cmd 의 평균
#   apply-r<rep>-<size>.log   원본 클라이언트 출력
#
# ── 읽기 전에 알 것 ───────────────────────────────────────────────────────
#
# **(1) RDMA 프레임 상한은 4MiB 다** (net/include/raft_rdma_transport.h:54).
# ClientApply 요청은 명령 (size - 32) 을 그대로 싣고 protobuf/프레임 헤더가 붙으므로,
# 명령이 4MiB 에 가까우면 encode_frame 에서 예외로 죽는다. preflight 가
# 걸리는 크기를 빼고 경고한다. 기본 SIZES (최대 1MiB) 는 전부 들어간다.
# **세 노드와 클라이언트가 모두 4MiB 로 빌드돼 있어야 한다** -- 노드가 옛
# 1MiB 빌드면 1M 지점에서 서버 쪽 수신이 실패한다. kRdmaMaxMessageBytes 를
# 다시 바꾸면 RDMA_MAX 도 맞출 것.
#
# **(2) 큰 엔트리는 링이 커야 한다.** 엔트리 하나가 먹는 슬롯은
# ceil(size / 512) 이고 (size 가 이미 헤더 포함; core/src/raft_ring_helpers.cpp:13), 링이 작으면
# 랩마다 GC 를 기다리다 busy 가 나서 지연 대신 백프레셔를 재게 된다.
# 1MiB 는 엔트리당 2048 슬롯이라 -ring-pages 4096 (16MiB) 이면 한 랩에 16 개다.
# 노드를 넉넉한 -ring-pages 로 띄울 것. busy_retries 가 큰 지점은 믿지 말 것.
#
# **(3) p50 / p99 는 서버 쪽 값만 있다.** 클라이언트는 RPC 별 서버 시간을
# 모아 분포를 내지만 자기 벽시계는 wall / N 평균만 낸다. srv_samples 는 성공한
# RPC 수라 busy 가 있으면 n 과 다를 수 있다. 항별 분해가 필요하면
# apply_latency_sweep.sh 를 볼 것 (그쪽은 -profile 오버헤드가 섞인다).
#
# **(4) RPC 타임아웃 (RDMA 5s, TCP 2s) 이 요청당 상한이다.** 지점이 실패해도
# 스윕은 계속하고 마지막에 실패 수를 보고한다 (종료코드 1).
#
# **IB 장치가 있는 호스트에서 실행할 것** (-transport rdma 는 장치가 없으면
# 클라이언트가 거부한다).

set -uo pipefail

TRANSPORT="${1:-}"
case "$TRANSPORT" in
    rdma|tcp) ;;
    *)
        printf 'usage: %s rdma|tcp [출력디렉터리]\n' "$0" >&2
        exit 2
        ;;
esac

OUTDIR="${2:-$HOME/raftof_clean/csv/lat_size_${TRANSPORT}_$(date +%m%d-%H%M%S)}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${BIN:-$REPO/build}"

ADDRS="${ADDRS:-10.0.0.4:6000,10.0.0.5:6000,10.0.0.6:6000}"
SIZES="${SIZES:-64 256 1024 4096 16384 65536 262144 1048576}"
# 엔트리 헤더 크기 (core/include/raft_constants.h ENTRY_META_SIZE). SIZES 는
# 이 헤더를 포함한 엔트리 크기이고, 클라이언트 -size 에는 이만큼 뺀 값을 넘긴다
ENTRY_META=32
N="${N:-1000000}"
REPS="${REPS:-3}"
TIMEOUT_S="${TIMEOUT_S:-15}"
RDMA_MAX="${RDMA_MAX:-$((4 * 1024 * 1024))}"
RING_BYTES="${RING_BYTES:-$((16 * 1024 * 1024))}"
WARMUP="${WARMUP:-1}"
WARMUP_SIZE="${WARMUP_SIZE:-4096}"
WARMUP_BATCH="${WARMUP_BATCH:-10}"

# 링 한 바퀴에 필요한 명령 수를 WARMUP_SIZE 에서 유도한다. WARMUP_SIZE 는 헤더
# 포함 엔트리 크기라 엔트리 하나가 먹는 링 바이트 = ceil(size / 512) * 512.
# 1.2 배를 곱해 한 바퀴를 확실히 넘긴다.
if [ "$WARMUP_SIZE" -le "$ENTRY_META" ]; then
    printf 'WARMUP_SIZE=%s must be > %s (entry header)\n' "$WARMUP_SIZE" "$ENTRY_META" >&2
    exit 2
fi
WARMUP_CMD=$(( WARMUP_SIZE - ENTRY_META ))
warmup_slot_bytes=$(( ((WARMUP_SIZE + 511) / 512) * 512 ))
WARMUP_N="${WARMUP_N:-$(( (RING_BYTES / warmup_slot_bytes) * 12 / 10 + 1 ))}"
BUSY_WARN="${BUSY_WARN:-100}"

CLIENT="$BIN/raft_client"

log()  { printf '\n=== %s\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }

size_label() {
    local b="$1"
    if [ "$b" -ge 1048576 ] && [ $((b % 1048576)) -eq 0 ]; then
        echo "$((b / 1048576))M"
    elif [ "$b" -ge 1024 ] && [ $((b % 1024)) -eq 0 ]; then
        echo "$((b / 1024))K"
    else
        echo "${b}B"
    fi
}

if [ ! -x "$CLIENT" ]; then
    fail "raft_client not found or not executable: $CLIENT"
    printf '       BIN=%s -- ./build.sh client 로 빌드하거나 BIN 을 지정할 것\n' "$BIN"
    exit 1
fi

mkdir -p "$OUTDIR" || exit 1

log "output -> $OUTDIR"
printf '  addrs     : %s\n  transport : %s\n' \
    "$ADDRS" "$TRANSPORT"
printf '  n         : %s   batch: 1   reps: %s\n' "$N" "$REPS"
printf '  client    : %s\n' "$CLIENT"

# ---------------------------------------------------------------------------
# preflight A -- 헤더보다 작은 크기와 RDMA 프레임 상한에 걸리는 크기를 뺀다
#               (머리 주석 (1))
# ---------------------------------------------------------------------------
SWEEP_SIZES=""
for size in $SIZES; do
    if [ "$size" -le "$ENTRY_META" ]; then
        warn "size=$(size_label "$size") <= entry header ${ENTRY_META}B -- empty command, skipping"
        continue
    fi
    if [ "$TRANSPORT" = "rdma" ]; then
        need=$(( size - ENTRY_META + 8 + 64 ))
        if [ "$need" -gt "$RDMA_MAX" ]; then
            warn "size=$(size_label "$size") -> rpc frame ~${need}B > RDMA_MAX=${RDMA_MAX}B -- skipping"
            warn "  (kRdmaMaxMessageBytes 를 올려 재빌드하거나 tcp 로)"
            continue
        fi
    fi
    SWEEP_SIZES="$SWEEP_SIZES $size"
done
SWEEP_SIZES="${SWEEP_SIZES# }"

if [ -z "$SWEEP_SIZES" ]; then
    fail "no sizes left to sweep after the frame check"
    exit 1
fi

# ---------------------------------------------------------------------------
# preflight B -- 클러스터가 실제로 떠 있는가
# ---------------------------------------------------------------------------
log "preflight: commit-index"
naddrs=$(printf '%s\n' "$ADDRS" | tr ',' '\n' | grep -c '[^[:space:]]')
"$CLIENT" -addrs "$ADDRS" -op commit-index -transport "$TRANSPORT" \
    > "$OUTDIR/preflight.log" 2>&1
rc=$?
sed 's/^/       /' "$OUTDIR/preflight.log"
nreach=$(grep -c 'commit_index=' "$OUTDIR/preflight.log")
if [ $rc -ne 0 ] || [ "$nreach" -lt "$naddrs" ]; then
    fail "cluster not ready: $nreach/$naddrs nodes answered (rc=$rc)"
    exit 1
fi
ok "$nreach/$naddrs nodes answered"

# ---------------------------------------------------------------------------
# 워밍업 -- 링을 한 바퀴 넘게 돌려 extent 를 written 으로 만들고 연결·캐시도
# 데운다 (apply_latency_sweep.sh 머리 주석 (4), U11). 결과는 버린다.
# 노드 배너의 ring alloc 이 FALLOC_FL_WRITE_ZEROES 면 링은 처음부터 written
# 이라 한 바퀴까지는 필요 없지만, 해가 없으므로 기본으로 켜 둔다.
# ---------------------------------------------------------------------------
if [ "$WARMUP" != "0" ]; then
    log "warmup: $WARMUP_N × ${WARMUP_SIZE}B entry (cmd ${WARMUP_CMD}B, ring=${RING_BYTES}B, ~1.2 laps) -- discarded"
    "$CLIENT" -addrs "$ADDRS" -op apply -n "$WARMUP_N" -size "$WARMUP_CMD" \
        -batch "$WARMUP_BATCH" -timeout-s "$TIMEOUT_S" -transport "$TRANSPORT" \
        > "$OUTDIR/warmup.log" 2>&1
    if [ $? -ne 0 ]; then
        fail "warmup failed -- see $OUTDIR/warmup.log"
        tail -5 "$OUTDIR/warmup.log" | sed 's/^/       /'
        exit 1
    fi
    ok "$(grep '^applied ' "$OUTDIR/warmup.log" | tail -1)"
fi

# ---------------------------------------------------------------------------
RAW_CSV="$OUTDIR/raw.csv"
SUMMARY_CSV="$OUTDIR/summary.csv"
echo "transport,size_bytes,rep,n,srv_samples,srv_avg_us,srv_p50_us,srv_p95_us,srv_p99_us,wall_ms,client_us_per_cmd,busy_retries" > "$RAW_CSV"

FAILED=0
POINTS=0

# $1 rep   $2 size
run_point() {
    local rep="$1" size="$2"
    local slabel
    slabel=$(size_label "$size")
    local plog="$OUTDIR/apply-r${rep}-${size}.log"
    local cmd=$(( size - ENTRY_META ))   # 헤더 포함 엔트리 크기 -> 명령 크기

    "$CLIENT" -addrs "$ADDRS" -op apply -n "$N" -size "$cmd" \
        -batch 1 -timeout-s "$TIMEOUT_S" -transport "$TRANSPORT" \
        > "$plog" 2>&1
    local rc=$?
    if [ $rc -ne 0 ]; then
        fail "size=$slabel rep=$rep -- client exited $rc, see $plog"
        tail -3 "$plog" | sed 's/^/       /'
        return 1
    fi

    # "applied N commands (incl. 1 leader probe), W ms total, U us/command, busy_retries=B"
    local wall_ms us busy
    wall_ms=$(sed -n 's/^applied .*, \([0-9.]*\) ms total.*/\1/p' "$plog" | tail -1)
    us=$(sed -n 's/^applied .*, \([0-9.]*\) us\/command.*/\1/p' "$plog" | tail -1)
    busy=$(sed -n 's/^applied .*busy_retries=\([0-9]*\).*/\1/p' "$plog" | tail -1)
    if [ -z "$us" ]; then
        fail "size=$slabel rep=$rep -- no 'applied' line in $plog"
        return 1
    fi
    : "${busy:=0}"

    # 서버 쪽 지연 (머리 주석 참고):
    #   "plain apply internal latency summary (n=S samples, microseconds):"
    #   "  avg=A  p50=P  p95=Q  p99=R"
    # 이 줄이 없으면 실패로 친다 -- 클라이언트 값으로 몰래 대체하지 않는다
    local s_n s_avg s_p50 s_p95 s_p99
    s_n=$(sed -n 's/^plain apply internal latency summary (n=\([0-9]*\) samples.*/\1/p' "$plog" | tail -1)
    s_avg=$(sed -n 's/^ *avg=\([0-9.]*\) .*/\1/p' "$plog" | tail -1)
    s_p50=$(sed -n 's/^ *avg=.* p50=\([0-9.]*\) .*/\1/p' "$plog" | tail -1)
    s_p95=$(sed -n 's/^ *avg=.* p95=\([0-9.]*\) .*/\1/p' "$plog" | tail -1)
    s_p99=$(sed -n 's/^ *avg=.* p99=\([0-9.]*\).*/\1/p' "$plog" | tail -1)
    if [ -z "$s_n" ] || [ -z "$s_avg" ] || [ -z "$s_p50" ] || [ -z "$s_p95" ] || [ -z "$s_p99" ]; then
        fail "size=$slabel rep=$rep -- no server latency summary in $plog"
        printf '       (클라이언트가 옛 빌드인가? ./build.sh client 로 다시 빌드할 것)\n'
        return 1
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$TRANSPORT" "$size" "$rep" "$N" "$s_n" "$s_avg" "$s_p50" "$s_p95" "$s_p99" \
        "$wall_ms" "$us" "$busy" >> "$RAW_CSV"
    printf '  size=%-5s rep=%-3s  srv avg=%9s p50=%9s p99=%9s us   client=%9s us/cmd  busy=%s\n' \
        "$slabel" "$rep" "$s_avg" "$s_p50" "$s_p99" "$us" "$busy"

    if [ "$busy" -gt "$BUSY_WARN" ]; then
        warn "busy_retries=$busy > $BUSY_WARN -- 링 백프레셔가 섞였다 (머리 주석 (2))"
    fi
    return 0
}

log "sweep: entry sizes (incl. ${ENTRY_META}B header) =$(for s in $SWEEP_SIZES; do printf ' %s' "$(size_label "$s")"; done)"
# 반복을 바깥 루프로 둔다 -- 시간에 따른 드리프트가 한 크기에 몰리지 않게
for rep in $(seq 1 "$REPS"); do
    for size in $SWEEP_SIZES; do
        POINTS=$((POINTS + 1))
        run_point "$rep" "$size" || FAILED=$((FAILED + 1))
    done
done

# ---------------------------------------------------------------------------
# 요약 -- 크기별로 반복의 srv_avg_us 를 평균한다. stdev 는 표본 표준편차.
# raw.csv 컬럼: 6=srv_avg 7=srv_p50 9=srv_p99 11=client_us_per_cmd 12=busy
# ---------------------------------------------------------------------------
echo "transport,size_bytes,size_label,reps,mean_us,min_us,max_us,stdev_us,p50_us,p99_us,client_mean_us,busy_total" \
    > "$SUMMARY_CSV"
for size in $SWEEP_SIZES; do
    awk -F, -v s="$size" -v t="$TRANSPORT" -v lbl="$(size_label "$size")" '
        NR > 1 && $2 == s {
            n++; v = $6 + 0; sum += v; sq += v * v
            p50 += $7; p99 += $9; cl += $11; busy += $12
            if (n == 1 || v < mn) mn = v
            if (n == 1 || v > mx) mx = v
        }
        END {
            if (n == 0) exit
            mean = sum / n
            sd = (n > 1) ? sqrt((sq - n * mean * mean) / (n - 1)) : 0
            if (sd != sd) sd = 0
            printf "%s,%s,%s,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d\n",
                   t, s, lbl, n, mean, mn, mx, sd, p50 / n, p99 / n, cl / n, busy
        }
    ' "$RAW_CSV" >> "$SUMMARY_CSV"
done

log "summary (server-side, mean of reps)"
column -t -s, "$SUMMARY_CSV" | sed 's/^/  /'

log "done"
printf '  points   : %d run, %d failed\n' "$POINTS" "$FAILED"
printf '  raw      : %s\n  summary  : %s\n' "$RAW_CSV" "$SUMMARY_CSV"

[ "$FAILED" -gt 0 ] && exit 1
exit 0
