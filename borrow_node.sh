#!/usr/bin/env bash
#
# borrow_node.sh -- 빌린 노드(eternity7~10)를 raftof 실험에 참여시키고 원래대로 되돌린다
#
#   ./borrow_node.sh up       설정: ARP 고정, nvme-rdma 로드, 볼륨 attach, 자기 볼륨 마운트, C-state·governor 조정
#   ./borrow_node.sh power    이미 up 인 노드에 C-state·governor 조정만 (아직 안 한 것만) 적용
#   ./borrow_node.sh down     해제: up 이 바꾼 것만, 바꾸기 전 상태로 되돌린다
#   ./borrow_node.sh status   현재 상태 출력 (아무것도 바꾸지 않는다)
#
# 노드마다 그 호스트에서 실행한다. 노드 id 는 호스트명(eternityN)에서 정한다.
# root 가 아니면 필요한 곳에서 sudo 를 부른다.
#
# 환경변수:
#   BORROW_NODES  attach 할 멤버 볼륨 (기본 "2 3 4 5 6 7 8 9 10" = TOPO 3/5/7/9 전부를 덮는다)
#   QUEUES        nvme connect -i 값 (기본 8). **모든 호스트가 같은 값**이어야 조건이 같다
#   CSTATE        1 이면 up 에서 C1E/C6 를 끄고 down 에서 원래 값으로 되돌린다 (기본 1)
#   GOVERNOR      1 이면 up 에서 cpufreq governor 를 performance 로 바꾸고 down 에서 되돌린다 (기본 1)
#   ID            노드 id 를 호스트명 대신 직접 줄 때
#
# up 이 바꾼 것은 전부 STATE_DIR 에 기록하고, down 은 그 기록에 있는 것만 되돌린다.
# 원래 있던 연결·ARP 항목·디렉터리는 건드리지 않는다. 다른 사람 노드이므로
# 실험이 끝나면 반드시 down 할 것.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BORROW_NODES="${BORROW_NODES:-2 3 4 5 6 7 8 9 10}"
QUEUES="${QUEUES:-8}"
CSTATE="${CSTATE:-1}"
GOVERNOR="${GOVERNOR:-1}"
TARGET="10.0.0.91"
PORT="4420"
# 스토리지 ibp59s0 의 IPoIB 하드웨어 주소. 같은 /24 의 ibp216s0(...0d:ff:de)로 잘못 배우면
# nvme connect 가 "invalid service ID" 로 거절된다 (ARP flux).
TARGET_LLADDR="00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e"
MNT="/mnt/raftvol"
STATE_DIR="/var/lib/raftof-borrow"
STATE="$STATE_DIR/state"
CSTATE_SAVED="$STATE_DIR/cstate.saved"
GOV_SAVED="$STATE_DIR/governor.saved"

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
    up|down|status|power) ;;
    *) sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# env.sh 의 dev_for_nqn / _pool_field / ib_iface 를 쓴다. NODES 를 먼저 정해 두면 그대로 쓴다.
export NODES="$BORROW_NODES"
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh" || die "env.sh 를 읽지 못했다"

if [[ -z "${ID:-}" ]]; then
    h="$(hostname -s)"
    ID="${h#eternity}"
fi
[[ "$ID" =~ ^[0-9]+$ ]] || die "노드 id 를 정하지 못했다 (호스트명 $(hostname -s)). ID=<번호> 로 줄 것"
is_valid_id "$ID" || die "node $ID 가 BORROW_NODES($BORROW_NODES)에 없다"
OWN_NQN="$(_pool_field "$ID" 3)" || die "node $ID 가 env.sh POOL 에 없다"

state_get() { [[ -r "$STATE" ]] && sed -n "s/^$1=//p" "$STATE" | tail -1; }
state_set() { echo "$1=$2" | as_root tee -a "$STATE" >/dev/null; }

nqn_list() {   # 자기 볼륨을 먼저 (connect 순서 = 장치 번호지만, 스크립트는 nqn 으로 찾는다)
    local n
    echo "$OWN_NQN"
    for n in $BORROW_NODES; do
        [[ "$n" == "$ID" ]] && continue
        _pool_field "$n" 3
    done
}

