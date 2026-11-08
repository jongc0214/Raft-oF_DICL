#!/usr/bin/env bash
#
# start_braft.sh -- braft 기준선 노드를 이 호스트에서 띄운다 (raftof start_node.sh 의 braft 판)
#
#   TOPO=9 ./start_braft.sh <node-id> [rdma|tcp]
#
# 하는 일 (braft_block_tools 의 스크립트를 순서대로 부른다):
#   1. raftof raft_node 가 떠 있으면 중단 (같은 /mnt/raftvol 과 IB 를 쓰므로 같이 돌리면 측정이 오염된다)
#   2. 이 노드의 block_server 가 떠 있으면 내린다
#   3. 데이터 디렉터리 삭제 (clean_block_node.sh) -- braft 는 저장된 멤버 구성을 우선 쓰므로
#      TOPO 를 바꿨으면 반드시 지워야 한다. KEEP_DATA=1 이면 지우지 않는다
#   4. run_block_node.sh 로 기동 (RDMA 장치 자동 탐색, NUMA 고정, 라이브러리 사본은 그쪽에서 처리)
#
# 환경변수: TOPO(3|4|5|6|7|9, 기본 3) 또는 NODES, KEEP_DATA, NUMA_BIND, RDMA_DEV, BRAFT_TOOLS
# 멈추기: ./stop_braft.sh <node-id>
#
set -euo pipefail

BRAFT_TOOLS="${BRAFT_TOOLS:-/home/jongc/braft/braft_block_tools}"

if [[ $# -lt 1 || $# -gt 2 ]]; then
    sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi
ID="$1"
TRANSPORT="${2:-rdma}"
case "$TRANSPORT" in rdma|tcp) ;; *) echo "transport 는 rdma|tcp: $TRANSPORT"; exit 1 ;; esac

as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
# sudo 가 환경변수를 지우므로 braft 스크립트가 읽는 값은 env 로 넘긴다
BENV=(env "TOPO=${TOPO:-3}" "NUMA_BIND=${NUMA_BIND:-1}")
[[ -n "${NODES:-}" ]]    && BENV+=("NODES=$NODES")
[[ -n "${RDMA_DEV:-}" ]] && BENV+=("RDMA_DEV=$RDMA_DEV")

# id 검증은 cluster.env 로 (TOPO 에 없는 id 면 여기서 끝낸다)
(
    export TOPO="${TOPO:-3}"
    # shellcheck disable=SC1091
    source "$BRAFT_TOOLS/cluster.env"
    is_valid_id "$ID" || { echo "invalid node id: $ID (TOPO=${TOPO} -> $(valid_ids_pipe))"; exit 1; }
    echo "TOPO=$TOPO nodes: $NODES"
)

# 다른 호스트에서 실행하면 그 호스트 볼륨의 남의 디렉터리를 지운다 -- 호스트명(eternityN)과 id 를 맞춘다
if [[ "$(hostname -s)" != "eternity$ID" && "${FORCE_HOST:-0}" != "1" ]]; then
    echo "ERROR: node $ID 는 eternity$ID 에서 띄워야 한다 (여기는 $(hostname -s)). 의도한 거면 FORCE_HOST=1"
    exit 1
fi

if pgrep -x raft_node >/dev/null; then
    echo "ERROR: raftof raft_node 가 떠 있다. cd /home/jongc/raftof_clean && ./stop_node.sh 먼저"
    exit 1
fi
mountpoint -q /mnt/raftvol || { echo "ERROR: /mnt/raftvol 이 마운트돼 있지 않다"; exit 1; }

DATA="/mnt/raftvol/node${ID}/braft-block"
PIDFILE="$DATA/server.pid"

# 2. 기존 block_server 정리 (pidfile 없이 떠 있는 것도 이 호스트에선 이 실험 것뿐이다)
"$(dirname "$0")/stop_braft.sh" "$ID"

cd "$BRAFT_TOOLS"

# 3. 데이터 삭제
if [[ "${KEEP_DATA:-0}" == "1" ]]; then
    echo "[start_braft] KEEP_DATA=1: $DATA 유지"
else
    as_root "${BENV[@]}" ./clean_block_node.sh "$ID"
fi

# 4. 기동
as_root "${BENV[@]}" ./run_block_node.sh "$TRANSPORT" "$ID"

echo
echo "[start_braft] 리더 확인: TOPO=${TOPO:-3} $BRAFT_TOOLS/status_block_node.sh $ID"
