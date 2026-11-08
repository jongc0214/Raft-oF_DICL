#!/usr/bin/env bash
#
# stop_braft.sh -- 이 호스트의 braft block_server 를 멈춘다 (TOPO 와 무관)
#
#   ./stop_braft.sh <node-id>
#
# pidfile(/mnt/raftvol/node<ID>/braft-block/server.pid)의 프로세스를 SIGTERM, 2초 안에 안 죽으면
# SIGKILL. pidfile 없이 떠 있는 block_server 도 같이 내린다.
#
set -uo pipefail

[[ $# -eq 1 ]] || { sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
ID="$1"
as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

PIDFILE="/mnt/raftvol/node${ID}/braft-block/server.pid"
PIDS="$(pgrep -x block_server | xargs)"
if [[ -f "$PIDFILE" ]]; then
    p="$(cat "$PIDFILE")"
    kill -0 "$p" 2>/dev/null && PIDS="$(echo "$PIDS $p" | xargs -n1 | sort -u | xargs)"
fi

if [[ -z "$PIDS" ]]; then
    echo "[stop_braft] block_server 없음"
else
    echo "[stop_braft] SIGTERM: $PIDS"
    as_root kill $PIDS 2>/dev/null || true
    for _ in $(seq 1 20); do pgrep -x block_server >/dev/null || break; sleep 0.1; done
    if pgrep -x block_server >/dev/null; then
        echo "[stop_braft] 안 죽어서 SIGKILL"
        as_root pkill -9 -x block_server || true
        sleep 0.2
    fi
    pgrep -x block_server >/dev/null && { echo "ERROR: block_server 가 남아 있다"; pgrep -ax block_server; exit 1; }
    echo "[stop_braft] 멈춤"
fi
[[ -f "$PIDFILE" ]] && as_root rm -f "$PIDFILE"
exit 0
