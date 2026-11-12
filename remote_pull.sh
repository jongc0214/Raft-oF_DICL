#!/usr/bin/env bash
#
# remote_pull.sh -- remote pull 실험(A 구성) 호스트 설정과 원복
#
#   ./remote_pull.sh up       설정 (이 호스트 몫만)
#   ./remote_pull.sh down     원복: up 이 바꾼 것만, 바꾸기 전 상태로 되돌린다
#   ./remote_pull.sh status   현재 상태 출력 (아무것도 바꾸지 않는다)
#
# A 구성: node4(리더 eternity4) 볼륨만 eternity1 의 970 EVO Plus 250GB (nvmet e1node1) 로 옮긴다.
#   팔로워 5/6 볼륨과 blockcopy 서버(eternitystorage)는 local pull 과 같다. 서버는 e1node1 을
#   initiator 로 붙여 node4 를 원격으로 읽는다 -> local pull 과 다른 것은 SRead 가 원격이라는 점뿐.
#   실행할 때는 모든 호스트에 NODE4_E1=1 을 준다 (env.sh).
#
# 호스트명으로 할 일을 정한다:
#   eternity1        e1node1 export 검증, nvme0n1 write_cache -> "write through" (PLP 없는 SSD 의
#                    FLUSH 를 없애 PM983 과 조건을 맞춘다. 전원 장애에 안전하지 않다)
#   eternity4        e1node1 attach, (비어 있으면) mkfs.ext4, /mnt/raftvol 을 e1node1 로 바꿔 마운트
#   eternitystorage  e1node1 attach (-w 10.0.0.91: ibp59s0/NUMA0 으로 나가게), by-id 링크 확인
#   그 밖            할 일 없음
#
# 순서: up 은 eternity1 -> eternity4 -> eternitystorage, down 은 그 반대.
#   raft_node / raft_blockcopy_server 를 먼저 멈출 것 (돌고 있으면 중단한다).
#
# 환경변수: QUEUES (nvme connect -i, 기본 8 -- 다른 볼륨과 같은 값)
#
# up 이 바꾼 것은 STATE_DIR 에 기록하고 down 은 그 기록에 있는 것만 되돌린다.
# 원래 있던 연결과 볼륨 내용은 건드리지 않는다 (down 은 e1node1 의 ext4 를 지우지 않는다).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

E1_NQN="e1node1"
E1_ADDR="10.0.0.1"
PORT="4420"
QUEUES="${QUEUES:-8}"
SRC_ADDR="10.0.0.91"            # eternitystorage ibp59s0 (NUMA0, PM983 과 같은 소켓)
E1_UUID_LINK="/dev/disk/by-id/nvme-uuid.3ffbc4a8-8cde-4ba2-b208-ccd5d47a433a"   # e1node1 ns1 device_uuid
E1_DISK="nvme0n1"               # eternity1 로컬 970 EVO
E1_MIN_BYTES=240000000000       # 970 EVO Plus 250GB = 250059350016 B
E1_MAX_BYTES=260000000000
MNT="/mnt/raftvol"
NVMET="/sys/kernel/config/nvmet"
STATE_DIR="/var/lib/raftof-remote-pull"
STATE="$STATE_DIR/state"
IOQ_FILE="$SCRIPT_DIR/results/io_queues/eternity4.env"        # probe_io_queues.sh 기록 (eternity4)
IOQ_BACKUP="$SCRIPT_DIR/results/io_queues/eternity4.env.confS"

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
    up|down|status) ;;
    *) sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
CMD="$1"

as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

# env.sh 의 dev_for_nqn 을 쓴다 (NODE4_E1 은 여기서 필요 없다 -- nqn 을 직접 준다)
# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh" || die "env.sh 를 읽지 못했다"

state_get() { [[ -r "$STATE" ]] && sed -n "s/^$1=//p" "$STATE" | tail -1; }
state_set() { echo "$1=$2" | as_root tee -a "$STATE" >/dev/null; }
state_begin() {
    [[ -e "$STATE" ]] && die "이미 up 상태다 ($STATE). 다시 하려면 먼저 down"
    as_root mkdir -p "$STATE_DIR" || die "$STATE_DIR 를 만들지 못했다"
    state_set HOST "$(hostname -s)"
}
state_end() { as_root rm -rf "$STATE_DIR"; echo "[down] 완료 -- 기록 삭제"; }

