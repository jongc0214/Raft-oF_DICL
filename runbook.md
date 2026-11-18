# Raft-oF v2 3-Node Runbook

## 1. 클러스터 구성

| 역할        | 서버              | Raft ID | Ethernet IP       | IPoIB IP    | Local NVMe-oF device |
| --------- | --------------- | ------: | ----------------- | ----------- | -------------------- |
| Compute 1 | eternity5       |       5 | `115.145.173.124` | `10.0.0.5`  | `/dev/nvme2n1`       |
| Compute 2 | eternity6       |       6 | `115.145.173.125` | `10.0.0.6`  | `/dev/nvme3n1`       |
| Compute 3 | eternity7       |       7 | `115.145.173.126` | `10.0.0.7`  | `/dev/nvme1n1`       |
| Storage   | eternitystorage |       - | `115.145.173.243` | `10.0.0.91` | physical NVMe 3개     |

Raft RPC port:

```
6000
```

BlockCopy RPC port:

```
5050
```

현재 transport mode는 세 가지를 사용한다.

```
rdma
→ RPC transport: RDMA
→ network address: 10.0.0.x IPoIB 주소

tcp-ib
→ RPC transport: TCP
→ network address: 10.0.0.x IPoIB 주소

tcp
→ RPC transport: TCP
→ network address: 115.145.173.x Ethernet 주소
```

즉:

```
rdma       = RDMA over InfiniBand
tcp-ib     = TCP over IPoIB
tcp        = TCP over Ethernet
```

---

# 2. 최초 세팅 확인

## 2.1 Compute node NVMe-oF 연결 확인

각 compute node:

```
sudo nvme list-subsys
```

필요하면:

```
sudo modprobe nvme_fabrics
sudo modprobe nvme_tcp
```

NVMe-oF discovery:

```
sudo nvme discover -t tcp -a 115.145.173.243 -s 4420
```

연결이 없는 경우 기존 subsystem 구성에 맞춰 connect한다.

예:

```
sudo nvme connect -t tcp -n node1 -a 115.145.173.243 -s 4420
sudo nvme connect -t tcp -n node3 -a 115.145.173.243 -s 4420
sudo nvme connect -t tcp -n node5 -a 115.145.173.243 -s 4420
```

다시 확인:

```
sudo nvme list-subsys
```

---

# 3. Compute node mount 확인

각 compute node:

```
mount | grep /mnt/raftvol
```

## ID 5

mount가 없다면:

```
sudo mkdir -p /mnt/raftvol
sudo mount /dev/nvme2n1 /mnt/raftvol
sudo mkdir -p /mnt/raftvol/node5
```

## ID 6

```
sudo mkdir -p /mnt/raftvol
sudo mount /dev/nvme3n1 /mnt/raftvol
sudo mkdir -p /mnt/raftvol/node6
```

## ID 7

```
sudo mkdir -p /mnt/raftvol
sudo mount /dev/nvme1n1 /mnt/raftvol
sudo mkdir -p /mnt/raftvol/node7
```

주의:

```
raft metadata 파일이 있는 filesystem과
cluster에 지정된 device_path는 같은 물리 NVMe-oF volume이어야 한다.
```

---

# 4. Build

## Compute node 3대

각 compute node:

```
cd /home/ryudb00/raftof_jongc

./build.sh node
./build.sh client
```

Raft core / timing 관련 파일을 수정했다면 최소:

```
./build.sh node
```

Client API 또는 출력도 수정했다면:

```
./build.sh client
```

---

## Storage node

Storage node:

```
cd /home/ryudb00/raftof_jongc

./build.sh blockcopy-server
```

다음 파일을 수정한 경우 재빌드 필요:

```
storage/raft_blockcopy_server.cpp
storage/raft_blockcopy_server.h
```

---

# 5. 사용하는 스크립트

현재 주요 스크립트:

```
env.sh
start_node.sh
stop_node.sh
clean_node.sh
start_blockcopy.sh
stop_blockcopy.sh
bench_latency.sh
```

실행 권한:

```
chmod +x env.sh
chmod +x start_node.sh
chmod +x stop_node.sh
chmod +x clean_node.sh
chmod +x start_blockcopy.sh
chmod +x stop_blockcopy.sh
chmod +x bench_latency.sh
```

---

# 6. Transport mode 정의

## RDMA

```
mode name:
rdma
```

실제 실행:

```
-transport rdma
```

사용 주소:

```
Raft:
10.0.0.5:6000
10.0.0.6:6000
10.0.0.7:6000

Storage:
10.0.0.91:5050
```

---

## TCP over IPoIB

```
mode name:
tcp-ib
```

실제 실행:

```
-transport tcp
```

사용 주소:

```
Raft:
10.0.0.5:6000
10.0.0.6:6000
10.0.0.7:6000

Storage:
10.0.0.91:5050
```

즉 RDMA와 동일한 IPoIB network path를 사용하지만 RPC 구현만 TCP로 바뀐다.

---

## TCP over Ethernet

```
mode name:
tcp
```

실제 실행:

```
-transport tcp
```

사용 주소:

```
Raft:
115.145.173.124:6000
115.145.173.125:6000
115.145.173.126:6000

Storage:
115.145.173.243:5050
```

---

# 7. Storage BlockCopy server 시작

사용법:

```
./start_blockcopy.sh <rdma|tcp-ib|tcp>
```

주의:

`tcp-ib`와 `tcp`는 둘 다 실제 binary에는:

```
-transport tcp
```

가 들어간다.

차이는 Raft node가 storage host로 어떤 IP를 사용하느냐이다.

---

## RDMA

Storage node:

```
./start_blockcopy.sh rdma
```

확인:

```
pgrep -af raft_blockcopy_server
```

로그:

```
tail -f raft_blockcopy_server_rdma.log
```

---

## TCP over IPoIB

Storage node:

```
./start_blockcopy.sh tcp-ib
```

확인:

```
pgrep -af raft_blockcopy_server
```

로그:

```
tail -f raft_blockcopy_server_tcp-ib.log
```

---

## TCP over Ethernet

Storage node:

```
./start_blockcopy.sh tcp
```

로그:

```
tail -f raft_blockcopy_server_tcp.log
```

---

# 8. Raft node 시작

사용법:

```
./start_node.sh <id> [destination|leader] [rdma|tcp-ib|tcp]
```

기본값:

```
mode      = destination
transport = rdma
```

---

## Destination + RDMA

eternity5:

```
./start_node.sh 5 destination rdma
```

eternity6:

```
./start_node.sh 6 destination rdma
```

eternity7:

```
./start_node.sh 7 destination rdma
```

---

## Destination + TCP over IPoIB

eternity5:

```
./start_node.sh 5 destination tcp-ib
```

eternity6:

```
./start_node.sh 6 destination tcp-ib
```

eternity7:

```
./start_node.sh 7 destination tcp-ib
```

---

## Destination + TCP Ethernet

eternity5:

```
./start_node.sh 5 destination tcp
```

eternity6:

```
./start_node.sh 6 destination tcp
```

eternity7:

```
./start_node.sh 7 destination tcp
```

---

## Leader + RDMA