cstate_files() {   # 이름이 C1E / C6 인 idle state 의 disable 파일 (번호는 CPU 모델마다 다를 수 있다)
    local f
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state*/name; do
        case "$(<"$f")" in
            C1E|C6) echo "${f%/name}/disable" ;;
        esac
    done
}

gov_files() { ls /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor 2>/dev/null; }

# C-state / governor 조정. 원래 값을 "파일 값" 줄로 저장해 두고 down 이 그대로 되돌린다.
# 이미 한 것(state 에 기록된 것)은 다시 하지 않는다 -- 두 번 저장하면 원래 값이 덮어써진다.
apply_power() {
    local f tmp
    if [[ "$CSTATE" == "1" && "$(state_get CSTATE)" != "1" ]]; then
        tmp="$(mktemp)"
        for f in $(cstate_files); do echo "$f $(<"$f")"; done > "$tmp"
        as_root cp "$tmp" "$CSTATE_SAVED" && rm -f "$tmp"
        as_root sh -c 'while read -r f v; do echo 1 > "$f"; done < "$1"' _ "$CSTATE_SAVED" \
            || die "C-state 변경 실패 (원래 값은 $CSTATE_SAVED)"
        state_set CSTATE 1
        echo "[up] C1E/C6 끔 (원래 값 저장: $CSTATE_SAVED)"
    fi
    if [[ "$GOVERNOR" == "1" && "$(state_get GOVERNOR)" != "1" ]]; then
        [[ -n "$(gov_files)" ]] || { echo "[up] cpufreq governor 없음 -- 건너뜀"; return 0; }
        tmp="$(mktemp)"
        for f in $(gov_files); do echo "$f $(<"$f")"; done > "$tmp"
        as_root cp "$tmp" "$GOV_SAVED" && rm -f "$tmp"
        as_root sh -c 'while read -r f v; do echo performance > "$f"; done < "$1"' _ "$GOV_SAVED" \
            || die "governor 변경 실패 (원래 값은 $GOV_SAVED)"
        state_set GOVERNOR 1
        echo "[up] governor -> performance (원래 값: $(awk '{print $2}' "$GOV_SAVED" | sort | uniq -c | xargs), 저장: $GOV_SAVED)"
    fi
}

cmd_status() {
    local i numa nq c
    i="$(ib_iface 2>/dev/null || echo '?')"
    numa="$(ib_numa_node 2>/dev/null || echo '?')"
    echo "host        : $(hostname -s)  (node $ID, 자기 볼륨 $OWN_NQN)"
    echo "ib iface    : $i  (NUMA $numa)"
    echo "arp $TARGET: $(ip neigh show "$TARGET" 2>/dev/null | sed 's/  */ /g')"
    echo "nvme-rdma   : $(lsmod | grep -q '^nvme_rdma' && echo loaded || echo 'not loaded')"
    echo "volumes     :"
    for nq in $(nqn_list); do
        local dev="" st=""
        dev="$(dev_for_nqn "$nq" 2>/dev/null)" || dev="-"
        for c in /sys/class/nvme-subsystem/nvme-subsys*/nvme[0-9]*; do
            [[ -r "$c/subsysnqn" && "$(<"$c/subsysnqn")" == "$nq" ]] || continue
            st="$(<"$c/state") q=$(<"$c/queue_count")"
        done
        printf '  %-8s %-14s %s\n' "$nq" "$dev" "${st:-not attached}"
    done
    if mountpoint -q "$MNT" 2>/dev/null; then
        echo "mount       : $(findmnt -n -o SOURCE "$MNT" | tail -1) -> $MNT"
    else
        echo "mount       : $MNT 마운트 안 됨"
    fi
    local on=0 off=0 f
    for f in $(cstate_files); do [[ "$(<"$f")" == 1 ]] && off=$((off+1)) || on=$((on+1)); done
    echo "C1E/C6      : 꺼짐 $off / 켜짐 $on (cpu x state)"
    echo "governor    : $(cat $(gov_files) 2>/dev/null | sort | uniq -c | xargs)  ($(awk '/MHz/{s+=$4;n++}END{if(n)printf "평균 %.0f MHz",s/n}' /proc/cpuinfo))"
    if [[ -r "$STATE" ]]; then
        echo "borrow state: UP ($STATE)"
        sed 's/^/  /' "$STATE"
    else
        echo "borrow state: down (기록 없음)"
    fi
}

