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
TRANSPORT_MODE="${3:-rdma}"

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

select_transport_env "$TRANSPORT"

META_DIR="$(metadata_dir_for_id "$ID")"
DEVICE="$(device_for_id "$ID")" || { echo "ERROR: node $ID 자기 볼륨을 찾지 못했다"; exit 1; }

LOG="$RAFT_ROOT/raft_node_${ID}_${MODE}_${TRANSPORT_MODE}.log"

# NUMA 고정: IB 카드가 꽂힌 소켓의 코어·메모리에서만 돌게 한다. 카드 위치가 호스트마다
# 다르다 (eternity7/8 은 NUMA1, 나머지 NUMA0). 반대 소켓에서 돌면 패킷·완료 처리가
# 소켓 간 링크를 건너 노드마다 지연 조건이 달라진다. NUMA_BIND=0 이면 끈다.
NUMA_PREFIX=()
NUMA_DESC="off"

# 공유 라이브러리: libprotobuf32 패키지가 없는 호스트(빌린 eternity8~10)는 저장소의
# 사본(third_party/lib, eternity1 의 3.21.12 와 같은 파일)을 쓴다. 패키지가 있으면 쓰지 않는다.
# sudo 가 LD_LIBRARY_PATH 를 지우므로 env 로 넘긴다.
LIB_PREFIX=()
if ldd "$RAFT_ROOT/build/raft_node" 2>/dev/null | grep -q 'not found'; then
    LIB_DIR="$RAFT_ROOT/third_party/lib"
    if LD_LIBRARY_PATH="$LIB_DIR" ldd "$RAFT_ROOT/build/raft_node" | grep -q 'not found'; then
        echo "ERROR: raft_node 의 공유 라이브러리를 찾지 못했다:"
        LD_LIBRARY_PATH="$LIB_DIR" ldd "$RAFT_ROOT/build/raft_node" | grep 'not found'
        exit 1
    fi
    LIB_PREFIX=(env "LD_LIBRARY_PATH=$LIB_DIR")
fi
if [[ "${NUMA_BIND:-1}" == "1" ]]; then
    IB_IF="$(ib_iface)" || { echo "ERROR: IB 인터페이스를 찾지 못했다 (NUMA_BIND=0 으로 끌 수 있다)"; exit 1; }
    IB_NUMA="$(ib_numa_node)"
    if [[ "$IB_NUMA" =~ ^[0-9]+$ ]]; then
        command -v numactl >/dev/null || { echo "ERROR: numactl 이 없다 (NUMA_BIND=0 으로 끌 수 있다)"; exit 1; }
        NUMA_PREFIX=(numactl "--cpunodebind=$IB_NUMA" "--membind=$IB_NUMA")
        NUMA_DESC="node $IB_NUMA ($IB_IF)"
    else
        NUMA_DESC="off ($IB_IF 의 NUMA 노드를 알 수 없음)"
    fi
fi

cd "$RAFT_ROOT"

echo "========================================"
echo "Starting Raft node"
echo "========================================"
echo "id          : $ID"
echo "mode        : $MODE"
echo "transport   : $TRANSPORT"
echo "metadata    : $META_DIR"
echo "device      : $DEVICE"
echo "push-devices: ${PUSH_DEVICES:-(none)}"
echo "cluster     : $CLUSTER"
echo "ring-pages  : $RING_PAGES"
echo "precondition: $RING_PRECONDITION"
echo "heartbeat   : $HEARTBEAT_MS ms"
echo "ae-batch    : $AE_BATCH"
echo "numa bind   : $NUMA_DESC"
echo "log         : $LOG"
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

sudo "${LIB_PREFIX[@]}" "${NUMA_PREFIX[@]}" stdbuf -oL -eL ./build/raft_node \
    -id "$ID" \
    -cluster "$CLUSTER" \
    -metadata-dir "$META_DIR" \
    -transport "$TRANSPORT" \
    -mode "$MODE" \
    -ring-pages "$RING_PAGES" \
    "${PRECONDITION_ARGS[@]}" \
    "${PUSH_ARGS[@]}" \
    -heartbeat-ms "$HEARTBEAT_MS" \
    -loop-sleep-us 200 \
    -ae-batch 256 \
    -gc-max-reqs 64 \
    -gc-max-bytes "$MAX_GC_BYTES" \
    -profile \
    -sm noop \
    "${EXTRA_ARR[@]}" \
    > "$LOG" 2>&1 &

# -gc-max-reqs "$MAX_GC_REQ" \
# -gc-max-bytes "$MAX_GC_BYTES" \
PID=$!

sleep 1

if ! ps -p "$PID" >/dev/null 2>&1; then
    echo "ERROR: raft_node exited during startup"
    tail -100 "$LOG"
    exit 1
fi

echo
echo "raft_node started"
echo "pid: $PID"

echo
pgrep -af '[r]aft_node' || true

echo
tail -30 "$LOG"