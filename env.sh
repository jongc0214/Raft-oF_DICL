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
    "4|10.0.0.4:6000|115.145.173.123:6000|nqn.2016-06.io.spdk:node4|/dev/ublkb4"
    "5|10.0.0.5:6000|115.145.173.124:6000|nqn.2016-06.io.spdk:node5|/dev/ublkb5"
    "6|10.0.0.6:6000|115.145.173.125:6000|nqn.2016-06.io.spdk:node6|/dev/ublkb6"
    # 2026-11-17 SPDK 타깃(spdk_cache wtcache, 10.0.0.91:4421) 실험: SPDK 는 NQN 이 11자 이상이어야 해서
    #   4/5/6 의 nqn 을 nqn.2016-06.io.spdk:nodeN 으로 바꿨다. 커널 nvmet(4420) 으로 원복하면 nodeN 으로 되돌릴 것.
    #   storage_dev 도 4/5/6 은 SPDK ublk 장치다 (ublk_start_disk <bdev> <id>, ublk id = node id, 루프백 없음).
    #   PM983 by-id(…509494/496/484)는 vfio 로 넘어가 커널에 없다. 커널 nvmet 으로 원복하면 by-id 로 되돌릴 것.
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

# NODE4_E1=1 : remote pull 실험 (2026-11-11). node4 볼륨을 eternitystorage PM983 대신
#   eternity1 의 970 EVO Plus 250GB (nvmet e1node1, rdma 10.0.0.1:4420) 로 쓴다.
#   팔로워 볼륨과 blockcopy 서버(eternitystorage)는 그대로라, 서버의 node4 읽기만 원격이 된다.
#   storage_dev 는 eternitystorage 가 e1node1 을 initiator 로 붙였을 때의 by-id (ns device_uuid).
#   호스트 설정/원복은 ./remote_pull.sh up|down. 모든 호스트(서버 포함)에 같은 값을 줄 것.
if [[ "${NODE4_E1:-0}" == "1" ]]; then
    for _i in "${!POOL[@]}"; do
        if [[ "${POOL[$_i]}" == 4\|* ]]; then
            POOL[$_i]="4|10.0.0.4:6000|115.145.173.123:6000|e1node1|/dev/disk/by-id/nvme-uuid.3ffbc4a8-8cde-4ba2-b208-ccd5d47a433a"   # eternity1 970 EVO
        fi
    done
    unset _i
fi

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

