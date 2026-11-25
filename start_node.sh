#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

if [[ $# -lt 1 || $# -gt 4 ]]; then
    echo "usage: $0 <node-id> [destination|leader] [rdma|tcp-ib|tcp]"
    echo
    echo "examples:"
    echo "  $0 5"
    echo "  $0 5 destination rdma"
    echo "  $0 5 destination tcp"
    echo "  $0 5 leader rdma"
    echo "  $0 5 leader tcp"
    exit 1
fi

ID="$1"
MODE="${2:-destination}"
TRANSPORT_MODE="${3:-tcp}"

is_valid_id "$ID" || {
    echo "invalid node id: $ID"
    echo "valid ids: $(valid_ids_str)"
    exit 1
}

case "$MODE" in
    destination|leader|push|normal) ;;
    *)
        echo "invalid mode: $MODE"
        echo "valid modes: destination, leader, push, normal"
        exit 1
        ;;
esac


case "$TRANSPORT_MODE" in
    rdma)
        TRANSPORT="rdma"
        select_transport_env rdma
        ;;
    tcp-ib)
        TRANSPORT="tcp"
        select_transport_env tcp-ib
        ;;
    tcp)
        TRANSPORT="tcp"
        select_transport_env tcp
        ;;
    *)
        echo "invalid transport: $TRANSPORT_MODE"
        echo "valid: rdma, tcp (이더넷, TCP 본 실험), tcp-ib (IPoIB)"
        exit 1
        ;;
esac

# push 모드: 다른 멤버 볼륨마다 이 호스트의 장치를 nqn 으로 찾아 id=dev 로 넘긴다.
# 장치 번호는 connect 순서에 따라 호스트마다 다르므로 고정값을 쓰지 않는다
# (틀린 장치를 주면 남의 ext4 볼륨을 조용히 덮어쓴다). PUSH_DEVICES 를 주면 그대로 쓴다.
PUSH_ARGS=()
if [[ "$MODE" == "push" ]]; then
    if [[ -z "${PUSH_DEVICES:-}" ]]; then
        PUSH_DEVICES=""
        for peer in $NODES; do
            [[ "$peer" == "$ID" ]] && continue
            pdev="$(device_for_id "$peer")" || {
                echo "ERROR: push 대상 node $peer 의 볼륨을 찾지 못했다 (모든 멤버 볼륨을 attach 해야 한다)"
                exit 1
            }
            PUSH_DEVICES+="${PUSH_DEVICES:+,}${peer}=${pdev}"
        done
    fi
    PUSH_ARGS+=(-push-devices "$PUSH_DEVICES")
fi

# (11-13) 예전에는 여기서 select_transport_env "$TRANSPORT" 를 한 번 더 불렀다. TRANSPORT 는
# 바이너리 인자(rdma|tcp)라서 tcp-ib 가 tcp(이더넷 주소)로 덮어써졌다 -> 11-13 이전 tcp-ib 는 1GbE 측정.

# 구성(TRANSPORT_MODE)과 실제 주소·NVMe 전송이 맞는지 기동 전에 확인한다 (env.sh check_transport)
MY_ID="$ID" check_transport "$TRANSPORT_MODE" || exit 1

META_DIR="$(metadata_dir_for_id "$ID")"
DEVICE="$(device_for_id "$ID")" || { echo "ERROR: node $ID 자기 볼륨을 찾지 못했다"; exit 1; }

LOG="$RAFT_ROOT/raft_node_${ID}_${MODE}_${TRANSPORT_MODE}.log"

# LOCAL_RUN=1 (기본): 실행 파일을 LOCAL_DIR(/var/tmp/raftof-<user>)로 복사해 돌리고 로그도 로컬에만 쓴다.
#   저장소에는 *.log 를 남기지 않는다 (2026-11-17). 스윕이 읽는 기동 배너는 ${LOG%.log}.cond 에 붙인다.
#   0 이면 예전처럼 build/raft_node 를 NFS 에서 돌리고 $LOG 에 바로 쓴다.
NODE_BIN="$RAFT_ROOT/build/raft_node"
RUN_LOG="$LOG"
BIN_SHA="-"
if [[ "${LOCAL_RUN:-1}" == "1" ]]; then
    read -r NODE_BIN BIN_SHA <<< "$(stage_binary "$RAFT_ROOT/build/raft_node")" || exit 1
    [[ -n "$NODE_BIN" ]] || exit 1
    RUN_LOG="$LOCAL_DIR/${LOG##*/}"
