#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export RAFT_ROOT="$SCRIPT_DIR"

#
# 노드 풀 (고정) + 실행 시 선택 (NODES / TOPO)
#
# 풀 형식: id|ipoib_addr|eth_addr|nqn|storage_dev
#   ipoib_addr / eth_addr : raft RPC 주소 (host:port)
#   nqn                   : 이 노드 볼륨의 nvmet subsystem NQN. 컴퓨트 호스트에서
#                           /dev/nvmeXnY 로의 해석은 실행 시 dev_for_nqn 이 한다
#                           (장치 번호는 connect 순서에 따라 호스트마다 다르다)
#   storage_dev           : 스토리지 서버 로컬 디바이스 (raft_blockcopy_server -devices)
# TODO 값이 있는 노드를 NODES 에 넣으면 build_cluster 가 에러로 막는다.
#
# !! 모든 raft 노드, blockcopy 서버, 클라이언트가 **같은 NODES** 를 써야 한다.
#    멤버 수가 quorum 을 정하고, NODES 순서가 cluster_index 와 blockcopy 의
#    -devices 인덱스를 정한다 (순서가 다르면 엉뚱한 볼륨에 쓴다).
#
POOL=(
    "1|10.0.0.1:6000|115.145.173.242:6000|node1|/dev/disk/by-id/nvme-SAMSUNG_MZQL2960HCJR-00A07_S64FNE0R906876"   # PM9A3 (나머지와 모델이 다름)
    "2|10.0.0.2:6000|115.145.173.244:6000|node2|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509498"
    "3|10.0.0.3:6000|115.145.173.245:6000|node3|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509501"
    "4|10.0.0.4:6000|115.145.173.123:6000|node4|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494"
    "5|10.0.0.5:6000|115.145.173.124:6000|node5|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496"
    "6|10.0.0.6:6000|115.145.173.125:6000|node6|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484"
    "7|10.0.0.7:6000|115.145.173.126:6000|node7|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509495"     # 빌린 노드
    "8|10.0.0.8:6000|115.145.173.127:6000|node8|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509502"     # 빌린 노드
    "9|10.0.0.9:6000|115.145.173.128:6000|node9|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509486"     # 빌린 노드
    "10|10.0.0.10:6000|115.145.173.129:6000|node10|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509503"  # 빌린 노드
)
# 7~10 (eternity7~10) 은 다른 사람 노드를 잠시 빌린 것이다. 그 호스트의 NVMe-oF·ARP·
#   C-state 설정은 borrow_node.sh up/down 으로만 바꾸고 되돌린다 (2026-11-05).
# storage_dev 는 by-id 시리얼이다 (스토리지 재부팅 때마다 nvmeN 번호가 바뀐다).
#   nvmet 의 device_path 와 같은 경로를 쓴다. 2~6 은 PM983 (MZQLB960HAJR).
#   node1 만 PM9A3 (MZQL2960HCJR, 스토리지 nvme7n1) 이다 -- eternity1 의 기존 볼륨을
#   그대로 쓰기로 했다 (2026-11-05). TOPO=6 결과에는 매체가 섞여 있음을 밝힐 것.
#   node2 는 예전에 PM9A3(nvme8n1)이었으나 2026-11-05 에 PM983 으로 옮겼다.
# eternityN = raft id N, raft 포트 6000. 1~10 모두 IPoIB EDR. IB 인터페이스 이름은 호스트마다
#   다르다 (7: ibp177s0, 8: ibp175s0, 나머지 ibp59s0) -- 이름 대신 10.0.0.x 주소로 찾는다.
# DOWN 은 해당 전송 모드(ipoib: rdma/tcp-ipoib)를 쓸 수 없다는 표시다.

# 실행 시 선택. 우선순위: NODES > TOPO > 기본(3노드)
#   NODES="1 3 4 5 6" ./start_node.sh ...      직접 지정 (순서 = cluster 순서, 1~6 아무 조합)
#   TOPO=5 ./start_node.sh ...                 프리셋 (2 3 4 5 6)
#   TOPO=6 ./start_node.sh ...                 프리셋 (1 2 3 4 5 6)
#   TOPO=7 ./start_node.sh ...                 프리셋 (2 .. 8)
#   TOPO=9 ./start_node.sh ...                 프리셋 (2 .. 10)
TOPO_3_NODES="${TOPO_3_NODES:-4 5 6}"
TOPO_4_NODES="${TOPO_4_NODES:-3 4 5 6}"
TOPO_5_NODES="${TOPO_5_NODES:-2 3 4 5 6}"
TOPO_6_NODES="${TOPO_6_NODES:-1 2 3 4 5 6}"
TOPO_7_NODES="${TOPO_7_NODES:-2 3 4 5 6 7 8}"
TOPO_9_NODES="${TOPO_9_NODES:-2 3 4 5 6 7 8 9 10}"
if [[ -z "${NODES:-}" ]]; then
    case "${TOPO:-3}" in
        3) NODES="$TOPO_3_NODES" ;;
        4) NODES="$TOPO_4_NODES" ;;
        5) NODES="$TOPO_5_NODES" ;;
        6) NODES="$TOPO_6_NODES" ;;
        7) NODES="$TOPO_7_NODES" ;;
        9) NODES="$TOPO_9_NODES" ;;
        *) echo "invalid TOPO: ${TOPO} (3|4|5|6|7|9)" >&2; return 1 2>/dev/null || exit 1 ;;
    esac
