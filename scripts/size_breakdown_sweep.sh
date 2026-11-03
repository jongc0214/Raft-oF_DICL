#!/usr/bin/env bash
#
# size_breakdown_sweep.sh -- size_latency_sweep.sh 와 같은 조건(16B..1MiB 4배씩,
#                            N=10000, batch 1, 단일 클라이언트, 3회)으로 돌리되
#                            ApplyTimings 항별 breakdown 까지 낸다
#
# 측정 자체는 apply_latency_sweep.sh 에 맡긴다 (-op apply-timed, 파싱, 워밍업,
# preflight 전부 그쪽). 이 스크립트는 기본값을 맞춰 그것을 부르고, 반복을
# 평균해 크기 × 항 표를 만든다.
#
# **서버는 이미 떠 있다고 가정한다.** 노드를 띄우지도 죽이지도 않는다.
#
# 사용법:
#   ./scripts/size_breakdown_sweep.sh rdma|tcp [출력디렉터리]
#
#   rdma|tcp  클라이언트 전송. **노드를 띄운 -transport 와 같아야 한다**
#
# 환경변수: SIZES N REPS ADDRS TIMEOUT_S BIN RING_BYTES WARMUP ... 는
# apply_latency_sweep.sh 로 그대로 넘어간다 (그 머리 주석 참고). 여기서 바꾸는
# 기본값은 SIZES (16 .. 1M, 4배씩) 와 REPS (3) 뿐이다.
#
# 출력 (출력디렉터리 안):
#   latency.csv          apply_latency_sweep.sh 원본 (반복이 행으로 쌓여 있다)
#   summary.csv          transport,size_bytes,size_label,term,reps,mean_us,p50_us,p99_us
#                        같은 (size, term) 행의 반복 산술평균. p50/p99 의 평균은
#                        전체의 p50/p99 가 아니다 -- 반복 간 흔들림을 줄이는 용도
#   breakdown_mean.csv   행 = 항, 열 = 크기, 값 = mean_us (반복 평균).
#                        **mean 이라야 항등식이 성립한다** (p50 끼리는 더할 수 없다)
#   client_wall.csv      size_bytes,size_label,reps,us_per_cmd
#                        클라이언트 벽시계 wall / N. size_latency_sweep.sh 의
#                        mean_us 와 견줄 값이다 (profile 오버헤드 확인용)
#
# ── 읽기 전에 알 것 ───────────────────────────────────────────────────────
#
# **노드에 -profile 이 켜져 있어야 한다.** 꺼져 있으면 항들이 0 으로 나온다
# (apply_latency_sweep.sh 가 첫 지점에서 경고한다). -profile 자체가 지연을 조금
# 올리므로 절대값은 size_latency_sweep.sh (profile 없이 띄운 노드) 쪽을 쓰고,
# 이 스크립트는 항의 비중을 보는 데 쓸 것.
#
# **push 모드에서는 ReplNet 이 0 이다** -- 팔로워가 pull 하지 않으므로.
# 팔로워 데이터 경로는 StorageIO 쪽에 잡힌다 (compare_latency.sh 머리 주석).
#
# **RDMA 프레임 상한은 4MiB 다** (net/include/raft_rdma_transport.h:54). 기본
# SIZES (최대 1MiB) 는 전부 들어간다. 세 노드와 클라이언트가 모두 4MiB 로
# 빌드돼 있어야 한다. 상한을 다시 바꾸면 RDMA_MAX 로 맞출 것 (그대로 넘어간다).
#
# **apply-timed 는 RPC 마다 한 줄을 stdout 에 찍는다.** 로그가 NFS(홈)에
# 쌓이지만 Total 은 서버가 잰 값이라 거기에 섞이지 않는다. client_wall 에는
# 섞일 수 있다.

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
OUTDIR="${2:-$REPO/csv/lat_breakdown_${TRANSPORT}_$(date +%m%d-%H%M%S)}"

export TRANSPORT
export SIZES="${SIZES:-16 64 256 1024 4096 16384 65536 262144 1048576}"
export REPS="${REPS:-3}"
export N="${N:-10000}"
export BATCH=1

