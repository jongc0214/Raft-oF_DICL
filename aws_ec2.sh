
#!/usr/bin/env bash

# Source from the end of the original env.sh.
# Do not run this file directly.

[[ -n "${SCRIPT_DIR:-}" ]] || {
    echo "ERROR: aws_ec2.sh must be sourced from env.sh" >&2
    return 1
}

source "$SCRIPT_DIR/aws_topology.conf"

aws_die() {
    echo "AWS TOPOLOGY ERROR: $*" >&2
    return 1
}

aws_valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local x
    local -a octets
    IFS=. read -r -a octets <<< "$1"

    for x in "${octets[@]}"; do
        (( 10#$x <= 255 )) || return 1
    done
}

aws_owner_for_id() {
    echo "${VOLUME_DISK[$1]%%:*}"
}

aws_storage_ip_for_id() {
    local owner
    owner="$(aws_owner_for_id "$1")"
    echo "${STORAGE_IP[$owner]:-}"
}

aws_local_device_for_id() {
    local slot="${VOLUME_DISK[$1]:-}"
    local owner="${slot%%:*}"
    local letter="${slot##*:}"
    local owner_ip="${STORAGE_IP[$owner]:-}"
    local dev

    # 다른 서버에서는 기존 토폴로지 설정 사용
    if [[ " $(hostname -I) " != *" $owner_ip "* ]]; then
        echo "${STORAGE_DISK[$slot]:-}"
        return
    fi

    # 현재 Storage EC2의 실제 Instance Store SSD 탐색
    local -a disks=()
    local path model

    for path in /dev/disk/by-id/nvme-Amazon_EC2_NVMe_Instance_Storage_AWS*; do
        [[ -b "$path" ]] || continue
        [[ "$path" != *_1 ]] || continue

        model="$(lsblk -dn -o MODEL "$(readlink -f "$path")" | xargs)"
        [[ "$model" == *"Instance Storage"* ]] || continue

        disks+=("$path")
    done

    # 시리얼 기준 정렬
    mapfile -t disks < <(printf '%s\n' "${disks[@]}" | sort -u)

    local index
    case "$letter" in
        A) index=0 ;;
        B) index=1 ;;
        C) index=2 ;;
        *) return 1 ;;
    esac

    [[ -n "${disks[$index]:-}" ]] || {
        echo "ERROR: Storage SSD $letter not found" >&2
        return 1
    }

    echo "${disks[$index]}"
}

