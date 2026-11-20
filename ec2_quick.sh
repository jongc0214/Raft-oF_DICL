#!/usr/bin/env bash
#
# ec2_quick.sh (v2) -- Raft-oF v2 EC2 구성. ec2.conf 의 IP 만 고치고 머신당 한 줄.
#
#   sudo bash ec2_quick.sh S           storage 인스턴스에서
#   sudo bash ec2_quick.sh C <id>      compute 인스턴스에서 (id = 11, 12, 13 ...)
#   bash ec2_quick.sh status           현재 상태
#   sudo bash ec2_quick.sh reset       (S) nvmet 구성을 지우고 싶을 때 (C 는 먼저 nvme disconnect)
#
# 하는 일
#   S : 패키지 -> nvmet(TCP) 구성(인스턴스 스토어 -> node<id>) -> env.sh 수정 -> blockcopy 빌드
#   C : 패키지 -> NVMe/TCP 연결, 필요 시 mkfs, /mnt/raftvol 마운트 -> env.sh 수정 -> node/client 빌드
#   env.sh 수정은 몇 번을 다시 해도 같은 결과가 된다 (이미 있는 항목은 지우고 다시 만든다).
#
# [확인 필요] 위 순서를 EC2 에서 처음부터 끝까지 한 번에 돌려 본 적은 없다.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$HERE/ec2.conf}"
[[ -r "$CONF" ]] || { echo "ec2.conf 가 없다: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONF"
: "${S_IP:?ec2.conf 에 S_IP 필요}"
: "${C_IPS:?ec2.conf 에 C_IPS 필요}"
if [[ -z "${IDS:-}" ]]; then                       # 기본: C_IPS 개수만큼 11, 12, 13 ...
    _n=$(wc -w <<< "$C_IPS"); IDS="$(seq -s' ' 11 $((10 + _n)))"
fi
ME="${SUDO_USER:-$(id -un)}"                       # sudo 로 실행해도 원래 사용자
REPO="${REPO:-/home/$ME/Raft-oF_DICL}"
PORT="${PORT:-4421}"
PORT_ID=11
CFG="${CFG:-/sys/kernel/config/nvmet}"
MNT=/mnt/raftvol

die()       { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "root 로 실행할 것 (sudo bash ec2_quick.sh ...)"; }
as_user()   { if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then sudo -u "$SUDO_USER" "$@"; else "$@"; fi; }

# ------------------------------------------------------------------ 패키지
pkgs() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        build-essential cmake git pkg-config libprotobuf-dev protobuf-compiler \
        librdmacm-dev libibverbs-dev liburing-dev \
        nvme-cli fio iperf3 ethtool numactl tmux >/dev/null
}