fi

# NUMA 고정: IB 카드가 꽂힌 소켓의 코어·메모리에서만 돌게 한다. 카드 위치가 호스트마다
# 다르다 (eternity7/8 은 NUMA1, 나머지 NUMA0). 반대 소켓에서 돌면 패킷·완료 처리가
# 소켓 간 링크를 건너 노드마다 지연 조건이 달라진다. NUMA_BIND=0 이면 끈다.
NUMA_PREFIX=()
NUMA_DESC="off"

# 공유 라이브러리: libprotobuf32 패키지가 없는 호스트(빌린 eternity8~10)는 저장소의
# 사본(third_party/lib, eternity1 의 3.21.12 와 같은 파일)을 쓴다. 패키지가 있으면 쓰지 않는다.
# sudo 가 LD_LIBRARY_PATH 를 지우므로 env 로 넘긴다.
LIB_PREFIX=()
if ldd "$NODE_BIN" 2>/dev/null | grep -q 'not found'; then
    LIB_DIR="$RAFT_ROOT/third_party/lib"
    if LD_LIBRARY_PATH="$LIB_DIR" ldd "$NODE_BIN" | grep -q 'not found'; then
        echo "ERROR: raft_node 의 공유 라이브러리를 찾지 못했다:"
        LD_LIBRARY_PATH="$LIB_DIR" ldd "$NODE_BIN" | grep 'not found'
        exit 1
    fi
    LIB_PREFIX=(env "LD_LIBRARY_PATH=$LIB_DIR")
fi
if [[ "${NUMA_BIND:-0}" == "1" ]]; then
    IB_IF="$(ib_iface)" || { echo "ERROR: IB 인터페이스를 찾지 못했다 (NUMA_BIND=0 으로 끌 수 있다)"; exit 1; }
    IB_NUMA="$(ib_numa_node)"
    if [[ "$IB_NUMA" =~ ^[0-9]+$ ]]; then
        command -v numactl >/dev/null || { echo "ERROR: numactl 이 없다 (NUMA_BIND=0 으로 끌 수 있다)"; exit 1; }
        NUMA_PREFIX=(numactl "--cpunodebind=$IB_NUMA" "--membind=$IB_NUMA")
        NUMA_DESC="node $IB_NUMA ($IB_IF)"
        # [실험] CPUS="9,22,25,28,29" 면 프로세스 전체를 그 CPU 에만 둔다 (메모리는 IB 노드 그대로).
        # NVMe-oF 쓰기는 보내는 CPU 의 큐로 나가는데, 스토리지 쪽에서 그 큐의 완료 IRQ 가 반대 소켓
        # CPU 에 걸려 있으면 1MiB 쓰기가 ~75us 느리다 (11-08). 빠른 큐의 CPU 만 남겨 비교하는 용도.
        if [[ -n "${CPUS:-}" ]]; then
            NUMA_PREFIX=(numactl "--physcpubind=$CPUS" "--membind=$IB_NUMA")
            NUMA_DESC="cpus $CPUS, mem node $IB_NUMA ($IB_IF)"
        fi
    else
        NUMA_DESC="off ($IB_IF 의 NUMA 노드를 알 수 없음)"
    fi
fi

