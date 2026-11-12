#!/usr/bin/env bash
#
# net_cost.sh -- remote pull 의 원격 읽기 비용을 "순수 네트워크(패브릭)" 와 "매체" 로 나누는 실험
#
#   ./net_cost.sh up       설정 (이 호스트 몫만, sudo)
#   ./net_cost.sh run      이 호스트의 fio 사다리 실행 -> results/net_cost/<host>.csv
#   ./net_cost.sh ib       RDMA verbs 하한 (ib_read_lat). eternity1 = 서버(먼저), eternitystorage = 클라이언트
#   ./net_cost.sh report   두 호스트 결과를 합쳐 분해표 출력 (어느 호스트에서든, 읽기만)
#   ./net_cost.sh down     원복: up 이 만든 것만 지운다
#   ./net_cost.sh status   현재 상태 (읽기만)
#
# 아이디어: eternity1 에 매체가 없는 메모리 블록 장치(null_blk, memory_backed)를 만들어 e1node1 과 같은
#   nvmet port 로 export 하고(e1null), eternitystorage 가 e1node1 과 똑같이(-w 10.0.0.91, -i 8) 붙인다.
#   blockcopy 서버와 같은 방식(O_DIRECT pread, QD1)으로 읽어서
#     remote_null - local_null   = 패브릭 순비용 (RDMA + nvme-rdma initiator + nvmet target, eternity1 CPU 포함)
#     remote970  - remote_null   = 패브릭 너머에서 본 970 매체
#     local970   - local_null    = 로컬에서 본 970 매체 (CPU NUMA0 vs NUMA1 로 소켓 건넘 비용도 본다)
#     remote970  - localPM983    = blockcopy 의 SRead 가 local pull 대비 늘어난 양 (StorageIO 차이와 대조)
#   ib_read_lat 은 그 아래 물리 하한이다 (null 계층과의 차이 = NVMe-oF 스택).
#
# 호스트:
#   eternity1        up: null_blk(configfs) 장치 + nvmet 서브시스템 e1null.  run: local_null, local970(NUMA0/1)
#   eternitystorage  up: e1null attach.  run: remote_null, remote970(e1node1 이 붙어 있을 때), localPM983
#
# 순서: up 은 eternity1 -> eternitystorage, down 은 eternitystorage -> eternity1 (반대로 하면 initiator 가
#   ctrl_loss_tmo 동안 재연결을 시도한다). run 은 두 호스트에서 동시에 돌리지 말 것 (970·CPU 를 서로 방해).
#   raft_node 는 멈춘 상태여야 한다. blockcopy 서버는 떠 있어도 되지만 일을 하고 있으면 안 된다.
#
# 환경변수: QUEUES(기본 8), RUNTIME(fio 한 번 초, 기본 10), SIZES(바이트, 기본 "512 4096 16384 65536 262144")
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NULL_NQN="e1null"
NULL_NAME="e1null"                                   # configfs nullb 항목 이름
NULL_UUID="4e554c4c-0000-4000-8000-0000000000e1"
NULL_UUID_LINK="/dev/disk/by-id/nvme-uuid.$NULL_UUID"
NULL_MB=1024
E1_NQN="e1node1"
E1_UUID_LINK="/dev/disk/by-id/nvme-uuid.3ffbc4a8-8cde-4ba2-b208-ccd5d47a433a"
E1_ADDR="10.0.0.1"
PORT="4420"
SRC_ADDR="10.0.0.91"
QUEUES="${QUEUES:-8}"
RUNTIME="${RUNTIME:-10}"
SIZES="${SIZES:-512 4096 16384 65536 262144}"
SPAN="128M"
OFF_970=59995324416          # node4 링 둘째 extent (물리 블록 14647296 x 4096) -- 실제로 쓰인 구간
OFF_PM983=210201739264       # node5 링 첫 extent (물리 블록 51318784 x 4096)
PM983_LINK="/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496"
NVMET="/sys/kernel/config/nvmet"
NULLB_CFS="/sys/kernel/config/nullb"
STATE_DIR="/var/lib/raftof-net-cost"
STATE="$STATE_DIR/state"
OUT_DIR="$SCRIPT_DIR/results/net_cost"

