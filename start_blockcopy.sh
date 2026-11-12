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

# LOCAL_RUN=1 (기본): 실행 파일을 LOCAL_DIR 로 복사해 돌리고 로그도 로컬에 쓴다 (start_node.sh 와 같다).
#   저장소($LOG)에는 기동 배너만, stop_blockcopy.sh 가 전체 로그로 덮어쓴다.
BC_BIN="$RAFT_ROOT/build/raft_blockcopy_server"
RUN_LOG="$LOG"
BIN_SHA="-"
if [[ "${LOCAL_RUN:-1}" == "1" ]]; then
    read -r BC_BIN BIN_SHA <<< "$(stage_binary "$RAFT_ROOT/build/raft_blockcopy_server")" || exit 1
    [[ -n "$BC_BIN" ]] || exit 1
    RUN_LOG="$LOCAL_DIR/${LOG##*/}"
fi

cd "$RAFT_ROOT"

echo "========================================"
echo "Starting BlockCopy server"
echo "========================================"
echo "transport   : $TRANSPORT"
echo "listen      : 0.0.0.0:5050"
echo "nodes       : $NODES"
echo "devices     : $BC_DEVICES   (NODES 순서 = cluster_index 순서)"
echo "workers     : 8"
if [[ "$RUN_LOG" == "$LOG" ]]; then
    echo "log         : $LOG"
else
    echo "binary      : $BC_BIN (sha $BIN_SHA)"
    echo "log         : $RUN_LOG (로컬; 저장소 $LOG 에는 배너만, stop_blockcopy.sh 가 전체를 가져온다)"
fi
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
    if [[ -n "$want" && "$want" == "$have" ]]; then
        echo "node$id -> $dev ($have) == nvmet node$id OK"
        continue
    fi
    # 원격 볼륨: 이 서버가 다른 스토리지의 서브시스템을 initiator 로 붙여 쓰는 경우
    # (NODE4_E1=1 의 node4 = eternity1 e1node1). POOL nqn 으로 붙은 장치와 같아야 한다.
    nqn="$(_pool_field "$id" 3)"
    rdev="$(dev_for_nqn "$nqn" 2>/dev/null || true)"
    if [[ -n "$rdev" && "$(readlink -f "$rdev")" == "$have" ]]; then
        echo "node$id -> $dev ($have) == attached $nqn OK (remote)"
        continue
    fi
    if [[ -z "$want" ]]; then
        echo "ERROR: nvmet subsystem node$id 의 device_path 를 읽지 못했고, $nqn 로 붙은 장치도 아니다 ($NVMET/node$id)"
    else
        echo "ERROR: node$id: -devices 의 $dev ($have) 가 nvmet node$id 의 장치($want)와도, 붙은 $nqn 장치(${rdev:-없음})와도 다르다 (env.sh POOL 확인)"
    fi
    exit 1
done

if pgrep -f '^(\S*/)?raft_blockcopy_server( |$)' >/dev/null; then
    echo "ERROR: raft_blockcopy_server already running:"
    pgrep -af '^(\S*/)?raft_blockcopy_server( |$)'
    exit 1
fi

sudo stdbuf -oL -eL "$BC_BIN" \
    -addr 0.0.0.0:5050 \
    -devices "$BC_DEVICES" \
    -copy-workers 8 \
    -transport "$TRANSPORT" \
    > "$RUN_LOG" 2>&1 &

PID=$!

if [[ "$RUN_LOG" != "$LOG" ]]; then
    printf 'LLOG=%q\nRLOG=%q\nSHA=%q\n' "$RUN_LOG" "$LOG" "$BIN_SHA" > "$LOCAL_DIR/running_blockcopy.env"
fi

sleep 1

if ! ps -p "$PID" >/dev/null 2>&1; then
    echo "ERROR: blockcopy server failed to start"
    tail -100 "$RUN_LOG"
    [[ "$RUN_LOG" != "$LOG" ]] && collect_local_logs blockcopy
    exit 1
fi

if [[ "$RUN_LOG" != "$LOG" ]]; then
    publish_banner "$RUN_LOG" "$LOG" "$BIN_SHA" '^raft_blockcopy_server listening'
fi

echo
echo "blockcopy server started"
echo "pid: $PID"

echo
pgrep -af '^(\S*/)?raft_blockcopy_server( |$)' || true

echo
tail -30 "$RUN_LOG"