```
./start_node.sh 5 leader rdma
./start_node.sh 6 leader rdma
./start_node.sh 7 leader rdma
```

---

## Leader + TCP over IPoIB

```
./start_node.sh 5 leader tcp-ib
./start_node.sh 6 leader tcp-ib
./start_node.sh 7 leader tcp-ib
```

---

## Leader + TCP Ethernet

```
./start_node.sh 5 leader tcp
./start_node.sh 6 leader tcp
./start_node.sh 7 leader tcp
```

한 실험에서는 세 노드 모두 동일한 replication mode와 transport mode를 사용한다.

---

# 9. Cluster 상태 확인

먼저:

```
source ./env.sh
```

그리고 transport mode를 선택한다.

## RDMA

```
select_transport_env rdma
```

Commit index:

```
./build/raft_client \
  -addrs "$ADDRS" \
  -op commit-index \
  -transport "$TRANSPORT"
```

AE stats:

```
./build/raft_client \
  -addrs "$ADDRS" \
  -op ae-stats \
  -transport "$TRANSPORT"
```

---

## TCP over IPoIB

```
select_transport_env tcp-ib
```

그 뒤 동일:

```
./build/raft_client \
  -addrs "$ADDRS" \
  -op commit-index \
  -transport "$TRANSPORT"

./build/raft_client \
  -addrs "$ADDRS" \
  -op ae-stats \
  -transport "$TRANSPORT"
```

이 경우 실제 값은:

```
TRANSPORT=tcp
ADDRS=10.0.0.x
```

이다.

---

## TCP Ethernet

```
select_transport_env tcp
```

그 뒤:

```
./build/raft_client \
  -addrs "$ADDRS" \
  -op commit-index \
  -transport "$TRANSPORT"
```

---

# 10. Smoke test

## RDMA

```
select_transport_env rdma

./build/raft_client \
  -addrs "$ADDRS" \
  -op apply \
  -n 200 \
  -size 512 \
  -batch 10 \
  -transport "$TRANSPORT"
```

---

## TCP over IPoIB

```
select_transport_env tcp-ib

./build/raft_client \
  -addrs "$ADDRS" \
  -op apply \
  -n 200 \
  -size 512 \
  -batch 10 \
  -transport "$TRANSPORT"
```

---

## TCP Ethernet

```
select_transport_env tcp

./build/raft_client \
  -addrs "$ADDRS" \
  -op apply \
  -n 200 \
  -size 512 \
  -batch 10 \
  -transport "$TRANSPORT"
```

---

# 11. Warm-up

성능 측정 전에는 동일한 warm-up 조건을 사용한다.

예:

```
n       = 5000
payload = 4064
batch   = 10
```

## RDMA

```
select_transport_env rdma

./build/raft_client \
  -addrs "$ADDRS" \
  -op apply \
  -n 5000 \
  -size 4064 \
  -batch 10 \
  -transport "$TRANSPORT"
```

---

## TCP over IPoIB

```
select_transport_env tcp-ib

./build/raft_client \
  -addrs "$ADDRS" \
  -op apply \
  -n 5000 \
  -size 4064 \
  -batch 10 \
  -transport "$TRANSPORT"
```

---

## TCP Ethernet

```
select_transport_env tcp

./build/raft_client \
  -addrs "$ADDRS" \
  -op apply \
  -n 5000 \
  -size 4064 \
  -batch 10 \
  -transport "$TRANSPORT"
```

Warm-up 결과는 실험 결과로 사용하지 않는다.

---

# 12. Latency benchmark

사용법:

```
./bench_latency.sh <mode> <transport-mode> [payload] [count] [batch]
```

transport-mode:

```
rdma
tcp-ib
tcp
```

---

## Destination + RDMA

```
./bench_latency.sh destination rdma 4064 10000 1
```

---

## Destination + TCP over IPoIB

```
./bench_latency.sh destination tcp-ib 4064 10000 1
```

---

## Destination + TCP Ethernet

```
./bench_latency.sh destination tcp 4064 10000 1
```

---

## Leader + RDMA

```
./bench_latency.sh leader rdma 4064 10000 1
```

---

## Leader + TCP over IPoIB

```
./bench_latency.sh leader tcp-ib 4064 10000 1
```

---

## Leader + TCP Ethernet

```
./bench_latency.sh leader tcp 4064 10000 1
```

---

# 13. Payload size별 측정

## 512 B

```
./bench_latency.sh destination rdma      512 10000 1
./bench_latency.sh destination tcp-ib 512 10000 1
./bench_latency.sh destination tcp       512 10000 1
```

## 약 4 KB

```
./bench_latency.sh destination rdma      4064 10000 1
./bench_latency.sh destination tcp-ib 4064 10000 1
./bench_latency.sh destination tcp       4064 10000 1
```

## 약 32 KB

```
./bench_latency.sh destination rdma      32736 10000 1
./bench_latency.sh destination tcp-ib 32736 10000 1
./bench_latency.sh destination tcp       32736 10000 1
```

Leader mode도 동일하게 첫 인자만 `leader`로 변경한다.

---

# 14. Benchmark 결과 저장

결과는:

```
results/
```

아래에 저장한다.

권장 파일명:

```
apply_timed_destination_rdma_4064B_n10000_b1_*.log

apply_timed_destination_tcp-ib_4064B_n10000_b1_*.log

apply_timed_destination_tcp_4064B_n10000_b1_*.log

apply_timed_leader_rdma_4064B_n10000_b1_*.log

apply_timed_leader_tcp-ib_4064B_n10000_b1_*.log

apply_timed_leader_tcp_4064B_n10000_b1_*.log
```

로그의 BENCH INFO에는 최소 다음을 기록한다.

```
mode
transport_mode
actual_transport
network_path
payload_bytes
count
batch
ring_pages
heartbeat_ms
ae_batch
raft_addrs
cluster
profiling
```

---

# 15. Transport 비교 해석

## RDMA vs TCP-over-IPoIB

비교:

```
rdma
vs
tcp-ib
```

둘 다:

```
10.0.0.x
```

IPoIB/InfiniBand 경로를 사용한다.

차이는 주로 RPC transport 구현이다.

```
rdma
→ RDMA transport

tcp-ib
→ TCP/IP stack
→ IPoIB
→ InfiniBand fabric
```

따라서 이 비교가 transport 자체의 비용 차이를 보는 데 더 적합하다.

예:

```
./bench_latency.sh destination rdma 4064 10000 1

./bench_latency.sh destination tcp-ib 4064 10000 1
```

---

## RDMA vs TCP Ethernet

비교:

```
rdma
vs
tcp
```

이 경우는 다음이 동시에 바뀐다.

```
transport implementation
physical/network path
NIC path
switch path
MTU
queueing
link latency
link bandwidth
```

따라서 이는 순수 transport 비교보다는:

```
system-level deployment comparison
```

으로 해석한다.

---

## TCP-over-IPoIB vs TCP Ethernet

비교:

```
tcp-ib
vs
tcp
```

둘 다 실제 RPC 구현은:

```
-transport tcp
```

이다.

차이는 network path다.