fi
export NODES

# 호스트명 규칙: eternity<ID> (sweep_payload.sh 의 기존 NODE5=eternity5 와 동일).
host_for_id() { echo "eternity$1"; }

# ib_iface -> 이 호스트에서 10.0.0.x(IPoIB) 주소가 붙은 인터페이스 이름.
#   IB 인터페이스 이름은 카드가 꽂힌 PCIe 위치에서 오므로 호스트마다 다르다.
ib_iface() {
    local i
    i="$(ip -o -4 addr show 2>/dev/null | awk '$4 ~ /^10\.0\.0\./ {print $2; exit}')"
    [[ -n "$i" ]] || { echo "ib_iface: 10.0.0.x 주소가 붙은 인터페이스가 없다" >&2; return 1; }
    echo "$i"
}

# ib_numa_node -> 그 IB 카드가 붙은 NUMA 노드 번호 (모르면 -1)
ib_numa_node() {
    local i n
    i="$(ib_iface)" || return 1
    n="$(cat "/sys/class/net/$i/device/numa_node" 2>/dev/null || echo -1)"
    echo "$n"
}

# _pool_field <id> <col>   col: 1=ipoib 2=eth 3=nqn 4=storage_dev
_pool_field() {
    local e f
    for e in "${POOL[@]}"; do
        e="${e%%#*}"                       # 줄 끝 주석 제거
        IFS='|' read -r -a f <<< "$e"
        if [[ "${f[0]}" == "$1" ]]; then echo "${f[$2]}"; return 0; fi
    done
    return 1
}

is_valid_id() {                            # 풀이 아니라 **이번 NODES** 기준
    local x
    for x in $NODES; do [[ "$x" == "$1" ]] && return 0; done
    return 1
}

valid_ids_str() { echo "${NODES// /, }"; }

# dev_for_nqn <nqn>  ->  이 호스트에서 그 subsystem 이 보이는 블록 장치 (/dev/nvmeXnY)
#   connect 순서에 따라 번호가 달라지므로 장치 이름을 POOL 에 적지 않고 매번 찾는다.
#   attach 안 돼 있거나 namespace 가 여럿이면 실패한다.
dev_for_nqn() {
    local nqn="$1" s heads=()
    for s in /sys/class/nvme-subsystem/nvme-subsys*; do
        [[ -r "$s/subsysnqn" ]] || continue
        [[ "$(<"$s/subsysnqn")" == "$nqn" ]] || continue
        heads=("$s"/nvme*n*)
        [[ -e "${heads[0]}" ]] || heads=()
        break
    done
    if [[ ${#heads[@]} -ne 1 ]]; then
        echo "dev_for_nqn: '$nqn' 의 namespace 가 이 호스트에 ${#heads[@]}개 (attach 됐는지 확인: nvme list-subsys)" >&2
        return 1
    fi
    if [[ ! -b "/dev/${heads[0]##*/}" ]]; then
        echo "dev_for_nqn: /dev/${heads[0]##*/} 가 블록 장치가 아니다" >&2
        return 1
    fi
    echo "/dev/${heads[0]##*/}"
}

# build_cluster <ipoib|eth>  ->  CLUSTER ADDRS (NODES 순서)
#   device 필드: 이 호스트에서 해석되면 실제 장치, 아니면 "nqn:<nqn>".
#   raft_node 는 자기 항목의 device_path 만 쓰므로(apps/raft_node_main.cpp:270)
#   다른 멤버 항목은 자리만 채우면 되고, 스토리지·클라이언트 호스트에서도 실패하지 않는다.
build_cluster() {
    local kind="$1" col id addr dev nqn sh
    case "$kind" in
        ipoib) col=1; sh="10.0.0.91:5050" ;;
        eth)   col=2; sh="115.145.173.243:5050" ;;
        *) echo "build_cluster: kind must be ipoib|eth" >&2; return 1 ;;
    esac
    CLUSTER=""; ADDRS=""
    for id in $NODES; do
        addr="$(_pool_field "$id" "$col")"  || { echo "node $id: 풀에 없음" >&2; return 1; }
        nqn="$(_pool_field "$id" 3)"
        dev="$(dev_for_nqn "$nqn" 2>/dev/null)" || dev="nqn:${nqn}"
        if [[ "$addr" == DOWN* ]]; then
            echo "node $id: 이 전송 모드($kind)의 링크가 비정상(DOWN). tcp(Ethernet)로만 쓸 수 있다 (env.sh POOL)" >&2
            return 1
        fi
        if [[ "$addr" == TODO* || -z "$nqn" || "$nqn" == TODO* ]]; then
            echo "node $id: 풀의 TODO 값(addr=$addr nqn=$nqn)을 채우기 전에는 NODES 에 넣을 수 없다 (env.sh POOL)" >&2
            return 1
        fi
        CLUSTER+="${CLUSTER:+,}${id}@${addr}@${dev}@${sh}"
        ADDRS+="${ADDRS:+,}${addr}"
    done
    export CLUSTER ADDRS
}