# e1node1 fabrics 컨트롤러 이름 (없으면 실패)
e1_ctrl() {
    local c
    for c in /sys/class/nvme/nvme[0-9]*; do
        [[ -r "$c/subsysnqn" && "$(<"$c/subsysnqn")" == "$E1_NQN" ]] || continue
        echo "${c##*/}"; return 0
    done
    return 1
}

# 블록 장치 -> 그 장치가 속한 subsysnqn (모르면 빈 문자열)
nqn_of_dev() {
    local base s
    base="$(basename "$(readlink -f "$1")")"
    for s in /sys/class/nvme-subsystem/nvme-subsys*; do
        [[ -e "$s/$base" && -r "$s/subsysnqn" ]] && { cat "$s/subsysnqn"; return 0; }
    done
    echo ""
}

mnt_src() { findmnt -n -o SOURCE "$MNT" 2>/dev/null | tail -1; }

# e1node1 attach (이미 붙어 있으면 그대로). 추가 nvme connect 인자를 받는다.
e1_attach() {
    if e1_ctrl >/dev/null; then
        echo "[up] $E1_NQN 이미 attach 됨 ($(e1_ctrl)) -- 건너뜀 (down 에서도 그대로 둔다)"
        return 0
    fi
    # lsmod | grep -q 는 pipefail 아래에서 SIGPIPE 로 거짓 실패할 수 있다 -> /sys/module 로 본다
    [[ -d /sys/module/nvme_rdma ]] || die "nvme-rdma 모듈이 없다 (sudo modprobe nvme-rdma)"
    as_root nvme connect -t rdma -a "$E1_ADDR" -s "$PORT" -n "$E1_NQN" -i "$QUEUES" "$@" \
        || die "$E1_NQN connect 실패 (eternity1 에서 ./remote_pull.sh status 로 export 확인)"
    state_set CONNECTED 1
    echo "[up] $E1_NQN attach (-i $QUEUES $*)"
    command -v udevadm >/dev/null && as_root udevadm settle
}

e1_dev_wait() {
    local dev=""
    for _ in $(seq 1 25); do
        dev="$(dev_for_nqn "$E1_NQN" 2>/dev/null)" && break
        sleep 0.2
    done
    [[ -n "$dev" ]] || die "$E1_NQN 장치가 나타나지 않았다"
    echo "$dev"
}

e1_detach_if_ours() {
    [[ "$(state_get CONNECTED)" == "1" ]] || return 0
    if as_root nvme disconnect -n "$E1_NQN" >/dev/null; then
        echo "[down] $E1_NQN detach"
    else
        echo "WARN: $E1_NQN detach 실패" >&2; return 1
    fi
}

print_state() {
    if [[ -r "$STATE" ]]; then
        echo "remote-pull : UP ($STATE)"; sed 's/^/  /' "$STATE"
    else
        echo "remote-pull : down (기록 없음)"
    fi
}