cmd_up() {
    [[ -e "$STATE" ]] && die "이미 up 상태다 ($STATE). 다시 하려면 먼저 down"
    local iface prev nq dev src
    iface="$(ib_iface)" || die "IB 인터페이스(10.0.0.x)를 찾지 못했다"

    as_root mkdir -p "$STATE_DIR" || die "$STATE_DIR 를 만들지 못했다"
    state_set IFACE "$iface"
    state_set QUEUES "$QUEUES"

    # 1. ARP 고정 (원래 PERMANENT 항목이 있었으면 그 주소를 기록)
    prev="$(ip neigh show "$TARGET" dev "$iface" 2>/dev/null)"
    if [[ "$prev" == *PERMANENT* ]]; then
        state_set ARP_PREV "$(awk '{for(i=1;i<=NF;i++) if($i=="lladdr") print $(i+1)}' <<<"$prev")"
    else
        state_set ARP_PREV none
    fi
    as_root ip neigh replace "$TARGET" lladdr "$TARGET_LLADDR" dev "$iface" nud permanent \
        || die "ARP 고정 실패"
    echo "[up] ARP $TARGET -> ...0e:00:4e 고정 ($iface)"

    # 2. nvme-rdma
    if lsmod | grep -q '^nvme_rdma'; then
        state_set MODPROBED 0
    else
        as_root modprobe nvme-rdma || die "modprobe nvme-rdma 실패"
        state_set MODPROBED 1
        echo "[up] nvme-rdma 로드"
    fi

    # 3. 볼륨 attach (이미 붙어 있던 것은 건드리지도, 기록하지도 않는다)
    for nq in $(nqn_list); do
        if dev_for_nqn "$nq" >/dev/null 2>&1; then
            echo "[up] $nq 이미 attach 됨 -- 건너뜀 (down 에서도 그대로 둔다)"
            continue
        fi
        if ! as_root nvme connect -t rdma -a "$TARGET" -s "$PORT" -i "$QUEUES" -n "$nq" >/dev/null; then
            echo "ERROR: $nq connect 실패. 'sudo dmesg -T | tail' 확인 후 ./borrow_node.sh down 으로 정리할 것" >&2
            exit 1
        fi
        state_set CONNECTED "$nq"
        echo "[up] $nq attach (-i $QUEUES)"
    done
    command -v udevadm >/dev/null && as_root udevadm settle

    # 4. 자기 볼륨 마운트
    dev=""
    for _ in $(seq 1 25); do
        dev="$(dev_for_nqn "$OWN_NQN" 2>/dev/null)" && break
        sleep 0.2
    done
    [[ -n "$dev" ]] || die "자기 볼륨($OWN_NQN) 장치가 나타나지 않았다"
    if [[ ! -d "$MNT" ]]; then
        as_root mkdir -p "$MNT" || die "$MNT 생성 실패"
        state_set MNT_CREATED 1
    fi
    if mountpoint -q "$MNT"; then
        src="$(findmnt -n -o SOURCE "$MNT" | tail -1)"
        [[ "$src" == "$dev" ]] || die "$MNT 에 이미 다른 장치($src)가 마운트돼 있다"
        echo "[up] $MNT 에 이미 $dev 마운트됨"
    else
        as_root mount "$dev" "$MNT" || die "mount $dev $MNT 실패"
        state_set MOUNTED "$dev"
        echo "[up] $dev -> $MNT 마운트"
    fi

    # 5. C-state / governor: 원래 값을 저장하고 C1E/C6 끔, governor performance (다른 노드와 조건을 맞춘다)
    apply_power

    echo
    cmd_status
}