```
tcp-ib
→ 10.0.0.x
→ IPoIB / InfiniBand

tcp
→ 115.145.173.x
→ Ethernet
```

따라서 이 비교는 TCP 구현을 고정하고 network fabric/path 차이를 보는 데 유용하다.

---

# 16. ApplyTimed 주요 지표

```
Total
LHandler
LPersist
AENet
FHandler
ReplNet
StorageIO
QuorumWait
Mutex
CommitWait
residual
```

Destination mode:

```
Leader local
├─ LHandler
└─ LPersist

AppendEntries
├─ AENet
└─ Follower handler
   ├─ FHandler
   └─ WritePBABatch
      ├─ ReplNet
      └─ StorageIO

이후
└─ QuorumWait
```

현재 StorageIO는:

```
parallel pread
+ parallel pwrite
+ fdatasync
```

batch wall-clock이다.

---

# 17. Leader mode timing

Leader mode:

```
Leader-side WritePBABatch
├─ ReplNet
└─ StorageIO

그 다음 AppendEntries
├─ AENet
└─ FHandler

그 다음
└─ QuorumWait
```

따라서:

```
FHandler = R2

QuorumWait =
    Replicate
    - WritePBA_RT
    - AE_RT
```

형태의 mode-aware decomposition을 사용해야 한다.

---

# 18. 실험 종료

## Compute node

각 compute node:

```
./stop_node.sh
```

확인:

```
pgrep -af raft_node
```

---

## Storage node

```
./stop_blockcopy.sh
```

확인:

```
pgrep -af raft_blockcopy_server
```

---

# 19. Clean Start

Mode 또는 transport mode를 바꿔 완전히 새 실험을 시작할 때 권장한다.

## Step 1. Raft node 종료

각 compute node:

```
./stop_node.sh
```

## Step 2. BlockCopy server 종료

Storage node:

```
./stop_blockcopy.sh
```

## Step 3. Metadata clean

eternity5:

```
./clean_node.sh 5
```

eternity6:

```
./clean_node.sh 6
```

eternity7:

```
./clean_node.sh 7
```

주의:

```
/mnt/raftvol 전체를 삭제하지 않는다.

Storage node의 raw NVMe device에
mkfs / dd / blkdiscard를 실행하지 않는다.
```

---

# 20. Clean Start 후 실행 예

## Destination + RDMA

Storage:

```
./start_blockcopy.sh rdma
```

Compute:

```
./start_node.sh 5 destination rdma
./start_node.sh 6 destination rdma
./start_node.sh 7 destination rdma
```

Warm-up 후:

```
./bench_latency.sh destination rdma 4064 10000 1
```

---

## Destination + TCP over IPoIB

Storage:

```
./start_blockcopy.sh tcp-ib
```

Compute:

```
./start_node.sh 5 destination tcp-ib
./start_node.sh 6 destination tcp-ib
./start_node.sh 7 destination tcp-ib
```

Warm-up 후:

```
./bench_latency.sh destination tcp-ib 4064 10000 1
```

---

## Destination + TCP Ethernet

Storage:

```
./start_blockcopy.sh tcp
```

Compute:

```
./start_node.sh 5 destination tcp
./start_node.sh 6 destination tcp
./start_node.sh 7 destination tcp
```

Warm-up 후:

```
./bench_latency.sh destination tcp 4064 10000 1
```

---

# 21. 권장 Transport 실험 Matrix

| Replication mode | Transport mode | 실제 RPC transport | Network path               |
| ---------------- | -------------- | ---------------- | -------------------------- |
| Destination      | `rdma`         | RDMA             | InfiniBand / `10.0.0.x`    |
| Destination      | `tcp-ib`    | TCP              | IPoIB / `10.0.0.x`         |
| Destination      | `tcp`          | TCP              | Ethernet / `115.145.173.x` |
| Leader           | `rdma`         | RDMA             | InfiniBand / `10.0.0.x`    |
| Leader           | `tcp-ib`    | TCP              | IPoIB / `10.0.0.x`         |
| Leader           | `tcp`          | TCP              | Ethernet / `115.145.173.x` |

비교 시 다음 조건은 동일하게 유지한다.

```
payload
count
batch
ring_pages
heartbeat_ms
ae_batch
warm-up
leader placement
storage topology
```

---

# 22. 자주 쓰는 명령

## Destination / RDMA

```
./start_blockcopy.sh rdma

./start_node.sh 5 destination rdma
./start_node.sh 6 destination rdma
./start_node.sh 7 destination rdma

./bench_latency.sh destination rdma 4064 10000 1
```

---

## Destination / TCP-over-IPoIB

```
./start_blockcopy.sh tcp-ib

./start_node.sh 5 destination tcp-ib
./start_node.sh 6 destination tcp-ib
./start_node.sh 7 destination tcp-ib

./bench_latency.sh destination tcp-ib 4064 10000 1
```

---

## Destination / TCP Ethernet

```
./start_blockcopy.sh tcp

./start_node.sh 5 destination tcp
./start_node.sh 6 destination tcp
./start_node.sh 7 destination tcp

./bench_latency.sh destination tcp 4064 10000 1
```

---

# 23. 현재 알려진 계측 주의사항

## Per-Apply timing correlation

`ReplSink` 자체는 per-Apply이지만 sink가 비었을 때 사용하는 global `prof.sample_*` fallback은 request/log-index correlation이 없다.

따라서 concurrent client에서는 다른 Apply의 timing sample이 섞일 수 있다.

현재:

```
single-client detailed timing
→ 우선 사용 가능

multi-client detailed timing
→ correlation 수정 전에는 주의
```

---

## Leader mode decomposition

Leader mode에서는 WritePBABatch가 AppendEntries보다 먼저 실행된다.

따라서 destination mode와 동일한 timing decomposition을 사용하면 안 된다.

Mode-aware decomposition이 적용된 build를 사용한다.

---

# 24. 권장 기본 실험

현재 기본 latency 실험:

```
replication mode = destination
transport mode   = rdma
payload          = 4064
count            = 10000
batch            = 1
```

실행:

```
./bench_latency.sh destination rdma 4064 10000 1
```

Transport 비교:

```
./bench_latency.sh destination rdma      4064 10000 1
./bench_latency.sh destination tcp-ib 4064 10000 1
./bench_latency.sh destination tcp       4064 10000 1
```

---

# 25. D24 스토리지 전환: node4/5/6 을 loop(512B) + page cache 구성으로

**상태 (2026-11-14): 원복 완료 — 현재 node4/5/6 은 SSD 를 bdev 로 내보내는 원래 구성(arm A)이다.** 다시 하려면
C(loop + ext4)는 1~5단계, C′(XFS v4 + 파일 백엔드)는 9단계, 되돌리기는 7단계. 결과와 결론은 DECISIONS.md D24.

목적과 이유는 DECISIONS.md D24. 아래 그림은 C 구성:

```
컴퓨트 ext4 ─NVMe-oF→ nvmet (bdev 백엔드, LBA 512) → /dev/loopN (sector 512, direct-io=off)
                                                     → /mnt/nvmet/node<ID>/vol.img (64GiB, 스토리지 ext4) → page cache → PM983
blockcopy: -devices 는 vol.img (일반 파일 → src 를 버퍼드로 읽음, 배너 read=buffered)
```

