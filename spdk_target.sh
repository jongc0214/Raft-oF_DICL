#!/usr/bin/env bash
#
# spdk_target.sh -- eternitystorage 에서 SPDK nvmf 타깃(spdk_cache 포크)을 세 구성 중 하나로 올리고 내린다
#
#   sudo ./spdk_target.sh status
#   sudo ./spdk_target.sh up vanilla|ocf|wtcache
#   sudo ./spdk_target.sh down [--force]
#
# 구성 = spdk_cache 의 setup 스크립트 (node4/5/6 용으로 고쳐 둔 것을 그대로 부른다):
#   vanilla -> setup_vanilla.sh       namespace = Nvme4n1..  (캐시 없음, SPDK 타깃만)
#   ocf     -> setup_ocf_cache.sh     namespace = Cache4..   (OCF wb, Malloc 캐시)
#   wtcache -> setup_custom_cache.sh  namespace = WT4..      (wtcache write-back, 볼륨당 1GiB)
#
# up  : nvmf_tgt 기동 -> setup 스크립트 -> discovery listener -> blockcopy 용 루프백 연결.
#       끝에 env.sh POOL 의 storage_dev(by-id)가 루프백 장치를 가리키는지 확인한다
#       (start_blockcopy.sh 의 -devices 와 장치 검사가 그 경로를 쓴다).
# down: blockcopy 서버가 멈춰 있고 컴퓨트 연결이 없을 때만 진행한다.
#       루프백 flush(dirty 를 SSD 로) -> disconnect -> spdk_kill_instance -> 종료 대기.
#       wtcache/OCF 는 write-back 이라 이 순서를 건너뛰고 죽이면 아직 안 내려간 데이터를 잃는다.
#       --force: 컴퓨트 연결이 남아 있어도 내린다 (그 호스트들은 I/O 에러를 받는다).
#
# 사전 조건 (재부팅 후 1회, SPDK_TARGET.md "1회 준비"): PM983 61/62/63 을 vfio-pci 로, NUMA0 hugepage,
#   커널 nvmet 의 node4/5/6 비활성, spdk_cache setup 스크립트 3개를 node4/5/6 용으로 변환.
# 컴퓨트 쪽 연결/마운트는 각 호스트에서 nvmeof_switch.sh (RDMA_PORT=4421) 로 한다.
#
# 환경변수: SPDK_DIR(/jongc/spdk_cache) TGT_MASK(0x6 = core 1,2, NUMA0) ADDR(10.0.0.91) PORT(4421)
#           QUEUES(8) TGT_LOG(/var/tmp/spdk_nvmf_tgt.log) TOPO/NODES(env.sh, 기본 4 5 6)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/env.sh" >/dev/null

SPDK_DIR="${SPDK_DIR:-/jongc/spdk_cache}"
TGT_MASK="${TGT_MASK:-0x6}"
ADDR="${ADDR:-10.0.0.91}"
PORT="${PORT:-4421}"
QUEUES="${QUEUES:-8}"
TGT_LOG="${TGT_LOG:-/var/tmp/spdk_nvmf_tgt.log}"
DISCOVERY_NQN="nqn.2014-08.org.nvmexpress.discovery"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
run()  { echo "+ $*"; "$@"; }
rpc()  { "$SPDK_DIR/scripts/rpc.py" "$@"; }

setup_script_for() {
    case "$1" in
        vanilla) echo "$SPDK_DIR/setup_vanilla.sh" ;;
        ocf)     echo "$SPDK_DIR/setup_ocf_cache.sh" ;;
        wtcache) echo "$SPDK_DIR/setup_custom_cache.sh" ;;
        *) die "구성은 vanilla|ocf|wtcache: $1" ;;
    esac
}

tgt_pid() { pgrep -f '(^|/)nvmf_tgt( |$)' | head -1 || true; }

member_nqns() { local id; for id in $NODES; do _pool_field "$id" 3; done; }

# 지금 떠 있는 구성: namespace bdev 이름의 접두어로 판정 (Nvme / Cache / WT)
current_mode() {
    rpc nvmf_get_subsystems 2>/dev/null | python3 -c '
import json, sys
names = [ns["name"] for s in json.load(sys.stdin) for ns in s.get("namespaces", [])]
modes = {("vanilla" if n.startswith("Nvme") else "ocf" if n.startswith("Cache")
          else "wtcache" if n.startswith("WT") else "?" + n) for n in names}
print(",".join(sorted(modes)) or "-")' 2>/dev/null || echo "?"
}

