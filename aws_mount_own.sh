#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"
source ./env.sh

[[ $EUID == 0 && $# == 1 ]] || {
    echo "usage: sudo ./aws_mount_own.sh <raft-id>" >&2
    exit 2
}

id="$1"

is_valid_id "$id" || {
    echo "ERROR: Raft $id is not an active member" >&2
    exit 1
}

ip="${RAFT_IP[$id]}"

[[ " $(hostname -I) " == *" $ip "* ]] || {
    echo "ERROR: this EC2 is not raft$id ($ip)" >&2
    exit 1
}

dev="$(device_for_id "$id")"

fs="$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)"

[[ "$fs" == ext4 ]] || {
    echo "ERROR: $dev has filesystem '$fs', expected ext4" >&2
    echo "No automatic formatting is performed." >&2
    exit 1
}

mkdir -p /mnt/raftvol

if mountpoint -q /mnt/raftvol; then
    src="$(findmnt -n -o SOURCE /mnt/raftvol)"

    [[ "$(readlink -f "$src")" == "$(readlink -f "$dev")" ]] || {
        echo "ERROR: another volume is mounted at /mnt/raftvol" >&2
        exit 1
    }

    echo "Already mounted: $dev"
else
    mount "$dev" /mnt/raftvol
    echo "Mounted raft$id own volume $dev at /mnt/raftvol"
fi