die() { echo "ERROR: $*" >&2; exit 1; }
as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

case "${1:-}" in
    up|down|status|run|ib|report) ;;
    *) sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
CMD="$1"

state_get() { [[ -r "$STATE" ]] && sed -n "s/^$1=//p" "$STATE" | tail -1; }
state_set() { echo "$1=$2" | as_root tee -a "$STATE" >/dev/null; }
state_begin() {
    [[ -e "$STATE" ]] && die "이미 up 상태다 ($STATE). 다시 하려면 먼저 down"
    as_root mkdir -p "$STATE_DIR" || die "$STATE_DIR 를 만들지 못했다"
    state_set HOST "$(hostname -s)"
}
state_end() { as_root rm -rf "$STATE_DIR"; echo "[down] 완료 -- 기록 삭제"; }
print_state() {
    if [[ -r "$STATE" ]]; then echo "net-cost    : UP ($STATE)"; sed 's/^/  /' "$STATE"
    else echo "net-cost    : down (기록 없음)"; fi
}

ctrl_for_nqn() {
    local c
    for c in /sys/class/nvme/nvme[0-9]*; do
        [[ -r "$c/subsysnqn" && "$(<"$c/subsysnqn")" == "$1" ]] && { echo "${c##*/}"; return 0; }
    done
    return 1
}

# ---------------------------------------------------------------- fio
# fio_one <tier> <dev> <cpu> <bs> <offset>  -> CSV 한 줄을 OUT 에 추가
fio_one() {
    local tier=$1 dev=$2 cpu=$3 bs=$4 off=$5 line
    line="$(as_root taskset -c "$cpu" fio --name="$tier" --filename="$dev" --readonly --direct=1 \
        --ioengine=psync --rw=randread --bs="$bs" --offset="$off" --size="$SPAN" --time_based \
        --runtime="$RUNTIME" --randrepeat=0 --output-format=json 2>/dev/null \
        | jq -r '.jobs[0].read | [ (.clat_ns.mean/1000), (.clat_ns.percentile["50.000000"]/1000), (.clat_ns.percentile["99.000000"]/1000), .total_ios ] | map(tostring) | join(",")')"
    [[ -n "$line" && "$line" != *null* ]] || { echo "WARN: fio 실패: $tier $dev cpu$cpu bs=$bs" >&2; return 1; }
    echo "$(hostname -s),$tier,$dev,$cpu,$bs,$line" >> "$OUT"
    printf "  %-12s cpu%-3s bs=%-7s mean=%s p50=%s p99=%s n=%s\n" "$tier" "$cpu" "$bs" $(echo "$line" | tr ',' ' ')
}

# ladder <tier> <dev> <offset> <cpus...>
ladder() {
    local tier=$1 dev=$2 off=$3; shift 3
    local cpu bs
    [[ -b "$(readlink -f "$dev")" ]] || { echo "WARN: $tier: $dev 가 없다 -- 건너뜀" >&2; return 0; }
    echo "[run] $tier  $dev -> $(readlink -f "$dev")  offset=$off"
    for bs in $SIZES; do for cpu in "$@"; do fio_one "$tier" "$dev" "$cpu" "$bs" "$off"; done; done
}

run_begin() {
    command -v fio >/dev/null && command -v jq >/dev/null || die "fio 와 jq 가 필요하다"
    pgrep -x raft_node >/dev/null && die "이 호스트에서 raft_node 가 돌고 있다"
    mkdir -p "$OUT_DIR"
    OUT="$OUT_DIR/$(hostname -s).csv"
    [[ -e "$OUT" ]] && mv "$OUT" "$OUT.$(date +%m%d-%H%M%S).bak"
    echo "host,tier,dev,cpu,bs,mean_us,p50_us,p99_us,n" > "$OUT"
    echo "[run] $(date '+%F %T')  RUNTIME=${RUNTIME}s  SIZES=$SIZES  -> $OUT"
    as_root true || exit 1
}