cmd_down() {
    [[ -r "$STATE" ]] || { echo "up 기록이 없다 -- 되돌릴 것이 없다"; cmd_status; return 0; }
    if pgrep -x raft_node >/dev/null; then
        die "raft_node 가 돌고 있다. ./stop_node.sh 로 먼저 멈출 것"
    fi
    local iface dev nq prev rc=0
    iface="$(state_get IFACE)"

    # 1. 언마운트 / 디렉터리
    dev="$(state_get MOUNTED)"
    if [[ -n "$dev" ]] && mountpoint -q "$MNT"; then
        if ! as_root umount "$MNT"; then
            as_root fuser -vm "$MNT"
            die "umount $MNT 실패 (위 프로세스를 먼저 정리할 것)"
        fi
        echo "[down] $MNT 언마운트"
    fi
    if [[ "$(state_get MNT_CREATED)" == "1" ]] && [[ -d "$MNT" ]] && ! mountpoint -q "$MNT"; then
        as_root rmdir "$MNT" 2>/dev/null && echo "[down] $MNT 삭제 (up 이 만든 것)"
    fi

    # 2. up 이 붙인 볼륨만 해제
    for nq in $(sed -n 's/^CONNECTED=//p' "$STATE"); do
        if as_root nvme disconnect -n "$nq" >/dev/null; then
            echo "[down] $nq detach"
        else
            echo "WARN: $nq detach 실패" >&2; rc=1
        fi
    done

    # 3. nvme-rdma: up 이 올렸고 남은 rdma 컨트롤러가 없을 때만 내린다
    if [[ "$(state_get MODPROBED)" == "1" ]]; then
        if grep -qx rdma /sys/class/nvme/nvme*/transport 2>/dev/null; then
            echo "[down] nvme-rdma 는 다른 rdma 컨트롤러가 남아 있어 그대로 둔다"
        else
            as_root modprobe -r nvme-rdma && echo "[down] nvme-rdma 내림"
        fi
    fi

    # 4. ARP 복원
    prev="$(state_get ARP_PREV)"
    if [[ -n "$iface" ]]; then
        if [[ "$prev" == "none" || -z "$prev" ]]; then
            as_root ip neigh del "$TARGET" dev "$iface" 2>/dev/null
            echo "[down] ARP 고정 해제 ($iface)"
        else
            as_root ip neigh replace "$TARGET" lladdr "$prev" dev "$iface" nud permanent
            echo "[down] ARP 원래 고정값으로 복원 ($prev)"
        fi
    fi

    # 5. C-state 복원
    if [[ "$(state_get CSTATE)" == "1" && -r "$CSTATE_SAVED" ]]; then
        if as_root sh -c 'while read -r f v; do echo "$v" > "$f"; done < "$1"' _ "$CSTATE_SAVED"; then
            echo "[down] C-state 원래 값으로 복원"
        else
            echo "WARN: C-state 복원 실패 ($CSTATE_SAVED 를 남겨 둔다)" >&2; rc=1
        fi
    fi

    # 6. governor 복원
    if [[ "$(state_get GOVERNOR)" == "1" && -r "$GOV_SAVED" ]]; then
        if as_root sh -c 'while read -r f v; do echo "$v" > "$f"; done < "$1"' _ "$GOV_SAVED"; then
            echo "[down] governor 원래 값으로 복원 ($(awk '{print $2}' "$GOV_SAVED" | sort | uniq -c | xargs))"
        else
            echo "WARN: governor 복원 실패 ($GOV_SAVED 를 남겨 둔다)" >&2; rc=1
        fi
    fi

    if [[ $rc -eq 0 ]]; then
        as_root rm -rf "$STATE_DIR"
        echo "[down] 완료 -- 기록 삭제"
    else
        echo "[down] 일부 실패 -- 기록($STATE_DIR)을 남겨 둔다. 확인 후 다시 down" >&2
    fi
    echo
    cmd_status
    return $rc
}

case "${1:-}" in
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    power)
        [[ -r "$STATE" ]] || die "up 상태가 아니다. ./borrow_node.sh up 을 쓸 것"
        apply_power
        echo
        cmd_status ;;
esac
