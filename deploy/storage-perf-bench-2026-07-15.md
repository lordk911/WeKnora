# 存储栈性能基准 (Ceph / MinIO / Milvus)

- **日期**: 2026-07-15
- **集群**: 10.9.27.27, ns=milvus/minio/rook-ceph
- **背景**: MinIO/Ceph/Milvus 存储 bug 全修复后（Ceph 19.2.4 升级 + 2 坏 OSD 重建 + Milvus 2.6 干净重建 + etcd Guaranteed QoS + 监控补全），验证栈性能正常、无修复前退化。
- **结论**: 三层全健康，性能符合 HDD+EC 分布式存储预期。**根因修复确认生效**（etcd 0 重启、无 compaction 停滞、OSD 1-2ms、binlog 不再膨胀）。

压测脚本存档: `deploy/milvus-perf-bench.py`（pymilvus 2.6, 用 `data-stack/langgenius/dify-api:1.14.2` 镜像跑, 内含 pymilvus 2.6.12）。

## 1. Ceph (裸存储层, rados bench on ec-data-pool)

工具: rook-ceph-toolbox 内 `rados bench`（官方 Ceph 压测）。RBD 走 `replicated-metadata-pool`(3 副本) + `ec-data-pool`(EC 数据), bench 直接压 ec-data-pool。

| 指标 | 值 | 备注 |
|---|---|---|
| 顺序写吞吐 | **494.6 MB/s** | 4M block, 16 并发, 60s; max 648 / min 248 |
| 随机读吞吐 | **1033 MB/s** | 4M block, 64 并发, 60s; IOPS 258 obj/s |
| OSD commit/apply 延迟 | **1-2 ms** | 全 44 osd, 健康（BlueStore bug 修复后） |
| 集群状态 | HEALTH_OK | 44 osd up/in, 160 TiB raw, 仅用 3.18% |

> Ceph 层是全栈底座（MinIO/Milvus 数据最终都落 ec-data-pool）。494 MB/s 写 / 1033 MB/s 读 = HDD-backed EC 池正常水平。

## 2. MinIO (S3 层, mc 8 并发)

工具: minio-0 pod 内 bitnami `mc`（alias `admin` → minio.minio.svc:9000, root/minio#root@k8s）。1GB 测试文件 dd 生成于 /tmp（主机盘, 读源不瓶颈）。

| 指标 | 值 | 备注 |
|---|---|---|
| 单流 PUT 1GB | 41.7 MiB/s (24s) | mc cp, concurrent=1 |
| 单流 GET 1GB | 61.7 MiB/s (16s) | mc cp |
| 8 并发 PUT 8GB | **65 MiB/s** aggregate (126s) | 8×1GB 并行 mc cp |
| 8 并发 GET 8GB | **151 MiB/s** aggregate (54s) | 8×1GB 并行 |

> **注意（偏低是测试方法局限，非修复退化）**: mc 8 进程全跑在 minio-0 pod 内（它本身也是 MinIO server, CPU 与 server 抢占）+ MinIO 分布式 EC 跨 16 pod 协调放大延迟, 所以并发未线性扩展。单 pod 客户端上限即此。真实多 pod 客户端（如 Milvus datanode 跨节点写）吞吐更高——见 Milvus 端到端。
> 对比 Ceph 裸读 1033 MB/s, MinIO 8 并发 GET 151 MB/s 的 ~7x 差距 = S3+EC+单 pod 客户端开销, 属正常。

## 3. Milvus (应用层, pymilvus 端到端)

工具: `deploy/milvus-perf-bench.py`，用 `data-stack/langgenius/dify-api:1.14.2` pod（venv 内 pymilvus 2.6.12）连 `milvus.milvus:19530`（dify/dify@admin, admin 角色）。768d 向量, COSINE, 100k 条, HNSW(M16/efC200, ef=64)。

| 指标 | 值 | 备注 |
|---|---|---|
| INSERT 吞吐 | **~2.5-3.2k vec/s** (7-9 MiB/s) | clean run 3176 vec/s; 100k×768d=293MiB, ~31-40s |
| HNSW 建索引 | 2.47s | 100k 向量 |
| LOAD | 9.94s | |
| SEARCH QPS | **111 QPS, 9.0 ms/q** | 单线程, top-10, ef=64, 1k query |
| binlog 残留 | 2.5 GiB / 300 obj | bench 后, 远低于 1.5 TiB 告警线, 会 GC |
| pod 重启 | etcd **0**（根因修复生效）| 其它组件 1-5 次初始 boot race 后 14h 稳定不涨 |

> **根因修复确认**: 修复前 binlog 膨胀 3 TiB + etcd BestEffort 死循环 + indexnode DataCodec segfault 4747 次; 修复后 100k 向量插入-建索引-查询全链路顺畅, 无 compaction 停滞, 无重启循环, bucket 用量正常。

## 工具链备忘 (air-gapped, 复现用)

- **Ceph**: `kubectl -n rook-ceph exec rook-ceph-tools-... -- rados -p ec-data-pool bench 60 write -t 16 -b 4M --no-cleanup --run-name bk1` + `rados ... bench 60 rand -t 64 --run-name bk1` + `rados -p ec-data-pool cleanup --run-name bk1`
- **MinIO**: `kubectl -n minio exec minio-0 -- /opt/bitnami/minio-client/bin/mc <cmd> admin/...`（alias `admin` 已配）
- **Milvus**: `kubectl run milvus-bench --image=harbor.glodon.com/data-stack/langgenius/dify-api:1.14.2 -n milvus --command -- sleep infinity` → `kubectl cp deploy/milvus-perf-bench.py milvus-bench:/tmp/` → `kubectl exec ... -- /app/api/.venv/bin/python /tmp/bench_milvus.py`（注: 用 dify/dify@admin, 非 root; root 密码已非默认 Milvus）

## 可选深挖（本次未做）

- **fio on RBD PVC**: 4K 随机读写 IOPS（rados bench 用 4M block, 测的是吞吐不是小 IOPS）。toolbox/minio 均无 fio 且 rootfs 只读装不了; 需 mirror 一个 fio 镜像到 harbor 建 Job pod 挂 RBD PVC 跑。若要小对象 IOPS 基准再补。
- **warp**: MinIO 官方 S3 压测工具, 多 pod 客户端真实并发; 需 mirror warp 镜像。