# ---------------------------------------------------------------- eternity1 (타깃)
null_dev() {   # configfs 항목의 블록 장치 경로
    local d="$NULLB_CFS/$NULL_NAME"
    [[ -d "$d" ]] || return 1
    if [[ -b "/dev/$NULL_NAME" ]]; then echo "/dev/$NULL_NAME"
    elif [[ -r "$d/index" && -b "/dev/nullb$(<"$d/index")" ]]; then echo "/dev/nullb$(<"$d/index")"
    else return 1; fi
}

t_up() {
    local port="$NVMET/ports/1" sub="$NVMET/subsystems/$NULL_NQN" dev
    [[ -d "$port" ]] || die "nvmet port 1 이 없다"
    [[ "$(cat "$port/addr_trtype") $(cat "$port/addr_traddr"):$(cat "$port/addr_trsvcid")" == "rdma $E1_ADDR:$PORT" ]] \
        || die "nvmet port 1 이 rdma $E1_ADDR:$PORT 가 아니다"
    [[ -e "$sub" ]] && die "nvmet 서브시스템 $NULL_NQN 이 이미 있다 (기록 없이) -- 손으로 확인"
    state_begin

    if [[ ! -d /sys/module/null_blk ]]; then
        as_root modprobe null_blk nr_devices=0 || die "modprobe null_blk 실패"
        state_set MODULE_LOADED 1
        echo "[up] null_blk 모듈 로드 (nr_devices=0)"
    fi
    [[ -d "$NULLB_CFS" ]] || die "$NULLB_CFS 가 없다 (configfs null_blk 미지원)"
    [[ -e "$NULLB_CFS/$NULL_NAME" ]] && die "$NULLB_CFS/$NULL_NAME 이 이미 있다"
    as_root mkdir "$NULLB_CFS/$NULL_NAME" || die "nullb 항목 생성 실패"
    state_set NULLB 1
    local kv
    for kv in "size=$NULL_MB" "blocksize=512" "memory_backed=1" "irqmode=0" "home_node=0" "power=1"; do
        echo "${kv#*=}" | as_root tee "$NULLB_CFS/$NULL_NAME/${kv%%=*}" >/dev/null || die "nullb ${kv%%=*} 설정 실패"
    done
    for _ in $(seq 1 25); do dev="$(null_dev)" && break; sleep 0.2; done
    [[ -n "${dev:-}" ]] || die "null_blk 장치가 나타나지 않았다"
    echo "[up] $dev: ${NULL_MB}MB, 512B, memory_backed, irqmode=0(인라인 완료), home_node=0"
    # 메모리 페이지를 미리 할당해 둔다 (안 쓴 구간을 읽으면 페이지 없이 0 채우기만 해서 더 빠르다)
    as_root dd if=/dev/urandom of="$dev" bs=1M count=128 oflag=direct status=none || die "$dev 채우기 실패"
    echo "[up] $dev 앞 128MiB 채움"

    as_root mkdir "$sub" || die "nvmet 서브시스템 생성 실패"
    state_set SUBSYS 1
    echo 1 | as_root tee "$sub/attr_allow_any_host" >/dev/null
    as_root mkdir "$sub/namespaces/1" || die "namespace 생성 실패"
    echo "$dev" | as_root tee "$sub/namespaces/1/device_path" >/dev/null
    echo "$NULL_UUID" | as_root tee "$sub/namespaces/1/device_uuid" >/dev/null
    echo 1 | as_root tee "$sub/namespaces/1/enable" >/dev/null || die "namespace enable 실패"
    as_root ln -s "$sub" "$port/subsystems/$NULL_NQN" || die "port 1 링크 실패"
    state_set LINKED 1
    echo "[up] nvmet $NULL_NQN ns1 -> $dev (uuid $NULL_UUID), port 1 rdma $E1_ADDR:$PORT"
    echo
    echo "다음: eternitystorage 에서 ./net_cost.sh up"
}