aws_validate_topology() {
    local id ip slot sid dev
    local -A seen_id=()
    local -A seen_slot=()

    [[ -n "$NODES" ]] || {
        aws_die "NODES is empty"
        return 1
    }

    for id in $NODES; do
        [[ "$id" =~ ^[1-9][0-9]*$ ]] || {
            aws_die "Invalid Raft ID: $id"
            return 1
        }

        [[ ! -v seen_id[$id] ]] || {
            aws_die "Duplicate Raft ID: $id"
            return 1
        }
        seen_id[$id]=1

        ip="${RAFT_IP[$id]:-}"
        aws_valid_ip "$ip" || {
            aws_die "RAFT_IP[$id] not configured: $ip"
            return 1
        }

        slot="${VOLUME_DISK[$id]:-}"

        [[ "$slot" =~ ^s[123]:[ABC]$ ]] || {
            aws_die "Invalid VOLUME_DISK[$id]: $slot"
            return 1
        }

        [[ ! -v seen_slot[$slot] ]] || {
            aws_die "Duplicate physical SSD slot: $slot"
            return 1
        }
        seen_slot[$slot]=1

        sid="${slot%%:*}"

        aws_valid_ip "${STORAGE_IP[$sid]:-}" || {
            aws_die "STORAGE_IP[$sid] is not configured"
            return 1
        }

        dev="${STORAGE_DISK[$slot]:-}"

        [[ "$dev" == /dev/disk/by-id/* ]] || {
            aws_die "STORAGE_DISK[$slot] must use /dev/disk/by-id/"
            return 1
        }
    done
}

aws_validate_topology || return 1

# ==============================================================
# Build original repository-compatible POOL
# ==============================================================
export NODES

POOL=()

for _aws_id in $NODES; do
    POOL+=(
        "${_aws_id}|DOWN|${RAFT_IP[$_aws_id]}:${RAFT_PORT}|node${_aws_id}|$(aws_local_device_for_id "$_aws_id")"
    )
done

unset _aws_id

host_for_id() {
    echo "raft$1"
}

# ==============================================================
# Raft cluster construction
# ==============================================================
build_cluster() {
    local kind="$1"
    local id addr dev nqn sh

    [[ "$kind" == "eth" ]] || {
        aws_die "AWS configuration supports TCP/Ethernet only"
        return 1
    }

    CLUSTER=""
    ADDRS=""

    for id in $NODES; do
        addr="${RAFT_IP[$id]}:${RAFT_PORT}"
        nqn="node${id}"

        dev="$(dev_for_nqn "$nqn" 2>/dev/null)" ||
            dev="nqn:${nqn}"

        sh="$(aws_storage_ip_for_id "$id"):${BLOCKCOPY_PORT}"

        CLUSTER+="${CLUSTER:+,}${id}@${addr}@${dev}@${sh}"
        ADDRS+="${ADDRS:+,}${addr}"
    done

    export CLUSTER ADDRS
}

# ==============================================================
# Verify real NVMe/TCP attachments
# ==============================================================
check_transport() {
    local mode="$1"
    local id ctrl tr endpoint expected found

    [[ "$mode" == "tcp" ]] || {
        aws_die "Unsupported AWS transport: $mode"
        return 1
    }

    if [[ "${CHECK_TRANSPORT:-1}" == "0" ]]; then
        echo "WARN: CHECK_TRANSPORT=0" >&2
        return 0
    fi

    for id in $NODES; do
        expected="$(aws_storage_ip_for_id "$id"):${NVME_PORT}"
        found=0

        while read -r ctrl tr endpoint; do
            [[ -n "$ctrl" ]] || continue
            found=1

            if [[ "$tr" != "tcp" ||
                  "$endpoint" != "$expected" ]]; then
                aws_die \
                    "node$id: $ctrl uses $tr/$endpoint, expected tcp/$expected"
                return 1
            fi
        done < <(nvme_paths_for_nqn "node$id")

        if [[ "$id" == "${MY_ID:-}" &&
              "$found" == "0" ]]; then
            aws_die "Own NVMe namespace node$id is not attached"
            return 1
        fi
    done
}

# ==============================================================
# BlockCopy devices
#
# On the owning Storage: use the local physical SSD.
# On another Storage: use the remote NVMe/TCP attachment.
# ==============================================================
build_bc_devices() {
    local id owner dev
    local self_ips

    self_ips=" $(hostname -I) "
    BC_DEVICES=""

    for id in $NODES; do
        owner="$(aws_owner_for_id "$id")"

        if [[ "$self_ips" == *" ${STORAGE_IP[$owner]} "* ]]; then
            dev="$(aws_local_device_for_id "$id")"
        else
            dev="$(dev_for_nqn "node$id")" || {
                aws_die \
                    "Storage must attach remote node$id for BlockCopy"
                return 1
            }
        fi

        BC_DEVICES+="${BC_DEVICES:+,}${dev}"
    done

    export BC_DEVICES
}

# ==============================================================
# AWS tuning defaults
# Disable the original IB-specific NUMA/IO pinning assumptions.
# ==============================================================
export NUMA_BIND="${NUMA_BIND:-0}"
export IO_PIN="${IO_PIN:-0}"

# Regenerate compatibility constants with AWS addresses.
build_cluster eth || return 1

export CLUSTER_ETH="$CLUSTER"
export ADDRS_ETH="$ADDRS"

unset CLUSTER ADDRS CLUSTER_IPOIB ADDRS_IPOIB
