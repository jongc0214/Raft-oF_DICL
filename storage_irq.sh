#!/usr/bin/env bash
#
# storage_irq.sh -- eternitystorage IB 카드(ibp59s0)의 완료 IRQ 를 카드와 같은 NUMA 노드로 모은다 (실험 기간에만)
#
#   ./storage_irq.sh up       mlx5_comp IRQ 를 IB 노드 CPU 로 옮긴다 (원래 값은 기록)
#   ./storage_irq.sh down     기록한 원래 affinity 로 되돌린다
#   ./storage_irq.sh status   현재 배치 출력 (아무것도 바꾸지 않는다)
#
# 왜: 호스트 hctx 마다 스토리지 nvmet-rdma 큐가 하나씩 있고, 그 큐 CQ 의 완료 벡터(mlx5_compN)가
#   걸린 CPU 에서 완료 처리(ib-comp-wq)와 PM983 bio 제출이 돈다. 기본 배치는 벡터 32개를 CPU 32개에
#   하나씩 걸어 comp16..31 이 NUMA1(8-15,24-31)에 있다 -> 그 벡터를 쓰는 큐는 1MiB 에 +~80us
#   (메모리 nvmeof-queue-numa-latency). 벡터를 전부 NUMA0 으로 모으면 어느 hctx 든 빠른 큐가 되어
#   probe 와 CPU 고정에 기대지 않아도 된다.
#
# 무엇을 바꾸나: IB_DEV 카드의 mlx5_compN 만. 벡터 N -> IB 노드 CPU 목록의 (N mod 개수)번째.
#   지금 배치에서는 comp0..15 는 이미 그 자리라 그대로, comp16..31 만 옮겨 노드0 CPU 하나가 벡터 둘을 맡는다.
#   mlx5_async, 다른 카드(ibp216s0), NVMe SSD IRQ 는 건드리지 않는다.
#   쓰는 즉시 적용된다 (재연결 불필요). 측정 도중이 아니라 실행 사이에 할 것.
#   재부팅하면 드라이버 기본값으로 돌아간다 (boot_id 로 감지해 down 이 기록만 지운다).
#   irqbalance 가 켜져 있으면 다시 흩어 놓으므로 up 을 거부한다.
#
# up 뒤에는 각 호스트에서 probe_io_queues.sh 를 다시 돌릴 것 (기존 기록의 slow 판정이 낡는다).
#
# 환경변수: IB_DEV (기본 ibp59s0)
#
set -uo pipefail

IB_DEV="${IB_DEV:-ibp59s0}"
STATE_DIR="/var/lib/raftof-storage-irq"
STATE="$STATE_DIR/state"
HOST_ONLY="eternitystorage"

die() { echo "ERROR: $*" >&2; exit 1; }
as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

case "${1:-}" in
    up|down|status) ;;
    *) sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
CMD="$1"

if [[ "$(hostname -s)" != "$HOST_ONLY" ]]; then
    echo "$(hostname -s): 할 일 없음 ($HOST_ONLY 에서 실행)"
    exit 0
fi

DEVDIR="/sys/class/infiniband/$IB_DEV/device"
[[ -d "$DEVDIR" ]] || die "$IB_DEV 장치가 없다"
PCI="$(basename "$(readlink -f "$DEVDIR")")"
NODE="$(cat "$DEVDIR/numa_node")"
[[ "$NODE" =~ ^[0-9]+$ ]] || die "$IB_DEV NUMA 노드를 알 수 없다 ($NODE)"

# cpulist "0-7,16-23" -> "0 1 ... 23"
expand() {
    local part a b out=()
    for part in ${1//,/ }; do
        if [[ "$part" == *-* ]]; then a="${part%-*}"; b="${part#*-}"; out+=($(seq "$a" "$b"))
        else out+=("$part"); fi
    done
    echo "${out[*]}"
}
NODE_CPUS=($(expand "$(cat /sys/devices/system/node/node$NODE/cpulist)"))
cpu_node() { ls -d /sys/devices/system/cpu/cpu"$1"/node* 2>/dev/null | head -1 | sed 's/.*node//'; }

# "irq vec" 목록 (vec = mlx5_comp 번호)
comp_irqs() {
    grep -E "mlx5_comp[0-9]+@pci:$PCI( |$)" /proc/interrupts |
        sed -E 's/^ *([0-9]+):.*mlx5_comp([0-9]+)@.*/\1 \2/' | sort -k2 -n
}
IRQS="$(comp_irqs)"
[[ -n "$IRQS" ]] || die "$PCI 의 mlx5_comp IRQ 를 찾지 못했다"

boot_id() { cat /proc/sys/kernel/random/boot_id; }
state_get() { [[ -r "$STATE" ]] && sed -n "s/^$1=//p" "$STATE" | tail -1; }

show() {
    local irq vec aff eff n off=0 cnt=0
    echo "== $IB_DEV ($PCI) NUMA $NODE, 노드 CPU: ${NODE_CPUS[*]}"
    echo "   irqbalance: $(systemctl is-active irqbalance 2>/dev/null)"
    if [[ -e "$STATE" ]]; then
        if [[ "$(state_get BOOT)" == "$(boot_id)" ]]; then echo "   상태: up ($(state_get WHEN) 부터)"
        else echo "   상태: 기록은 있으나 그 뒤 재부팅됨 -> 이미 기본값. down 으로 기록만 지울 것"; fi
    else
        echo "   상태: 기본 (up 기록 없음)"
    fi
    printf '   %-6s %-8s %-10s %-10s %s\n' irq vector affinity effective node
    while read -r irq vec; do
        aff="$(cat /proc/irq/$irq/smp_affinity_list)"
        eff="$(cat /proc/irq/$irq/effective_affinity_list 2>/dev/null || echo "$aff")"
        n="$(cpu_node "${eff%%[,-]*}")"
        cnt=$((cnt + 1)); [[ "$n" == "$NODE" ]] || off=$((off + 1))
        printf '   %-6s comp%-4s %-10s %-10s %s%s\n' "$irq" "$vec" "$aff" "$eff" "$n" "$([[ "$n" == "$NODE" ]] || echo '  <- IB 노드 밖')"
    done <<< "$IRQS"
    echo "   => 벡터 $cnt 개 중 IB 노드 밖 $off 개"
}

case "$CMD" in
status)
    show
    ;;