**왜 loop 인가 (2026-11-13 실측):** 처음에는 vol.img 를 nvmet **파일 백엔드**(`buffered_io=1`)로 내보냈다.
파일 백엔드는 namespace 블록 크기를 백킹 FS 블록(`min(i_blkbits, 12)`, ext4 = 4096)으로 정해 컴퓨트의
`logical_block_size` 가 4096 이 됐고, 512B O_DIRECT 헤더 쓰기가 `CachedFD::write_at_file: pwrite at 0 (512 bytes):
Invalid argument` 로 죽었다. ext4 최소 블록은 1K 라 FS 로는 512 를 만들 수 없다. loop 를 bdev 로 내보내면 LBA 는 512 이고,
loop 가 vol.img 에 버퍼드로 쓰므로 page cache 적중 원리는 같다. flush 는 loop 가 `vfs_fsync` 로 처리한다.
nvmet `buffered_io` 는 쓰지 않는다(0). `start_blockcopy.sh` 는 nvmet 장치가 loop 면 백킹 파일끼리 비교한다.

**지워지는 것:** node4/5/6 볼륨(컴퓨트 ext4, 링, braft-block). 각 호스트 `/mnt/raftvol` 의 etcd(eternity5 는
fio_test 도)만 1단계에서 로컬 tar 로 두었다가 3단계에서 되돌린다.

**순서:** 1 → 2 → 3 → 4 → 5. 각 단계에서 호스트 블록을 전부 끝낸 뒤 다음 단계로 간다. **블록은 반드시 그
호스트에서** 실행한다(블록마다 node 번호가 다르다). eternity2/3 도 push 용으로 node4/5/6 을 붙이므로 같이
끊고 다시 붙인다. 스토리지 재부팅·파일 백엔드 상태에서의 복구는 6단계, 원복은 7단계.

## 1. 정지·백업·분리

eternity4
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
sudo tar -C /mnt/raftvol -cf /var/tmp/raftvol-bak-20261113.tar etcd
sudo umount /mnt/raftvol
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

eternity5
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
sudo tar -C /mnt/raftvol -cf /var/tmp/raftvol-bak-20261113.tar etcd fio_test
sudo umount /mnt/raftvol
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

eternity6
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
sudo tar -C /mnt/raftvol -cf /var/tmp/raftvol-bak-20261113.tar etcd
sudo umount /mnt/raftvol
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

eternity2
```bash
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

eternity3
```bash
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

## 2. 스토리지: ext4 → 64GiB vol.img → loop → namespace

- `lazy_itable_init=0,lazy_journal_init=0`: 기본값이면 마운트 뒤 ext4lazyinit 가 백그라운드로 inode 테이블을 써서
  측정 중 SSD 트래픽이 섞인다.
- vol.img 는 dd 로 끝까지 써서 할당한다(`fallocate` 만 하면 unwritten extent 변환이 측정에 섞인다). 세 SSD 병렬, 각 1분 안팎.
  `filefrag ... | grep -c unwritten` 은 세 줄 모두 `0`.
- `losetup -l` 에서 세 loop 모두 `LOG-SEC 512`, `DIO 0`.

eternitystorage
```bash
pgrep -af raft_blockcopy || echo "blockcopy not running"
cd /sys/kernel/config/nvmet/subsystems
echo 0 | sudo tee node4/namespaces/10/enable node5/namespaces/10/enable node6/namespaces/10/enable
sudo mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 -L nvmet-node4 /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494
sudo mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 -L nvmet-node5 /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496
sudo mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 -L nvmet-node6 /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484
sudo mkdir -p /mnt/nvmet/node4 /mnt/nvmet/node5 /mnt/nvmet/node6
sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494 /mnt/nvmet/node4
sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496 /mnt/nvmet/node5
sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484 /mnt/nvmet/node6
sudo dd if=/dev/zero of=/mnt/nvmet/node4/vol.img bs=4M count=16384 oflag=direct conv=fsync status=none &
sudo dd if=/dev/zero of=/mnt/nvmet/node5/vol.img bs=4M count=16384 oflag=direct conv=fsync status=none &
sudo dd if=/dev/zero of=/mnt/nvmet/node6/vol.img bs=4M count=16384 oflag=direct conv=fsync status=none &
wait
ls -l /mnt/nvmet/node4/vol.img /mnt/nvmet/node5/vol.img /mnt/nvmet/node6/vol.img
sudo filefrag -v /mnt/nvmet/node4/vol.img | grep -c unwritten
sudo filefrag -v /mnt/nvmet/node5/vol.img | grep -c unwritten
sudo filefrag -v /mnt/nvmet/node6/vol.img | grep -c unwritten
L4=$(sudo losetup --find --show --sector-size 512 --direct-io=off /mnt/nvmet/node4/vol.img)
L5=$(sudo losetup --find --show --sector-size 512 --direct-io=off /mnt/nvmet/node5/vol.img)
L6=$(sudo losetup --find --show --sector-size 512 --direct-io=off /mnt/nvmet/node6/vol.img)
echo "node4=$L4 node5=$L5 node6=$L6"
sudo losetup -l -O NAME,BACK-FILE,LOG-SEC,DIO
echo 0 | sudo tee node4/namespaces/10/buffered_io node5/namespaces/10/buffered_io node6/namespaces/10/buffered_io
echo -n "$L4" | sudo tee node4/namespaces/10/device_path
echo -n "$L5" | sudo tee node5/namespaces/10/device_path
echo -n "$L6" | sudo tee node6/namespaces/10/device_path
echo 1 | sudo tee node4/namespaces/10/enable node5/namespaces/10/enable node6/namespaces/10/enable
grep -H . node4/namespaces/10/device_path node4/namespaces/10/enable node5/namespaces/10/device_path node5/namespaces/10/enable node6/namespaces/10/device_path node6/namespaces/10/enable
```

## 3. 다시 붙이기 + 컴퓨트 ext4

- 첫 줄은 ARP 고정이다: 스토리지 IB 두 포트가 같은 /24 라 10.0.0.91 을 ibp216s0(…0d:ff:de)로 배우면 `nvme connect` 가
  `Connection reset by peer` 로 거절된다. `ip neigh show` 가 `…0e:00:4e PERMANENT` 여야 한다.
- `lsblk` 가 `64G` 와 LOG-SEC `512` 를 보여야 한다. 아니면 **멈추고** mkfs 로 가지 않는다. 연결이 실패하면 `DEV` 가 비어
  mkfs/mount 가 실패하고, tar 는 마운트되지 않은 /mnt/raftvol(루트 fs)에 풀린다.

