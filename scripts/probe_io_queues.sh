#!/usr/bin/env bash
#
# probe_io_queues.sh -- 이 호스트의 NVMe-oF 큐(hctx) 중 어느 것이 빠른지 찾는다
#
#   ./scripts/probe_io_queues.sh            자기 볼륨만 (호스트명 eternityN -> node N)
#   ./scripts/probe_io_queues.sh 4 6        node 4, 6 볼륨 (push 대상 확인용)
#   ALL=1 ./scripts/probe_io_queues.sh      NODES(TOPO) 의 모든 멤버 볼륨
#
# 왜: NVMe-oF 쓰기는 보내는 CPU 의 큐로 나가고, 큐마다 스토리지의 nvmet-rdma 큐가 따로 있다.
#   그 큐의 완료 IRQ 가 스토리지 IB 카드와 다른 NUMA 노드의 CPU 에 걸려 있으면 1MiB 쓰기가
#   ~75us 느리다 (2026-11-08, eternity4/5/6 fio 로 확인). 배치는 연결할 때 정해지고 재연결하면 바뀐다.
#
# 방법 (데이터는 바꾸지 않는다):
#   큐마다 그 큐의 CPU 하나에 고정해 장치 앞부분을 O_DIRECT 4K 로 COUNT 번 **읽고**,
#   그동안 스토리지 /proc/interrupts 의 mlx5_comp 증가분이 가장 큰 IRQ 를 그 큐의 것으로 본다.
#   그 IRQ 가 고정된 스토리지 CPU 의 NUMA 노드 == IB 카드 NUMA 노드면 fast, 아니면 slow.
#   raft_node 가 돌고 있으면 다른 트래픽이 섞이므로 멈춘 상태에서 돌린다 (이 호스트만 검사한다.
#   다른 호스트의 raft_node 도 스토리지 트래픽을 만들므로 클러스터 전체를 멈출 것).
#   여러 호스트에서 동시에 실행하면 공유 잠금 파일로 차례대로 돈다.
#
# 결과:
#   표 출력 + $RAFT_ROOT/results/io_queues/<호스트>.env
#     IOQ_<id>_CTRL / IOQ_<id>_CNTLID  재연결 감지용 (start_node.sh 가 지금 값과 대조)
#     IOQ_<id>_CPUS                    고정에 쓸 CPU: 빠른 큐 중 이 호스트 IB 노드의 CPU,
#                                      없으면 반대 노드의 빠른 큐 CPU (호스트 쪽 소켓은 거의 무관, 11-08)
#     IOQ_<id>_TABLE                   hctx별 판정 (기록용)
#   start_node.sh 가 IO_PIN 에 따라 이 파일을 읽어 -io-cpus / -push-cpus 로 넘긴다.
#
# 환경변수: COUNT(기본 20000), STORAGE_SSH(기본 eternitystorage), TOPO/NODES (ALL=1 일 때)
# sudo 필요 (원시 장치 읽기). 스토리지는 ssh 로 읽기만 한다 (sudo 불필요).
# root 로 돌려도 된다: ssh 는 저장소 주인 계정(runuser)으로 하고 결과 파일도 그 계정 소유로 둔다.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../env.sh"

COUNT="${COUNT:-20000}"
STORAGE_SSH="${STORAGE_SSH:-eternitystorage}"
HOST="$(hostname -s)"
OWN_ID="${HOST#eternity}"