# ------------------------------------------------------------------ env.sh 수정
# 읽은 코드(env.sh, start_node.sh) 기준으로 EC2 에서 걸리는 연구실 가정을 고친다:
#   1) POOL 에 node 항목 추가 (포트 포함)   2) storage 주소   3) 망 접두사 점검(115.145.173. -> EC2 대역)
#   4) NUMA 고정 끄기 (IB 인터페이스가 없다)
cmd_patch() {
    [[ -f "$REPO/env.sh" && -f "$REPO/start_node.sh" ]] || die "repo 를 찾지 못했다: $REPO (ec2.conf 에 REPO=...)"
    IDS="$IDS" C_IPS="$C_IPS" S_IP="$S_IP" CFG="$CFG" python3 - "$REPO" <<'PY'
import os, re, sys
repo = sys.argv[1]
ids  = os.environ["IDS"].split()
ips  = os.environ["C_IPS"].split()
sip  = os.environ["S_IP"]
cfg  = os.environ["CFG"]
assert len(ids) == len(ips), "IDS 와 C_IPS 개수가 같아야 한다"
prefix = ".".join(sip.split(".")[:2]) + "."          # 예: 172.31.

def rw(path, fn):
    s = open(path, encoding="utf-8").read()
    if not os.path.exists(path + ".ec2bak"):
        open(path + ".ec2bak", "w", encoding="utf-8").write(s)
    t = fn(s)
    open(path, "w", encoding="utf-8").write(t)

def devpath(i):                                       # S 쪽 장치 = nvmet 이 실제로 내보내는 것
    p = os.path.join(cfg, "subsystems", "node" + i, "namespaces", "1", "device_path")
    try:
        return open(p).read().strip() or "none"
    except OSError:
        return "none"                                 # C 에서는 쓰이지 않는 자리 채움

def env_fix(s):
    for i in ids:                                     # 이미 있는 같은 id 줄은 지운다 (손으로 고친 것 포함)
        s = re.sub(r'^[ \t]*"%s\|[^\n]*\n' % re.escape(i), "", s, flags=re.M)
    lines = "".join('    "%s|DOWN|%s:6000|node%s|%s"   # ec2_quick\n' % (i, ip, i, devpath(i))
                    for i, ip in zip(ids, ips))
    s, n = re.subn(r'^(POOL=\(\n)', lambda m: m.group(1) + lines, s, count=1, flags=re.M)
    assert n == 1, "POOL=( 를 찾지 못했다"
    s, n = re.subn(r'(eth\)\s+col=2; sh=")[^"]*(")',
                   lambda m: m.group(1) + sip + ":5050" + m.group(2), s)
    assert n == 1, "storage 주소 줄(eth) col=2)을 찾지 못했다"
    s, n = re.subn(r'(eth\)\s+echo ")[0-9.]*(" ;;)',      # 숫자와 점만: "$BRAFT_TOOLS_SRC" 줄은 건드리지 않는다
                   lambda m: m.group(1) + prefix + m.group(2), s)
    assert n == 1, "net_prefix 의 eth 줄을 찾지 못했다"
    return s

def start_fix(s):
    return s.replace("NUMA_BIND:-1", "NUMA_BIND:-0")

rw(os.path.join(repo, "env.sh"), env_fix)
rw(os.path.join(repo, "start_node.sh"), start_fix)
print("env.sh / start_node.sh 수정 완료 (원본: *.ec2bak).  NODES='%s', 망 접두사 %s" % (" ".join(ids), prefix))
PY
    chown "$ME" "$REPO/env.sh" "$REPO/start_node.sh" "$REPO"/*.ec2bak 2>/dev/null || true
}

# ------------------------------------------------------------------ S
find_instance_store() {
    local b model dev l byid
    for b in /sys/block/nvme*n1; do
        [[ -e "$b" ]] || continue
        model="$(tr -d '\n' < "$b/device/model" 2>/dev/null || true)"
        [[ "$model" == *"Instance Storage"* ]] || continue
        dev="/dev/${b##*/}"; byid=""
        for l in /dev/disk/by-id/nvme-Amazon_EC2_NVMe_Instance_Storage_*; do
            [[ -e "$l" && "$l" != *-part* ]] || continue
            [[ "$(readlink -f "$l")" == "$dev" ]] && { byid="$l"; break; }
        done
        echo "${byid:-$dev}"
    done | sort
}

