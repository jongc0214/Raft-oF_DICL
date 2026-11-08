#!/usr/bin/env bash
#
# braft_size_latency_sweep.sh -- size_latency_sweep.sh 의 braft 판.
#                                페이로드를 16B 부터 4배씩 1MiB 까지 키우며
#                                3-node braft(block 예제)의 apply 지연을 잰다
#
# raftof 쪽과 같게 맞춘 것: 크기 목록(16 .. 1M, 4배씩), 지점당 N=10000, batch 1,
# 단일 closed-loop 클라이언트, 반복 3회(반복을 바깥 루프로), 시작 시 워밍업 1회,
# raw.csv / summary.csv 형식(앞 8열이 같다), 지점별 원본 로그.
#
# 지표 두 가지를 같이 남긴다:
#   us_per_cmd  클라이언트 벽시계 = elapsed_sec / completed. size_latency_sweep.sh 의
#               us_per_cmd 와 같은 정의(측정 루프만, 워밍업 제외)
#   srv_*_us    서버가 잰 값 = block_server 가 node->apply 직전부터 완료 콜백까지
#               (server.cpp BlockClosure). block_client 가 원래 출력하는 latency_* 가
#               이것이다. raftof 의 대응값은 raft_client -op apply 의
#               "plain apply internal latency summary" 줄 (apply-r*.log 에 남는다)
#
# **서버는 이미 떠 있다고 가정한다** (braft_block_tools/run_block_node.sh).
# 노드를 띄우지도 죽이지도 않는다.
#
# 사용법:
#   ./scripts/braft_size_latency_sweep.sh rdma|tcp [출력디렉터리]
#
#   rdma|tcp  **기록용 라벨**이다 -- 노드를 띄운 RPC_TRANSPORT(run_block_node.sh)와
#             같게 줄 것. 노드 사이 raft RPC 의 전송을 뜻한다. 클라이언트는 이
#             값과 무관하게 brpc 기본 채널(TCP, cluster.env 의 1GbE 주소)로 리더에
#             붙는다 -- 아래 "읽기 전에 알 것" (1)
#
# 환경변수:
#   BRAFT_TOOLS  braft_block_tools 디렉터리 (기본 /home/jongc/braft/braft_block_tools).
#                cluster.env 에서 CONF / PORT / BLOCK_BUILD_DIR 를 가져온다
#   NODES / TOPO cluster.env 로 그대로 넘어간다 (기본 4 5 6). 노드와 같아야 한다
#   SIZES        페이로드 바이트 목록 (기본 16 64 256 1K 4K 16K 64K 256K 1M)
#   N            지점당 측정 요청 수 (기본 10000)
#   REPS         지점당 반복 횟수 (기본 3)
#   POINT_WARMUP 지점마다 측정 전에 버리는 요청 수 (기본 100). block_client 는
#                프로세스마다 리더 탐색과 채널 생성을 새로 하므로 그 비용을 뺀다
#   WARMUP       1 이면 시작 시 전역 워밍업 1회 (기본 1). 결과는 버린다
#   WARMUP_SIZE / WARMUP_N   전역 워밍업 파라미터 (기본 4064 / 5000)
#   REQ_TIMEOUT_MS  요청당 brpc 타임아웃 (기본 3000)
#   POINT_TIMEOUT_S 지점 하나(프로세스 하나)의 상한 (기본 1800). block_client 는
#                실패한 요청을 **무한 재시도**하므로 이게 없으면 영원히 멈출 수 있다
#   BREAKDOWN    1 이면 지점마다 서버 breakdown 을 초기화하고 끝나면 리더 것을 저장
#                (기본 1, run_block_10k.sh 와 같은 /flags/breakdown_reset, /vars/braft_breakdown)
#
# 출력:
#   raw.csv      transport,size_bytes,rep,n,wall_ms,us_per_cmd,srv_avg_us,srv_p50_us,srv_p99_us
#   summary.csv  transport,size_bytes,size_label,reps,mean_us,min_us,max_us,stdev_us,
#                srv_avg_us,srv_p50_us,srv_p99_us
#                앞 8열은 size_latency_sweep.sh 의 summary.csv 와 같은 정의다
#                (mean_us = 반복별 us_per_cmd 의 평균). srv_* 는 반복 평균
#   block-r<rep>-<size>.log      원본 클라이언트 출력
#   breakdown-r<rep>-<size>.txt  리더 breakdown (BREAKDOWN=1)
#
# ── 읽기 전에 알 것 ───────────────────────────────────────────────────────
#
# **(1) 클라이언트→리더 경로가 raftof 와 다르다.** block_client 는 brpc 채널을
# 기본 옵션으로 만들므로 TCP 이고, 주소는 cluster.env 의 1GbE(115.145.173.x)다.
# 페이로드가 이 경로로 실리므로 큰 크기에서 us_per_cmd 에 1GbE 전송 시간이
# 그대로 들어간다(256KiB ≈ 2ms). raftof 를 rdma(IPoIB)로 돌렸다면 us_per_cmd 끼리는
# 같은 조건이 아니다 -- **시스템끼리는 srv_*_us 로 비교할 것.**
#
# **(2) block_client 는 offset 0 에 같은 페이로드('a')를 쓴다.** raftof 의 'x' 와
# 마찬가지로 내용은 상수다.
#
# **(3) 서버는 -breakdown=true 로 떠 있다** (run_block_node.sh). raftof 의
# -profile 과 같은 종류의 계측 오버헤드가 양쪽에 다 있다.
#
# **(4) 실행 호스트:** block_client 바이너리가 있는 곳 (BLOCK_BUILD_DIR, NFS).

