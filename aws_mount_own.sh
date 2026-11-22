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

if [[ "$fs" == "ext4" ]]; then
    echo "Existing ext4 filesystem: $dev"

elif [[ -z "$fs" ]]; then
    # blkid가 비어 있다는 것만으로 빈 디스크라고 단정하지 않는다.
    # 기존 파일시스템/RAID 등의 시그니처가 있으면 중단한다.
    if [[ -n "$(wipefs -n --noheadings "$dev")" ]]; then
        echo "ERROR: existing disk signature detected: $dev" >&2
        exit 1
    fi

    [[ "$(lsblk -dn -o TYPE "$dev")" == "disk" ]] || {
        echo "ERROR: unexpected device type: $dev" >&2
        exit 1
    }

    echo "Creating ext4 filesystem on $dev (node$id)"
    mkfs.ext4 "$dev"

else
    echo "ERROR: unexpected filesystem '$fs' on $dev" >&2
    exit 1
fi

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