# ctrl_for_nqn <nqn>  ->  "<컨트롤러 이름> <cntlid>" (예: "nvme1 4")
#   cntlid 는 연결(association)마다 새로 받으므로, 재연결 여부를 이것으로 안다
#   (scripts/probe_io_queues.sh 기록과 start_node.sh 의 대조에 쓴다).
ctrl_for_nqn() {
    local nqn="$1" s c
    for s in /sys/class/nvme-subsystem/nvme-subsys*; do
        [[ -r "$s/subsysnqn" && "$(<"$s/subsysnqn")" == "$nqn" ]] || continue
        for c in "$s"/nvme[0-9]*; do
            [[ "${c##*/}" =~ ^nvme[0-9]+$ ]] || continue
            echo "${c##*/} $(<"/sys/class/nvme/${c##*/}/cntlid")"
            return 0
        done
    done
    echo "ctrl_for_nqn: '$nqn' 컨트롤러가 이 호스트에 없다" >&2
    return 1
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

# record_io_pin <outfile>  ->  NODES 의 각 노드가 어떤 CPU 로 persist 스레드를 고정했는지 기록
#   (start_node.sh IO_PIN / raft_node -io-cpus). 각 노드의 가장 최근 .cond 에 붙은 기동 배너($RAFT_ROOT 는 NFS
#   라 모든 노드 로그가 보인다)에서 뽑는다. 스윕 결과의 LPersist/StorageIO 는 고정 여부에 따라
#   1MiB 기준 ~75us 달라지므로 결과와 같이 남긴다.
record_io_pin() {
    local out="$1" id lg line push
    : > "$out"
    for id in $NODES; do
        lg="$(ls -t "$RAFT_ROOT"/raft_node_"${id}"_*.cond 2>/dev/null | head -1)"   # 배너는 .cond 에 붙어 있다
        if [[ -z "$lg" ]]; then echo "node $id: (시작 기록 없음)" >> "$out"; continue; fi
        line="$(grep -m1 '^  io cpus' "$lg" | sed 's/^  io cpus *: //')"
        push="$(grep '^  push device' "$lg" | grep -oE '^  push device *: [0-9]+|cpus [^)]*' | sed 's/^  push device *: /push /' | paste -sd' ' -)"
        echo "node $id: io cpus ${line:-(줄 없음: -io-cpus 이전 바이너리)}${push:+ | $push} [${lg##*/}]" >> "$out"
    done
}

# ---------------------------------------------------------------------------
# 전송 구성 확인 (11-13/11-16, 배포 시뮬레이션)
#   TCP 코드는 망을 모른다 -- 어느 NIC 로 가는지는 **주소로만** 정해진다. 그래서 주소 하나가
#   다른 망으로 남으면 라벨과 실제 측정이 조용히 어긋난다 (11-13 이전 tcp-ib 결과가 실제로는
#   1GbE 였다). 기동 전에 구성(TRANSPORT_MODE)과 실제 주소·NVMe 전송을 대조한다.
#
#   구성     raft/blockcopy 주소   NVMe-oF
#   rdma     10.0.0.x  (ipoib)     rdma, 10.0.0.x
#   tcp      115.145.173.x (eth)   tcp,  115.145.173.x   <- TCP 본 실험 (이더넷)
#   tcp-ib   10.0.0.x  (ipoib)     tcp,  10.0.0.x        <- IPoIB 전환 선택지
# ---------------------------------------------------------------------------

# net_prefix <ipoib|eth>  ->  그 망의 주소 앞부분
net_prefix() {
    case "$1" in
        ipoib) echo "10.0.0." ;;
        eth)   echo "115.145.173." ;;
        *) echo "net_prefix: ipoib|eth" >&2; return 1 ;;
    esac
}

# mode_expect <rdma|tcp|tcp-ib>  ->  "<주소 망> <NVMe 전송> <NVMe 망>"
mode_expect() {
    case "$1" in
        rdma)   echo "ipoib rdma ipoib" ;;
        tcp)    echo "eth tcp eth" ;;
        tcp-ib) echo "ipoib tcp ipoib" ;;
        *) echo "mode_expect: rdma|tcp|tcp-ib" >&2; return 1 ;;
    esac
}

# nvme_paths_for_nqn <nqn>  ->  그 subsystem 의 컨트롤러마다 "<ctrl> <transport> <traddr>:<trsvcid>" 한 줄
nvme_paths_for_nqn() {
    local nqn="$1" s c name addr ta ts
    for s in /sys/class/nvme-subsystem/nvme-subsys*; do
        [[ -r "$s/subsysnqn" && "$(<"$s/subsysnqn")" == "$nqn" ]] || continue
        for c in "$s"/nvme[0-9]*; do
            name="${c##*/}"
            [[ "$name" =~ ^nvme[0-9]+$ ]] || continue
            addr="$(cat "/sys/class/nvme/$name/address" 2>/dev/null)"
            ta="$(sed -n 's/.*traddr=\([^,]*\).*/\1/p' <<< "$addr")"
            ts="$(sed -n 's/.*trsvcid=\([^,]*\).*/\1/p' <<< "$addr")"
            echo "$name $(cat "/sys/class/nvme/$name/transport" 2>/dev/null) ${ta:-?}:${ts:-?}"
        done
    done
}

# nvme_desc_for_id <id>  ->  배너용 한 줄 ("tcp 115.145.173.243:4421 (nvme3)" 등, 여럿이면 ' / ')
nvme_desc_for_id() {
    local out
    out="$(nvme_paths_for_nqn "$(_pool_field "$1" 3)" | awk '{printf "%s%s %s (%s)", (NR>1?" / ":""), $2, $3, $1}')"
    echo "${out:-(attach 안 됨)}"
}

