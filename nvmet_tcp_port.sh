#!/usr/bin/env bash
#
# nvmet_tcp_port.sh -- eternitystorage nvmet 에 NVMe/TCP 포트를 열고 닫는다 (TCP 실험 기간에만)
#
#   ./nvmet_tcp_port.sh up       NET 의 tcp 포트를 만들고 NODES 의 subsystem 을 링크한다 (한 일은 기록)
#   ./nvmet_tcp_port.sh down     up 이 만든 링크·포트만 지운다
#   ./nvmet_tcp_port.sh status   포트 목록 (아무것도 바꾸지 않는다)
#
# 망 (11-16):
#   NET=eth   (기본) ports/11  tcp 115.145.173.243:4421   <- TCP 본 실험 (이더넷)
#   NET=ipoib         ports/12  tcp 10.0.0.91:4421         <- tcp-ib (IPoIB 전환)
#   둘 다 열어 둘 수 있다 (포트 번호가 다르다). 기록도 NET 별로 따로 둔다.
#
# 건드리지 않는 것: 기존 rdma ports/10, NODES 밖의 subsystem(다른 사람 것 포함), subsystem 자체.
# NODES 는 env.sh 의 TOPO/NODES 로 정한다 (TOPO=5 ./nvmet_tcp_port.sh up). 노드와 같은 값을 줄 것.
# down 은 그 포트로 붙은 호스트 연결을 끊는다 -- 먼저 각 노드를 rdma 로 돌려 놓을 것
#   (sudo ./nvmeof_switch.sh rdma --all-members).
# nvmet-tcp 모듈을 up 이 올렸으면 down 이 (다른 tcp 포트가 없을 때) 내린다.
#
# 접근 제한 (NET=eth): node subsystem 은 attr_allow_any_host=1 이다 (11-16 확인). 이더넷은 캠퍼스망이라
#   포트만 열면 누구나 인증 없이 원시 볼륨을 읽고 쓸 수 있다. 그래서 up 이 iptables 로 $TRADDR:4421 을
#   NODES 의 이더넷 주소에만 열고 나머지는 DROP 한다 (주석 raftof-nvmet-tcp, 기록해서 down 이 지운다).
#   ALLOW_SRC="ip ip .." 로 허용 목록을 바꿀 수 있다. FIREWALL=0 이면 걸지 않는다 (권하지 않음).
#   IPoIB(10.0.0.x)는 사설 패브릭이라 기본으로 걸지 않는다 (FIREWALL=1 이면 건다).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET="${NET:-eth}"
case "$NET" in
    eth)   PORT_ID=11; TRADDR=115.145.173.243 ;;
    ipoib) PORT_ID=12; TRADDR=10.0.0.91 ;;
    *) echo "ERROR: NET 은 eth|ipoib: $NET" >&2; exit 2 ;;
esac
TRSVCID="${TRSVCID:-4421}"
CFG=/sys/kernel/config/nvmet
PORT_DIR="$CFG/ports/$PORT_ID"
STATE_DIR="/var/lib/raftof-nvmet-tcp"
STATE="$STATE_DIR/$NET"
HOST_ONLY="eternitystorage"
if [[ "$NET" == eth ]]; then FIREWALL="${FIREWALL:-1}"; else FIREWALL="${FIREWALL:-0}"; fi
FW_TAG="raftof-nvmet-tcp"

die() { echo "ERROR: $*" >&2; exit 1; }
as_root() { if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi; }
put() { echo "$2" | as_root tee "$1" >/dev/null || die "$1 <- $2 실패"; }

case "${1:-}" in
    up|down|status) ;;
    *) sed -n '2,/^[^#]/{/^#/p}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
CMD="$1"

if [[ "$(hostname -s)" != "$HOST_ONLY" ]]; then
    echo "$(hostname -s): 할 일 없음 ($HOST_ONLY 에서 실행)"
    exit 0
fi
[[ -d "$CFG/ports" ]] || die "$CFG 가 없다 (nvmet 모듈/configfs 확인)"

show() {
    local p
    echo "== nvmet ports"
    for p in "$CFG"/ports/*; do
        [[ -d "$p" ]] || continue
        printf '   ports/%-3s %-5s %s:%s  subsystems: %s\n' "${p##*/}" \
            "$(cat "$p/addr_trtype")" "$(cat "$p/addr_traddr")" "$(cat "$p/addr_trsvcid")" \
            "$(ls "$p/subsystems" | tr '\n' ' ')"
    done
    echo "   nvmet_tcp 모듈: $(lsmod | awk '$1=="nvmet_tcp"{print "loaded"; f=1} END{if(!f) print "not loaded"}')"
    if [[ -r "$STATE" ]]; then echo "   기록($STATE): $(grep -c '^LINK=' "$STATE") 개 링크, $(grep -c '^RULE=' "$STATE") 개 방화벽 규칙, $(grep '^PORT_CREATED=' "$STATE")"
    else echo "   기록($STATE): 없음"; fi
}

