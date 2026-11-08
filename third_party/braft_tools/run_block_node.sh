#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/cluster.env"

MODE="${RPC_TRANSPORT:-rdma}"               # 환경변수로도 지정 가능, 기본 tcp
if [[ "${1:-}" == "tcp" || "${1:-}" == "rdma" ]]; then
  MODE="$1"; shift
fi
NODE_ID="${1:-}"

if ! is_valid_id "$NODE_ID"; then
  echo "usage: $0 {$(valid_ids_pipe)}"
  exit 1
fi

build_conf
IP="$(ip_for_id "$NODE_ID")"

BIN="$BLOCK_BUILD_DIR/block_server"
DATA="/mnt/raftvol/node${NODE_ID}/braft-block"
LOG="$DATA/server.log"
PIDFILE="$DATA/server.pid"

test -x "$BIN" || {
  echo "missing executable: $BIN"
  exit 1
}

mkdir -p "$DATA"

if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "block_server already running: pid=$(cat "$PIDFILE")"
  exit 0
fi

echo "nodes=$NODES"
echo "node=$NODE_ID"
echo "ip=$IP"
echo "port=$PORT"
echo "conf=$CONF"
echo "data=$DATA"

# RDMA 장치: 10.0.0.x(IPoIB) 주소가 붙은 인터페이스의 IB 장치. 카드가 꽂힌 PCIe 위치에 따라
# 이름이 호스트마다 다르다 (eternity7 ibp177s0, eternity8 ibp175s0, 나머지 ibp59s0).
IB_IF="$(ip -o -4 addr show | awk '$4 ~ /^10\.0\.0\./ {print $2; exit}')"
if [[ -z "${RDMA_DEV:-}" ]]; then
  RDMA_DEV="$(ls "/sys/class/net/$IB_IF/device/infiniband" 2>/dev/null | head -1)"
  RDMA_DEV="${RDMA_DEV:-ibp59s0}"
fi

# NUMA 고정: raftof_clean/start_node.sh 와 같게 IB 카드가 붙은 소켓에 묶는다 (NUMA_BIND=0 이면 끔).
NUMA_PREFIX=()
if [[ "${NUMA_BIND:-1}" == "1" && -n "$IB_IF" ]]; then
  IB_NUMA="$(cat "/sys/class/net/$IB_IF/device/numa_node" 2>/dev/null || echo -1)"
  if [[ "$IB_NUMA" =~ ^[0-9]+$ ]] && command -v numactl >/dev/null; then
    NUMA_PREFIX=(numactl "--cpunodebind=$IB_NUMA" "--membind=$IB_NUMA")
  fi
fi
echo "numa_bind=${NUMA_PREFIX[*]:-off}"

# 공유 라이브러리: 패키지가 없는 호스트(빌린 eternity8~10)는 raftof_clean/third_party/lib 사본을 쓴다.
LIB_DIR="/home/jongc/raftof_clean/third_party/lib"
if ldd "$BIN" 2>/dev/null | grep -q 'not found'; then
  export LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  if ldd "$BIN" | grep -q 'not found'; then
    echo "missing shared libraries:"; ldd "$BIN" | grep 'not found'; exit 1
  fi
  echo "ld_library_path=$LD_LIBRARY_PATH"
fi

EXTRA_FLAGS=()
if [[ "$MODE" == "rdma" ]]; then
  ulimit -n 65536                          # RDMA 사전 생성 QP용 fd
  EXTRA_FLAGS+=(-raft_rpc_use_rdma=true -rdma_device="$RDMA_DEV")
fi
echo "rpc_transport=$MODE rdma_device=$RDMA_DEV"

nohup "${NUMA_PREFIX[@]}" "$BIN" \
  -ip="$IP" \
  -port="$PORT" \
  -conf="$CONF" \
  -data_path="$DATA" \
  -raft_sync=true \
  -raft_use_fsync_rather_than_fdatasync=false \
  -check_term=true \
  -disable_cli=false \
  -snapshot_interval=3600 \
  -noop_apply=true \
  -breakdown=true \
  -breakdown_quorum_k=1 \
  "${EXTRA_FLAGS[@]}" \
  >"$LOG" 2>&1 &

echo $! > "$PIDFILE"
 
sleep 1
 
if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "started node=$NODE_ID pid=$(cat "$PIDFILE")"
  echo "log=$LOG"
else
  echo "failed to start"
  tail -n 50 "$LOG" || true
  exit 1
fi