# check_transport <rdma|tcp|tcp-ib>
#   1) CLUSTER 가 있으면 각 항목의 raft 주소와 storage_host 가 기대 망인지
#   2) NODES 의 볼륨 중 이 호스트에 붙은 것의 모든 컨트롤러가 기대 전송·망인지
#      (자기 볼륨만 필수: MY_ID 가 있으면 그 볼륨이 붙어 있어야 한다)
#   하나라도 어긋나면 이유를 찍고 1. CHECK_TRANSPORT=0 이면 건너뛴다 (경고만).
check_transport() {
    local mode="$1" net nvt nvnet pfx nvpfx bad=0 e id addr sh nqn line ctrl tr ta found
    if [[ "${CHECK_TRANSPORT:-1}" == "0" ]]; then
        echo "WARN: CHECK_TRANSPORT=0 -- 전송 구성 확인을 건너뛴다" >&2
        return 0
    fi
    read -r net nvt nvnet <<< "$(mode_expect "$mode")" || return 1
    pfx="$(net_prefix "$net")"; nvpfx="$(net_prefix "$nvnet")"

    if [[ -n "${CLUSTER:-}" ]]; then
        for e in ${CLUSTER//,/ }; do
            IFS='@' read -r id addr _ sh <<< "$e"
            if [[ "$addr" != "$pfx"* ]]; then
                echo "ERROR: [$mode] node $id raft 주소 $addr 가 $net($pfx*) 가 아니다" >&2; bad=1
            fi
            if [[ -n "$sh" && "$sh" != "$pfx"* ]]; then
                echo "ERROR: [$mode] node $id storage_host $sh 가 $net($pfx*) 가 아니다" >&2; bad=1
            fi
        done
    fi

    for id in $NODES; do
        nqn="$(_pool_field "$id" 3)" || continue
        found=0
        while read -r ctrl tr ta; do
            [[ -n "$ctrl" ]] || continue
            found=1
            if [[ "$tr" != "$nvt" || "$ta" != "$nvpfx"* ]]; then
                echo "ERROR: [$mode] node $id 볼륨($nqn) $ctrl 가 $tr $ta 다 -- 기대: $nvt $nvpfx* (nvmeof_switch.sh)" >&2
                bad=1
            fi
        done < <(nvme_paths_for_nqn "$nqn")
        if [[ $found -eq 0 && "${MY_ID:-}" == "$id" ]]; then
            echo "ERROR: [$mode] 자기 볼륨($nqn)이 이 호스트에 붙어 있지 않다" >&2; bad=1
        fi
    done

    if [[ $bad -ne 0 ]]; then
        echo "       구성 '$mode' 는 주소 $net, NVMe $nvt/$nvnet 이어야 한다. 의도한 것이면 CHECK_TRANSPORT=0" >&2
        return 1
    fi
    return 0
}

# braft_tools_dir <eth|ipoib>  ->  braft 도구 디렉터리 경로
#   eth   : 원본 (/home/jongc/braft/braft_block_tools, cluster.env 의 POOL 이 1GbE 주소)
#   ipoib : 원본의 스크립트와 cluster.env 를 $RAFT_ROOT/results/braft_tools_ipoib 로 복사하고
#           POOL 주소만 이 파일 POOL 의 IPoIB 주소로 바꾼다 (원본은 root 소유라 고치지 않는다).
#           저장소(NFS) 안이라 노드와 클라이언트 호스트가 같은 사본을 본다. 부를 때마다 다시 만든다.
BRAFT_TOOLS_SRC="${BRAFT_TOOLS_SRC:-/home/jongc/braft/braft_block_tools}"
braft_tools_dir() {
    local dst="$RAFT_ROOT/results/braft_tools_ipoib" f e id ip sedx=()
    case "$1" in
        eth) echo "$BRAFT_TOOLS_SRC"; return 0 ;;
        ipoib) ;;
        *) echo "braft_tools_dir: eth|ipoib" >&2; return 1 ;;
    esac
    mkdir -p "$dst" || return 1
    # 내용이 다를 때만 바꾼다 (다른 호스트가 이 사본으로 run_block_node.sh 를 돌리는 중일 수 있다 -- NFS)
    for f in "$BRAFT_TOOLS_SRC"/*.sh; do
        cmp -s "$f" "$dst/${f##*/}" && continue
        cp "$f" "$dst/${f##*/}.tmp.$$" && mv -f "$dst/${f##*/}.tmp.$$" "$dst/${f##*/}" || return 1
    done
    for e in "${POOL[@]}"; do
        e="${e%%#*}"
        IFS='|' read -r id ip _ <<< "$e"
        ip="${ip%:*}"
        sedx+=(-e "s/^\([[:space:]]*\"\)${id}|[0-9.]*\"/\1${id}|${ip}\"/")
    done
    {
        echo "# 자동 생성 (raftof_clean env.sh braft_tools_dir ipoib): $BRAFT_TOOLS_SRC/cluster.env 의 POOL 을 IPoIB 로"
        sed "${sedx[@]}" "$BRAFT_TOOLS_SRC/cluster.env"
    } > "$dst/cluster.env.tmp.$$" || return 1
    if cmp -s "$dst/cluster.env.tmp.$$" "$dst/cluster.env"; then rm -f "$dst/cluster.env.tmp.$$"
    else mv -f "$dst/cluster.env.tmp.$$" "$dst/cluster.env" || return 1; fi
    if grep -qE '^[[:space:]]*"[0-9]+\|115\.' "$dst/cluster.env"; then
        echo "braft_tools_dir: $dst/cluster.env 에 이더넷 주소가 남았다" >&2
        return 1
    fi
    echo "$dst"
}

