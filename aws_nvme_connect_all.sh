#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh
(( EUID == 0 )) || { echo 'ERROR: root required' >&2; exit 1; }
ACTION="${1:-connect}"
[[ "$ACTION" == connect || "$ACTION" == disconnect ]] || {
    echo 'usage: sudo ./aws_nvme_connect_all.sh [connect|disconnect]' >&2; exit 2;
}
command -v nvme >/dev/null || { echo 'ERROR: nvme-cli missing' >&2; exit 1; }
modprobe nvme-tcp

if [[ "$ACTION" == disconnect ]]; then
    # Dedicated Raft/Storage hosts only. Disconnect all experiment NQNs,
    # including those from the previous scenario. Never touches EBS/root NQN.
    if pgrep -f '[/]raft_node|[/]raft_blockcopy_server' >/dev/null; then
        echo 'ERROR: Raft or BlockCopy process still running' >&2; exit 1
    fi
    for id in {11..19}; do
        nqn="node$id"
        paths="$(nvme_paths_for_nqn "$nqn")"
        [[ -n "$paths" ]] || continue
        while read -r ctrl tr endpoint; do
            [[ "$tr" == tcp ]] || { echo "ERROR: unexpected transport for $nqn ($tr)" >&2; exit 1; }
            allowed=0
            for s in s1 s2 s3; do
                [[ "$endpoint" == "${STORAGE_IP[$s]:-}:$NVME_PORT" ]] && allowed=1
            done
            (( allowed == 1 )) || { echo "ERROR: $nqn attached to unrecognized endpoint $endpoint" >&2; exit 1; }
        done <<< "$paths"
        dev="$(dev_for_nqn "$nqn")" || exit 1
        # Refuse to disconnect any mounted namespace, not just /mnt/raftvol.
        if [[ -n "$(lsblk -nr -o MOUNTPOINTS "$dev" | sed '/^$/d')" ]]; then
            echo "ERROR: $dev ($nqn) is mounted; unmount it first" >&2; exit 1
        fi
        echo "Disconnecting $nqn ($dev)"
        nvme disconnect -n "$nqn"
    done
    echo 'Raft-oF NVMe/TCP connections disconnected'
    exit 0
fi

self_ips=" $(hostname -I) "
for id in $NODES; do
    target="$(aws_storage_ip_for_id "$id")"
    if [[ "$self_ips" == *" $target "* ]]; then
        echo "Skipping locally owned node$id ($target)"
        continue
    fi
    nqn="node$id"; expected="$target:$NVME_PORT"
    paths="$(nvme_paths_for_nqn "$nqn")"
    if [[ -n "$paths" ]]; then
        while read -r ctrl tr endpoint; do
            [[ "$tr" == tcp && "$endpoint" == "$expected" ]] || {
                echo "ERROR: $nqn attached to $tr/$endpoint, expected tcp/$expected" >&2; exit 1;
            }
        done <<< "$paths"
        echo "Already connected: $nqn -> $expected"
    else
        echo "Connecting $nqn -> $expected"
        nvme connect -t tcp -a "$target" -s "$NVME_PORT" -n "$nqn" --disable-sqflow
        udevadm settle 2>/dev/null || true
    fi
    dev=""
    for attempt in {1..20}; do
        if dev="$(dev_for_nqn "$nqn" 2>/dev/null)" && [[ -b "$dev" ]]; then
            break
        fi
        dev=""
        sleep 0.5
    done

    [[ -n "$dev" ]] || {
        echo "ERROR: $nqn namespace not ready after 10 seconds" >&2
        nvme list-subsys >&2
        exit 1
    }
    echo "$nqn -> $dev"
done
echo 'NVMe/TCP connection check completed'
