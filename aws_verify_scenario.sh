#!/usr/bin/env bash
# Read-only verification of AWS Raft-oF topology and running services.
set -euo pipefail
cd "$(dirname "$0")"
source ./aws_topology.conf
MODE="${1:-destination}"
[[ "$MODE" == destination || "$MODE" == push ]] || { echo 'Usage: ./aws_verify_scenario.sh [destination|push]' >&2; exit 2; }
SSH_USER="${SSH_USER:-ubuntu}"
REMOTE_REPO="${REMOTE_REPO:-/home/$SSH_USER/Raft-oF_DICL}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
CONFIG_SHA="$(sha256sum aws_topology.conf | awk '{print $1}')"
FAIL=0
check() { local label="$1"; shift; if "$@"; then echo "[PASS] $label"; else echo "[FAIL] $label"; FAIL=$((FAIL+1)); fi; }
remote() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "cd '$REMOTE_REPO' && $*"; }
remote_script() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "cd '$REMOTE_REPO' && bash -s -- $*"; }

nodes=($NODES)
declare -A storage_active=()
for id in "${nodes[@]}"; do
  slot="${VOLUME_DISK[$id]:-}"
  [[ "$slot" =~ ^s[123]:[ABC]$ ]] || { echo "ERROR: invalid slot for node$id: $slot" >&2; exit 2; }
  storage_active["${slot%%:*}"]=1
done
printf 'VERIFY mode=%s NODES=%s config_sha=%s\n' "$MODE" "$NODES" "$CONFIG_SHA"

for s in "${!storage_active[@]}"; do
  ip="${STORAGE_IP[$s]}"
  echo "=== Storage $s ($ip) ==="
  check "$s config identical" remote "$ip" "test \"\$(sha256sum aws_topology.conf | cut -d' ' -f1)\" = '$CONFIG_SHA'"
  check "$s BlockCopy listening :$BLOCKCOPY_PORT" remote "$ip" "ss -lnt | grep -Eq '[:.]$BLOCKCOPY_PORT[[:space:]]'"
  check "$s BlockCopy process" remote "$ip" "pgrep -f '[r]aft_blockcopy_server' >/dev/null"
  check "$s local exports and SSD paths" remote_script "$ip" <<'REMOTE'
set -euo pipefail
source ./env.sh
self=" $(hostname -I) "
base=/sys/kernel/config/nvmet
for id in $NODES; do
  owner="$(aws_owner_for_id "$id")"
  [[ "$self" == *" ${STORAGE_IP[$owner]} "* ]] || continue
  ss="$base/subsystems/node$id"
  [[ -d "$ss" && "$(cat "$ss/namespaces/1/enable")" == 1 ]] || exit 1
  dev="$(aws_local_device_for_id "$id")"
  actual="$(cat "$ss/namespaces/1/device_path")"
  [[ "$(readlink -f "$actual")" == "$(readlink -f "$dev")" ]] || exit 1
  [[ "$(lsblk -dn -o MODEL "$(readlink -f "$dev")")" == *'Instance Storage'* ]] || exit 1
  echo "node$id -> $actual"
done
REMOTE
 done

for id in "${nodes[@]}"; do
  ip="${RAFT_IP[$id]}"
  echo "=== Raft node$id ($ip) ==="
  check "node$id config identical" remote "$ip" "test \"\$(sha256sum aws_topology.conf | cut -d' ' -f1)\" = '$CONFIG_SHA'"
  check "node$id TCP $RAFT_PORT listening" remote "$ip" "ss -lnt | grep -Eq '[:.]$RAFT_PORT[[:space:]]'"
  check "node$id process args / own mount / NQNs" remote_script "$ip" "$id" "$MODE" <<'REMOTE'
set -euo pipefail
id="$1"; mode="$2"
source ./env.sh
pids="$(pgrep -x raft_node || true)"
found=0
while read -r pid; do
  [[ -n "$pid" && -r "/proc/$pid/cmdline" ]] || continue
  cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline")"
  [[ "$cmd" == *" -id $id "* && "$cmd" == *" -mode $mode "* && "$cmd" == *" -transport tcp "* ]] || continue
  [[ "$cmd" == *" -cluster "* ]] || exit 1
  found=$((found+1))
done <<< "$pids"
[[ "$found" -eq 1 ]] || { echo "expected 1 matching raft process, got $found"; exit 1; }
expected="$(device_for_id "$id")"
mounted="$(findmnt -rn -o SOURCE /mnt/raftvol)"
[[ -n "$expected" && -n "$mounted" && "$(readlink -f "$expected")" == "$(readlink -f "$mounted")" ]] || exit 1
[[ "$(findmnt -rn -o FSTYPE /mnt/raftvol)" == ext4 ]] || exit 1
for n in $NODES; do
  [[ -b "$(dev_for_nqn "node$n")" ]] || { echo "missing node$n"; exit 1; }
done
echo "process OK; own device $expected; all NQNs present"
REMOTE
 done

echo "FAILED CHECKS: $FAIL"
(( FAIL == 0 )) || exit 1
echo 'Static/OS checks passed. Leader election and ClientApply are NOT verified by this script.'
