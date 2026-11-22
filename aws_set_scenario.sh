
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$SCRIPT_DIR/aws_topology.conf"

usage() {
    echo "Usage: $0 S1|S2|S3 C3|C5|C7|C9"
    echo
    echo "Supported scenarios:"
    echo "  S1 C3"
    echo "  S2 C3"
    echo "  S3 C3"
    echo "  S2 C5"
    echo "  S3 C5"
    echo "  S3 C7"
    echo "  S3 C9"
}

if [[ $# -ne 2 ]]; then
    usage
    exit 1
fi

SCENARIO_S="$1"
SCENARIO_C="$2"

[[ -f "$CONF" ]] || {
    echo "ERROR: aws_topology.conf not found" >&2
    exit 1
}

python3 - "$CONF" "$SCENARIO_S" "$SCENARIO_C" <<'PY'
import os
import re
import sys
import shutil
import tempfile
from pathlib import Path

conf = Path(sys.argv[1])
storage = sys.argv[2].upper()
compute = sys.argv[3].upper()

# 각 Storage별 Compute 개수
SCENARIOS = {
    ("S1", "C3"): [3],
    ("S2", "C3"): [2, 1],
    ("S3", "C3"): [1, 1, 1],

    ("S2", "C5"): [3, 2],
    ("S3", "C5"): [2, 2, 1],

    ("S3", "C7"): [2, 2, 3],

    ("S3", "C9"): [3, 3, 3],
}

key = (storage, compute)

if key not in SCENARIOS:
    print(f"ERROR: unsupported scenario {storage} {compute}")
    print("Available:")
    for s, c in SCENARIOS:
        print(f"  {s} {c}")
    sys.exit(1)

counts = SCENARIOS[key]

# Raft ID: 11, 12, ... 19
ids = list(range(11, 11 + sum(counts)))

mapping = {}
idx = 0

for sidx, count in enumerate(counts, start=1):
    for disk_idx in range(count):
        node_id = ids[idx]
        disk_letter = "ABC"[disk_idx]
        mapping[node_id] = f"s{sidx}:{disk_letter}"
        idx += 1

source = conf.read_text(encoding="utf-8")

# ============================================================
# 설정 파일 구조 검사
# ============================================================

def get_assoc_block(text, name):
    pattern = (
        rf"^declare\s+-A\s+{name}=\(\s*\n"
        rf"(.*?)"
        rf"^\)"
    )
    m = re.search(pattern, text, re.M | re.S)

    if not m:
        raise ValueError(f"{name} block not found")

    return m.group(1)


def get_assoc_value(block, key):
    pattern = rf'^\s*\[{re.escape(str(key))}\]="([^"]+)"'
    m = re.search(pattern, block, re.M)
    return m.group(1) if m else None


raft_ips = get_assoc_block(source, "RAFT_IP")
storage_ips = get_assoc_block(source, "STORAGE_IP")
storage_disks = get_assoc_block(source, "STORAGE_DISK")

# 활성 Raft IP 확인
for node_id in ids:
    ip = get_assoc_value(raft_ips, node_id)

    if not ip or ip == "CHANGE_ME":
        sys.exit(f"ERROR: RAFT_IP[{node_id}] not configured")

# 활성 Storage IP 확인
for sidx in range(1, len(counts) + 1):
    sid = f"s{sidx}"
    ip = get_assoc_value(storage_ips, sid)

    if not ip or ip == "CHANGE_ME":
        sys.exit(f"ERROR: STORAGE_IP[{sid}] not configured")

# 슬롯 설정 존재 확인
for slot in mapping.values():
    dev = get_assoc_value(storage_disks, slot)

    if not dev or dev == "CHANGE_ME":
        sys.exit(f"ERROR: STORAGE_DISK[{slot}] not configured")

# ============================================================
# NODES 수정
# ============================================================

new_nodes = 'NODES="' + " ".join(map(str, ids)) + '"'

updated, n = re.subn(
    r'^NODES="[^"]*"',
    lambda _: new_nodes,
    source,
    count=1,
    flags=re.M,
)

if n != 1:
    sys.exit("ERROR: NODES assignment not found")

# ============================================================
# VOLUME_DISK 수정
# ============================================================

lines = ["declare -A VOLUME_DISK=("]

for node_id, slot in mapping.items():
    lines.append(f'    [{node_id}]="{slot}"')

lines.append(")")

new_block = "\n".join(lines)

pattern = (
    r'^declare\s+-A\s+VOLUME_DISK=\(\s*\n'
    r'.*?'
    r'^\)'
)

updated, n = re.subn(
    pattern,
    lambda _: new_block,
    updated,
    count=1,
    flags=re.M | re.S,
)

if n != 1:
    sys.exit("ERROR: VOLUME_DISK block not found")

# ============================================================
# 백업 + 원자적 저장
# ============================================================

backup = conf.with_suffix(".conf.bak")
shutil.copy2(conf, backup)

fd, tmp = tempfile.mkstemp(
    prefix=".aws_topology.",
    dir=conf.parent,
)

try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(updated)

    shutil.copymode(conf, tmp)
    os.replace(tmp, conf)

finally:
    if os.path.exists(tmp):
        os.unlink(tmp)

# ============================================================
# 결과 출력
# ============================================================

print()
print("=" * 50)
print(f"Scenario: {storage} {compute}")
print("=" * 50)

print("NODES:", " ".join(map(str, ids)))
print()

for node_id, slot in mapping.items():
    print(f"  Raft {node_id} -> {slot}")

print()
print(f"Updated: {conf}")
print(f"Backup : {backup}")
print()
print("NOTE: Only aws_topology.conf was modified.")
print("      No NVMe, mount, or running process was changed.")
PY