# I/O 큐 고정 (core/include/raft_cpu_affinity.h, scripts/probe_io_queues.sh)
#   NVMe-oF 쓰기는 보내는 CPU 의 큐로 나가고, 스토리지 쪽에서 그 큐의 완료 IRQ 가 IB 카드와
#   다른 소켓에 걸려 있으면 1MiB 쓰기가 ~75us 느리다 (11-08). 그래서 persist 하는 스레드를
#   probe_io_queues.sh 가 찾은 빠른 큐의 CPU 에 고정한다.
#   IO_PIN=auto (기본)  기록이 있으면 쓰고, 없으면 고정 없이 경고만. 기록이 재연결 전 것이면 중단
#   IO_PIN=1            기록이 없어도 중단
#   IO_PIN=0            고정하지 않는다
#   IO_CPUS="..." / PUSH_CPUS="5=..../6=...."  기록 대신 직접 지정 (대조하지 않는다)
#   IO_SAME_NODE=1 (기본)  기록의 CPU 중 IB NUMA 노드 안의 것만 쓴다 (아래 same_node). 0 이면 기록 그대로
IO_PIN="${IO_PIN:-auto}"
IOQ_FILE="$RAFT_ROOT/results/io_queues/$(hostname -s).env"
IO_ARGS=()
IO_DESC="off (IO_PIN=0)"
PUSH_CPU_DESC=""
ioq_fail() {   # <msg>: IO_PIN=1 이면 중단, auto 면 경고
    if [[ "$IO_PIN" == "1" ]]; then echo "ERROR: $1"; exit 1; fi
    echo "WARN: $1 -- 고정 없이 띄운다"
}
# ioq_cpus <id> -> 기록된 CPU 목록. 기록이 없으면 1, 재연결돼 기록이 낡았으면 2 ($(...) 안이라 exit 대신)
ioq_cpus() {
    local id="$1" vc="IOQ_${1}_CTRL" vi="IOQ_${1}_CNTLID" vp="IOQ_${1}_CPUS" cur
    [[ -n "${!vc:-}" ]] || return 1
    cur="$(ctrl_for_nqn "$(_pool_field "$id" 3)")" || return 1
    if [[ "$cur" != "${!vc} ${!vi}" ]]; then
        echo "ERROR: node $id 볼륨이 기록($IOQ_FILE: ${!vc} cntlid ${!vi}) 뒤에 다시 연결됐다(지금 $cur)." >&2
        echo "       큐 배치가 바뀌었을 수 있다: ./scripts/probe_io_queues.sh 를 다시 돌리거나 IO_PIN=0" >&2
        return 2
    fi
    echo "${!vp}"
}
# 같은 소켓 규칙 (11-12 측정): IO CPU 는 프로세스를 묶은 IB NUMA 노드 안에서만 고른다.
#   -io-cpus 는 Apply/RPC 스레드만 옮긴다. 그 CPU 가 IB 노드 밖이면 AE 스레드(IB 노드)의 커밋 통지를
#   소켓 너머로 받고 메모리도 원격이라 QuorumWait 가 3~4us 늘고 큰 크기에서 튄다 (S 구성 node4:
#   probe 가 NUMA1 을 골라 QW 22~49 -> NUMA0 고정 시 19~22, Total 은 전 크기에서 같거나 나음).
#   probe 가 고른 CPU 중 IB 노드에 속한 것만 남기고, 하나도 없으면 IB 노드 CPU 전체를 쓴다
#   (그 노드의 큐가 모두 느리다는 뜻 -- 큰 쓰기의 LPersist 가 늘어나는 대가를 감수한다).
#   IO_SAME_NODE=0 이면 예전처럼 probe 기록을 그대로 쓴다. IO_CPUS/PUSH_CPUS 직접 지정과
#   CPUS(physcpubind) 에는 적용하지 않는다.
IO_SAME_NODE="${IO_SAME_NODE:-1}"
SAME_NODE_CPUS=""
if [[ "$IO_SAME_NODE" == "1" && "${NUMA_BIND:-0}" == "1" && -z "${CPUS:-}" \
      && "${IB_NUMA:-}" =~ ^[0-9]+$ && -r "/sys/devices/system/node/node$IB_NUMA/cpulist" ]]; then
    for r in $(tr ',' ' ' < "/sys/devices/system/node/node$IB_NUMA/cpulist"); do
        if [[ "$r" == *-* ]]; then
            for ((c = ${r%-*}; c <= ${r#*-}; c++)); do SAME_NODE_CPUS+="${SAME_NODE_CPUS:+,}$c"; done
        else
            SAME_NODE_CPUS+="${SAME_NODE_CPUS:+,}$r"
        fi
    done
fi
# same_node <cpu목록> <설명> -> IB 노드에 속한 CPU 만 (없으면 IB 노드 전체). 바뀌면 stderr 에 알린다.
same_node() {
    local list="$1" what="$2" out="" c
    [[ -n "$SAME_NODE_CPUS" && -n "$list" ]] || { echo "$list"; return 0; }
    for c in ${list//,/ }; do
        [[ ",$SAME_NODE_CPUS," == *",$c,"* ]] && out+="${out:+,}$c"
    done
    if [[ -z "$out" ]]; then
        echo "NOTE: $what: probe CPU($list)가 전부 IB 노드($IB_NUMA) 밖 -> IB 노드 CPU 전체로 고정 (그 노드 큐는 느린 큐)" >&2
        out="$SAME_NODE_CPUS"
    elif [[ "$out" != "$list" ]]; then
        echo "NOTE: $what: IB 노드($IB_NUMA) 밖 CPU 를 뺐다: $list -> $out" >&2
    fi
    echo "$out"
}
if [[ "$IO_PIN" != "0" ]]; then
    [[ -f "$IOQ_FILE" ]] && source "$IOQ_FILE"
    if [[ -n "${IO_CPUS:-}" ]]; then
        IO_ARGS+=(-io-cpus "$IO_CPUS"); IO_DESC="$IO_CPUS (IO_CPUS 직접 지정)"
    elif [[ ! -f "$IOQ_FILE" ]]; then
        ioq_fail "큐 기록($IOQ_FILE)이 없다. ./scripts/probe_io_queues.sh 로 만든다"; IO_DESC="off (기록 없음)"
    elif rc=0; own_cpus="$(ioq_cpus "$ID")" || rc=$?; [[ $rc -eq 2 ]] && exit 1; [[ $rc -ne 0 ]]; then
        ioq_fail "$IOQ_FILE 에 node $ID 기록이 없다"; IO_DESC="off (기록 없음)"
    elif [[ -z "$own_cpus" ]]; then
        IO_DESC="off (빠른 큐 없음, $IOQ_FILE)"
    else
        pinned="$(same_node "$own_cpus" "node $ID io")"
        IO_ARGS+=(-io-cpus "$pinned")
        if [[ "$pinned" == "$own_cpus" ]]; then IO_DESC="$pinned ($IOQ_FILE)"
        else IO_DESC="$pinned (IB 노드 $IB_NUMA 규칙, probe: $own_cpus)"; fi
    fi
    if [[ "$MODE" == "push" ]]; then
        if [[ -n "${PUSH_CPUS:-}" ]]; then
            IO_ARGS+=(-push-cpus "$PUSH_CPUS"); PUSH_CPU_DESC="$PUSH_CPUS (직접 지정)"
        else
            pmap=""
            for item in ${PUSH_DEVICES//,/ }; do
                peer="${item%%=*}"
                rc=0; pc="$(ioq_cpus "$peer")" || rc=$?
                [[ $rc -eq 2 ]] && exit 1
                if [[ $rc -ne 0 ]]; then
                    ioq_fail "push 대상 node $peer 의 큐 기록이 없다 (ALL=1 ./scripts/probe_io_queues.sh)"
                    continue
                fi
                [[ -n "$pc" ]] && pc="$(same_node "$pc" "push $peer")"
                [[ -n "$pc" ]] && pmap+="${pmap:+/}${peer}=${pc}"
            done
            [[ -n "$pmap" ]] && IO_ARGS+=(-push-cpus "$pmap")
            PUSH_CPU_DESC="${pmap:-(none)}"
        fi
    fi
fi

cd "$RAFT_ROOT"

echo "========================================"
echo "Starting Raft node"
echo "========================================"
echo "id          : $ID"
echo "mode        : $MODE"
echo "transport   : $TRANSPORT_MODE (binary -transport $TRANSPORT)"
echo "metadata    : $META_DIR"
echo "device      : $DEVICE"
echo "push-devices: ${PUSH_DEVICES:-(none)}"
echo "cluster     : $CLUSTER"
echo "storage rpc : ${CLUSTER##*@}"
echo "nvme        : $(nvme_desc_for_id "$ID")"
echo "ring-pages  : $RING_PAGES"
echo "precondition: $RING_PRECONDITION"
echo "heartbeat   : $HEARTBEAT_MS ms"
echo "loop_sleep  : $LOOP_SLEEP_US us"
echo "ae-batch    : $AE_BATCH"
echo "numa bind   : $NUMA_DESC"
echo "io cpus     : $IO_DESC"
[[ -n "$PUSH_CPU_DESC" ]] && echo "push cpus   : $PUSH_CPU_DESC"
if [[ "$RUN_LOG" == "$LOG" ]]; then
    echo "log         : $LOG"
else
    echo "binary      : $NODE_BIN (sha $BIN_SHA)"
    echo "log         : $RUN_LOG (로컬에만. 저장소에는 배너를 ${LOG%.log}.cond 에 붙인다)"
fi
echo "========================================"

if [[ ! -b "$DEVICE" ]]; then
    echo "ERROR: block device does not exist: $DEVICE"
    exit 1
fi

if ! mountpoint -q /mnt/raftvol; then
    echo "ERROR: /mnt/raftvol is not mounted"
    exit 1
fi

MNT_SRC="$(findmnt -n -o SOURCE /mnt/raftvol | tail -1)"
if [[ "$MNT_SRC" != "$DEVICE" ]]; then
    echo "ERROR: /mnt/raftvol 에 마운트된 장치($MNT_SRC)가 node $ID 볼륨($DEVICE)이 아니다"
    exit 1
fi

sudo mkdir -p "$META_DIR"

if pgrep -f '[r]aft_node' >/dev/null; then
    echo "ERROR: raft_node already running:"
    pgrep -af '[r]aft_node'
    exit 1
fi

PRECONDITION_ARGS=()
if [[ "$RING_PRECONDITION" == "1" ]]; then
    PRECONDITION_ARGS+=("-precondition-ring")
fi

# EXTRA_ARGS: 맨 뒤에 덧붙일 raft_node 옵션 (예: EXTRA_ARGS="-debug -sm hash").
# 뒤에 온 값이 이기므로 아래 고정값(-sm noop 등)도 여기서 덮어쓸 수 있다.
read -r -a EXTRA_ARR <<< "${EXTRA_ARGS:-}"

sudo "${LIB_PREFIX[@]}" "${NUMA_PREFIX[@]}" stdbuf -oL -eL "$NODE_BIN" \
    -id "$ID" \
    -cluster "$CLUSTER" \
    -metadata-dir "$META_DIR" \
    -transport "$TRANSPORT" \
    -mode "$MODE" \
    -ring-pages "$RING_PAGES" \
    "${PRECONDITION_ARGS[@]}" \
    "${PUSH_ARGS[@]}" \
    "${IO_ARGS[@]}" \
    -heartbeat-ms "$HEARTBEAT_MS" \
    -loop-sleep-us "$LOOP_SLEEP_US" \
    -ae-batch 256 \
    -gc-max-reqs 64 \
    -gc-max-bytes "$MAX_GC_BYTES" \
    -sm noop \
    "${EXTRA_ARR[@]}" \
    > "$RUN_LOG" 2>&1 &

# -gc-max-reqs "$MAX_GC_REQ" \
# -gc-max-bytes "$MAX_GC_BYTES" \
PID=$!

# 측정 조건 (env.sh record_net_cond 가 읽는다): 스크립트가 고른 전송 구성. 바이너리 로그와 따로 둔다
{
    echo "host        : $(hostname -s)"
    echo "transport   : $TRANSPORT_MODE (binary -transport $TRANSPORT)"
    echo "cluster     : $CLUSTER"
    echo "storage rpc : ${CLUSTER##*@}"
    echo "nvme        : $(nvme_desc_for_id "$ID")"
    echo "binary sha  : $BIN_SHA"
} > "${LOG%.log}.cond"

sleep 1

if ! ps -p "$PID" >/dev/null 2>&1; then
    echo "ERROR: raft_node exited during startup"
    tail -100 "$RUN_LOG"
    exit 1
fi

# 스윕의 record_io_pin 이 읽는 기동 배너(io cpus / push device)를 저장소의 .cond 에 붙인다
if [[ "$RUN_LOG" != "$LOG" ]]; then
    publish_banner "$RUN_LOG" "$LOCAL_DIR/banner_node_${ID}" "$BIN_SHA" '^  term/tail'
    cat "$LOCAL_DIR/banner_node_${ID}" >> "${LOG%.log}.cond"
fi

echo
echo "raft_node started"
echo "pid: $PID"

echo
pgrep -af '[r]aft_node' || true

echo
# FOLLOW=1: 기동 후 로그를 터미널에 계속 띄운다 (tail -f). 노드는 백그라운드라
# Ctrl-C 는 tail 만 끊고 raft_node 는 계속 돈다. 끌 때는 ./stop_node.sh.
# 디버그 상태 줄까지 보려면 EXTRA_ARGS="-debug" 와 같이 준다.
if [[ "${FOLLOW:-0}" == "1" ]]; then
    echo "---- following $RUN_LOG (Ctrl-C 는 tail 만 끊는다) ----"
    exec tail -n 30 -f "$RUN_LOG"
fi
tail -30 "$RUN_LOG"