t_down() {
    [[ -r "$STATE" ]] || { echo "up 기록이 없다 -- 되돌릴 것이 없다"; return 0; }
    local sub="$NVMET/subsystems/$NULL_NQN" rc=0
    echo "(eternitystorage 에서 먼저 ./net_cost.sh down 했어야 한다)"
    if [[ "$(state_get LINKED)" == "1" && -L "$NVMET/ports/1/subsystems/$NULL_NQN" ]]; then
        as_root rm "$NVMET/ports/1/subsystems/$NULL_NQN" && echo "[down] port 1 링크 해제" || rc=1
    fi
    if [[ "$(state_get SUBSYS)" == "1" && -d "$sub" ]]; then
        if [[ -d "$sub/namespaces/1" ]]; then
            echo 0 | as_root tee "$sub/namespaces/1/enable" >/dev/null
            as_root rmdir "$sub/namespaces/1" || rc=1
        fi
        as_root rmdir "$sub" && echo "[down] nvmet $NULL_NQN 삭제" || rc=1
    fi
    if [[ "$(state_get NULLB)" == "1" && -d "$NULLB_CFS/$NULL_NAME" ]]; then
        echo 0 | as_root tee "$NULLB_CFS/$NULL_NAME/power" >/dev/null
        as_root rmdir "$NULLB_CFS/$NULL_NAME" && echo "[down] null_blk 장치 삭제" || rc=1
    fi
    if [[ "$(state_get MODULE_LOADED)" == "1" && $rc -eq 0 ]]; then
        as_root modprobe -r null_blk && echo "[down] null_blk 모듈 내림" || rc=1
    fi
    if [[ $rc -eq 0 ]]; then state_end; else echo "[down] 일부 실패 -- 기록($STATE)을 남겨 둔다" >&2; return 1; fi
}

t_status() {
    local sub="$NVMET/subsystems/$NULL_NQN"
    echo "host        : $(hostname -s) (타깃)"
    echo "null_blk    : $(null_dev 2>/dev/null || echo '없음')"
    if [[ -d "$sub/namespaces/1" ]]; then
        echo "$NULL_NQN      : ns1 $(cat "$sub/namespaces/1/device_path") enable=$(cat "$sub/namespaces/1/enable") port1=$([[ -L "$NVMET/ports/1/subsystems/$NULL_NQN" ]] && echo linked || echo no)"
    else
        echo "$NULL_NQN      : 없음"
    fi
    echo "nvme0n1     : write_cache=$(cat /sys/block/nvme0n1/queue/write_cache)"
    print_state
}

t_run() {
    local dev
    dev="$(null_dev)" || die "null_blk 장치가 없다 -- 먼저 ./net_cost.sh up"
    run_begin
    ladder local_null  "$dev"         0         0 2 4      # HCA 와 같은 NUMA0
    ladder local970_n0 /dev/nvme0n1   "$OFF_970" 0 2 4      # NUMA0 CPU (HCA 쪽, SSD 와 소켓이 다름)
    ladder local970_n1 /dev/nvme0n1   "$OFF_970" 10 12 14   # NUMA1 CPU (SSD 쪽)
    echo "[run] 끝: $OUT"
}

t_ib() {
    command -v ib_read_lat >/dev/null || die "ib_read_lat 이 없다"
    mkdir -p "$OUT_DIR"
    echo "[ib] 서버 대기 (eternitystorage 에서 ./net_cost.sh ib 를 실행할 것). 끝나면 자동 종료"
    taskset -c 2 ib_read_lat -d ibp59s0 -F -a -n 5000
}