# <nqn> 에 붙은 컨트롤러 중 이 호스트(루프백)가 아닌 것의 hostnqn 목록
remote_hosts() {
    local me
    me="$(cat /etc/nvme/hostnqn 2>/dev/null || true)"
    rpc nvmf_subsystem_get_controllers "$1" 2>/dev/null | python3 -c '
import json, sys
me = sys.argv[1]
for c in json.load(sys.stdin):
    if c.get("hostnqn") != me:
        print(c.get("hostnqn"))' "$me" 2>/dev/null || true
}

status() {
    local pid n dev sdev hp
    pid="$(tgt_pid)"
    echo "nvmf_tgt   : ${pid:-<not running>}${pid:+ (mode $(current_mode))}  log=$TGT_LOG"
    hp="$(cat /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo ?)"
    echo "hugepages  : node0 ${hp} x 2MiB"
    echo "members    : $(echo $(member_nqns))  ($ADDR:$PORT)"
    for n in $(member_nqns); do
        dev="$(dev_for_nqn "$n" 2>/dev/null || true)"
        echo "  $n loopback=${dev:-<none>}"
        if [[ -n "$pid" ]]; then
            remote_hosts "$n" | sed 's/^/    remote host: /'
        fi
    done
    for id in $NODES; do
        sdev="$(_pool_field "$id" 4)"
        echo "  node$id storage_dev $sdev -> $(readlink -f "$sdev" 2>/dev/null || echo '<없음>')"
    done
}

check_vfio() {
    local script="$1" b drv bad=0
    for b in $(grep -oE '0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]' "$script" | sort -u); do
        drv="$(basename "$(readlink "/sys/bus/pci/devices/$b/driver" 2>/dev/null)" 2>/dev/null || true)"
        if [[ "$drv" != vfio-pci ]]; then
            echo "  $b driver=${drv:-<none>} (vfio-pci 여야 한다)" >&2
            bad=1
        fi
    done
    [[ $bad -eq 0 ]] || die "SSD 가 vfio-pci 에 없다. SPDK_TARGET.md '1회 준비' 의 바인딩을 먼저 하라."
}

loopback_up() {
    local n dev sdev i id
    run modprobe nvme-rdma
    for n in $(member_nqns); do
        run nvme connect -t rdma -a "$ADDR" -s "$PORT" -n "$n" -i "$QUEUES"
    done
    for id in $NODES; do
        n="$(_pool_field "$id" 3)"
        sdev="$(_pool_field "$id" 4)"
        dev=""
        for i in $(seq 1 40); do
            dev="$(dev_for_nqn "$n" 2>/dev/null || true)"
            [[ -n "$dev" && -e "$sdev" ]] && break
            sleep 0.25
        done
        [[ -n "$dev" ]] || die "루프백 연결 후 $n 의 장치를 찾지 못했다"
        if [[ "$(readlink -f "$sdev")" != "$(readlink -f "$dev")" ]]; then
            die "node$id: POOL storage_dev $sdev ($(readlink -f "$sdev" 2>/dev/null || echo 없음)) 가 루프백 $dev 와 다르다 (setup 스크립트의 -s 시리얼 / -d 모델 확인)"
        fi
        echo "node$id: $sdev -> $dev OK"
    done
}

