#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")"
source ./env.sh

[[ $EUID == 0 ]] || {
    echo "Run with sudo" >&2
    exit 1
}

command -v nvme >/dev/null || {
    echo "Install nvme-cli first" >&2
    exit 1
}

modprobe nvme-tcp

self_ips=" $(hostname -I) "

for id in $NODES; do
    target="$(aws_storage_ip_for_id "$id")"

    # Storage servers use their own disks locally.
    if [[ "$self_ips" == *" $target "* ]]; then
        echo "Skipping local node$id ($target)"
        continue
    fi

    nqn="node$id"
    expected="$target:$NVME_PORT"

    paths="$(nvme_paths_for_nqn "$nqn")"

    if [[ -n "$paths" ]]; then
        while read -r ctrl tr endpoint; do
            [[ "$tr" == tcp && "$endpoint" == "$expected" ]] || {
                echo "ERROR: $nqn attached to unexpected endpoint" >&2
                echo "$ctrl $tr $endpoint" >&2
                exit 1
            }
        done <<< "$paths"

        echo "Already connected: $nqn -> $expected"
    else
        echo "Connecting $nqn -> $expected"

        nvme connect \
            -t tcp \
            -a "$target" \
            -s "$NVME_PORT" \
            -n "$nqn"

        udevadm settle 2>/dev/null || true
    fi

    dev="$(dev_for_nqn "$nqn")" || exit 1

    echo "$nqn -> $dev"
done

echo "NVMe/TCP connection check completed"