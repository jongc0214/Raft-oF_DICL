#!/usr/bin/env bash
# Run on a dedicated EC2 host. Requires repository, env.sh and aws_topology.conf.
set -Eeuo pipefail
cd "$(dirname "$0")"
ACTION="${1:?action}"; ID="${2:-}"
case "$ACTION" in
  disable-cstate3)
    [[ "$EUID" == 0 ]] || exit 1
    shopt -s nullglob
    files=(/sys/devices/system/cpu/cpu*/cpuidle/state3/disable)
    if ((${#files[@]} == 0)); then
      echo "SKIP: cpuidle state3 not available on this host (no state3 setting to change)"
      exit 0
    fi
    for f in "${files[@]}"; do echo 1 > "$f"; done
    for f in "${files[@]}"; do [[ "$(cat "$f")" == 1 ]] || exit 1; done
    echo "disabled state3 on ${#files[@]} CPUs"
    exit 0
    ;;
  stop-node) exec ./stop_node.sh ;;
  stop-bc) exec ./stop_blockcopy.sh ;;
  start-node)
    export HEARTBEAT_MS="${4:-300}" LOOP_SLEEP_US="${5:-200}"
    exec ./start_node.sh "$ID" "${3:?mode}" tcp ;;
  start-bc) exec ./start_blockcopy.sh tcp ;;
  connect) exec sudo -n ./aws_nvme_connect_all.sh connect ;;
  export) exec sudo -n ./aws_storage_export.sh up ;;
esac
source ./env.sh
[[ "$EUID" == 0 ]] || { echo "root required for $ACTION" >&2; exit 1; }
case "$ACTION" in
  detach-own)
    # Called only on an old active Compute node before an NQN changes ownership.
    [[ "$ID" =~ ^(1[1-9])$ ]] || exit 2
    dev="$(dev_for_nqn "node$ID")"
    expected="$(aws_storage_ip_for_id "$ID"):$NVME_PORT"
    while read -r ctrl tr endpoint; do
      [[ "$tr" == tcp && "$endpoint" == "$expected" ]] || { echo "unexpected endpoint for node$ID" >&2; exit 1; }
    done < <(nvme_paths_for_nqn "node$ID")
    [[ "$(findmnt -rn -o TARGET /mnt/raftvol 2>/dev/null || true)" == /mnt/raftvol ]] || exit 1
    src="$(findmnt -rn -o SOURCE /mnt/raftvol)"
    [[ "$(readlink -f "$src")" == "$(readlink -f "$dev")" ]] || { echo 'wrong mount, refusing detach' >&2; exit 1; }
    umount /mnt/raftvol
    ;;
  disconnect)
    [[ "$ID" =~ ^(1[1-9])$ ]] || exit 2
    nqn="node$ID"
    paths="$(nvme_paths_for_nqn "$nqn")"
    [[ -n "$paths" ]] || exit 0
    while read -r ctrl tr endpoint; do
      [[ "$tr" == tcp ]] || { echo "unexpected transport $tr" >&2; exit 1; }
      ok=0
      for sid in s1 s2 s3; do
        [[ "$endpoint" == "${STORAGE_IP[$sid]}:$NVME_PORT" ]] && ok=1
      done
      (( ok == 1 )) || { echo "unexpected endpoint $endpoint" >&2; exit 1; }
    done <<< "$paths"
    dev="$(dev_for_nqn "$nqn")"
    [[ -z "$(lsblk -nr -o MOUNTPOINTS "$dev" | sed '/^$/d')" ]] || { echo "mounted: $dev" >&2; exit 1; }
    nvme disconnect -n "$nqn"
    ;;
  unexport)
    [[ "$ID" =~ ^(1[1-9])$ ]] || exit 2
    base=/sys/kernel/config/nvmet
    ss="$base/subsystems/node$ID"
    [[ -d "$ss" ]] || exit 0
    owner="$(aws_owner_for_id "$ID")"
    [[ " $(hostname -I) " == *" ${STORAGE_IP[$owner]} "* ]] || { echo 'wrong owner storage' >&2; exit 1; }
    existing="$(cat "$ss/namespaces/1/device_path" 2>/dev/null || true)"
    expected="$(aws_local_device_for_id "$ID")"
    [[ -n "$existing" && "$(readlink -f "$existing")" == "$(readlink -f "$expected")" ]] || { echo 'wrong export SSD' >&2; exit 1; }
    [[ "$(cat "$ss/attr_allow_any_host" 2>/dev/null)" == 1 ]] || { echo 'unexpected nvmet ACL' >&2; exit 1; }
    [[ -d "$ss/namespaces/1" ]] || { echo 'unexpected nvmet namespaces' >&2; exit 1; }
    for ns in "$ss"/namespaces/*; do [[ "$ns" == "$ss/namespaces/1" ]] || { echo 'multiple namespaces' >&2; exit 1; }; done
    for p in "$base"/ports/*/subsystems/"node$ID"; do
      [[ ! -e "$p" && ! -L "$p" ]] && continue
      [[ -L "$p" && "$(readlink -f "$p")" == "$(readlink -f "$ss")" ]] || exit 1
      rm "$p"
    done
    echo 0 > "$ss/namespaces/1/enable"
    rmdir "$ss/namespaces/1"
    rmdir "$ss"
    ;;
  reset-own)
    [[ "$ID" =~ ^(1[1-9])$ ]] && is_valid_id "$ID" || exit 2
    # clean_node.sh protects the volume path and keeps raft-ID.ring.
    # No mkfs, no unmount and no NQN disconnect.
    exec ./clean_node.sh "$ID"
    ;;
  reformat-own)
    [[ "${RAFT_EXP_FORMAT:-}" == YES ]] || { echo 'RAFT_EXP_FORMAT=YES required' >&2; exit 2; }
    # Exact own NQN and allowed endpoint must agree, and only own mount may exist.
    [[ "$ID" =~ ^(1[1-9])$ ]] && is_valid_id "$ID" || exit 2
    nqn="node$ID"; dev="$(device_for_id "$ID")"
    expected="$(aws_storage_ip_for_id "$ID"):$NVME_PORT"
    paths="$(nvme_paths_for_nqn "$nqn")"
    [[ -n "$paths" ]] || exit 1
    while read -r ctrl tr endpoint; do
      [[ "$tr" == tcp && "$endpoint" == "$expected" ]] || { echo "endpoint mismatch: $tr/$endpoint vs $expected" >&2; exit 1; }
    done <<< "$paths"
    [[ "$(lsblk -dn -o TYPE "$dev")" == disk ]] || exit 1
    [[ "$(findmnt -rn -o FSTYPE /mnt/raftvol)" == ext4 ]] || exit 1
    src="$(findmnt -rn -o SOURCE /mnt/raftvol)"
    [[ "$(readlink -f "$src")" == "$(readlink -f "$dev")" ]] || { echo 'wrong mounted volume' >&2; exit 1; }
    # Only the intended mount is permitted.
    mounts="$(lsblk -nr -o MOUNTPOINTS "$dev" | sed '/^$/d' | sort -u)"
    [[ "$mounts" == /mnt/raftvol ]] || { echo "unexpected mounts: $mounts" >&2; exit 1; }
    umount /mnt/raftvol
    # Clears filesystem / Raft metadata; it is NOT a secure physical SSD zero-fill.
    mkfs.ext4 -F -q -E nodiscard "$dev"
    mount "$dev" /mnt/raftvol
    [[ "$(findmnt -rn -o FSTYPE /mnt/raftvol)" == ext4 ]] || exit 1
    ;;
  *) echo "invalid action: $ACTION" >&2; exit 2 ;;
esac