cmd_S() {
    need_root
    pkgs
    modprobe nvmet nvmet-tcp || die "nvmet-tcp 모듈을 올리지 못했다 (커널 모듈 패키지 확인)"

    local ids=($IDS) devs=() d i id sub p="$CFG/ports/$PORT_ID"
    mapfile -t devs < <(find_instance_store)
    (( ${#devs[@]} >= ${#ids[@]} )) || die "인스턴스 스토어 ${#devs[@]}개 (필요 ${#ids[@]}개). lsblk -o NAME,MODEL 확인"

    if [[ ! -d "$p" ]]; then
        mkdir -p "$p"
        echo tcp > "$p/addr_trtype"; echo ipv4 > "$p/addr_adrfam"
        echo "$S_IP" > "$p/addr_traddr"; echo "$PORT" > "$p/addr_trsvcid"
    fi
    for i in "${!ids[@]}"; do
        id="${ids[$i]}"; sub="$CFG/subsystems/node$id"
        if [[ ! -d "$sub" ]]; then
            d="${devs[$i]}"
            [[ -z "$(lsblk -no MOUNTPOINT "$(readlink -f "$d")" | tr -d '[:space:]')" ]] || die "$d 가 마운트되어 있다"
            mkdir -p "$sub/namespaces/1"
            echo 1 > "$sub/attr_allow_any_host"          # 접근 제한은 Security Group 으로
            echo -n "$d" > "$sub/namespaces/1/device_path"
            echo 1 > "$sub/namespaces/1/enable"
        fi
        [[ -e "$p/subsystems/node$id" ]] || ln -s "$sub" "$p/subsystems/node$id"
    done

    # 같은 장치가 두 노드에 걸려 있지 않은지
    local dup
    dup="$(for id in "${ids[@]}"; do cat "$CFG/subsystems/node$id/namespaces/1/device_path"; echo; done | sort | uniq -d)"
    [[ -z "$dup" ]] || die "같은 장치가 여러 노드에 내보내진다: $dup  (sudo bash ec2_quick.sh reset 후 다시)"

    echo "nvmet tcp $S_IP:$PORT"
    for id in "${ids[@]}"; do echo "  node$id -> $(cat "$CFG/subsystems/node$id/namespaces/1/device_path")"; done

    cmd_patch
    build_if_needed raft_blockcopy_server blockcopy-server
    echo
    echo "다음(S):  cd $REPO && NODES='$IDS' ./start_blockcopy.sh tcp"
}

cmd_reset() {
    need_root
    local p="$CFG/ports/$PORT_ID" s
    [[ -d "$p" ]] && { rm -f "$p"/subsystems/* 2>/dev/null || true; rmdir "$p" 2>/dev/null || true; }
    for s in "$CFG"/subsystems/node*; do
        [[ -d "$s" ]] || continue
        echo 0 > "$s/namespaces/1/enable" 2>/dev/null || true
        rmdir "$s/namespaces/1" 2>/dev/null || true
        rmdir "$s" 2>/dev/null || true
    done
    echo "nvmet 구성을 지웠다. 다시: sudo bash ec2_quick.sh S"
}

# ------------------------------------------------------------------ C
dev_for_nqn() {                                      # env.sh 의 dev_for_nqn 과 같은 방식
    local nqn="$1" s heads=()
    for s in /sys/class/nvme-subsystem/nvme-subsys*; do
        [[ -r "$s/subsysnqn" ]] || continue
        [[ "$(<"$s/subsysnqn")" == "$nqn" ]] || continue
        heads=("$s"/nvme*n*); [[ -e "${heads[0]}" ]] || heads=(); break
    done
    [[ ${#heads[@]} -eq 1 ]] || return 1
    echo "/dev/${heads[0]##*/}"
}

cmd_C() {
    need_root
    local id="${1:?usage: sudo bash ec2_quick.sh C <id>}" nqn dev t
    nqn="node$id"
    [[ " $IDS " == *" $id "* ]] || die "id $id 가 ec2.conf 의 IDS($IDS) 에 없다"
    pkgs
    modprobe nvme-tcp
    dev_for_nqn "$nqn" >/dev/null 2>&1 || nvme connect -t tcp -a "$S_IP" -s "$PORT" -n "$nqn"
    for t in $(seq 1 20); do dev="$(dev_for_nqn "$nqn" 2>/dev/null)" && break; sleep 0.5; done
    [[ -n "${dev:-}" && -b "$dev" ]] || die "$nqn 장치를 찾지 못했다 (S 에서 먼저 sudo bash ec2_quick.sh S ; nvme list-subsys 확인)"

    if ! blkid "$dev" >/dev/null 2>&1; then echo "파일시스템 없음 -> mkfs.ext4 $dev"; mkfs.ext4 -F -q "$dev"
    else echo "기존 파일시스템 유지($(blkid -o value -s TYPE "$dev"))"; fi
    mkdir -p "$MNT"
    if mountpoint -q "$MNT"; then
        [[ "$(findmnt -n -o SOURCE "$MNT" | tail -1)" == "$dev" ]] || die "$MNT 에 다른 장치가 마운트되어 있다"
    else mount "$dev" "$MNT"; fi
    chown "$ME" "$MNT"
    echo "OK: $dev -> $MNT (node $id)"

    cmd_patch
    build_if_needed raft_node node
    build_if_needed raft_client client
    echo
    echo "다음(C):  cd $REPO && NODES='$IDS' ./start_node.sh $id destination tcp"
}

build_if_needed() {                                   # <바이너리> <build.sh 타깃>
    if [[ -x "$REPO/build/$1" ]]; then echo "빌드 생략 (이미 있음): build/$1"; return; fi
    echo "빌드: ./build.sh $2"
    as_user bash -c "cd '$REPO' && ./build.sh $2"
}

cmd_status() {
    echo "hostname: $(hostname -s)"; nvme list-subsys 2>/dev/null || true
    findmnt "$MNT" || echo "($MNT 마운트 안 됨)"
    [[ -d $CFG/subsystems ]] && for s in "$CFG"/subsystems/node*; do
        [[ -d "$s" ]] && echo "nvmet $(basename "$s") -> $(cat "$s/namespaces/1/device_path" 2>/dev/null)"; done
    true
}

cmd="${1:-}"; shift || true
case "$cmd" in
    S)      cmd_S "$@" ;;
    C)      cmd_C "$@" ;;
    patch)  cmd_patch "$@" ;;
    reset)  cmd_reset "$@" ;;
    status) cmd_status "$@" ;;
    *)      sed -n '3,12p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac