#!/usr/bin/env bash
# compare_raw.sh 가 FAIL 일 때: 두 볼륨의 raw 구간에서 어디가 다른지, 그 자리에 각자 어떤 엔트리가 있는지 보여준다.
# 스토리지 노드에서 sudo 로 실행 (읽기만 한다).
#   사용: sudo ./scripts/diff_raw.sh <섹터수> <장치A:skip> <장치B:skip> [시작슬롯]
#   skip 은 compare_raw.sh 와 같은 값. 시작슬롯 = 구간 첫 섹터의 링 슬롯 번호 (파일 첫 extent 면 0)
# 슬롯 k 는 링 파일 오프셋 512 + k*512. 엔트리 헤더(슬롯 첫 32B) = term, cmd_len, num_slots, log_index (LE u64).
set -uo pipefail
[[ $# -ge 3 ]] || { sed -n '2,6p' "$0"; exit 2; }
COUNT="$1"; A="$2"; B="$3"; BASE="${4:-0}"
TMP=$(mktemp -d /dev/shm/rawdiff.XXXXXX); trap 'rm -rf "$TMP"' EXIT
dd if="${A%%:*}" bs=512 skip="${A##*:}" count="$COUNT" iflag=direct of="$TMP/a" status=none || exit 1
dd if="${B%%:*}" bs=512 skip="${B##*:}" count="$COUNT" iflag=direct of="$TMP/b" status=none || exit 1
python3 - "$TMP/a" "$TMP/b" "$BASE" "${A%%:*}" "${B%%:*}" <<'EOF'
import struct, sys
a = open(sys.argv[1], 'rb').read(); b = open(sys.argv[2], 'rb').read()
base = int(sys.argv[3]); na, nb = sys.argv[4].split('/')[-1], sys.argv[5].split('/')[-1]
S = 512; n = min(len(a), len(b)) // S
sec = lambda d, i: d[i*S:(i+1)*S]
diff = [i for i in range(n) if sec(a, i) != sec(b, i)]
print(f"섹터 {n}개 중 다른 섹터 {len(diff)}개")
if not diff:
    sys.exit(0)
rng = []
for i in diff:
    if rng and i == rng[-1][1] + 1: rng[-1][1] = i
    else: rng.append([i, i])

def chain(d):
    """구간 첫 슬롯부터 엔트리 헤더를 따라간다. {슬롯: (term, cmd_len, num_slots, idx)}"""
    out, s = {}, 0
    while s < n:
        t, cl, ns, ix = struct.unpack_from('<4Q', d, s*S)
        if ns == 0 or ns > 1 << 20 or t == 0 or t > 1 << 20:
            break
        out[s] = (t, cl, ns, ix); s += ns
    return out, s
ca, enda = chain(a); cb, endb = chain(b)
print(f"엔트리 체인: {na} {len(ca)}개 (슬롯 {base}~{base+enda-1} 까지 이어짐), {nb} {len(cb)}개 (~{base+endb-1})")

def owner(c, i):
    best = None
    for s in c:
        if s <= i: best = s
        else: break
    if best is None: return "체인 밖"
    t, cl, ns, ix = c[best]
    if i >= best + ns: return f"체인 끝 뒤 (마지막 엔트리 idx={ix} 슬롯 {base+best}+{ns})"
    return f"idx={ix} term={t} cmd_len={cl} 슬롯 {base+best}..{base+best+ns-1} 의 {i-best}번째"

zero = lambda d, i, j: d[i*S:(j+1)*S].count(0) == (j-i+1)*S
for k, (i, j) in enumerate(rng[:20]):
    print(f"\n[{k}] 슬롯 {base+i}..{base+j} ({j-i+1}섹터)")
    for nm, d, c in ((na, a, ca), (nb, b, cb)):
        hdr = struct.unpack_from('<4Q', d, i*S)
        print(f"  {nm:<45} 전부0={zero(d, i, j)!s:<5} 소유={owner(c, i)}")
        print(f"  {'':<45} 첫 섹터 앞 32B(term,len,slots,idx 로 읽으면)={hdr}  hex={sec(d, i)[:32].hex()}")
if len(rng) > 20:
    print(f"\n... 구간 {len(rng)}개 중 20개만 표시")
EOF
