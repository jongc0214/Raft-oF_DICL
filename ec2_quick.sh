#!/usr/bin/env bash
#
# ec2_quick.sh -- Raft-oF v2 EC2 빠른 구성
#   compute 3 + storage 1, NVMe/TCP (커널 nvmet), 캐시 없음 (Phase 1)
#
#   sudo ./ec2_quick.sh common <hostname>   모든 인스턴스: 패키지, hostname, /etc/hosts
#   sudo ./ec2_quick.sh storage             S: 인스턴스 스토어 -> nvmet 구성, DEVS 출력
#        DEVS="a b c" ./ec2_quick.sh patch <repo_dir>
#                                           모든 인스턴스: env.sh 에 노드 추가 + storage 주소 교체
#   sudo ./ec2_quick.sh compute <id>        C: 자기 볼륨 연결, 필요하면 mkfs, /mnt/raftvol 마운트
#        ./ec2_quick.sh status              현재 상태 확인
#
# 설정은 같은 디렉터리의 ec2.conf (S_IP, IDS, C_IPS).
#
# [확인 필요] 이 스크립트는 EC2 에서 아직 실행해 보지 않았다.
#   - nvmet-tcp 모듈이 linux-modules-extra 에 들어 있는지
#   - 인스턴스 스토어 by-id 이름 패턴 (Amazon_EC2_NVMe_Instance_Storage_*)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${CONF:-$HERE/ec2.conf}"
[[ -r "$CONF" ]] || { echo "ec2.conf 가 없다: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONF"
: "${S_IP:?ec2.conf 에 S_IP 필요}"
: "${IDS:?ec2.conf 에 IDS 필요 (예: \"11 12 13\")}"
: "${C_IPS:?ec2.conf 에 C_IPS 필요 (IDS 와 같은 순서)}"
PORT="${PORT:-4421}"
PORT_ID=11
CFG=/sys/kernel/config/nvmet
MNT=/mnt/raftvol

die()       { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "root 로 실행할 것 (sudo)"; }

# ---------------------------------------------------------------- common
cmd_common() {
    need_root
    local host="${1:?usage: common <hostname>}"

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential cmake git pkg-config \
        libprotobuf-dev protobuf-compiler \
        librdmacm-dev libibverbs-dev liburing-dev \
        nvme-cli fio iperf3 ethtool numactl tmux
    # nvmet-tcp / nvme-tcp 모듈이 extra 패키지에 있을 수 있다
    apt-get install -y "linux-modules-extra-$(uname -r)" \
        || echo "[경고] linux-modules-extra-$(uname -r) 설치 실패 -- modprobe nvmet-tcp 가 안 되면 확인"

    hostnamectl set-hostname "$host"
    mkdir -p /etc/cloud/cloud.cfg.d
    echo 'preserve_hostname: true' > /etc/cloud/cloud.cfg.d/99-hostname.cfg

    # /etc/hosts: 이전에 우리가 쓴 줄을 지우고 다시 쓴다
    sed -i '/# ec2_quick$/d' /etc/hosts
    {
        echo "127.0.1.1 $host # ec2_quick"
        echo "$S_IP storage # ec2_quick"
        local ids=($IDS) ips=($C_IPS) i
        for i in "${!ids[@]}"; do
            echo "${ips[$i]} eternity${ids[$i]} # ec2_quick"
        done
    } >> /etc/hosts

    echo "OK: hostname=$host ($(findmnt -no FSTYPE /tmp) /tmp -- ext4/xfs 여야 한다)"
}

# ---------------------------------------------------------------- storage
# 인스턴스 스토어 NVMe 의 by-id 경로를 이름순으로 출력
find_instance_store() {
    local b model dev l
    for b in /sys/block/nvme*n1; do
        [[ -e "$b" ]] || continue
        model="$(tr -d '\n' < "$b/device/model" 2>/dev/null || true)"
        [[ "$model" == *"Instance Storage"* ]] || continue
        dev="/dev/${b##*/}"
        local byid=""
        for l in /dev/disk/by-id/nvme-Amazon_EC2_NVMe_Instance_Storage_*; do
            [[ -e "$l" && "$l" != *-part* ]] || continue
            [[ "$(readlink -f "$l")" == "$dev" ]] && { byid="$l"; break; }
        done
        echo "${byid:-$dev}"
    done | sort
}

cmd_storage() {
    need_root
    modprobe nvmet
    modprobe nvmet-tcp

    local ids=($IDS) devs=() d
    mapfile -t devs < <(find_instance_store)
    (( ${#devs[@]} >= ${#ids[@]} )) \
        || die "인스턴스 스토어 ${#devs[@]}개 (필요 ${#ids[@]}개). lsblk -o NAME,MODEL 확인"
    devs=("${devs[@]:0:${#ids[@]}}")

    for d in "${devs[@]}"; do
        [[ -z "$(lsblk -no MOUNTPOINT "$(readlink -f "$d")" 2>/dev/null | tr -d '[:space:]')" ]] \
            || die "$d 가 마운트되어 있다 -- 쓰면 안 되는 장치일 수 있다"
    done

    # 포트
    local p="$CFG/ports/$PORT_ID"
    if [[ ! -d "$p" ]]; then
        mkdir -p "$p"
        echo tcp     > "$p/addr_trtype"
        echo ipv4    > "$p/addr_adrfam"
        echo "$S_IP" > "$p/addr_traddr"
        echo "$PORT" > "$p/addr_trsvcid"
    fi

    # subsystem: 노드마다 1개 (NQN = node<id>), 인스턴스 스토어 1개 전용
    local i id sub
    for i in "${!ids[@]}"; do
        id="${ids[$i]}"; sub="$CFG/subsystems/node$id"
        if [[ ! -d "$sub" ]]; then
            mkdir -p "$sub/namespaces/1"
            echo 1 > "$sub/attr_allow_any_host"      # 접근 제한은 Security Group 으로
            echo -n "${devs[$i]}" > "$sub/namespaces/1/device_path"
            echo 1 > "$sub/namespaces/1/enable"
        fi
        [[ -e "$p/subsystems/node$id" ]] || ln -s "$sub" "$p/subsystems/node$id"
    done

    echo "OK: nvmet tcp $S_IP:$PORT, subsystem: $(printf 'node%s ' "${ids[@]}")"
    echo
    echo "다음 줄을 모든 인스턴스에서 patch 에 쓴다:"
    echo "DEVS=\"${devs[*]}\""
    echo "DEVS=\"${devs[*]}\"" > "$HERE/devs.env"
}

# ---------------------------------------------------------------- patch
cmd_patch() {
    local repo="${1:?usage: DEVS=\"a b c\" patch <repo_dir>}"
    local envsh="$repo/env.sh"
    [[ -f "$envsh" ]] || die "$envsh 없음"
    : "${DEVS:?DEVS=\"by-id1 by-id2 by-id3\" (storage 단계가 출력한 값)}"
    IDS="$IDS" C_IPS="$C_IPS" DEVS="$DEVS" S_IP="$S_IP" python3 - "$envsh" <<'PY'
import os, re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if not os.path.exists(p + ".ec2bak"):
    open(p + ".ec2bak", "w", encoding="utf-8").write(s)
ids  = os.environ["IDS"].split()
ips  = os.environ["C_IPS"].split()
devs = os.environ["DEVS"].split()
sip  = os.environ["S_IP"]
assert len(ids) == len(ips) == len(devs), "IDS, C_IPS, DEVS 개수가 같아야 한다"

lines = []
for i, ip, dev in zip(ids, ips, devs):
    if re.search(r'^\s*"%s\|' % re.escape(i), s, re.M):
        continue                      # 이미 있다
    lines.append('    "%s|%s:6000|%s:6000|node%s|%s"   # ec2_quick' % (i, ip, ip, i, dev))
if lines:
    text = "\n".join(lines) + "\n"
    s, n = re.subn(r'^(POOL=\(\n)', lambda m: m.group(1) + text, s, count=1, flags=re.M)
    assert n == 1, "POOL=( 를 찾지 못했다"

s, n = re.subn(r'(eth\)\s+col=2; sh=")[^"]*(")',
               lambda m: m.group(1) + sip + ":5050" + m.group(2), s)
assert n == 1, "eth) col=2 줄을 찾지 못했다 (env.sh 구조가 바뀜?)"
open(p, "w", encoding="utf-8").write(s)
print("patched:", p, "(백업: %s.ec2bak)" % p)
PY
    echo "다음: export NODES='$IDS'"
}

# ---------------------------------------------------------------- compute
# env.sh 의 dev_for_nqn 과 같은 방식으로 장치를 찾는다 (start_node.sh 가 mount 출처와 비교한다)
dev_for_nqn() {
    local nqn="$1" s heads=()
    for s in /sys/class/nvme-subsystem/nvme-subsys*; do
        [[ -r "$s/subsysnqn" ]] || continue
        [[ "$(<"$s/subsysnqn")" == "$nqn" ]] || continue
        heads=("$s"/nvme*n*)
        [[ -e "${heads[0]}" ]] || heads=()
        break
    done
    [[ ${#heads[@]} -eq 1 ]] || return 1
    echo "/dev/${heads[0]##*/}"
}

cmd_compute() {
    need_root
    local id="${1:?usage: compute <id>}" nqn dev t
    nqn="node$id"
    modprobe nvme-tcp

    if ! dev_for_nqn "$nqn" >/dev/null 2>&1; then
        nvme connect -t tcp -a "$S_IP" -s "$PORT" -n "$nqn"
    fi
    for t in $(seq 1 20); do
        dev="$(dev_for_nqn "$nqn" 2>/dev/null)" && break
        sleep 0.5
    done
    [[ -n "${dev:-}" && -b "$dev" ]] || die "$nqn 장치를 찾지 못했다 (nvme list-subsys 확인)"

    if ! blkid "$dev" >/dev/null 2>&1; then
        echo "파일시스템 없음 -> mkfs.ext4 $dev"
        mkfs.ext4 -F -q "$dev"
    else
        echo "기존 파일시스템 유지: $(blkid -o value -s TYPE "$dev")"
    fi

    mkdir -p "$MNT"
    if mountpoint -q "$MNT"; then
        [[ "$(findmnt -n -o SOURCE "$MNT" | tail -1)" == "$dev" ]] \
            || die "$MNT 에 다른 장치가 마운트되어 있다"
    else
        mount "$dev" "$MNT"
    fi
    chown "${SUDO_USER:-$USER}" "$MNT"
    echo "OK: $dev -> $MNT (node $id)"
}

# ---------------------------------------------------------------- status
cmd_status() {
    echo "hostname : $(hostname -s)"
    echo "--- nvme subsystem ---"; nvme list-subsys 2>/dev/null || echo "(없음)"
    echo "--- $MNT ---"; findmnt "$MNT" || echo "(마운트 안 됨)"
    if [[ -d $CFG/ports ]]; then
        echo "--- nvmet ports ---"
        ls "$CFG/ports" 2>/dev/null; ls "$CFG/ports/$PORT_ID/subsystems" 2>/dev/null || true
    fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
    common)  cmd_common  "$@" ;;
    storage) cmd_storage "$@" ;;
    patch)   cmd_patch   "$@" ;;
    compute) cmd_compute "$@" ;;
    status)  cmd_status  "$@" ;;
    *) sed -n '3,14p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac