#!/usr/bin/env bash
#
# size_latency_sweep.sh -- 페이로드 크기를 16B 부터 4배씩 1MiB 까지 키우며
#                          3-node Raft 의 end-to-end apply 지연을 잰다
#                          (breakdown 없음)
#
# 묻는 것: **엔트리 하나가 커질 때 클라이언트가 보는 지연이 어떻게 늘어나는가.**
# apply_latency_sweep.sh 와 달리 항별 분해(ApplyTimings)는 보지 않는다.
# -op apply (apply-timed 아님) 로 돌리고, 클라이언트 벽시계 기준
# us/command = wall / N 을 지점 값으로 쓴다. batch 1, 단일 클라이언트이므로
# 이 값이 곧 명령 하나의 평균 왕복 지연이다.
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
#   SIZES        페이로드 바이트 목록 (기본 16 64 256 1K 4K 16K 64K 256K 1M)
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
#   WARMUP_SIZE / WARMUP_BATCH   워밍업 파라미터 (기본 4064 / 10)
#   WARMUP_N     워밍업 명령 수 (기본: RING_BYTES 에서 링 1.2 바퀴로 유도)
#   BUSY_WARN    busy_retries 가 이 값을 넘으면 경고 (기본 100)
#
# 출력:
#   raw.csv      transport,size_bytes,rep,n,wall_ms,us_per_cmd,busy_retries
#   summary.csv  transport,size_bytes,size_label,reps,mean_us,min_us,max_us,stdev_us,busy_total
#                mean_us = 반복별 us_per_cmd 의 산술평균
#   apply-r<rep>-<size>.log   원본 클라이언트 출력
#
# ── 읽기 전에 알 것 ───────────────────────────────────────────────────────
#
# **(1) RDMA 프레임 상한은 4MiB 다** (net/include/raft_rdma_transport.h:54).
# ClientApply 요청은 페이로드를 그대로 싣고 protobuf/프레임 헤더가 붙으므로,
# 페이로드가 4MiB 에 가까우면 encode_frame 에서 예외로 죽는다. preflight 가
# 걸리는 크기를 빼고 경고한다. 기본 SIZES (최대 1MiB) 는 전부 들어간다.
# **세 노드와 클라이언트가 모두 4MiB 로 빌드돼 있어야 한다** -- 노드가 옛
# 1MiB 빌드면 1M 지점에서 서버 쪽 수신이 실패한다. kRdmaMaxMessageBytes 를
# 다시 바꾸면 RDMA_MAX 도 맞출 것.
#
# **(2) 큰 페이로드는 링이 커야 한다.** 엔트리 하나가 먹는 슬롯은
# ceil((32 + size) / 512) 이고 (core/src/raft_ring_helpers.cpp:13), 링이 작으면
# 랩마다 GC 를 기다리다 busy 가 나서 지연 대신 백프레셔를 재게 된다.
# 1MiB 는 엔트리당 2049 슬롯이라 -ring-pages 4096 (16MiB) 이면 한 랩에 15 개다.
# 노드를 넉넉한 -ring-pages 로 띄울 것. busy_retries 가 큰 지점은 믿지 말 것.
#
# **(3) p50 / p99 는 없다.** -op apply 는 RPC 별 시간을 남기지 않아서 wall / N
# 평균만 나온다. 분포가 필요하면 apply_latency_sweep.sh 의 Total 을 볼 것
# (그쪽은 -profile 오버헤드가 섞인다).
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

ADDRS="${ADDRS:-10.0.0.4:6001,10.0.0.5:6001,10.0.0.6:6001}"
SIZES="${SIZES:-16 64 256 1024 4096 16384 65536 262144 1048576}"
N="${N:-10000}"
REPS="${REPS:-3}"
TIMEOUT_S="${TIMEOUT_S:-15}"
RDMA_MAX="${RDMA_MAX:-$((4 * 1024 * 1024))}"
RING_BYTES="${RING_BYTES:-$((16 * 1024 * 1024))}"
WARMUP="${WARMUP:-1}"
WARMUP_SIZE="${WARMUP_SIZE:-4064}"
WARMUP_BATCH="${WARMUP_BATCH:-10}"