# ---------------------------------------------------------------- eternity1 (타깃)
t_check_export() {
    local ns="$NVMET/subsystems/$E1_NQN/namespaces/1" dp p linked=""
    [[ -d "$NVMET/subsystems/$E1_NQN" ]] || die "nvmet 서브시스템 $E1_NQN 이 없다"
    dp="$(readlink -f "$(cat "$ns/device_path" 2>/dev/null)")"
    [[ "$dp" == "/dev/$E1_DISK" ]] || die "$E1_NQN ns1 device_path 가 /dev/$E1_DISK 가 아니다 ($dp)"
    [[ "$(cat "$ns/enable")" == "1" ]] || die "$E1_NQN ns1 이 enable 돼 있지 않다"
    for p in "$NVMET"/ports/*/subsystems/"$E1_NQN"; do [[ -e "$p" ]] && linked="$p"; done
    [[ -n "$linked" ]] || die "$E1_NQN 이 어느 nvmet port 에도 링크돼 있지 않다"
    echo "[up] export OK: $E1_NQN ns1 -> /dev/$E1_DISK, $(cat "${linked%/subsystems/*}/addr_trtype") $(cat "${linked%/subsystems/*}/addr_traddr"):$(cat "${linked%/subsystems/*}/addr_trsvcid")"
}

t_stat() {
    awk '{printf "reads=%s writes=%s flushes=%s\n", $1, $5, $16}' "/sys/block/$E1_DISK/stat"
}

t_up() {
    t_check_export
    state_begin
    local wc_file="/sys/block/$E1_DISK/queue/write_cache" prev
    prev="$(<"$wc_file")"
    state_set WC_PREV "$prev"
    if [[ "$prev" != "write through" ]]; then
        echo "write through" | as_root tee "$wc_file" >/dev/null || die "write_cache 변경 실패"
        state_set WC_CHANGED 1
        echo "[up] $E1_DISK write_cache: $prev -> write through (FLUSH 를 장치로 보내지 않는다)"
    else
        echo "[up] $E1_DISK write_cache 이미 write through"
    fi
    echo "[up] $E1_DISK $(t_stat)   (런 동안 flushes 가 늘지 않아야 한다)"
    echo
    echo "다음: eternity4 에서 ./remote_pull.sh up"
}

t_down() {
    [[ -r "$STATE" ]] || { echo "up 기록이 없다 -- 되돌릴 것이 없다"; return 0; }
    if [[ "$(state_get WC_CHANGED)" == "1" ]]; then
        echo "$(state_get WC_PREV)" | as_root tee "/sys/block/$E1_DISK/queue/write_cache" >/dev/null \
            || die "write_cache 복원 실패 (기록 유지: $STATE)"
        echo "[down] $E1_DISK write_cache -> $(state_get WC_PREV)"
    fi
    state_end
}

t_status() {
    local ns="$NVMET/subsystems/$E1_NQN/namespaces/1"
    echo "host        : $(hostname -s) (타깃, e1node1 export)"
    if [[ -d "$ns" ]]; then
        echo "e1node1     : ns1 $(cat "$ns/device_path") enable=$(cat "$ns/enable") uuid=$(cat "$ns/device_uuid")"
    else
        echo "e1node1     : 없음"
    fi
    echo "write_cache : $(cat "/sys/block/$E1_DISK/queue/write_cache")"
    echo "$E1_DISK stat : $(t_stat)"
    print_state
}

# ---------------------------------------------------------------- eternity4 (리더)
l_up() {
    pgrep -x raft_node >/dev/null && die "raft_node 가 돌고 있다. ./stop_node.sh 로 먼저 멈출 것"
    [[ -e "$STATE" ]] && die "이미 up 상태다 ($STATE). 다시 하려면 먼저 down"
    [[ -d /sys/module/nvme_rdma ]] || die "nvme-rdma 모듈이 없다 (sudo modprobe nvme-rdma)"
    local src prev_nqn dev bytes fstype
    src="$(mnt_src)"
    if [[ -n "$src" ]]; then
        prev_nqn="$(nqn_of_dev "$src")"
        [[ "$prev_nqn" == "$E1_NQN" ]] && die "$MNT 에 이미 $E1_NQN($src) 이 마운트돼 있다"
        [[ -n "$prev_nqn" ]] || die "$MNT 의 장치($src)가 NVMe-oF 서브시스템이 아니다 -- 손으로 확인할 것"
    fi
    state_begin
    if [[ -n "$src" ]]; then
        state_set PREV_NQN "$prev_nqn"
        echo "[up] 원래 $MNT: $src ($prev_nqn)"
    else
        state_set PREV_NQN ""
        echo "[up] 원래 $MNT 마운트 없음"
    fi

    e1_attach
    dev="$(e1_dev_wait)" || exit 1
    bytes=$(( $(cat "/sys/block/${dev##*/}/size") * 512 ))
    (( bytes >= E1_MIN_BYTES && bytes <= E1_MAX_BYTES )) \
        || die "$dev 크기 $bytes B 가 970 EVO Plus 250GB 가 아니다 -- 중단"
    echo "[up] $E1_NQN -> $dev ($bytes B)"

    fstype="$(as_root blkid -p -o value -s TYPE "$dev" 2>/dev/null)"
    case "$fstype" in
        "")
            echo "[up] $dev 에 파일시스템 없음 -> mkfs.ext4"
            as_root mkfs.ext4 -q -F "$dev" || die "mkfs.ext4 실패"
            state_set MKFS 1 ;;
        ext4) echo "[up] $dev 이미 ext4 -- mkfs 건너뜀" ;;
        *) die "$dev 에 다른 파일시스템($fstype)이 있다 -- 중단" ;;
    esac

    if [[ -n "$src" ]]; then
        if ! as_root umount "$MNT"; then
            as_root fuser -vm "$MNT"
            die "umount $MNT 실패 (위 프로세스를 정리한 뒤 ./remote_pull.sh down 후 다시 up)"
        fi
        echo "[up] $MNT 언마운트 ($src)"
    fi
    as_root mount "$dev" "$MNT" || die "mount $dev $MNT 실패"
    state_set MOUNTED "$dev"
    as_root mkdir -p "$MNT/node4"
    echo "[up] $dev -> $MNT 마운트, $MNT/node4"

    # probe_io_queues.sh 기록은 node id(IOQ_4_*) 로 저장된다. A 구성에서 다시 재면 S 구성(node4 PM983)
    # 기록이 덮어써져 S 로 돌아갔을 때 start_node.sh 가 "재연결됨"으로 멈춘다 -> 백업해 두고 down 이 복원.
    if [[ -f "$IOQ_FILE" ]]; then
        cp -p "$IOQ_FILE" "$IOQ_BACKUP" || die "$IOQ_FILE 백업 실패"
        state_set IOQ_BACKUP "$IOQ_BACKUP"
        echo "[up] 큐 기록 백업: $IOQ_BACKUP (down 이 복원)"
    fi
    echo
    echo "다음 (eternity4):"
    echo "  sudo -E env NODE4_E1=1 STORAGE_SSH=eternity1 ./scripts/probe_io_queues.sh 4"
    echo "  NODE4_E1=1 ./start_node.sh 4 destination rdma     (probe 실패 시 IO_PIN=0 추가)"
    echo "그 전에 eternitystorage 에서 ./remote_pull.sh up"
}