set -uo pipefail

TRANSPORT="${1:-}"
case "$TRANSPORT" in
    rdma|tcp) ;;
    *)
        printf 'usage: %s rdma|tcp [출력디렉터리]\n' "$0" >&2
        exit 2
        ;;
esac

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${2:-$REPO/csv/braft_lat_size_${TRANSPORT}_$(date +%m%d-%H%M%S)}"

BRAFT_TOOLS="${BRAFT_TOOLS:-/home/jongc/braft/braft_block_tools}"
if [ ! -r "$BRAFT_TOOLS/cluster.env" ]; then
    printf '  [FAIL] %s/cluster.env 를 읽을 수 없다 (BRAFT_TOOLS 확인)\n' "$BRAFT_TOOLS" >&2
    exit 1
fi
# shellcheck disable=SC1091
source "$BRAFT_TOOLS/cluster.env"
build_conf || exit 1

CLIENT="$BLOCK_BUILD_DIR/block_client"
SIZES="${SIZES:-4096 262144}"
N="${N:-100000}"
REPS="${REPS:-3}"
POINT_WARMUP="${POINT_WARMUP:-100}"
WARMUP="${WARMUP:-1}"
WARMUP_SIZE="${WARMUP_SIZE:-4064}"
WARMUP_N="${WARMUP_N:-5000}"
REQ_TIMEOUT_MS="${REQ_TIMEOUT_MS:-3000}"
POINT_TIMEOUT_S="${POINT_TIMEOUT_S:-1800}"
BREAKDOWN="${BREAKDOWN:-1}"

NODE_IPS="$(printf '%s\n' "$CONF" | tr ',' '\n' | cut -d: -f1)"

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

# key=value 출력에서 값 하나 ($1 = key, $2 = 파일)
kv() { sed -n "s/^$1=//p" "$2" | tail -1; }

# block_client 한 번 ($1 size  $2 warmup  $3 count  $4 log)
run_client() {
    timeout "$POINT_TIMEOUT_S" "$CLIENT" \
        --conf="$CONF" --group=Block \
        --request_size="$1" --warmup_count="$2" --request_count="$3" \
        --timeout_ms="$REQ_TIMEOUT_MS" \
        > "$4" 2>&1
}