# 링 한 바퀴에 필요한 명령 수를 WARMUP_SIZE 에서 유도한다 (apply_latency_sweep.sh
# 와 같은 식). 엔트리 하나가 먹는 링 바이트 = ceil((32 + size) / 512) * 512.
# 1.2 배를 곱해 한 바퀴를 확실히 넘긴다.
warmup_slot_bytes=$(( ((32 + WARMUP_SIZE + 511) / 512) * 512 ))
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
# preflight A -- RDMA 프레임 상한에 걸리는 크기를 뺀다 (머리 주석 (1))
# ---------------------------------------------------------------------------
SWEEP_SIZES=""
for size in $SIZES; do
    if [ "$TRANSPORT" = "rdma" ]; then
        need=$(( size + 8 + 64 ))
        if [ "$need" -gt "$RDMA_MAX" ]; then
            warn "size=$(size_label "$size") + header = ${need}B > RDMA_MAX=${RDMA_MAX}B -- skipping"
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
    log "warmup: $WARMUP_N × ${WARMUP_SIZE}B (ring=${RING_BYTES}B, ~1.2 laps) -- discarded"
    "$CLIENT" -addrs "$ADDRS" -op apply -n "$WARMUP_N" -size "$WARMUP_SIZE" \
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
echo "transport,size_bytes,rep,n,wall_ms,us_per_cmd,busy_retries" > "$RAW_CSV"

FAILED=0
POINTS=0

# $1 rep   $2 size
run_point() {
    local rep="$1" size="$2"
    local slabel
    slabel=$(size_label "$size")
    local plog="$OUTDIR/apply-r${rep}-${size}.log"

    "$CLIENT" -addrs "$ADDRS" -op apply -n "$N" -size "$size" \
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

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$TRANSPORT" "$size" "$rep" "$N" "$wall_ms" "$us" "$busy" >> "$RAW_CSV"
    printf '  size=%-5s rep=%-3s  %10s us/cmd  busy=%s\n' \
        "$slabel" "$rep" "$us" "$busy"

    if [ "$busy" -gt "$BUSY_WARN" ]; then
        warn "busy_retries=$busy > $BUSY_WARN -- 링 백프레셔가 섞였다 (머리 주석 (2))"
    fi
    return 0
}

log "sweep: sizes =$(for s in $SWEEP_SIZES; do printf ' %s' "$(size_label "$s")"; done)"
# 반복을 바깥 루프로 둔다 -- 시간에 따른 드리프트가 한 크기에 몰리지 않게
for rep in $(seq 1 "$REPS"); do
    for size in $SWEEP_SIZES; do
        POINTS=$((POINTS + 1))
        run_point "$rep" "$size" || FAILED=$((FAILED + 1))
    done
done

# ---------------------------------------------------------------------------
# 요약 -- 크기별로 반복의 us_per_cmd 를 평균한다. stdev 는 표본 표준편차
# ---------------------------------------------------------------------------
echo "transport,size_bytes,size_label,reps,mean_us,min_us,max_us,stdev_us,busy_total" \
    > "$SUMMARY_CSV"
for size in $SWEEP_SIZES; do
    awk -F, -v s="$size" -v t="$TRANSPORT" -v lbl="$(size_label "$size")" '
        NR > 1 && $2 == s {
            n++; v = $6 + 0; sum += v; sq += v * v; busy += $7
            if (n == 1 || v < mn) mn = v
            if (n == 1 || v > mx) mx = v
        }
        END {
            if (n == 0) exit
            mean = sum / n
            sd = (n > 1) ? sqrt((sq - n * mean * mean) / (n - 1)) : 0
            if (sd != sd) sd = 0
            printf "%s,%s,%s,%d,%.2f,%.2f,%.2f,%.2f,%d\n", t, s, lbl, n, mean, mn, mx, sd, busy
        }
    ' "$RAW_CSV" >> "$SUMMARY_CSV"
done

log "summary (mean of reps)"
column -t -s, "$SUMMARY_CSV" | sed 's/^/  /'

log "done"
printf '  points   : %d run, %d failed\n' "$POINTS" "$FAILED"
printf '  raw      : %s\n  summary  : %s\n' "$RAW_CSV" "$SUMMARY_CSV"

[ "$FAILED" -gt 0 ] && exit 1
exit 0