eternity4
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo udevadm settle
DEV=$(bash -c 'source /home/jongc/raftof_clean/env.sh >/dev/null 2>&1; dev_for_nqn node4')
echo "node4 -> $DEV"
lsblk -no NAME,SIZE,LOG-SEC "$DEV"
```

위 출력이 맞으면 같은 터미널에서:

eternity4
```bash
sudo mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 "$DEV"
sudo mount "$DEV" /mnt/raftvol
sudo tar -C /mnt/raftvol -xf /var/tmp/raftvol-bak-20261113.tar
sudo mkdir -p /mnt/raftvol/node4
findmnt -n -o SOURCE,SIZE /mnt/raftvol
ls /mnt/raftvol
```

eternity5
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo udevadm settle
DEV=$(bash -c 'source /home/jongc/raftof_clean/env.sh >/dev/null 2>&1; dev_for_nqn node5')
echo "node5 -> $DEV"
lsblk -no NAME,SIZE,LOG-SEC "$DEV"
```

위 출력이 맞으면 같은 터미널에서:

eternity5
```bash
sudo mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 "$DEV"
sudo mount "$DEV" /mnt/raftvol
sudo tar -C /mnt/raftvol -xf /var/tmp/raftvol-bak-20261113.tar
sudo mkdir -p /mnt/raftvol/node5
findmnt -n -o SOURCE,SIZE /mnt/raftvol
ls /mnt/raftvol
```

eternity6
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo udevadm settle
DEV=$(bash -c 'source /home/jongc/raftof_clean/env.sh >/dev/null 2>&1; dev_for_nqn node6')
echo "node6 -> $DEV"
lsblk -no NAME,SIZE,LOG-SEC "$DEV"
```

위 출력이 맞으면 같은 터미널에서:

eternity6
```bash
sudo mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 "$DEV"
sudo mount "$DEV" /mnt/raftvol
sudo tar -C /mnt/raftvol -xf /var/tmp/raftvol-bak-20261113.tar
sudo mkdir -p /mnt/raftvol/node6
findmnt -n -o SOURCE,SIZE /mnt/raftvol
ls /mnt/raftvol
```

eternity2
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$"
```