if [ ! -x "$CLIENT" ]; then
    fail "block_client not found or not executable: $CLIENT"
    exit 1
fi

mkdir -p "$OUTDIR" || exit 1

log "output -> $OUTDIR"
printf '  conf      : %s\n  transport : %s (label; node RPC)\n' "$CONF" "$TRANSPORT"
printf '  n         : %s   batch: 1   reps: %s   point warmup: %s\n' "$N" "$REPS" "$POINT_WARMUP"
printf '  client    : %s\n' "$CLIENT"
{
    printf 'conf=%s\ntransport=%s\nn=%s\nreps=%s\npoint_warmup=%s\nclient=%s\n' \
        "$CONF" "$TRANSPORT" "$N" "$REPS" "$POINT_WARMUP" "$CLIENT"
    # 노드별 C-state (state0.. 의 disable). 지연 비교의 교란 변수라 결과와 같이 남긴다.
    # 호스트명 규칙 eternity<ID> (raftof env.sh 와 같다). 실패하면 빈 값.
    for id in $NODES; do
        printf 'cpuidle_disable_eternity%s=%s\n' "$id" \
            "$(ssh -o BatchMode=yes -o ConnectTimeout=3 "eternity$id" \
                 'cat /sys/devices/system/cpu/cpu0/cpuidle/state*/disable' 2>/dev/null | tr '\n' ' ')"
    done
} > "$OUTDIR/meta.txt"

# ---------------------------------------------------------------------------
# preflight -- 노드 HTTP 포트가 살아 있고, 요청 하나가 커밋되는가
# ---------------------------------------------------------------------------
log "preflight"
nup=0; nn=0
for ip in $NODE_IPS; do
    nn=$((nn + 1))
    if curl -s -m 3 -o /dev/null "http://$ip:$PORT/health"; then
        nup=$((nup + 1))
    else
        warn "$ip:$PORT 가 HTTP 에 응답하지 않는다"
    fi
done
if [ "$nup" -lt "$nn" ]; then
    fail "cluster not ready: $nup/$nn nodes answered"
    exit 1
fi
ok "$nup/$nn nodes answered"

if ! POINT_TIMEOUT_S=30 run_client 16 0 1 "$OUTDIR/preflight.log" ||
   [ "$(kv completed "$OUTDIR/preflight.log")" != "1" ]; then
    fail "한 요청도 커밋되지 않았다 (30s) -- see $OUTDIR/preflight.log"
    tail -5 "$OUTDIR/preflight.log" | sed 's/^/       /'
    exit 1
fi
ok "1 request committed"

# ---------------------------------------------------------------------------
# 전역 워밍업 -- 결과는 버린다
# ---------------------------------------------------------------------------
if [ "$WARMUP" != "0" ]; then
    log "warmup: $WARMUP_N × ${WARMUP_SIZE}B -- discarded"
    if ! run_client "$WARMUP_SIZE" 0 "$WARMUP_N" "$OUTDIR/warmup.log"; then
        fail "warmup failed -- see $OUTDIR/warmup.log"
        tail -5 "$OUTDIR/warmup.log" | sed 's/^/       /'
        exit 1
    fi
    ok "completed=$(kv completed "$OUTDIR/warmup.log") elapsed_sec=$(kv elapsed_sec "$OUTDIR/warmup.log")"
fi

# ---------------------------------------------------------------------------
RAW_CSV="$OUTDIR/raw.csv"
SUMMARY_CSV="$OUTDIR/summary.csv"
echo "transport,size_bytes,rep,n,wall_ms,us_per_cmd,srv_avg_us,srv_p50_us,srv_p99_us" > "$RAW_CSV"

FAILED=0
POINTS=0