l_down() {
    [[ -r "$STATE" ]] || { echo "up 기록이 없다 -- 되돌릴 것이 없다"; return 0; }
    pgrep -x raft_node >/dev/null && die "raft_node 가 돌고 있다. ./stop_node.sh 로 먼저 멈출 것"
    local rc=0 src prev dev
    src="$(mnt_src)"
    if [[ -n "$src" && "$(nqn_of_dev "$src")" == "$E1_NQN" ]]; then
        if ! as_root umount "$MNT"; then
            as_root fuser -vm "$MNT"
            die "umount $MNT 실패"
        fi
        echo "[down] $MNT 언마운트 ($src)"
    fi
    prev="$(state_get PREV_NQN)"
    if [[ -n "$prev" ]]; then
        if mountpoint -q "$MNT" && [[ "$(nqn_of_dev "$(mnt_src)")" == "$prev" ]]; then
            echo "[down] $MNT 에 이미 원래 볼륨($(mnt_src), $prev)이 마운트돼 있다"
        elif mountpoint -q "$MNT"; then
            echo "WARN: $MNT 에 다른 것($(mnt_src))이 마운트돼 있어 $prev 를 다시 마운트하지 않는다" >&2; rc=1
        elif dev="$(dev_for_nqn "$prev")"; then
            as_root mount "$dev" "$MNT" && echo "[down] $dev ($prev) -> $MNT 다시 마운트" \
                || { echo "WARN: mount $dev 실패" >&2; rc=1; }
        else
            echo "WARN: 원래 볼륨 $prev 가 attach 돼 있지 않다" >&2; rc=1
        fi
    fi
    e1_detach_if_ours || rc=1
    local bk
    bk="$(state_get IOQ_BACKUP)"
    if [[ -n "$bk" ]]; then
        if [[ -f "$bk" ]] && cp -p "$bk" "$IOQ_FILE"; then
            rm -f "$bk"
            echo "[down] 큐 기록 복원: $IOQ_FILE (S 구성 node4 기록)"
        else
            echo "WARN: 큐 기록 복원 실패 ($bk). S 구성에서 ./scripts/probe_io_queues.sh 를 다시 돌릴 것" >&2; rc=1
        fi
    fi
    if [[ $rc -eq 0 ]]; then state_end; else echo "[down] 일부 실패 -- 기록($STATE)을 남겨 둔다" >&2; fi
    return $rc
}