eternity3
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$"
```

## 4. I/O 큐 재검사 (재연결로 큐 배치가 바뀌었다)

클러스터 전체가 멈춘 상태에서. 세 호스트를 동시에 실행해도 잠금 파일로 차례대로 돈다.

eternity4
```bash
cd /home/jongc/raftof_clean
sudo ./scripts/probe_io_queues.sh 4 5 6
```

eternity5
```bash
cd /home/jongc/raftof_clean
sudo ./scripts/probe_io_queues.sh 4 5 6
```

eternity6
```bash
cd /home/jongc/raftof_clean
sudo ./scripts/probe_io_queues.sh 4 5 6
```

## 5. blockcopy 서버 기동

먼저 env.sh POOL 의 node4/5/6 storage_dev(4번째 열)를 vol.img 로 바꾼다(원복 때 원래 by-id 로 되돌려 둔다). grep 에서 세 줄이
`/mnt/nvmet/node<ID>/vol.img` 여야 한다. 배너에서 세 장치 모두 `== nvmet nodeN OK` 와 `read=buffered` 를 확인한다.

eternitystorage
```bash
cd /home/jongc/raftof_clean
sed -i 's#|node4|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494"#|node4|/mnt/nvmet/node4/vol.img"#' env.sh
sed -i 's#|node5|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496"#|node5|/mnt/nvmet/node5/vol.img"#' env.sh
sed -i 's#|node6|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484"#|node6|/mnt/nvmet/node6/vol.img"#' env.sh
grep -nE "node[456]\|" env.sh
```


eternitystorage
```bash
cd /home/jongc/raftof_clean
./start_blockcopy.sh rdma
```

arm C 측정은 arm A 와 같은 명령으로 한다. 측정이 끝날 때마다:

eternitystorage
```bash
sudo dmesg | grep -i "invalidation failure" || echo "no DIO/page-cache collision"
grep -E "^(Cached|Dirty|Writeback):" /proc/meminfo
free -g | head -2
```

## 6. 복구: 스토리지 재부팅 후, 또는 파일 백엔드(LBA 4096) 상태에서 loop 로

스토리지를 재부팅하면 nvmet configfs, `/mnt/nvmet/*` 마운트(fstab 미등록), loop 장치가 모두 사라진다. vol.img 와 그 안의
컴퓨트 ext4 는 남아 있으므로 **mkfs·dd 없이** 붙이기만 다시 한다. 2026-11-13 처음 전환 때 파일 백엔드로 붙였던 상태에서
loop 로 바꾸는 것도 이 절차다. (재부팅으로 configfs 자체가 없으면 subsystem·port 부터 다시 만들어야 한다 — 이 절 범위 밖.)

eternity4
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
sudo umount /mnt/raftvol
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

eternity5
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
sudo umount /mnt/raftvol
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

eternity6
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
sudo umount /mnt/raftvol
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

eternity2
```bash
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

eternity3
```bash
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

`losetup -l` 에 vol.img 를 가리키는 loop 가 이미 있으면 먼저 `sudo losetup -d` 로 뗀 뒤 실행한다(중복 loop 방지).

eternitystorage
```bash
pgrep -af raft_blockcopy || echo "blockcopy not running"
cd /sys/kernel/config/nvmet/subsystems
echo 0 | sudo tee node4/namespaces/10/enable node5/namespaces/10/enable node6/namespaces/10/enable
sudo mkdir -p /mnt/nvmet/node4 /mnt/nvmet/node5 /mnt/nvmet/node6
findmnt /mnt/nvmet/node4 >/dev/null || sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494 /mnt/nvmet/node4
findmnt /mnt/nvmet/node5 >/dev/null || sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496 /mnt/nvmet/node5
findmnt /mnt/nvmet/node6 >/dev/null || sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484 /mnt/nvmet/node6
sudo losetup -l -O NAME,BACK-FILE
L4=$(sudo losetup --find --show --sector-size 512 --direct-io=off /mnt/nvmet/node4/vol.img)
L5=$(sudo losetup --find --show --sector-size 512 --direct-io=off /mnt/nvmet/node5/vol.img)
L6=$(sudo losetup --find --show --sector-size 512 --direct-io=off /mnt/nvmet/node6/vol.img)
echo "node4=$L4 node5=$L5 node6=$L6"
sudo losetup -l -O NAME,BACK-FILE,LOG-SEC,DIO
echo 0 | sudo tee node4/namespaces/10/buffered_io node5/namespaces/10/buffered_io node6/namespaces/10/buffered_io
echo -n "$L4" | sudo tee node4/namespaces/10/device_path
echo -n "$L5" | sudo tee node5/namespaces/10/device_path
echo -n "$L6" | sudo tee node6/namespaces/10/device_path
echo 1 | sudo tee node4/namespaces/10/enable node5/namespaces/10/enable node6/namespaces/10/enable
grep -H . node4/namespaces/10/device_path node4/namespaces/10/enable node5/namespaces/10/device_path node5/namespaces/10/enable node6/namespaces/10/device_path node6/namespaces/10/enable
```

다시 붙이기 (mkfs 없음):

eternity4
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo udevadm settle
DEV=$(bash -c 'source /home/jongc/raftof_clean/env.sh >/dev/null 2>&1; dev_for_nqn node4')
echo "node4 -> $DEV"
lsblk -no NAME,SIZE,LOG-SEC "$DEV"
sudo mount "$DEV" /mnt/raftvol
ls /mnt/raftvol
```

eternity5
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo udevadm settle
DEV=$(bash -c 'source /home/jongc/raftof_clean/env.sh >/dev/null 2>&1; dev_for_nqn node5')
echo "node5 -> $DEV"
lsblk -no NAME,SIZE,LOG-SEC "$DEV"
sudo mount "$DEV" /mnt/raftvol
ls /mnt/raftvol
```

eternity6
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo udevadm settle
DEV=$(bash -c 'source /home/jongc/raftof_clean/env.sh >/dev/null 2>&1; dev_for_nqn node6')
echo "node6 -> $DEV"
lsblk -no NAME,SIZE,LOG-SEC "$DEV"
sudo mount "$DEV" /mnt/raftvol
ls /mnt/raftvol
```

eternity2
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$"
```

eternity3
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$"
```

그 뒤 4단계(큐 재검사), 5단계(blockcopy 기동).

## 7. 원복 (SSD 를 bdev 로 직접 내보내던 구성으로)

1단계를 그대로 한 뒤(tar 파일 이름은 `raftvol-bak-20261114.tar` 등으로 바꿀 것), 스토리지에서. loop 구성(C)과
XFS 파일 백엔드 구성(C′) 모두 이 절차다. 블록은 둘로 나눈다: 첫 블록 끝 `findmnt` 가 아무것도 안 찍어야 둘째 블록으로
간다(스토리지 FS 가 마운트된 채로 SSD 를 bdev 로 켜면 컴퓨트 mkfs 와 스토리지 FS 가 같은 장치를 동시에 쓴다).

eternitystorage
```bash
cd /home/jongc/raftof_clean
./stop_blockcopy.sh
pgrep -af raft_blockcopy || echo "blockcopy stopped"
cd /sys/kernel/config/nvmet/subsystems
echo 0 | sudo tee node4/namespaces/10/enable node5/namespaces/10/enable node6/namespaces/10/enable
echo 0 | sudo tee node4/namespaces/10/buffered_io node5/namespaces/10/buffered_io node6/namespaces/10/buffered_io
echo -n /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494 | sudo tee node4/namespaces/10/device_path
echo -n /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496 | sudo tee node5/namespaces/10/device_path
echo -n /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484 | sudo tee node6/namespaces/10/device_path
losetup -l -n -O NAME -j /mnt/nvmet/node4/vol.img | xargs -r -n1 sudo losetup -d
losetup -l -n -O NAME -j /mnt/nvmet/node5/vol.img | xargs -r -n1 sudo losetup -d
losetup -l -n -O NAME -j /mnt/nvmet/node6/vol.img | xargs -r -n1 sudo losetup -d
sudo umount /mnt/nvmet/node4 /mnt/nvmet/node5 /mnt/nvmet/node6
findmnt -rn -o SOURCE,TARGET,FSTYPE | grep nvmet
```

eternitystorage
```bash
cd /sys/kernel/config/nvmet/subsystems
echo 1 | sudo tee node4/namespaces/10/enable node5/namespaces/10/enable node6/namespaces/10/enable
grep -H . node4/namespaces/10/device_path node4/namespaces/10/buffered_io node4/namespaces/10/enable node5/namespaces/10/device_path node5/namespaces/10/buffered_io node5/namespaces/10/enable node6/namespaces/10/device_path node6/namespaces/10/buffered_io node6/namespaces/10/enable
```

그 뒤 3단계(컴퓨트 mkfs.ext4 포함, `lsblk` 는 894.3G / LOG-SEC 512), 4단계를 하고 env.sh POOL 의 node4/5/6
storage_dev 를 by-id 로 되돌린 뒤 blockcopy 를 기동한다(배너 by-id, `read=direct`). 2026-11-14 원복 때는 env.sh 를
`git checkout` 으로 되돌렸다(D24 변경만 있던 파일). 다른 변경이 섞여 있으면 아래 sed 로:

eternitystorage
```bash
cd /home/jongc/raftof_clean
sed -i 's#|node4|/mnt/nvmet/node4/vol.img"#|node4|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494"#' env.sh
sed -i 's#|node5|/mnt/nvmet/node5/vol.img"#|node5|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496"#' env.sh
sed -i 's#|node6|/mnt/nvmet/node6/vol.img"#|node6|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484"#' env.sh
grep -nE "node[456]\|" env.sh
```

## 8. 추적: loop 구성의 쓰기 경로 분해 (256K, destination)

목적: arm C 에서 LPersist(= normal 모드 StorageIO, 같은 경로)가 256K 에서 +200us 늘어난 원인을 스토리지에서
나눈다. `scripts/trace_loop_persist.bt` 가 loop WRITE(page cache 복사)와 loop FLUSH(vfs_fsync)를 잡고, FLUSH 안을
writeback 대기 / 저널 커밋 대기 / SSD flush 로 나눈다. 블록 장치 요청 크기 분포(writeback 이 쪼개지는지)와
jbd2 커밋 시간도 같이 낸다. kprobe 비용이 더해지므로 이 런의 apply-timed 수치는 비교 측정에 쓰지 않는다.
destination 모드에서는 팔로워 볼륨은 blockcopy 가 vol.img 에 직접 쓰므로 loop 의 256K WRITE 는 리더 것뿐이다.

순서: (1) 스토리지 터미널에서 추적 시작 → (2) 노드 기동 → (3) 클라이언트 측정 → (4) 스토리지에서 Ctrl-C.

(1) eternitystorage — 장치 번호표를 찍고 추적을 시작한다(이 터미널은 Ctrl-C 할 때까지 그대로 둔다)
```bash
cd /home/jongc/raftof_clean
sudo losetup -l -O NAME,BACK-FILE
lsblk -dno NAME,MAJ:MIN /dev/loop0 /dev/loop1 /dev/loop2
ls -l /dev/disk/by-id/ | grep -E "S437NA0N5094(94|96|84) "
lsblk -dno NAME,MAJ:MIN /dev/nvme10n1 /dev/nvme12n1 /dev/nvme13n1
sudo bpftrace -l "kprobe:do_writepages"
pgrep -af raft_blockcopy || ./start_blockcopy.sh rdma
sudo bpftrace -o /home/jongc/raftof_clean/results/trace_loop_256k_dest2.txt scripts/trace_loop_persist.bt
```

(2) 노드 기동 (destination)

eternity4
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
./start_node.sh 4 destination rdma
```

eternity5
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
./start_node.sh 5 destination rdma
```

eternity6
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
./start_node.sh 6 destination rdma
```

(3) eternity5 — 256K 한 크기만 한 번. `ls` 에 `apply-timed-r1-262144.log` 만 있어야 한다
(1차 추적은 세 크기가 섞여 FLUSH 통계가 평균이 됐다).
```bash
cd /home/jongc/raftof_clean
sudo env SIZES=262144 REPS=1 ./scripts/size_breakdown_sweep.sh rdma csv/trace_256k_dest2
ls csv/trace_256k_dest2
```

(4) eternitystorage — (1) 의 터미널에서 Ctrl-C. 결과는 `results/trace_loop_256k_dest2.txt`.
1차 결과(`results/trace_loop_256k_dest.txt`, 세 크기 혼합)는 비교용으로 남겨 둔다.

## 9. arm C′: loop 제거 — 스토리지 FS 를 XFS v4(512B 블록)로, nvmet 파일 백엔드

목적: arm C 쓰기 손해 중 loop 가 만든 몫(저널 커밋 47us, loop 큐 ~7us)을 뺀다. 최종 구성:

```
컴퓨트 ext4 ─NVMe-oF→ nvmet (파일 백엔드, buffered_io=1, LBA 512)
                       → /mnt/nvmet/node<ID>/vol.img (64GiB, 스토리지 XFS v4 bsize=512) → page cache → PM983
blockcopy: -devices 는 vol.img (env.sh POOL 을 9-5 에서 바꾼다, 배너 read=buffered)
```

- **왜 512 가 되나:** 파일 백엔드 LBA = `min(i_blkbits, 12)`. XFS v4 는 512B 블록이 가능해 i_blkbits=9 → LBA 512.
  ext4(최소 1K), XFS v5(최소 1K)로는 안 된다. v4 는 폐기 예정 포맷이라 마운트 때 dmesg 에 경고가 나온다(정상).
- **flush 가 달라진다:** 파일 백엔드 flush = `vfs_fsync(file, 1)`(fdatasync). 미리 다 쓴 vol.img 는 시각만 바뀌므로
  로그 강제 없이 끝날 것으로 예상(측정으로 확인할 것). 복사(~100us)와 writeback 은 그대로 남는다.
- `mkfs.xfs -b size=512 -m crc=0` 만 주면 reflink/finobt/rmapbt/bigtime/inobtcount/sparse 는 자동으로 꺼진다
  (mkfs.xfs 6.6 에서 확인).
- **지워지는 것:** node4/5/6 의 스토리지 ext4 와 vol.img(그 안의 컴퓨트 ext4 전체). etcd 는 tar 로 되돌린다
  (2026-11-14 실행 때는 `/var/tmp/raftvol-bak-20261113.tar`; 원복 때 `raftvol-bak-20261114.tar` 를 새로 떴으니 다음에는
  그것을 쓰거나 9-1 에서 새로 뜬다). eternity2/3 은 2026-11-14 시점에 node4/5/6 을 붙이고 있지 않아 이 절에서 건드리지
  않았다 — 다시 할 때 `nvme list-subsys` 로 확인할 것.
- 순서: 9-1 → 9-2 → 9-3 → 9-4 → 9-5. 블록은 반드시 그 호스트에서.

### 9-1. 컴퓨트 정지·분리

eternity4
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
sudo umount /mnt/raftvol
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

eternity5
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
sudo umount /mnt/raftvol
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

eternity6
```bash
cd /home/jongc/raftof_clean
./stop_node.sh
sudo umount /mnt/raftvol
sudo nvme disconnect -n node4
sudo nvme disconnect -n node5
sudo nvme disconnect -n node6
sudo nvme list-subsys | grep -E "NQN=node[456]$" || echo "node4/5/6 detached"
```

### 9-2. 스토리지: loop 분리 → XFS v4 512B → vol.img → 파일 백엔드

확인할 출력:
- `losetup -l` 에 vol.img 를 가리키는 loop 가 없어야 한다.
- `xfs_info` 세 개 모두 `crc=0` 과 data 줄 `bsize=512`.
- `filefrag ... | grep -c unwritten` 세 줄 모두 `0`.
- 마지막 grep 에서 device_path = vol.img, buffered_io = 1, enable = 1.

블록은 두 개로 나눈다. 첫 블록 끝에서 `findmnt` 가 아무것도 안 찍어야(= 세 마운트가 풀림) 둘째 블록으로 간다.
umount 가 `target is busy` 면 blockcopy 가 vol.img 를 잡고 있는 것이다(2026-11-14: 한 블록으로 붙였다가 umount 실패
→ mkfs 거부 → dd 가 옛 ext4 위 vol.img 를 덮고 파일 백엔드가 ext4 위로 켜졌다).

eternitystorage
```bash
cd /home/jongc/raftof_clean
./stop_blockcopy.sh
pgrep -af raft_blockcopy || echo "blockcopy stopped"
cd /sys/kernel/config/nvmet/subsystems
echo 0 | sudo tee node4/namespaces/10/enable node5/namespaces/10/enable node6/namespaces/10/enable
losetup -l -n -O NAME -j /mnt/nvmet/node4/vol.img | xargs -r -n1 sudo losetup -d
losetup -l -n -O NAME -j /mnt/nvmet/node5/vol.img | xargs -r -n1 sudo losetup -d
losetup -l -n -O NAME -j /mnt/nvmet/node6/vol.img | xargs -r -n1 sudo losetup -d
sudo losetup -l -O NAME,BACK-FILE
sudo umount /mnt/nvmet/node4 /mnt/nvmet/node5 /mnt/nvmet/node6
findmnt -rn -o SOURCE,TARGET,FSTYPE | grep nvmet
```

eternitystorage
```bash
cd /sys/kernel/config/nvmet/subsystems
sudo mkfs.xfs -q -f -b size=512 -m crc=0 -L nvmet-node4 /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494
sudo mkfs.xfs -q -f -b size=512 -m crc=0 -L nvmet-node5 /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496
sudo mkfs.xfs -q -f -b size=512 -m crc=0 -L nvmet-node6 /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484
sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494 /mnt/nvmet/node4
sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496 /mnt/nvmet/node5
sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484 /mnt/nvmet/node6
xfs_info /mnt/nvmet/node4 | grep -E "crc=|^data"
xfs_info /mnt/nvmet/node5 | grep -E "crc=|^data"
xfs_info /mnt/nvmet/node6 | grep -E "crc=|^data"
sudo dd if=/dev/zero of=/mnt/nvmet/node4/vol.img bs=4M count=16384 oflag=direct conv=fsync status=none &
sudo dd if=/dev/zero of=/mnt/nvmet/node5/vol.img bs=4M count=16384 oflag=direct conv=fsync status=none &
sudo dd if=/dev/zero of=/mnt/nvmet/node6/vol.img bs=4M count=16384 oflag=direct conv=fsync status=none &
wait
ls -l /mnt/nvmet/node4/vol.img /mnt/nvmet/node5/vol.img /mnt/nvmet/node6/vol.img
sudo filefrag -v /mnt/nvmet/node4/vol.img | grep -c unwritten
sudo filefrag -v /mnt/nvmet/node5/vol.img | grep -c unwritten
sudo filefrag -v /mnt/nvmet/node6/vol.img | grep -c unwritten
echo -n /mnt/nvmet/node4/vol.img | sudo tee node4/namespaces/10/device_path
echo -n /mnt/nvmet/node5/vol.img | sudo tee node5/namespaces/10/device_path
echo -n /mnt/nvmet/node6/vol.img | sudo tee node6/namespaces/10/device_path
echo 1 | sudo tee node4/namespaces/10/buffered_io node5/namespaces/10/buffered_io node6/namespaces/10/buffered_io
echo 1 | sudo tee node4/namespaces/10/enable node5/namespaces/10/enable node6/namespaces/10/enable
grep -H . node4/namespaces/10/device_path node4/namespaces/10/buffered_io node4/namespaces/10/enable node5/namespaces/10/device_path node5/namespaces/10/buffered_io node5/namespaces/10/enable node6/namespaces/10/device_path node6/namespaces/10/buffered_io node6/namespaces/10/enable
sudo dmesg | tail -n 20
```

### 9-3. 컴퓨트 다시 붙이기 + ext4

`lsblk` 가 `64G` 와 LOG-SEC **`512`** 여야 한다. `4096` 이면 **멈춘다**(파일 백엔드가 512 를 못 받은 것 — mkfs 로 가지 않는다).

eternity4
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo udevadm settle
DEV=$(bash -c 'source /home/jongc/raftof_clean/env.sh >/dev/null 2>&1; dev_for_nqn node4')
echo "node4 -> $DEV"
lsblk -no NAME,SIZE,LOG-SEC "$DEV"
```

위 출력이 맞으면 같은 터미널에서:

eternity4
```bash
sudo mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 "$DEV"
sudo mount "$DEV" /mnt/raftvol
sudo tar -C /mnt/raftvol -xf /var/tmp/raftvol-bak-20261113.tar
sudo mkdir -p /mnt/raftvol/node4
findmnt -n -o SOURCE,SIZE /mnt/raftvol
ls /mnt/raftvol
```

eternity5
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo udevadm settle
DEV=$(bash -c 'source /home/jongc/raftof_clean/env.sh >/dev/null 2>&1; dev_for_nqn node5')
echo "node5 -> $DEV"
lsblk -no NAME,SIZE,LOG-SEC "$DEV"
```

위 출력이 맞으면 같은 터미널에서:

eternity5
```bash
sudo mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 "$DEV"
sudo mount "$DEV" /mnt/raftvol
sudo tar -C /mnt/raftvol -xf /var/tmp/raftvol-bak-20261113.tar
sudo mkdir -p /mnt/raftvol/node5
findmnt -n -o SOURCE,SIZE /mnt/raftvol
ls /mnt/raftvol
```

eternity6
```bash
sudo ip neigh replace 10.0.0.91 lladdr 00:00:10:29:fe:80:00:00:00:00:00:00:b8:3f:d2:03:00:0e:00:4e dev ibp59s0 nud permanent
ip neigh show 10.0.0.91
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node4
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node5
sudo nvme connect -t rdma -a 10.0.0.91 -s 4420 -i 8 -n node6
sudo udevadm settle
DEV=$(bash -c 'source /home/jongc/raftof_clean/env.sh >/dev/null 2>&1; dev_for_nqn node6')
echo "node6 -> $DEV"
lsblk -no NAME,SIZE,LOG-SEC "$DEV"
```

위 출력이 맞으면 같은 터미널에서:

eternity6
```bash
sudo mkfs.ext4 -q -F -E lazy_itable_init=0,lazy_journal_init=0 "$DEV"
sudo mount "$DEV" /mnt/raftvol
sudo tar -C /mnt/raftvol -xf /var/tmp/raftvol-bak-20261113.tar
sudo mkdir -p /mnt/raftvol/node6
findmnt -n -o SOURCE,SIZE /mnt/raftvol
ls /mnt/raftvol
```

### 9-4. I/O 큐 재검사

eternity4
```bash
cd /home/jongc/raftof_clean
sudo ./scripts/probe_io_queues.sh 4 5 6
```

eternity5
```bash
cd /home/jongc/raftof_clean
sudo ./scripts/probe_io_queues.sh 4 5 6
```

eternity6
```bash
cd /home/jongc/raftof_clean
sudo ./scripts/probe_io_queues.sh 4 5 6
```

### 9-5. blockcopy 기동과 측정

먼저 env.sh POOL 을 vol.img 로 바꾼다(5단계의 sed 블록과 같다 — 원복 때 by-id 로 되돌려 두었다). 배너에서 세 장치 모두
`== nvmet nodeN OK`(device_path 가 vol.img 그대로라 직접 비교) 와 `read=buffered`.

eternitystorage
```bash
cd /home/jongc/raftof_clean
sed -i 's#|node4|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494"#|node4|/mnt/nvmet/node4/vol.img"#' env.sh
sed -i 's#|node5|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496"#|node5|/mnt/nvmet/node5/vol.img"#' env.sh
sed -i 's#|node6|/dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484"#|node6|/mnt/nvmet/node6/vol.img"#' env.sh
grep -nE "node[456]\|" env.sh
./start_blockcopy.sh rdma
```

측정은 arm A/C 와 같은 명령(노드를 destination / normal 로 띄우고 eternity5 에서 `sudo ./scripts/size_breakdown_sweep.sh rdma
csv/<디렉터리>`; 2026-11-14 는 csv/armCp_dest, csv/armCp_normal). 측정이 끝날 때마다 5단계의 점검 블록(invalidation failure,
meminfo)을 **sudo 로** 돌린다. 8단계 추적 스크립트(`scripts/trace_loop_persist.bt`)는 loop probe 라 C′ 에서는 쓰기 경로를
나누지 못한다(C′ 용 probe 는 아직 없다).

### 9-6. C′ 에서 스토리지 재부팅 후 복구

컴퓨트 분리/다시 붙이기는 6단계 블록 그대로(mkfs 없음). 스토리지 블록만 아래로 바꾼다.

eternitystorage
```bash
cd /sys/kernel/config/nvmet/subsystems
echo 0 | sudo tee node4/namespaces/10/enable node5/namespaces/10/enable node6/namespaces/10/enable
sudo mkdir -p /mnt/nvmet/node4 /mnt/nvmet/node5 /mnt/nvmet/node6
findmnt /mnt/nvmet/node4 >/dev/null || sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509494 /mnt/nvmet/node4
findmnt /mnt/nvmet/node5 >/dev/null || sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509496 /mnt/nvmet/node5
findmnt /mnt/nvmet/node6 >/dev/null || sudo mount -o noatime /dev/disk/by-id/nvme-SAMSUNG_MZQLB960HAJR-00007_S437NA0N509484 /mnt/nvmet/node6
echo -n /mnt/nvmet/node4/vol.img | sudo tee node4/namespaces/10/device_path
echo -n /mnt/nvmet/node5/vol.img | sudo tee node5/namespaces/10/device_path
echo -n /mnt/nvmet/node6/vol.img | sudo tee node6/namespaces/10/device_path
echo 1 | sudo tee node4/namespaces/10/buffered_io node5/namespaces/10/buffered_io node6/namespaces/10/buffered_io
echo 1 | sudo tee node4/namespaces/10/enable node5/namespaces/10/enable node6/namespaces/10/enable
grep -H . node4/namespaces/10/device_path node4/namespaces/10/buffered_io node5/namespaces/10/device_path node5/namespaces/10/buffered_io node6/namespaces/10/device_path node6/namespaces/10/buffered_io
```

원복은 7단계 그대로 된다(losetup 줄은 loop 가 없으면 아무것도 안 한다, buffered_io 0 줄 포함).