up() {
    local mode="$1" script pid n i
    [[ $EUID -eq 0 ]] || die "root 로 실행하라 (sudo)."
    script="$(setup_script_for "$mode")"
    [[ -r "$script" ]] || die "$script 가 없다"
    for n in $(member_nqns); do
        grep -q -- "$n" "$script" || die "$script 에 $n 이 없다 -- node4/5/6 용으로 변환하라 (SPDK_TARGET.md)"
    done
    pid="$(tgt_pid)"
    [[ -z "$pid" ]] || die "nvmf_tgt 가 이미 떠 있다 (pid $pid, mode $(current_mode)). 먼저 down."
    check_vfio "$script"

    echo "== nvmf_tgt 기동 ($mode, -m $TGT_MASK, log $TGT_LOG)"
    ( cd "$SPDK_DIR" && nohup build/bin/nvmf_tgt -m "$TGT_MASK" > "$TGT_LOG" 2>&1 & )
    for i in $(seq 1 60); do
        [[ -S /var/tmp/spdk.sock ]] && rpc -t 5 framework_wait_init >/dev/null 2>&1 && break
        [[ -n "$(tgt_pid)" ]] || { tail -20 "$TGT_LOG" >&2; die "nvmf_tgt 가 기동 중에 죽었다"; }
        sleep 0.5
    done
    rpc -t 5 framework_wait_init >/dev/null || die "nvmf_tgt RPC 가 준비되지 않았다 ($TGT_LOG)"

    echo "== $(basename "$script")"
    ( cd "$SPDK_DIR" && bash "$script" )
    for n in $(member_nqns); do
        rpc nvmf_get_subsystems | python3 -c '
import json, sys
n = sys.argv[1]
s = [x for x in json.load(sys.stdin) if x["nqn"] == n]
ok = s and s[0].get("namespaces") and s[0].get("listen_addresses")
sys.exit(0 if ok else 1)' "$n" || die "$n 에 namespace/listener 가 없다 -- setup 스크립트 출력 확인"
    done
    # nvmeof_switch.sh 의 사전 점검(nvme discover)이 SPDK 쪽 NQN 을 보려면 discovery 에도 listener 가 필요하다
    rpc nvmf_subsystem_add_listener "$DISCOVERY_NQN" -t rdma -a "$ADDR" -s "$PORT" ||
        warn "discovery listener 를 못 붙였다 (컴퓨트의 nvmeof_switch.sh 사전 점검이 실패할 수 있다)"

    echo "== 루프백 연결 (blockcopy 용)"
    loopback_up
    echo
    status
    echo
    echo "다음: 각 컴퓨트에서 sudo RDMA_PORT=$PORT ./nvmeof_switch.sh rdma --all-members --force,"
    echo "      스토리지에서 ./start_blockcopy.sh rdma"
}

down() {
    local force="${1:-}" pid n dev remote="" i
    [[ $EUID -eq 0 ]] || die "root 로 실행하라 (sudo)."
    pid="$(tgt_pid)"
    if [[ -z "$pid" ]]; then
        echo "nvmf_tgt 가 떠 있지 않다."
        return 0
    fi
    if pgrep -f '(^|/)raft_blockcopy_server( |$)' >/dev/null; then
        die "raft_blockcopy_server 가 돌고 있다. 먼저 ./stop_blockcopy.sh"
    fi
    for n in $(member_nqns); do
        remote+="$(remote_hosts "$n" | sed "s|^|  $n <- |")"$'\n'
    done
    if [[ -n "${remote//$'\n'/}" ]]; then
        echo "아직 붙어 있는 컴퓨트 호스트:" >&2
        printf '%s' "$remote" | grep -v '^$' >&2
        [[ "$force" == "--force" ]] ||
            die "각 컴퓨트에서 먼저 sudo ./nvmeof_switch.sh down --all-members (또는 --force)"
        warn "--force: 컴퓨트 연결을 남긴 채 내린다"
    fi

    echo "== 루프백 flush + disconnect (mode $(current_mode))"
    for n in $(member_nqns); do
        dev="$(dev_for_nqn "$n" 2>/dev/null || true)"
        [[ -n "$dev" ]] || { echo "$n: 루프백 없음"; continue; }
        run blockdev --flushbufs "$dev"
        run nvme disconnect -n "$n"
    done

    echo "== nvmf_tgt 종료 (write-back 캐시는 남은 dirty 를 내려보낸 뒤 끝난다)"
    rpc spdk_kill_instance SIGTERM || true
    for i in $(seq 1 120); do
        [[ -z "$(tgt_pid)" ]] && { echo "nvmf_tgt stopped."; return 0; }
        sleep 0.5
    done
    die "nvmf_tgt 가 60초 안에 끝나지 않았다 (pid $pid). $TGT_LOG 확인 -- SIGKILL 은 dirty 유실 위험"
}

[[ $# -ge 1 ]] || { sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
case "$1" in
    status) status ;;
    up)     [[ $# -ge 2 ]] || die "up vanilla|ocf|wtcache"; up "$2" ;;
    down)   down "${2:-}" ;;
    *)      die "status | up vanilla|ocf|wtcache | down [--force]" ;;
esac