if [[ $# -gt 0 ]]; then
    IDS="$*"
elif [[ "${ALL:-0}" == "1" ]]; then
    IDS="$NODES"
else
    [[ "$OWN_ID" =~ ^[0-9]+$ ]] || { echo "ERROR: 호스트명($HOST)에서 node id 를 알 수 없다. id 를 인자로 줄 것"; exit 1; }
    IDS="$OWN_ID"
fi

if pgrep -x raft_node >/dev/null; then
    echo "ERROR: raft_node 가 돌고 있다. 스토리지 IRQ 에 그 트래픽이 섞이므로 ./stop_node.sh 후에 돌릴 것"
    exit 1
fi
sudo -v

IB_NODE="$(ib_numa_node)"

# root 로 돌려도 된다. 다만 스토리지 ssh 는 root 의 키/known_hosts 로는 안 되므로
# (eternity4: 호스트 키 없음, eternity5: 키 미등록, 11-11) 저장소 주인 계정으로 한다.
# 결과 파일도 그 계정 소유로 남겨 일반 계정의 start_node.sh 가 읽을 수 있게 한다.
REPO_OWNER="$(stat -c %U "$RAFT_ROOT")"
AS_OWNER=()
if [[ $EUID -eq 0 && "$REPO_OWNER" != "root" ]]; then
    AS_OWNER=(runuser -u "$REPO_OWNER" --)
fi
ssh_storage() { "${AS_OWNER[@]}" ssh -o BatchMode=yes "$STORAGE_SSH" "$@"; }

# 스토리지 mlx5_comp IRQ 별 누적 횟수: "irq count" 줄들
storage_irq_counts() {
    ssh_storage \
        "awk '/mlx5_comp/ { s=0; for (i=2; i<=NF && \$i ~ /^[0-9]+\$/; i++) s+=\$i; sub(\":\",\"\",\$1); print \$1, s }' /proc/interrupts"
}

# storage_irq_info <irq> -> "<storage cpu> <cpu numa> <hca numa>"
storage_irq_info() {
    ssh_storage bash -s -- "$1" <<'EOS'
irq="$1"
cpu="$(cut -d, -f1 /proc/irq/$irq/effective_affinity_list | cut -d- -f1)"
node="$(ls -d /sys/devices/system/cpu/cpu$cpu/node* 2>/dev/null | head -1 | sed 's/.*node//')"
pci="$(grep -E "^ *$irq:" /proc/interrupts | grep -oE '@pci:[0-9a-f:.]+' | sed 's/@pci://')"
hca="$(cat /sys/bus/pci/devices/$pci/numa_node 2>/dev/null || echo '?')"
echo "$cpu ${node:-?} $hca"
EOS
}

OUT_DIR="$RAFT_ROOT/results/io_queues"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$HOST.env"

# 여러 호스트에서 동시에 돌리면 스토리지 IRQ 증가분에 서로의 dd 가 섞여 엉뚱한 IRQ 를 고른다.
# $RAFT_ROOT 는 모든 호스트가 공유하는 NFS(v4, local_lock=none -> 잠금이 서버에서 걸린다)라
# 여기 잠금 파일로 호스트 사이에서도 한 번에 하나만 돌게 한다.
LOCK="$OUT_DIR/.probe.lock"
[[ -e "$LOCK" ]] || { : > "$LOCK"; chmod 666 "$LOCK" 2>/dev/null || true; }
exec 9<>"$LOCK"
if ! flock -n 9; then
    echo "다른 호스트가 probe 중이다. 끝나면 이어서 돈다..."
    flock 9
fi
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
{
    echo "# probe_io_queues.sh $(date -u +%Y-%m-%dT%H:%M:%SZ) host=$HOST ib_numa=$IB_NODE count=$COUNT"
} > "$TMP"

for id in $IDS; do
    nqn="$(_pool_field "$id" 3)" || { echo "ERROR: node $id 가 env.sh POOL 에 없다"; exit 1; }
    dev="$(dev_for_nqn "$nqn")" || exit 1
    # 이 subsystem 의 컨트롤러와, 큐 정보가 있는 경로(nvmeXcYnZ)
    read -r ctrl cntlid <<< "$(ctrl_for_nqn "$nqn")" || exit 1
    [[ -n "$ctrl" ]] || { echo "ERROR: node $id ($nqn) 컨트롤러를 찾지 못했다"; exit 1; }
    mqdir=""
    for p in /sys/class/nvme/"$ctrl"/"$ctrl"c*n*; do
        [[ -d "$p/mq" ]] && { mqdir="$p/mq"; break; }
    done
    if [[ -z "$mqdir" && -d "/sys/block/${dev##*/}/mq" ]]; then mqdir="/sys/block/${dev##*/}/mq"; fi
    [[ -n "$mqdir" ]] || { echo "ERROR: node $id 의 mq 디렉터리를 찾지 못했다 ($ctrl)"; exit 1; }

    echo
    echo "== node $id ($nqn) $dev ctrl=$ctrl cntlid=$cntlid  (host IB NUMA $IB_NODE)"
    printf '  %-6s %-22s %-5s %-6s %-12s %s\n' hctx "host cpus" probe "irq" "storage cpu" verdict

    fast_ib=""; fast_other=""; table=""
    for q in $(ls "$mqdir" | sort -n); do
        cpus="$(tr -d ' ' < "$mqdir/$q/cpu_list")"
        [[ -n "$cpus" ]] || continue
        cpu="${cpus%%,*}"
        before="$(storage_irq_counts)"
        sudo taskset -c "$cpu" dd if="$dev" of=/dev/null bs=4096 count="$COUNT" iflag=direct status=none
        after="$(storage_irq_counts)"
        top="$(LC_ALL=C join <(LC_ALL=C sort <<< "$before") <(LC_ALL=C sort <<< "$after") | awk '{print $1, $3-$2}' | sort -k2 -n -r | head -1)"
        irq="${top% *}"; delta="${top#* }"
        verdict="?"; scpu="?"
        if [[ -n "$irq" && "$delta" -ge $((COUNT / 2)) ]]; then
            read -r scpu snode hnode <<< "$(storage_irq_info "$irq")"
            if [[ "$snode" == "$hnode" ]]; then verdict="fast"; else verdict="slow"; fi
            scpu="$scpu(n$snode)"
        else
            irq="${irq:-?}(${delta:-0})"
        fi
        printf '  %-6s %-22s %-5s %-6s %-12s %s\n' "$q" "$cpus" "$cpu" "$irq" "$scpu" "$verdict"
        table+="${table:+ }hctx$q:$verdict"
        if [[ "$verdict" == "fast" ]]; then
            for c in ${cpus//,/ }; do
                if [[ "$(ls -d /sys/devices/system/cpu/cpu$c/node* | sed 's/.*node//')" == "$IB_NODE" ]]; then
                    fast_ib+="${fast_ib:+,}$c"
                else
                    fast_other+="${fast_other:+,}$c"
                fi
            done
        fi
    done

    use="${fast_ib:-$fast_other}"
    if [[ -z "$use" ]]; then
        echo "  -> 빠른 큐가 없다. 이 볼륨은 고정해도 이득이 없다 (IOQ_${id}_CPUS 비움)"
    elif [[ -z "$fast_ib" ]]; then
        echo "  -> IB 노드($IB_NODE)에는 빠른 큐가 없어 반대 노드 CPU 를 쓴다: $use"
    else
        echo "  -> 고정 CPU: $use"
    fi
    {
        echo "IOQ_${id}_CTRL=$ctrl"
        echo "IOQ_${id}_CNTLID=$cntlid"
        echo "IOQ_${id}_CPUS=\"$use\""
        echo "IOQ_${id}_TABLE=\"$table\""
    } >> "$TMP"
done

# 이번에 재지 않은 다른 id 의 기존 기록은 남긴다 (자기 볼륨만 다시 재도 push 기록이 지워지지 않게)
if [[ -f "$OUT" ]]; then
    for v in $(grep -oE '^IOQ_[0-9]+_' "$OUT" | sort -u); do
        id="${v#IOQ_}"; id="${id%_}"
        grep -q "^IOQ_${id}_" "$TMP" || grep "^IOQ_${id}_" "$OUT" >> "$TMP"
    done
fi
cp "$TMP" "$OUT"
if [[ $EUID -eq 0 && "$REPO_OWNER" != "root" ]]; then
    chown "$REPO_OWNER": "$OUT_DIR" "$OUT"
fi
echo
echo "saved: $OUT"
