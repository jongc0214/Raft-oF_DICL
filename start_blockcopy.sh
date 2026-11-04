#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAFT_ROOT="$SCRIPT_DIR"
source "$SCRIPT_DIR/env.sh"
build_bc_devices

TRANSPORT="${1:-tcp}"

case "$TRANSPORT" in
    rdma|tcp|tcp-ib) ;;
    *)
        echo "usage: $0 [rdma|tcp|tcp-ib]"
        exit 1
        ;;
esac

LOG="$RAFT_ROOT/raft_blockcopy_server_${TRANSPORT}.log"

cd "$RAFT_ROOT"

echo "========================================"
echo "Starting BlockCopy server"
echo "========================================"
echo "transport   : $TRANSPORT"
echo "listen      : 0.0.0.0:5050"
echo "nodes       : $NODES"
echo "devices     : $BC_DEVICES   (NODES 순서 = cluster_index 순서)"
echo "workers     : 8"
echo "log         : $LOG"
echo "========================================"

IFS=',' read -r -a BC_DEV_ARR <<< "$BC_DEVICES"
for dev in "${BC_DEV_ARR[@]}"; do
    if [[ ! -b "$dev" ]]; then
        echo "ERROR: block device not found: $dev"
        exit 1
    fi
done

# -devices[i] 는 NODES 의 i 번째 노드 볼륨이어야 한다. 어긋나면 블록 복사가 에러 없이
# 다른 볼륨으로 간다. nvmet 서브시스템 node<ID> 가 내보내는 장치와 실제 장치가 같은지 확인한다.
NVMET=/sys/kernel/config/nvmet/subsystems
read -r -a NODE_ARR <<< "$NODES"
for i in "${!NODE_ARR[@]}"; do
    id="${NODE_ARR[$i]}"
    dev="${BC_DEV_ARR[$i]}"
    want=""
    for dp in "$NVMET/node$id"/namespaces/*/device_path; do
        [[ -r "$dp" ]] && want="$(readlink -f "$(cat "$dp")")"
    done
    have="$(readlink -f "$dev")"
    if [[ -z "$want" ]]; then
        echo "ERROR: nvmet subsystem node$id 의 device_path 를 읽지 못했다 ($NVMET/node$id)"
        exit 1
    fi
    if [[ "$want" != "$have" ]]; then
        echo "ERROR: node$id: -devices 의 $dev ($have) 가 nvmet node$id 의 장치($want)와 다르다 (env.sh POOL 확인)"
        exit 1
    fi
    echo "node$id -> $dev ($have) == nvmet node$id OK"
done

if pgrep -f '^(\S*/)?raft_blockcopy_server( |$)' >/dev/null; then
    echo "ERROR: raft_blockcopy_server already running:"
    pgrep -af '^(\S*/)?raft_blockcopy_server( |$)'
    exit 1
fi

sudo stdbuf -oL -eL ./build/raft_blockcopy_server \
    -addr 0.0.0.0:5050 \
    -devices "$BC_DEVICES" \
    -copy-workers 8 \
    -transport "$TRANSPORT" \
    > "$LOG" 2>&1 &

PID=$!

sleep 1

if ! ps -p "$PID" >/dev/null 2>&1; then
    echo "ERROR: blockcopy server failed to start"
    tail -100 "$LOG"
    exit 1
fi

echo
echo "blockcopy server started"
echo "pid: $PID"

echo
pgrep -af '^(\S*/)?raft_blockcopy_server( |$)' || true

echo
tail -30 "$LOG"