# build_bc_devices -> BC_DEVICES (NODES 순서, 스토리지 서버의 raft_blockcopy_server -devices 용)
build_bc_devices() {
    local id sdev
    BC_DEVICES=""
    for id in $NODES; do
        sdev="$(_pool_field "$id" 4)" || { echo "node $id: 풀에 없음" >&2; return 1; }
        if [[ -z "$sdev" || "$sdev" == TODO* ]]; then
            echo "node $id: storage_dev 가 풀에 없음 (env.sh POOL, ./nvmeof_ctl.sh map 으로 확인)" >&2
            return 1
        fi
        BC_DEVICES+="${BC_DEVICES:+,}${sdev}"
    done
    export BC_DEVICES
}

#
# Common benchmark settings 
#
# export RING_PAGES=4096
export RING_PAGES=524288
export RING_PRECONDITION="${RING_PRECONDITION:-1}"
export HEARTBEAT_MS=300
export AE_BATCH=64
export COPY_WORKERS=8
export MAX_GC_REQ=32
export MAX_GC_BYTES=4194304

metadata_dir_for_id() {
    if ! is_valid_id "$1"; then
        echo "unknown node id: $1 (NODES=$NODES)" >&2
        return 1
    fi
    echo "/mnt/raftvol/node$1"
}

# device_for_id <id>  ->  이 호스트에서 그 멤버 볼륨이 보이는 장치 (nqn 으로 해석)
#   자기 볼륨(-cluster)과 push 대상(-push-devices) 모두 이것으로 찾는다.
device_for_id() {
    local nqn
    is_valid_id "$1" || { echo "unknown node id: $1 (NODES=$NODES)" >&2; return 1; }
    nqn="$(_pool_field "$1" 3)"
    if [[ -z "$nqn" || "$nqn" == TODO* ]]; then
        echo "node $1: nqn 이 풀에 없음 (env.sh POOL)" >&2
        return 1
    fi
    dev_for_nqn "$nqn" || { echo "node $1: 볼륨($nqn)이 이 호스트에 attach 안 됨" >&2; return 1; }
}

#
# 하위 호환: 예전 env.sh 가 source 시점에 export 하던 상수들
#
# IPoIB addresses
# - RDMA transport에서도 사용
# - TCP-over-IPoIB에서도 사용
#   -> CLUSTER_IPOIB / ADDRS_IPOIB
# Ethernet addresses
# - Normal TCP/Ethernet에서 사용
#   -> CLUSTER_ETH / ADDRS_ETH
#
# 이제 정적 문자열이 아니라 현재 NODES 로 풀에서 생성한다.
# DOWN/TODO 때문에 만들 수 없는 쪽(예: NODES 에 2번이 있는 IPoIB)은 정의하지 않는다.
# CLUSTER / ADDRS 는 원본처럼 select_transport_env 를 부를 때만 설정된다.
#
_export_compat_constants() {
    local had_c=0 had_a=0 sc="" sa=""
    if [[ -n "${CLUSTER+x}" ]]; then had_c=1; sc="$CLUSTER"; fi
    if [[ -n "${ADDRS+x}" ]];   then had_a=1; sa="$ADDRS";   fi

    if build_cluster ipoib 2>/dev/null; then
        export CLUSTER_IPOIB="$CLUSTER" ADDRS_IPOIB="$ADDRS"
    fi
    if build_cluster eth 2>/dev/null; then
        export CLUSTER_ETH="$CLUSTER" ADDRS_ETH="$ADDRS"
    fi

    if [[ $had_c -eq 1 ]]; then export CLUSTER="$sc"; else unset CLUSTER; fi
    if [[ $had_a -eq 1 ]]; then export ADDRS="$sa";   else unset ADDRS;   fi
}
_export_compat_constants

#
# transport mode 선택
#
# rdma
#   → -transport rdma
#   → 10.0.0.x IPoIB addresses
#
# tcp-ib
#   → -transport tcp
#   → 10.0.0.x IPoIB addresses
#
# tcp
#   → -transport tcp
#   → 115.145.173.x Ethernet addresses
#
select_transport_env() {
    local mode="$1"

    case "$mode" in
        rdma)
            export TRANSPORT="rdma"
            build_cluster ipoib || return 1
            ;;

        tcp-ib)
            export TRANSPORT="tcp"
            build_cluster ipoib || return 1
            ;;

        tcp)
            export TRANSPORT="tcp"
            build_cluster eth || return 1
            ;;

        *)
            echo "invalid transport mode: $mode" >&2
            echo "valid modes: rdma, tcp-ib, tcp" >&2
            return 1
            ;;
    esac
}