# record_net_cond <outfile>  ->  측정 조건 스냅샷 (record_io_pin 옆에 둔다)
#   NODES 각 노드의 최근 기동 조건(start_node.sh 가 쓰는 raft_node_<id>_*.cond: 전송 구성, 주소, NVMe, sha)과, ssh 로 읽은 호스트별
#   NIC·IRQ·C-state. ssh 가 안 되면 그 줄에 (ssh 실패)만 남긴다 (REC_SSH=0 이면 ssh 생략).
record_net_cond() {
    local out="$1" id lg h
    {
        echo "# record_net_cond $(date '+%F %T') from $(hostname -s)  TRANSPORT=${TRANSPORT:-?} NODES=$NODES"
        for id in $NODES; do
            lg="$(ls -t "$RAFT_ROOT"/raft_node_"${id}"_*.cond 2>/dev/null | head -1)"
            echo "## node $id  [${lg##*/}]"
            [[ -n "$lg" ]] && sed 's/^/  /' "$lg"
            [[ "${REC_SSH:-1}" == "1" ]] || continue
            h="$(host_for_id "$id")"
            ssh -o BatchMode=yes -o ConnectTimeout=3 "$h" 'bash -s' 2>/dev/null <<'EOS' | sed 's/^/  /' || echo "  (ssh $h 실패)"
for i in $(ls /sys/class/net); do
    a="$(ip -o -4 addr show dev "$i" 2>/dev/null | awk '{print $4}' | head -1)"
    case "$a" in 10.0.0.*|115.145.173.*) ;; *) continue ;; esac
    echo "if $i $a mtu=$(cat /sys/class/net/$i/mtu) speed=$(cat /sys/class/net/$i/speed 2>/dev/null)Mb mode=$(cat /sys/class/net/$i/mode 2>/dev/null || echo -) numa=$(cat /sys/class/net/$i/device/numa_node 2>/dev/null)"
    drv="$(basename "$(readlink /sys/class/net/$i/device/driver 2>/dev/null)")"
    irqs="$(ls /sys/class/net/$i/device/msi_irqs 2>/dev/null | head -64)"
    aff=""
    for q in $irqs; do aff+="$q:$(cat /proc/irq/$q/smp_affinity_list 2>/dev/null) "; done
    echo "   driver=$drv irq(affinity)=${aff:-?}"
done
echo "cstate $(for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do printf '%s=%s ' "$(cat $s/name)" "$(cat $s/disable)"; done)"
echo "governor $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
EOS
        done
    } > "$out"
}

# ---------------------------------------------------------------------------
# 로컬 실행 (LOCAL_RUN=1, start_node.sh / start_blockcopy.sh 기본)
#   저장소($RAFT_ROOT)는 NFS 라 실행 중 로그 쓰기와 실행 파일 페이지 읽기가 가끔 수백 ms~수 초
#   멈춘다 (2026-11-12: 리더 mu 를 쥔 스레드가 멈춰 MutexC/QW 평균만 튐, 락 계측으로 확인).
#   그래서 실행 파일은 로컬로 복사해 돌리고, 로그는 로컬에 쓴다. 저장소 로그 경로에는 기동 배너만
#   두었다가(record_io_pin 용) stop_*.sh 가 전체 로그로 덮어쓴다.
# ---------------------------------------------------------------------------
LOCAL_DIR="${LOCAL_DIR:-/var/tmp/raftof-$(id -un)}"

