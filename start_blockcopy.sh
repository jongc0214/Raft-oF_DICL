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

# tcp-ib 는 스크립트 쪽 구성 이름이다. 바이너리는 rdma|tcp 만 안다 -- 서버는 0.0.0.0 에서 받으므로
# 이더넷(tcp)과 IPoIB(tcp-ib)의 차이는 노드가 거는 storage_host 주소뿐이다 (env.sh build_cluster).
BIN_TRANSPORT="$TRANSPORT"
[[ "$TRANSPORT" == "tcp-ib" ]] && BIN_TRANSPORT="tcp"

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
echo "transport   : $TRANSPORT (binary -transport $BIN_TRANSPORT)"
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
# 블록 장치(nvmet bdev 백엔드) 또는 일반 파일(nvmet 파일 백엔드의 백킹 파일, D24).
# 일반 파일이면 서버가 src를 버퍼드로 읽는다(배너 read=buffered).
for dev in "${BC_DEV_ARR[@]}"; do
    if [[ ! -b "$dev" && ! -f "$dev" ]]; then
        echo "ERROR: block device or backing file not found: $dev"
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
    # SPDK ublk (2026-11-17): /dev/ublkb<N> 은 spdk_tgt 의 bdev 를 바로 연 장치다 (루프백 없음).
    #   ublk id = node id 규약이고, 그 디스크의 bdev 가 이 노드 볼륨(WT<id> / Nvme<id>n1 / Cache<id>)인지 확인한다.
    if [[ "$dev" =~ ^/dev/ublkb([0-9]+)$ ]]; then
        uid="${BASH_REMATCH[1]}"
        if [[ "$uid" != "$id" ]]; then
            echo "ERROR: node$id 에 $dev (ublk id $uid) -- ublk id 는 node id 와 같아야 한다 (env.sh POOL)"
            exit 1
        fi
        ubdev="$(sudo /jongc/spdk_cache/scripts/rpc.py ublk_get_disks 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin):
    if str(d.get("id")) == sys.argv[1]:
        print(d.get("bdev_name", ""))' "$uid" 2>/dev/null || true)"
        case "$ubdev" in
            "WT$id"|"Nvme${id}n1"|"Cache$id")
                echo "node$id -> $dev (ublk, bdev $ubdev) OK"
                continue ;;
            "")
                echo "ERROR: node$id: ublk_get_disks 에 id $uid 가 없다 (spdk_tgt / ublk_start_disk 확인)"
                exit 1 ;;
            *)
                echo "ERROR: node$id: $dev 의 bdev 가 $ubdev 다 (WT$id / Nvme${id}n1 / Cache$id 여야 한다)"
                exit 1 ;;
        esac
    fi
    want=""
    for dp in "$NVMET/node$id"/namespaces/*/device_path; do
        [[ -r "$dp" ]] && want="$(readlink -f "$(cat "$dp")")"
    done
    # D24: nvmet 이 loop 장치를 내보내면 -devices 에는 그 백킹 파일(vol.img)을 준다 -> 백킹 파일끼리 비교
    if [[ "$want" == /dev/loop* && -r "/sys/block/${want##*/}/loop/backing_file" ]]; then
        want="$(readlink -f "$(cat "/sys/block/${want##*/}/loop/backing_file")")"
    fi
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
    -transport "$BIN_TRANSPORT" \
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