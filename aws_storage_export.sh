#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

ACTION="${1:-}"
[[ "$ACTION" == up || "$ACTION" == status || "$ACTION" == down ]] || {
    echo 'usage: sudo ./aws_storage_export.sh up|status|down' >&2; exit 2;
}
(( EUID == 0 )) || { echo 'ERROR: root required' >&2; exit 1; }

self_ips=" $(hostname -I) "
my_storage=""
for s in s1 s2 s3; do
    ip="${STORAGE_IP[$s]:-}"
    if [[ -n "$ip" && "$ip" != CHANGE_ME && "$self_ips" == *" $ip "* ]]; then
        my_storage="$s"; break
    fi
done
[[ -n "$my_storage" ]] || { echo 'ERROR: not a configured Storage host' >&2; exit 1; }

modprobe nvmet
modprobe nvmet-tcp
mountpoint -q /sys/kernel/config || mount -t configfs configfs /sys/kernel/config
base=/sys/kernel/config/nvmet
port="$base/ports/1"

# Only run 'down' after *all* initiators have disconnected and BlockCopy stopped.
# Dedicated Raft-oF Storage servers only. Never deletes data or filesystems.
if [[ "$ACTION" == down ]]; then
    if pgrep -f '[/]raft_blockcopy_server' >/dev/null; then
        echo 'ERROR: BlockCopy server still running' >&2; exit 1
    fi
    # Refuse to change any exported namespace while a controller is connected.
    for ss in "$base"/subsystems/node{11..19}; do
        [[ -d "$ss" ]] || continue
        if [[ -d "$ss/allowed_hosts" ]] && find "$ss/allowed_hosts" -mindepth 1 -maxdepth 1 | grep -q .; then
            echo "ERROR: unexpected host ACL under $ss" >&2; exit 1
        fi
        for p in "$base"/ports/*/subsystems/"${ss##*/}"; do
            [[ -L "$p" ]] && rm "$p"
        done
        for ns in "$ss"/namespaces/*; do
            [[ -d "$ns" ]] || continue
            [[ -e "$ns/enable" ]] && echo 0 > "$ns/enable"
            rmdir "$ns"
        done
        rmdir "$ss"
        echo "Removed export ${ss##*/}"
    done
    # Keep port/1 when already configured; 'up' checks IP/port consistency.
    echo 'Raft-oF exports removed (SSD contents unchanged)'
    exit 0
fi

if [[ "$ACTION" == up ]]; then
    if [[ ! -d "$port" ]]; then
        mkdir "$port"
        echo tcp > "$port/addr_trtype"
        echo ipv4 > "$port/addr_adrfam"
        echo "${STORAGE_IP[$my_storage]}" > "$port/addr_traddr"
        echo "$NVME_PORT" > "$port/addr_trsvcid"
    else
        [[ "$(cat "$port/addr_trtype")" == tcp && \
           "$(cat "$port/addr_traddr")" == "${STORAGE_IP[$my_storage]}" && \
           "$(cat "$port/addr_trsvcid")" == "$NVME_PORT" ]] || {
            echo 'ERROR: existing nvmet port conflicts with topology' >&2; exit 1;
        }
    fi
fi

for id in $NODES; do
    [[ "$(aws_owner_for_id "$id")" == "$my_storage" ]] || continue
    dev="$(aws_local_device_for_id "$id")"
    [[ -b "$dev" ]] || { echo "ERROR: missing block device: $dev" >&2; exit 1; }
    real="$(readlink -f "$dev")"
    model="$(lsblk -dn -o MODEL "$real" | xargs)"
    [[ "$model" == *'Instance Storage'* ]] || {
        echo "ERROR: refusing non-Instance-Store device $dev ($model)" >&2; exit 1;
    }
    [[ -z "$(lsblk -nr -o MOUNTPOINTS "$real" | sed '/^$/d')" ]] || {
        echo "ERROR: $dev is mounted" >&2; exit 1;
    }
    nqn="node$id"; ss="$base/subsystems/$nqn"
    if [[ "$ACTION" == status ]]; then
        echo "$nqn -> $dev [$my_storage]"; continue
    fi
    if [[ -d "$ss" ]]; then
        old="$(cat "$ss/namespaces/1/device_path" 2>/dev/null || true)"
        [[ -n "$old" && "$(readlink -f "$old")" == "$real" ]] || {
            echo "ERROR: $nqn existing export maps to a different disk" >&2; exit 1;
        }
    else
        mkdir "$ss"
        echo 1 > "$ss/attr_allow_any_host"
        mkdir "$ss/namespaces/1"
        echo "$dev" > "$ss/namespaces/1/device_path"
        echo 1 > "$ss/namespaces/1/enable"
    fi
    [[ -L "$port/subsystems/$nqn" ]] || ln -s "$ss" "$port/subsystems/$nqn"
    echo "Exported $nqn -> $dev at ${STORAGE_IP[$my_storage]}:$NVME_PORT"
done
