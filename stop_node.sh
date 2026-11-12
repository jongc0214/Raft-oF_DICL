#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"
# LOCAL_RUN 으로 띄운 경우: 프로세스가 내려간 뒤 로컬 로그 전체를 저장소 로그 경로로 가져온다
# (env.sh collect_local_logs). 아직 돌고 있으면 건드리지 않는다.
_collect_on_exit() { pgrep -f '[r]aft_node' >/dev/null || collect_local_logs node_; }
trap _collect_on_exit EXIT

echo "[stop] raft_node"

PIDS="$(pgrep -f '[r]aft_node' || true)"

if [[ -z "$PIDS" ]]; then
    echo "raft_node is not running."
    exit 0
fi

echo "running:"
pgrep -af '[r]aft_node' || true

echo
echo "sending SIGTERM..."

sudo kill $PIDS 2>/dev/null || true

for _ in $(seq 1 20); do
    if ! pgrep -f '[r]aft_node' >/dev/null; then
        echo "raft_node stopped cleanly."
        exit 0
    fi

    sleep 0.1
done

echo "raft_node did not exit; sending SIGKILL..."

sudo pkill -9 -f '[r]aft_node' 2>/dev/null || true

sleep 0.2

if pgrep -f '[r]aft_node' >/dev/null; then
    echo "ERROR: raft_node still running:"
    pgrep -af '[r]aft_node'
    exit 1
fi

echo "raft_node killed."