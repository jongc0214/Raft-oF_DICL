#!/usr/bin/env bash
# Dedicated AWS Raft-oF experiment cluster only (Raft IDs 11..19, Storage s1..s3).
# Run from a controller that can SSH to every old and new active EC2.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

usage() {
    cat <<'USAGE'
usage: ./aws_apply_scenario.sh S1|S2|S3 C3|C5|C7|C9 [--mode destination|push] [--plan] [--fresh]

--plan   no connections, no writes, print configuration and target hosts
--fresh  explicitly destroy *all new active Raft volumes* and recreate ext4.
         REQUIRED when changing member list or volume ownership.

Requires passwordless SSH and sudo -n on target EC2s, ubuntu user by default.
Set SSH_USER / REMOTE_REPO if necessary. Does not run a benchmark.
USAGE
}
[[ $# -ge 2 ]] || { usage; exit 2; }
SC_S="$1"; SC_C="$2"; shift 2
MODE=destination; PLAN=0; FRESH=0
while (($#)); do
    case "$1" in
        --mode) MODE="${2:?missing mode}"; shift 2 ;;
        --plan) PLAN=1; shift ;;
        --fresh) FRESH=1; shift ;;
        *) usage; exit 2 ;;
    esac
done
[[ "$MODE" == destination || "$MODE" == push ]] || { echo 'ERROR: mode must be destination|push' >&2; exit 2; }
case "$SC_S/$SC_C" in
    S1/C3) counts=(3) ;;
    S2/C3) counts=(2 1) ;;
    S3/C3) counts=(1 1 1) ;;
    S2/C5) counts=(3 2) ;;
    S3/C5) counts=(2 2 1) ;;
    S3/C7) counts=(2 2 3) ;;
    S3/C9) counts=(3 3 3) ;;
    *) echo "ERROR: unsupported scenario $SC_S $SC_C" >&2; exit 2 ;;
esac
for f in aws_topology.conf aws_ec2.sh aws_set_scenario.sh aws_storage_export.sh aws_nvme_connect_all.sh aws_mount_own.sh start_node.sh start_blockcopy.sh; do
    [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done
# Existing topology must be sourced BEFORE the scenario generator changes it.
source ./aws_topology.conf
old_nodes="$NODES"
old_topology_sha="$(sha256sum aws_topology.conf | awk '{print $1}')"
declare -A previous=()
for i in $old_nodes; do previous[$i]="${VOLUME_DISK[$i]:-}"; done
old_storages=()
for i in $old_nodes; do
    slot="${previous[$i]}"; owner="${slot%%:*}"
    [[ " ${old_storages[*]:-} " == *" $owner "* ]] || old_storages+=("$owner")
done

# Construct the proposed plan without changing the file.
letters=ABC
new_nodes=(); new_storages=(); declare -A new_mapping=()
id=11
for idx in "${!counts[@]}"; do
    sid="s$((idx+1))"; new_storages+=("$sid")
    for ((j=0;j<counts[idx];j++)); do
        letter="${letters:j:1}"
        new_nodes+=("$id")
        new_mapping[$id]="$sid:$letter"
        ((id+=1))
    done
done
new_nodes_str="${new_nodes[*]}"
old_compute_ids=(); for i in $old_nodes; do old_compute_ids+=("$i"); done
all_compute_ids=("${old_compute_ids[@]}" "${new_nodes[@]}")
mapfile -t all_compute_ids < <(printf '%s\n' "${all_compute_ids[@]}" | sort -nu)
all_storage_ids=("${old_storages[@]}" "${new_storages[@]}")
mapfile -t all_storage_ids < <(printf '%s\n' "${all_storage_ids[@]}" | sort -u)

changed=0
[[ "$old_nodes" == "$new_nodes_str" ]] || changed=1
for i in "${new_nodes[@]}"; do
    [[ "${previous[$i]:-}" == "${new_mapping[$i]}" ]] || changed=1
done
if (( changed && ! FRESH && ! PLAN )); then
    echo 'ERROR: membership or SSD ownership changes; refuse reuse of old on-disk Raft state.' >&2
    echo 'Pass --fresh ONLY if all active Raft volume data may be erased.' >&2
    exit 1
fi

# Check that all requested IPs exist before any destructive operations.
for i in "${all_compute_ids[@]}"; do
    [[ "${RAFT_IP[$i]:-}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || { echo "ERROR: RAFT_IP[$i] missing" >&2; exit 1; }
done
for s in "${all_storage_ids[@]}"; do
    [[ "${STORAGE_IP[$s]:-}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || { echo "ERROR: STORAGE_IP[$s] missing" >&2; exit 1; }
done

echo "Old NODES: $old_nodes"