# ---------------------------------------------------------------- eternitystorage (initiator)
s_up() {
    [[ -d /sys/module/nvme_rdma ]] || die "nvme-rdma 모듈이 없다"
    ctrl_for_nqn "$NULL_NQN" >/dev/null && die "$NULL_NQN 이 이미 붙어 있다 (기록 없이) -- 손으로 확인"
    state_begin
    as_root nvme connect -t rdma -a "$E1_ADDR" -s "$PORT" -n "$NULL_NQN" -i "$QUEUES" -w "$SRC_ADDR" \
        || die "$NULL_NQN connect 실패 (eternity1 에서 ./net_cost.sh up 했는지)"
    state_set CONNECTED 1
    command -v udevadm >/dev/null && as_root udevadm settle
    local ctrl
    ctrl="$(ctrl_for_nqn "$NULL_NQN")" || die "$NULL_NQN 컨트롤러가 없다"
    grep -q "host_traddr=$SRC_ADDR" "/sys/class/nvme/$ctrl/address" \
        || die "$ctrl 가 $SRC_ADDR 에서 나가지 않는다 ($(tr '\n' ' ' < "/sys/class/nvme/$ctrl/address"))"
    for _ in $(seq 1 25); do [[ -e "$NULL_UUID_LINK" ]] && break; sleep 0.2; done
    [[ -e "$NULL_UUID_LINK" ]] || die "$NULL_UUID_LINK 가 생기지 않았다"
    echo "[up] $NULL_NQN -> $(readlink -f "$NULL_UUID_LINK") ($ctrl, -i $QUEUES, host_traddr=$SRC_ADDR)"
    ctrl_for_nqn "$E1_NQN" >/dev/null \
        && echo "[up] $E1_NQN 도 붙어 있다 -> run 이 remote970 까지 잰다" \
        || echo "WARN: $E1_NQN 이 붙어 있지 않다 -> run 에서 remote970 을 건너뛴다 (./remote_pull.sh up)" >&2
    echo
    echo "다음: eternity1 에서 ./net_cost.sh run, 끝나면 eternitystorage 에서 ./net_cost.sh run (동시에 하지 말 것)"
}

s_down() {
    [[ -r "$STATE" ]] || { echo "up 기록이 없다 -- 되돌릴 것이 없다"; return 0; }
    if [[ "$(state_get CONNECTED)" == "1" ]] && ctrl_for_nqn "$NULL_NQN" >/dev/null; then
        as_root nvme disconnect -n "$NULL_NQN" >/dev/null || die "$NULL_NQN detach 실패 (기록 유지)"
        echo "[down] $NULL_NQN detach"
    fi
    state_end
    echo "다음: eternity1 에서 ./net_cost.sh down"
}

s_status() {
    local c
    echo "host        : $(hostname -s) (initiator)"
    for n in "$NULL_NQN" "$E1_NQN"; do
        if c="$(ctrl_for_nqn "$n")"; then
            echo "$(printf '%-12s' "$n"): $c $(tr '\n' ' ' < "/sys/class/nvme/$c/address") q=$(cat "/sys/class/nvme/$c/queue_count")"
        else
            echo "$(printf '%-12s' "$n"): not attached"
        fi
    done
    echo "server      : $(pgrep -af '^(\S*/)?raft_blockcopy_server( |$)' | head -1 || true)"
    print_state
}

s_run() {
    [[ -e "$NULL_UUID_LINK" ]] || die "$NULL_UUID_LINK 가 없다 -- 먼저 ./net_cost.sh up"
    run_begin
    ladder remote_null  "$NULL_UUID_LINK" 0            0 2 4
    if ctrl_for_nqn "$E1_NQN" >/dev/null; then
        ladder remote970 "$E1_UUID_LINK" "$OFF_970"    0 2 4
    else
        echo "WARN: $E1_NQN 이 붙어 있지 않아 remote970 을 건너뛴다" >&2
    fi
    ladder localPM983  "$PM983_LINK"     "$OFF_PM983"  0 2 4
    echo "[run] 끝: $OUT"
}