l_status() {
    local src
    src="$(mnt_src)"
    echo "host        : $(hostname -s) (리더 node4)"
    if [[ -n "$src" ]]; then
        echo "mount       : $src ($(nqn_of_dev "$src")) -> $MNT"
    else
        echo "mount       : $MNT 마운트 안 됨"
    fi
    if e1_ctrl >/dev/null; then
        echo "e1node1     : $(e1_ctrl) $(dev_for_nqn "$E1_NQN" 2>/dev/null) $(tr '\n' ' ' < "/sys/class/nvme/$(e1_ctrl)/address") q=$(cat "/sys/class/nvme/$(e1_ctrl)/queue_count")"
    else
        echo "e1node1     : not attached"
    fi
    echo "node4(PM983): $(dev_for_nqn node4 2>/dev/null || echo 'not attached')"
    print_state
}

# ---------------------------------------------------------------- eternitystorage (blockcopy 서버)
bc_running() { pgrep -f '^(\S*/)?raft_blockcopy_server( |$)' >/dev/null; }

s_up() {
    bc_running && die "raft_blockcopy_server 가 돌고 있다. ./stop_blockcopy.sh 로 멈춘 뒤 up (서버 -devices 가 바뀐다)"
    [[ -d /sys/module/nvme_rdma ]] || die "nvme-rdma 모듈이 없다 (sudo modprobe nvme-rdma)"
    state_begin
    e1_attach -w "$SRC_ADDR"
    local ctrl dev link
    ctrl="$(e1_ctrl)" || die "$E1_NQN 컨트롤러가 없다"
    if ! grep -q "host_traddr=$SRC_ADDR" "/sys/class/nvme/$ctrl/address"; then
        die "$ctrl 가 $SRC_ADDR 에서 나가지 않는다 ($(tr '\n' ' ' < "/sys/class/nvme/$ctrl/address")). 기존 연결이면 'sudo nvme disconnect -n $E1_NQN' 후 다시 up"
    fi
    dev="$(e1_dev_wait)" || exit 1
    link=""
    for _ in $(seq 1 25); do [[ -e "$E1_UUID_LINK" ]] && { link="$(readlink -f "$E1_UUID_LINK")"; break; }; sleep 0.2; done
    [[ -n "$link" ]] || die "$E1_UUID_LINK 가 생기지 않았다 (env.sh NODE4_E1 의 storage_dev). ls /dev/disk/by-id | grep -i uuid 로 확인"
    [[ "$link" == "$dev" ]] || die "$E1_UUID_LINK ($link) 가 $E1_NQN 장치($dev)와 다르다"
    echo "[up] $E1_NQN -> $dev ($ctrl, host_traddr=$SRC_ADDR), $E1_UUID_LINK OK"
    echo
    echo "다음 (eternitystorage): NODE4_E1=1 ./start_blockcopy.sh rdma"
}

s_down() {
    [[ -r "$STATE" ]] || { echo "up 기록이 없다 -- 되돌릴 것이 없다"; return 0; }
    bc_running && die "raft_blockcopy_server 가 돌고 있다 (e1node1 을 열고 있을 수 있다). ./stop_blockcopy.sh 로 먼저 멈출 것"
    if e1_detach_if_ours; then
        state_end
        echo "S 구성 서버: ./start_blockcopy.sh rdma"
    else
        echo "[down] 일부 실패 -- 기록($STATE)을 남겨 둔다" >&2; return 1
    fi
}

s_status() {
    echo "host        : $(hostname -s) (blockcopy 서버)"
    if e1_ctrl >/dev/null; then
        echo "e1node1     : $(e1_ctrl) $(dev_for_nqn "$E1_NQN" 2>/dev/null) $(tr '\n' ' ' < "/sys/class/nvme/$(e1_ctrl)/address") q=$(cat "/sys/class/nvme/$(e1_ctrl)/queue_count")"
    else
        echo "e1node1     : not attached"
    fi
    if [[ -e "$E1_UUID_LINK" ]]; then
        echo "by-id link  : $E1_UUID_LINK -> $(readlink -f "$E1_UUID_LINK")"
    else
        echo "by-id link  : $E1_UUID_LINK 없음"
    fi
    echo "server      : $(pgrep -af '^(\S*/)?raft_blockcopy_server( |$)' || echo 'not running')"
    print_state
}

# ----------------------------------------------------------------
case "$(hostname -s)" in
    eternity1)       ROLE=t ;;
    eternity4)       ROLE=l ;;
    eternitystorage) ROLE=s ;;
    *) echo "$(hostname -s): remote_pull 에서 이 호스트가 할 일은 없다 (eternity1/eternity4/eternitystorage 만)"; exit 0 ;;
esac
"${ROLE}_${CMD}"