case "$CMD" in
status)
    show
    ;;
up)
    [[ -e "$STATE" ]] && die "이미 up 기록이 있다 ($STATE). 먼저 down"
    NODES_LIST="$(source "$SCRIPT_DIR/env.sh" >/dev/null 2>&1; echo "$NODES")"
    [[ -n "$NODES_LIST" ]] || die "env.sh 에서 NODES 를 얻지 못했다 (TOPO 확인)"
    NQNS="$(source "$SCRIPT_DIR/env.sh" >/dev/null 2>&1; for id in $NODES; do _pool_field "$id" 3; done)"
    # 허용할 initiator 주소: NODES 의 이 망 주소 (env.sh POOL: 1=ipoib, 2=eth)
    col=2; [[ "$NET" == ipoib ]] && col=1
    ALLOW="${ALLOW_SRC:-$(source "$SCRIPT_DIR/env.sh" >/dev/null 2>&1; for id in $NODES; do a="$(_pool_field "$id" "$col")"; echo "${a%:*}"; done)}"
    if [[ "$FIREWALL" == 1 ]]; then
        command -v iptables >/dev/null || die "iptables 가 없다 (FIREWALL=0 으로 끌 수 있으나 권하지 않음)"
        [[ -n "$ALLOW" ]] || die "허용할 주소 목록이 비었다"
    fi
    for n in $NQNS; do
        [[ -d "$CFG/subsystems/$n" ]] || die "subsystem $n 이 없다 -- 아무것도 바꾸지 않았다"
    done
    # 다른 포트가 같은 주소:포트를 쓰고 있으면 중단
    for p in "$CFG"/ports/*; do
        [[ -d "$p" && "$p" != "$PORT_DIR" ]] || continue
        if [[ "$(cat "$p/addr_traddr")" == "$TRADDR" && "$(cat "$p/addr_trsvcid")" == "$TRSVCID" ]]; then
            die "ports/${p##*/} 가 이미 $TRADDR:$TRSVCID 를 쓴다"
        fi
    done

    as_root mkdir -p "$STATE_DIR" || die "$STATE_DIR 를 만들지 못했다"
    { echo "WHEN=$(date '+%F %T')"; echo "NODES=$NODES_LIST"; } | as_root tee "$STATE" >/dev/null

    if ! lsmod | grep -q '^nvmet_tcp '; then
        as_root modprobe nvmet-tcp || die "modprobe nvmet-tcp 실패"
        echo "MODULE_LOADED=1" | as_root tee -a "$STATE" >/dev/null
        echo "[up] nvmet-tcp 모듈을 올렸다"
    fi

    if [[ -d "$PORT_DIR" ]]; then
        [[ "$(cat "$PORT_DIR/addr_trtype")" == tcp && "$(cat "$PORT_DIR/addr_traddr")" == "$TRADDR" \
           && "$(cat "$PORT_DIR/addr_trsvcid")" == "$TRSVCID" ]] ||
            die "ports/$PORT_ID 가 이미 다른 설정으로 있다 ($(cat "$PORT_DIR/addr_trtype") $(cat "$PORT_DIR/addr_traddr"):$(cat "$PORT_DIR/addr_trsvcid"))"
        echo "PORT_CREATED=0" | as_root tee -a "$STATE" >/dev/null
        echo "[up] ports/$PORT_ID 는 이미 있다 (그대로 쓴다)"
    else
        as_root mkdir "$PORT_DIR" || die "ports/$PORT_ID 를 만들지 못했다"
        echo "PORT_CREATED=1" | as_root tee -a "$STATE" >/dev/null
        put "$PORT_DIR/addr_trtype" tcp
        put "$PORT_DIR/addr_adrfam" ipv4
        put "$PORT_DIR/addr_traddr" "$TRADDR"
        put "$PORT_DIR/addr_trsvcid" "$TRSVCID"
        echo "[up] ports/$PORT_ID tcp $TRADDR:$TRSVCID 를 만들었다"
    fi

    # 포트를 subsystem 에 잇기 전에 방화벽부터 (잇는 순간 연결을 받는다)
    if [[ "$FIREWALL" == 1 ]]; then
        drop=(INPUT -p tcp -d "$TRADDR" --dport "$TRSVCID" -m comment --comment "$FW_TAG" -j DROP)
        as_root iptables -I "${drop[@]}" || die "iptables DROP 규칙 실패"
        echo "RULE=${drop[*]}" | as_root tee -a "$STATE" >/dev/null
        for a in $ALLOW; do
            acc=(INPUT -p tcp -s "$a" -d "$TRADDR" --dport "$TRSVCID" -m comment --comment "$FW_TAG" -j ACCEPT)
            as_root iptables -I "${acc[@]}" || die "iptables ACCEPT($a) 실패"
            echo "RULE=${acc[*]}" | as_root tee -a "$STATE" >/dev/null
        done
        echo "[up] 방화벽: $TRADDR:$TRSVCID 는 $(echo $ALLOW) 에서만 받는다"
    else
        echo "[up] 방화벽 없음 (FIREWALL=0) -- allow_any_host=1 이면 이 주소로 오는 누구나 붙을 수 있다"
    fi

    for n in $NQNS; do
        if [[ -e "$PORT_DIR/subsystems/$n" ]]; then
            echo "[up] $n 은 이미 링크돼 있다"
            continue
        fi
        as_root ln -s "$CFG/subsystems/$n" "$PORT_DIR/subsystems/$n" || die "$n 링크 실패 (지금까지 한 일은 down 으로 되돌린다)"
        echo "LINK=$n" | as_root tee -a "$STATE" >/dev/null
        echo "[up] $n -> ports/$PORT_ID"
    done
    echo
    show
    echo
    echo "다음: 각 노드에서 sudo NET=$NET TOPO=${TOPO:-3} ./nvmeof_switch.sh tcp --all-members, 이어서 ./scripts/probe_io_queues.sh"
    echo "실험이 끝나면: 노드를 rdma 로 돌린 뒤 NET=$NET ./nvmet_tcp_port.sh down"
    ;;