"$REPO/scripts/apply_latency_sweep.sh" "$OUTDIR"
SWEEP_RC=$?

LATENCY_CSV="$OUTDIR/latency.csv"
if [ ! -s "$LATENCY_CSV" ] || [ "$(grep -c . "$LATENCY_CSV")" -le 1 ]; then
    printf '  [FAIL] %s 에 데이터가 없다 -- 요약을 건너뛴다\n' "$LATENCY_CSV"
    exit 1
fi

# ---------------------------------------------------------------------------
# 요약 -- (size, term) 별 반복 평균. 크기 순서는 SIZES, 항 순서는 latency.csv
# 에 처음 나온 순서 그대로 둔다 (Total, LHandler, ... residual)
# ---------------------------------------------------------------------------
SUMMARY_CSV="$OUTDIR/summary.csv"
WIDE_CSV="$OUTDIR/breakdown_mean.csv"
WALL_CSV="$OUTDIR/client_wall.csv"

awk -F, -v t="$TRANSPORT" -v n_cmd="$N" \
    -v sizes="$SIZES" -v summary="$SUMMARY_CSV" -v wide="$WIDE_CSV" -v wall="$WALL_CSV" '
    function label(b) {
        if (b >= 1048576 && b % 1048576 == 0) return (b / 1048576) "M"
        if (b >= 1024 && b % 1024 == 0)       return (b / 1024) "K"
        return b "B"
    }
    NR == 1 { next }
    {
        s = $1; term = $3; k = s SUBSEP term
        if (!(term in seen_term)) { seen_term[term] = 1; terms[++nt] = term }
        cnt[k]++; mean[k] += $4; p50[k] += $5; p99[k] += $6
        # wall_ms 는 지점마다 13 행에 같은 값이 반복된다 -- Total 행에서만 센다
        if (term == "Total" && $7 != "") { wcnt[s]++; wsum[s] += $7 }
        has_size[s] = 1
    }
    END {
        ns = split(sizes, sz, /[ \t]+/)
        m = 0
        for (i = 1; i <= ns; i++) if (sz[i] != "" && (sz[i] in has_size)) ok[++m] = sz[i]

        print "transport,size_bytes,size_label,term,reps,mean_us,p50_us,p99_us" > summary
        for (i = 1; i <= m; i++) for (j = 1; j <= nt; j++) {
            k = ok[i] SUBSEP terms[j]
            if (!(k in cnt)) continue
            c = cnt[k]
            printf "%s,%s,%s,%s,%d,%.2f,%.2f,%.2f\n", t, ok[i], label(ok[i]), terms[j], c,
                   mean[k] / c, p50[k] / c, p99[k] / c > summary
        }

        line = "term"
        for (i = 1; i <= m; i++) line = line "," label(ok[i])
        print line > wide
        for (j = 1; j <= nt; j++) {
            line = terms[j]
            for (i = 1; i <= m; i++) {
                k = ok[i] SUBSEP terms[j]
                line = line "," ((k in cnt) ? sprintf("%.2f", mean[k] / cnt[k]) : "")
            }
            print line > wide
        }

        print "size_bytes,size_label,reps,us_per_cmd" > wall
        for (i = 1; i <= m; i++) {
            s = ok[i]
            if (!(s in wcnt)) continue
            printf "%s,%s,%d,%.2f\n", s, label(s), wcnt[s],
                   wsum[s] / wcnt[s] * 1000 / n_cmd > wall
        }
    }
' "$LATENCY_CSV"

printf '\n=== breakdown (%s, mean_us, mean of reps)\n' "$TRANSPORT"
column -t -s, "$WIDE_CSV" | sed 's/^/  /'
printf '\n=== client wall (us/cmd)\n'
column -t -s, "$WALL_CSV" | sed 's/^/  /'
printf '\n  summary   : %s\n  breakdown : %s\n  wall      : %s\n' \
    "$SUMMARY_CSV" "$WIDE_CSV" "$WALL_CSV"

exit "$SWEEP_RC"