# $1 rep   $2 size
run_point() {
    local rep="$1" size="$2"
    local slabel plog
    slabel=$(size_label "$size")
    plog="$OUTDIR/block-r${rep}-${size}.log"

    if [ "$BREAKDOWN" = "1" ]; then
        for ip in $NODE_IPS; do
            curl -s -m 3 -o /dev/null "http://$ip:$PORT/flags/breakdown_reset?setvalue=true" || true
        done
    fi

    run_client "$size" "$POINT_WARMUP" "$N" "$plog"
    local rc=$?
    if [ $rc -ne 0 ]; then
        if [ $rc -eq 124 ]; then
            fail "size=$slabel rep=$rep -- ${POINT_TIMEOUT_S}s 안에 끝나지 않았다 (block_client 는 실패를 무한 재시도한다), see $plog"
        else
            fail "size=$slabel rep=$rep -- client exited $rc, see $plog"
        fi
        tail -3 "$plog" | sed 's/^/       /'
        return 1
    fi

    local done_n el avg p50 p99
    done_n=$(kv completed "$plog")
    el=$(kv elapsed_sec "$plog")
    avg=$(kv latency_avg_us "$plog")
    p50=$(kv latency_p50_us "$plog")
    p99=$(kv latency_p99_us "$plog")
    if [ -z "$done_n" ] || [ -z "$el" ] || [ "$done_n" -eq 0 ]; then
        fail "size=$slabel rep=$rep -- no result lines in $plog"
        return 1
    fi

    local wall_ms us
    wall_ms=$(awk -v e="$el" 'BEGIN { printf "%.2f", e * 1000 }')
    us=$(awk -v e="$el" -v n="$done_n" 'BEGIN { printf "%.1f", e * 1e6 / n }')

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$TRANSPORT" "$size" "$rep" "$done_n" "$wall_ms" "$us" "$avg" "$p50" "$p99" >> "$RAW_CSV"
    printf '  size=%-5s rep=%-3s  %10s us/cmd  srv avg=%s p50=%s p99=%s\n' \
        "$slabel" "$rep" "$us" "$avg" "$p50" "$p99"

    if [ "$BREAKDOWN" = "1" ]; then
        local ip out
        for ip in $NODE_IPS; do
            out="$(curl -s -m 5 "http://$ip:$PORT/vars/braft_breakdown" | grep BRAFT-BREAKDOWN || true)"
            [ -z "$out" ] && continue
            case "$out" in *"(n=0 samples"*) continue ;; esac   # follower: 값 없음
            { echo "# breakdown leader=$ip size=$size rep=$rep"; echo "$out"; } \
                > "$OUTDIR/breakdown-r${rep}-${size}.txt"
        done
    fi
    return 0
}

log "sweep: sizes =$(for s in $SIZES; do printf ' %s' "$(size_label "$s")"; done)"
# 반복을 바깥 루프로 둔다 -- 시간에 따른 드리프트가 한 크기에 몰리지 않게
for rep in $(seq 1 "$REPS"); do
    for size in $SIZES; do
        POINTS=$((POINTS + 1))
        run_point "$rep" "$size" || FAILED=$((FAILED + 1))
    done
done

# ---------------------------------------------------------------------------
# 요약 -- 크기별 반복 평균. stdev 는 us_per_cmd 의 표본 표준편차
# ---------------------------------------------------------------------------
echo "transport,size_bytes,size_label,reps,mean_us,min_us,max_us,stdev_us,srv_avg_us,srv_p50_us,srv_p99_us" \
    > "$SUMMARY_CSV"
for size in $SIZES; do
    awk -F, -v s="$size" -v t="$TRANSPORT" -v lbl="$(size_label "$size")" '
        NR > 1 && $2 == s {
            n++; v = $6 + 0; sum += v; sq += v * v
            sa += $7; s50 += $8; s99 += $9
            if (n == 1 || v < mn) mn = v
            if (n == 1 || v > mx) mx = v
        }
        END {
            if (n == 0) exit
            mean = sum / n
            sd = (n > 1) ? sqrt((sq - n * mean * mean) / (n - 1)) : 0
            if (sd != sd) sd = 0
            printf "%s,%s,%s,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
                   t, s, lbl, n, mean, mn, mx, sd, sa / n, s50 / n, s99 / n
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