# local_dir_ok  ->  LOCAL_DIR 을 만들고 로컬 디스크인지 확인 (NFS 등이면 실패)
local_dir_ok() {
    mkdir -p "$LOCAL_DIR/bin" || { echo "ERROR: $LOCAL_DIR 를 만들지 못했다" >&2; return 1; }
    case "$(findmnt -no FSTYPE -T "$LOCAL_DIR" 2>/dev/null)" in
        nfs*|cifs|smb*|fuse*|"") echo "ERROR: LOCAL_DIR=$LOCAL_DIR 가 로컬 디스크가 아니다" >&2; return 1 ;;
    esac
}

# stage_binary <원본 경로>  ->  "<로컬 경로> <sha256 앞 12자리>" 출력
#   내용이 다를 때만 복사한다. 임시 파일에 쓰고 mv 로 바꿔 넣어 돌고 있는 프로세스의 파일은 건드리지 않는다.
stage_binary() {
    local src="$1" dst
    dst="$LOCAL_DIR/bin/$(basename "$src")"
    [[ -x "$src" ]] || { echo "ERROR: $src 가 없다" >&2; return 1; }
    local_dir_ok || return 1
    if ! cmp -s "$src" "$dst"; then
        cp "$src" "$dst.tmp.$$" && chmod 755 "$dst.tmp.$$" && mv -f "$dst.tmp.$$" "$dst" ||
            { rm -f "$dst.tmp.$$"; echo "ERROR: $src -> $dst 복사 실패" >&2; return 1; }
    fi
    echo "$dst $(sha256sum "$dst" | cut -c1-12)"
}

# publish_banner <로컬 로그> <저장소 로그> <바이너리 sha> [끝 줄 정규식]
#   로컬 로그의 첫 줄부터 끝 줄(포함)까지를 저장소 로그에 쓴다. 끝 줄이 없으면 최대 3초 기다린 뒤
#   있는 만큼 쓴다. 맨 위에 '# local run' 머리를 붙인다.
publish_banner() {
    local llog="$1" rlog="$2" sha="$3" endre="${4:-^  term/tail}" i
    for i in $(seq 1 30); do
        grep -qE "$endre" "$llog" 2>/dev/null && break
        sleep 0.1
    done
    {
        echo "# local run: host=$(hostname -s) log=$llog bin_sha=$sha"
        echo "# (기동 배너만. 전체 로그는 stop 스크립트가 여기로 가져온다)"
        awk -v re="$endre" 'NR > 200 {exit} {print} $0 ~ re {exit}' "$llog" 2>/dev/null
    } > "$rlog.tmp.$$" && mv -f "$rlog.tmp.$$" "$rlog"
}

# collect_local_logs <접두사>  ->  LOCAL_DIR/running_<접두사>*.env 마다 로컬 로그 전체를 저장소로 복사
#   env 파일 형식: LLOG=… / RLOG=… / SHA=…
collect_local_logs() {
    local prefix="$1" f LLOG RLOG SHA
    for f in "$LOCAL_DIR"/running_"$prefix"*.env; do
        [[ -e "$f" ]] || continue
        LLOG=""; RLOG=""; SHA=""
        # shellcheck disable=SC1090
        source "$f"
        if [[ -n "$LLOG" && -n "$RLOG" && -r "$LLOG" ]]; then
            { echo "# local run: host=$(hostname -s) log=$LLOG bin_sha=$SHA (전체, stop 때 복사)"; cat "$LLOG"; } \
                > "$RLOG.tmp.$$" && mv -f "$RLOG.tmp.$$" "$RLOG" &&
                echo "[log] $LLOG -> $RLOG ($(wc -l < "$LLOG") lines)"
        else
            echo "[log] WARN: $f 의 로컬 로그($LLOG)를 읽지 못했다"
        fi
        rm -f "$f"
    done
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