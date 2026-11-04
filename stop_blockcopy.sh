#!/usr/bin/env bash
set -euo pipefail

echo "[stop] raft_blockcopy_server"

PIDS="$(pgrep -f '^(\S*/)?raft_blockcopy_server( |$)' || true)"

if [[ -z "$PIDS" ]]; then
    echo "raft_blockcopy_server is not running."
    exit 0
fi

pgrep -af '^(\S*/)?raft_blockcopy_server( |$)'

echo
echo "sending SIGTERM..."

sudo kill $PIDS 2>/dev/null || true

for _ in $(seq 1 20); do
    if ! pgrep -f '^(\S*/)?raft_blockcopy_server( |$)' >/dev/null; then
        echo "raft_blockcopy_server stopped cleanly."
        exit 0
    fi

    sleep 0.1
done

echo "still running; sending SIGKILL..."

sudo pkill -9 -f '^(\S*/)?raft_blockcopy_server( |$)' 2>/dev/null || true

sleep 0.2

if pgrep -f '^(\S*/)?raft_blockcopy_server( |$)' >/dev/null; then
    echo "ERROR: process still running:"
    pgrep -af '^(\S*/)?raft_blockcopy_server( |$)'
    exit 1
fi

echo "raft_blockcopy_server killed."