s_ib() {
    command -v ib_read_lat >/dev/null || die "ib_read_lat 이 없다"
    mkdir -p "$OUT_DIR"
    local out="$OUT_DIR/ib_read_lat.txt"
    echo "[ib] eternity1 에 접속 (eternity1 에서 ./net_cost.sh ib 가 먼저 떠 있어야 한다) -> $out"
    taskset -c 2 ib_read_lat -d ibp59s0 -F -a -n 5000 "$E1_ADDR" | tee "$out"
}

# ---------------------------------------------------------------- report (읽기만)
do_report() {
    python3 - "$OUT_DIR" <<'EOF'
import csv, os, sys, statistics as st
d = sys.argv[1]
rows = []
for h in ("eternity1", "eternitystorage"):
    p = os.path.join(d, h + ".csv")
    if os.path.exists(p):
        rows += list(csv.DictReader(open(p)))
    else:
        print(f"(없음: {p})")
if not rows:
    sys.exit(0)
# tier,bs -> CPU 3개의 중앙값
agg = {}
for r in rows:
    agg.setdefault((r["tier"], int(r["bs"])), []).append(r)
def m(tier, bs, k="p50_us"):
    v = agg.get((tier, bs))
    return st.median(float(x[k]) for x in v) if v else None
ib = {}
p = os.path.join(d, "ib_read_lat.txt")
if os.path.exists(p):
    for line in open(p):
        f = line.split()
        if len(f) >= 5 and f[0].isdigit():
            # #bytes #iter t_min t_max t_typical t_avg t_stdev 99% 99.9%
            ib[int(f[0])] = {"p50_us": float(f[4]), "p99_us": float(f[7]) if len(f) >= 8 else None}
sizes = sorted({bs for _, bs in agg})
tiers = ["local_null", "remote_null", "local970_n0", "local970_n1", "remote970", "localPM983"]
def lab(b): return f"{b//1024}K" if b >= 1024 else f"{b}B"
def fmt(x): return f"{x:8.1f}" if x is not None else "       -"
def sub(a, b): return None if a is None or b is None else a - b
for k in ("p50_us", "p99_us"):
    print(f"\n== 원시값 {k} (CPU 3개 중앙값, us)")
    print(f"{'bs':>6} " + " ".join(f"{t:>11}" for t in tiers) + f" {'ib_read':>8}")
    for b in sizes:
        print(f"{lab(b):>6} " + " ".join(f"{fmt(m(t, b, k)):>11}" for t in tiers) + f" {fmt(ib.get(b, {}).get(k))}")
print("\n== 분해 (p50, us)")
print(f"{'bs':>6} {'패브릭':>8} {'NVMeoF스택':>10} {'970@원격':>9} {'970@로컬':>9} {'소켓건넘':>8} {'원격-PM983':>10}")
print(f"{'':>6} {'rN-lN':>8} {'rN-lN-ib':>10} {'r970-rN':>9} {'l970-lN':>9} {'n0-n1':>8} {'r970-PM':>10}")
for b in sizes:
    fab = sub(m("remote_null", b), m("local_null", b))
    print(f"{lab(b):>6} {fmt(fab)} {fmt(sub(fab, ib.get(b, {}).get('p50_us'))):>10} "
          f"{fmt(sub(m('remote970', b), m('remote_null', b))):>9} {fmt(sub(m('local970_n0', b), m('local_null', b))):>9} "
          f"{fmt(sub(m('local970_n0', b), m('local970_n1', b)))} {fmt(sub(m('remote970', b), m('localPM983', b))):>10}")
print("\n참고: 1111 StorageIO p50 차이(remote-local pull): 64B~1K +16~19, 4K +22.5, 16K +33.5, 64K +56.0, 256K +59.0")
EOF
}

# ----------------------------------------------------------------
if [[ "$CMD" == "report" ]]; then do_report; exit 0; fi
case "$(hostname -s)" in
    eternity1)       ROLE=t ;;
    eternitystorage) ROLE=s ;;
    *) echo "$(hostname -s): net_cost 에서 이 호스트가 할 일은 없다 (eternity1/eternitystorage 만, report 는 어디서든)"; exit 0 ;;
esac
"${ROLE}_${CMD}"