up)
    if [[ -e "$STATE" ]]; then
        [[ "$(state_get BOOT)" == "$(boot_id)" ]] && die "이미 up 상태다 ($STATE). 다시 하려면 먼저 down"
        echo "[up] 재부팅 전 기록이 남아 있어 지운다"; as_root rm -rf "$STATE_DIR"
    fi
    [[ "$(systemctl is-active irqbalance 2>/dev/null)" == "active" ]] &&
        die "irqbalance 가 켜져 있다 -- 옮겨도 다시 흩어 놓는다"
    as_root mkdir -p "$STATE_DIR" || die "$STATE_DIR 를 만들지 못했다"
    { echo "BOOT=$(boot_id)"; echo "WHEN=$(date '+%F %T')"; echo "PCI=$PCI"; } | as_root tee "$STATE" >/dev/null
    moved=0; fail=0
    while read -r irq vec; do
        want="${NODE_CPUS[$((vec % ${#NODE_CPUS[@]}))]}"
        cur="$(cat /proc/irq/$irq/smp_affinity_list)"
        [[ "$cur" == "$want" ]] && continue
        echo "IRQ_$irq=$cur" | as_root tee -a "$STATE" >/dev/null
        if echo "$want" | as_root tee /proc/irq/$irq/smp_affinity_list >/dev/null; then
            eff="$(cat /proc/irq/$irq/effective_affinity_list 2>/dev/null || echo "$want")"
            echo "[up] IRQ $irq comp$vec: $cur -> $want (effective $eff)"
            moved=$((moved + 1))
            [[ "$eff" == "$want" ]] || { echo "  WARN: effective 가 $want 이 아니다"; fail=$((fail + 1)); }
        else
            echo "  ERROR: IRQ $irq 를 쓰지 못했다"; fail=$((fail + 1))
        fi
    done <<< "$IRQS"
    echo "[up] $moved 개 옮김, 문제 $fail 개"
    echo
    show
    echo
    echo "다음: 각 호스트(eternity4/5/6)에서 raft_node 를 멈추고 probe 를 다시 돌린다 -- 모든 hctx 가 fast 로 나와야 한다."
    echo "실험이 끝나면: ./storage_irq.sh down"
    [[ $fail -eq 0 ]] || exit 1
    ;;
down)
    [[ -e "$STATE" ]] || { echo "[down] up 기록이 없다 -- 할 일 없음"; exit 0; }
    if [[ "$(state_get BOOT)" != "$(boot_id)" ]]; then
        echo "[down] up 뒤 재부팅됨 -- affinity 는 이미 기본값. 기록만 지운다"
        as_root rm -rf "$STATE_DIR"; exit 0
    fi
    fail=0
    while IFS='=' read -r key val; do
        [[ "$key" == IRQ_* ]] || continue
        irq="${key#IRQ_}"
        [[ -e /proc/irq/$irq/smp_affinity_list ]] || { echo "  WARN: IRQ $irq 가 없다 (드라이버 재적재?)"; continue; }
        if echo "$val" | as_root tee /proc/irq/$irq/smp_affinity_list >/dev/null; then
            echo "[down] IRQ $irq -> $val"
        else
            echo "  ERROR: IRQ $irq 를 되돌리지 못했다"; fail=$((fail + 1))
        fi
    done < "$STATE"
    [[ $fail -eq 0 ]] || die "일부를 되돌리지 못했다 -- 기록($STATE)은 남겨 둔다"
    as_root rm -rf "$STATE_DIR"
    echo "[down] 완료 -- 기록 삭제"
    echo
    show
    ;;
esac