down)
    [[ -e "$STATE" ]] || { echo "[down] up 기록이 없다 ($STATE) -- 할 일 없음"; exit 0; }
    fail=0
    while IFS='=' read -r key val; do
        [[ "$key" == LINK ]] || continue
        if [[ -L "$PORT_DIR/subsystems/$val" ]]; then
            as_root rm "$PORT_DIR/subsystems/$val" && echo "[down] $val 링크 제거" ||
                { echo "  ERROR: $val 링크를 지우지 못했다"; fail=$((fail + 1)); }
        fi
    done < "$STATE"
    if grep -q '^PORT_CREATED=1' "$STATE" && [[ -d "$PORT_DIR" ]]; then
        if [[ -n "$(ls "$PORT_DIR/subsystems")" ]]; then
            echo "  WARN: ports/$PORT_ID 에 다른 링크가 남아 있어 포트는 두었다"
        else
            as_root rmdir "$PORT_DIR" && echo "[down] ports/$PORT_ID 제거" ||
                { echo "  ERROR: ports/$PORT_ID 를 지우지 못했다"; fail=$((fail + 1)); }
        fi
    fi
    # 방화벽은 포트를 지운 뒤에 푼다
    while IFS= read -r line; do
        [[ "$line" == RULE=* ]] || continue
        read -r -a rule <<< "${line#RULE=}"
        as_root iptables -D "${rule[@]}" && echo "[down] iptables 규칙 제거: ${rule[*]}" ||
            { echo "  ERROR: iptables 규칙을 지우지 못했다: ${rule[*]}"; fail=$((fail + 1)); }
    done < "$STATE"
    if grep -q '^MODULE_LOADED=1' "$STATE"; then
        others=0
        for p in "$CFG"/ports/*; do
            [[ -d "$p" && "$(cat "$p/addr_trtype")" == tcp ]] && others=1
        done
        if [[ $others -eq 0 ]]; then
            as_root modprobe -r nvmet-tcp && echo "[down] nvmet-tcp 모듈을 내렸다" ||
                echo "  WARN: nvmet-tcp 를 내리지 못했다 (사용 중?)"
        else
            echo "[down] 다른 tcp 포트가 있어 nvmet-tcp 모듈은 둔다"
        fi
    fi
    [[ $fail -eq 0 ]] || die "일부를 되돌리지 못했다 -- 기록($STATE)은 남겨 둔다"
    as_root rm -f "$STATE"
    echo "[down] 완료 -- 기록 삭제"
    echo
    show
    ;;
esac
