#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"
source ./env.sh

[[ "${1:-}" == up || "${1:-}" == status ]] || {
    echo "usage: sudo ./aws_storage_export.sh up|status" >&2
    exit 2
}

[[ $EUID == 0 ]] || {
    echo "Run with sudo" >&2
    exit 1
}

self_ips=" $(hostname -I) "
my_storage=""

for s in s1 s2 s3; do
    ip="${STORAGE_IP[$s]:-}"

    if [[ "$ip" != "CHANGE_ME" &&
          "$self_ips" == *" $ip "* ]]; then
        my_storage="$s"
        break
    fi
done

[[ -n "$my_storage" ]] || {
    echo "ERROR: this host is not a configured Storage IP" >&2
    exit 1
}

modprobe nvmet
modprobe nvmet-tcp

mountpoint -q /sys/kernel/config ||
    mount -t configfs configfs /sys/kernel/config

base=/sys/kernel/config/nvmet
port="$base/ports/1"

if [[ "$1" == up ]]; then
    if [[ ! -d "$port" ]]; then
        mkdir "$port"

        echo tcp > "$port/addr_trtype"
        echo ipv4 > "$port/addr_adrfam"

        echo "${STORAGE_IP[$my_storage]}" \
            > "$port/addr_traddr"

        echo "$NVME_PORT" > "$port/addr_trsvcid"
    else
        [[ $(cat "$port/addr_trtype") == tcp &&
           $(cat "$port/addr_traddr") == "${STORAGE_IP[$my_storage]}" &&
           $(cat "$port/addr_trsvcid") == "$NVME_PORT" ]] || {
            echo "ERROR: existing nvmet port conflicts with configuration" >&2
            exit 1
        }
    fi
fi

for id in $NODES; do
    [[ "$(aws_owner_for_id "$id")" == "$my_storage" ]] ||
        continue

    dev="$(aws_local_device_for_id "$id")"

    [[ -b "$dev" ]] || {
        echo "ERROR: missing block device: $dev" >&2
        exit 1
    }

    real="$(readlink -f "$dev")"
    model="$(lsblk -dn -o MODEL "$real" | xargs)"

    # Never export the EBS root disk.
    [[ "$model" == *"Instance Storage"* ]] || {
        echo "ERROR: not EC2 Instance Storage: $dev ($model)" >&2
        exit 1
    }

    [[ -z "$(lsblk -nr -o MOUNTPOINTS "$real" |
               sed '/^$/d')" ]] || {
        echo "ERROR: device is mounted: $dev" >&2
        exit 1
    }

    nqn="node$id"
    subsystem="$base/subsystems/$nqn"

    if [[ "$1" == status ]]; then
        echo "$nqn -> $dev [$my_storage]"
        continue
    fi

    if [[ -d "$subsystem" ]]; then
        old="$(cat "$subsystem/namespaces/1/device_path" \
            2>/dev/null || true)"

        [[ -n "$old" &&
           "$(readlink -f "$old")" == "$real" ]] || {
            echo "ERROR: existing $nqn maps to another device" >&2
            exit 1
        }
    else
        mkdir "$subsystem"
        echo 1 > "$subsystem/attr_allow_any_host"

        mkdir "$subsystem/namespaces/1"
        echo "$dev" > "$subsystem/namespaces/1/device_path"
        echo 1 > "$subsystem/namespaces/1/enable"
    fi

    [[ -L "$port/subsystems/$nqn" ]] ||
        ln -s "$subsystem" "$port/subsystems/$nqn"

    echo "Exported $nqn -> $dev"
    echo "  TCP ${STORAGE_IP[$my_storage]}:$NVME_PORT"
done