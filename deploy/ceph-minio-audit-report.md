# WeKnora 集群基础设施审计报告

**审计日期**: 2026-07-14
**审计范围**: Ceph 19.2.2 (Squid) + MinIO + 监控栈 + 节点/Pod QoS
**集群**: glodon 内网 k8s v1.32.5, 6 worker (25/26/41-gpu/42-gpu) + 3 control-plane (27/28/29)
**审计方式**: 全部 read-only

---

## 1. 当前状态总览

### 1.1 Ceph (rook-ceph ns)

| 维度 | 数值 | 状态 |
|---|---|---|
| cluster id | 58f4b068-9049-4891-bec6-7b57c28a2caa | – |
| 健康 | HEALTH_WARN | ⚠ |
| 告警 | 2 pgs not scrubbed + 2 pgs not deep-scrubbed + 13 daemons recently crashed | ⚠ |
| OSD | 44 total, 42 up/in, **2 down/out** (osd.4、osd.14) | ⚠ |
| Pool | 7 pools, 177 pgs, 174 active+clean + 3 scrubbing | – |
| 容量 | 5.1 TiB / 153 TiB (3.3% used) | OK |
| 数据吞吐 | 142 KiB/s rd + 3.6 MiB/s wr, 36 op/s rd + 278 op/s wr | OK |
| Mon | 3 daemons, quorum a,d,e (age 11M) | OK |
| Mgr | b active (7M) + a standby | OK |
| MDS (cephfs) | 1+1 (1 active + 1 hot standby) | OK |
| 客户端 | 5 cephfs 客户端 | – |

**坏 OSD 详情** (从 `ceph crash info` 拿到根因)：

| OSD | 节点 | 首次崩溃 | 累计次数 | 根因 |
|---|---|---|---|---|
| osd.4 | xa-k8s-node25 | 2026-07-13 20:21 | 7 次 (13 日) | BlueStore assertion `diff <= bytes_per_au[pos]` at bluestore_types.cc:511 (Ceph 19.2.2 已知 bug, ECBackend::commit_txn_send_replies 路径) |
| osd.14 | xa-k8s-node26 | 2026-07-14 05:40 | 13 次 (14 日) | 同上 (OSD::dequeue_delete 路径) |

**根因**: 这是 Ceph Squid **19.2.2 软件层 bug** (BlueStore Blob::put_ref 期间 punch_hole/truncate 事务触发 `ceph_assert(diff <= bytes_per_au[pos])`)。**销毁 OSD 重建不会修复** — bug 在 ceph-osd 进程代码里，需升级到 19.2.3+ 或 19.2.2 后续修复版本。

**PG not scrubbed**: pg 3.1 (自 2026-06-08) 和 pg 3.2 (自 2026-06-08) — 这 2 个 PG 大概率托管在已 down 的 osd.4/14 上，需要把 OSD 恢复后才会自动补 scrub。

### 1.2 MinIO (minio ns)

| 维度 | 数值 | 状态 |
|---|---|---|
| StatefulSet | minio, 16/16 ready | OK |
| 副本分布 | 25(2) 26(3) 27(3) 28(3) 41-gpu(2) 42-gpu(3) | OK, 6 节点均衡 |
| 版本 | 2025.5.24 (chart 17.0.2) | – |
| QoS | Burstable (req 1 CPU/2Gi, lim 2 CPU/4Gi) | OK |
| 探针 | startup TCP/5s×30 + liveness HTTP /minio/health/live (10s×5) + readiness TCP (5s×5) | OK, 合理 |
| 启动时间 | 11d (无近期重启，仅 minio-1/7/11/13 在 20h 前各 1 次) | OK |
| Service | minio:9000 + minio-console:9090 + minio-headless | OK |
| PVC | 16 pod × 4 卷 = 64 RWO 50Gi PVCs (rook-ceph-block) | OK |
| 5 天前 | minio-console 重启过 (但当前 4h47m 稳) | – |
| Console | Burstable (200m/256Mi req, 1/512Mi lim) | OK |

**桶内容** (尝试 `mc du` 被 minio 自身权限拦截，需要从 host 端用 root key 查) — 已知 milvus bucket 之前被 milvus binlog 写满 3 TiB 后已清，但当前实际占用没拿到。

### 1.3 监控栈 (prometheus ns)

| 组件 | 状态 | 备注 |
|---|---|---|
| prometheus-prometheus-stack-kube-prom-prometheus-0 | 2/2 Running (2 restarts 16h ago) | ⚠ 有近期重启 |
| prometheus-stack-grafana-0 | 3/3 Running (**8 restarts 12h ago**) | ⚠ 频繁重启 |
| prometheus-stack-kube-prom-operator | 1/1 Running | OK |
| prometheus-stack-kube-state-metrics | 1/1 Running | OK |
| **alertmanager-prometheus-stack-kube-prom-alertmanager** | **0/1 (down)** | ❌ **严重** |
| **metrics-server** | **未安装** | ❌ `kubectl top` 不可用 |
| **ServiceMonitor (整个集群)** | **全空** | ❌ ceph/minio/milvus 均未被抓取 |
| **PrometheusRule (整个集群)** | **全空** | ❌ 无业务告警规则 |

### 1.4 Pod QoS 全景 (Milvus 教训对照)

| 组件 | QoS | Requests | Limits | 探针评估 | 风险 |
|---|---|---|---|---|---|
| Ceph OSD | Burstable | 12Gi mem | 18Gi mem | 严格 (10s×3 exec) | OK |
| **Ceph mgr** | **BestEffort** | **none** | none | 严格 (10s×3 exec) | ⚠ **Milvus 教训重演风险** |
| **Ceph mon** | **BestEffort** | **none** | none | 严格 (10s×3 exec) | ⚠ 同上 |
| rook-ceph-tools | BestEffort | none | none | 无 | OK (debug pod) |
| MinIO | Burstable | 1 CPU/2Gi | 2 CPU/4Gi | 合理 (含 startup probe 30×10s) | OK |
| Milvus etcd (升级后) | Burstable | 1 CPU/2Gi | 2 CPU/4Gi | 合理 (60s 周期) | OK, 已修复 |
| Milvus datanode/querynode | Burstable (待复验) | – | – | – | – |
| Milvus pulsar | (待复验) | – | – | – | – |
| Milvus-attu | BestEffort | none | none | 无 (UI) | 低 (UI 不关键) |

---

## 2. 发现的问题 (按严重度排序)

### Critical

**C-1. [CONFIRMED] Ceph osd.4 和 osd.14 因 Ceph 19.2.2 BlueStore 已知 bug 反复崩溃**
- 现象: osd.4 累计 7 次、osd.14 累计 13 次，全部 `ceph_assert(diff <= bytes_per_au[pos])`
- 路径: BlueStore::Blob::put_ref → ExtentMap::punch_hole → _do_truncate/_do_remove
- 影响: OSD 不可用, 触发 rebalance, 进一步触发 recovery → 更多 OSD 触发同 bug 风险
- 触发条件: 在 EC recovery 事务中 (ECBackend::commit_txn_send_replies) 或 delete 上下文 (OSD::dequeue_delete)
- **重要**: 此 bug 是 ceph-osd 软件层缺陷，**销毁 OSD 重建无法修复** (会再崩)，必须升级 Ceph

**C-2. [CONFIRMED] AlertManager 长期 down (0/1 Ready 398d)**
- 现象: `alertmanager-prometheus-stack-kube-prom-alertmanager` 0/1 ready 状态持续 398 天
- 影响: 即使后续配置 PrometheusRule，所有告警无法发送出去
- 风险: 集群故障无人感知 (Milvus 3TiB binlog 事件就是缺告警导致的)

**C-3. [CONFIRMED] Grafana 12h 内重启 8 次, Prometheus 16h 内重启 2 次**
- 影响: 监控视图断流, 历史数据可能丢失, 现有告警配置可能丢失
- 需查 prometheus-operator 日志, 怀疑是 OOM 或 PVC 问题

**C-4. [CONFIRMED] metrics-server 未安装**
- 影响: `kubectl top node/pod` 全部不可用, HPA 无法基于 CPU/mem 工作
- 风险: 节点资源耗尽无法预警, 复现 milvus-busy-node 模式

### High

**H-1. [CONFIRMED] rook-ceph mgr/mon 仍是 BestEffort + 严格探针 — Milvus 教训未根治**
- 现象: mgr-a 在 node41-gpu, mon-a 在 node27, requests={}, 探针 10s×3
- 风险: 与 milvus etcd 死循环崩溃同模式 — 节点抖动 → exec 探针超时 → kubelet 重启 → Ceph 短暂失主 → 触发 mgr failover / mon election → 进一步抖动
- 节点 41-gpu 已是 58% CPU req / 104% lim 状态, 高度紧张

**H-2. [CONFIRMED] ServiceMonitor 全部缺失 — ceph/minio/milvus 指标无法采集**
- 影响: 无法看 Ceph OSD 延迟、PG 状态、容量增长曲线; 无法看 MinIO 磁盘用量、IO、网络; 无法看 Milvus binlog 堆积
- 直接导致 3TiB binlog 事件无人察觉的根因

**H-3. [CONFIRMED] PrometheusRule 全部缺失 — 0 业务告警**
- 影响: 无 Ceph HEALTH_WARN 告警、无 MinIO 容量告警、无 Milvus binlog 告警、无 OSD down 告警
- 集群当前已经 HEALTH_WARN 13d, 0 告警

**H-4. [CONFIRMED] xa-k8s-node41-gpu 资源严重 overcommit**
- 现状: CPU req 58% / lim **104%**, mem req 14% / lim 23%
- 同时承载: rook-ceph-mgr-a (BestEffort) + milvus-etcd-0 + minio-12/13/14 + 多个 RBD 卷
- 后果: 节点抖动时 (etcd 慢 fdatasync 现象) 会影响所有 BestEffort pod 调度与重启

**H-5. [CONFIRMED] PG 3.1 / 3.2 已 36 天没 scrub**
- 风险: 静默位腐败 (silent bitrot) 累积, 一旦相关 OSD 故障，恢复时可能数据丢失
- 与 osd.4/14 down 强相关, 恢复后会自然补

### Medium

**M-1. [PLAUSIBLE] MinIO 副本分布不均 (2/3/3/3/2/3)**
- 25 节点: 2 副本 (其他 4 节点均为 3 副本) — 略偏低, 25 同时还跑 4 个 OSD (0/1/2/3) + 5 副本
- 影响: 25 节点压力略大, 失败域略偏

**M-2. [CONFIRMED] CSI 插件 node25 重启过 7 次 (66d 前)、node26 重启 1 次 (406d 前)**
- 历史问题, 当前稳, 但说明早期 RBD 卷 I/O 抖动存在

**M-3. [PLAUSIBLE] Milvus datanode/querynode 重启过 2 次 (62m 前)**
- 时间点与 MinIO 桶清理/minio-console 重启接近, 需进一步看日志确认是否相关

**M-4. [CONFIRMED] MinIO bucket du 命令无权限**
- 当前用 minio 自身 console admin 账号, 缺 S3:GetBucketLocation, 无法看真实桶容量
- 需 root key 或 host 端 `du -sh` 校验

### Low

**L-1. [CONFIRMED] 节点 kernel 版本不一致**
- node25: 5.15.0-177-generic (新)
- node26/27/28/29: 5.15.0-112-generic
- node41-gpu: 5.15.0-105-generic
- node42-gpu: 5.15.0-105-generic
- 影响: 驱动/系统调用行为可能不一致 (与 RBD I/O 抖动可能相关)

**L-2. [CONFIRMED] rook-ceph cluster 命名 集群 id 与 deploy 命名非标准 (58f4b068 是合法但未备注文档归属)**
- 备忘性质, 跨集群复用工具时需注意

---

## 3. 优化建议

### 3.1 Ceph

| 建议 | 优先级 | 命令/步骤 | 风险 |
|---|---|---|---|
| 升级 Ceph 到 19.2.3+ (修 bluestore bug) | **P0** | `helm upgrade rook-ceph rook-release/rook-ceph --version <new> -n rook-ceph` + `ceph osd require-osd-release luminous` | 中: 升级期间 OSD 滚动重启, PG 短暂 degrade; 需先备份 ceph 密钥到 etcd |
| 给 mgr/mon 加 requests/limits | **P0** | 编辑 `rook-ceph-cluster` CephCluster CR 的 `mgr`/`mon` spec, 加 `resources: { requests: {cpu:500m, memory:1Gi}, limits: {cpu:2, memory:2Gi} }` | 中: 修改后 mgr/mon pod 会重建, 短暂单 mgr 状态 |
| 放宽 mgr/mon liveness 探针 (initialDelay + failureThreshold) | **P0** | helm values 里 `cephClusterSpec.mgr.livenessProbe.failureThreshold: 5` `periodSeconds: 30` | 低: 治标 |
| 主动 ack osd.4/14 的 crash 记录 | P1 | `kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph crash archive-all` | 无 (清空已知 crash 列表) |
| 配置 `osd scrubber` 主动补 scrub | P1 | `ceph config set osd osd_scrub_sleep 0.1` + `ceph pg deep-scrub 3.1 3.2` | 低: 抢一些 CPU |
| 给 osd.4/14 标 "out" (在升级到 19.2.3 之前) | P1 | `ceph osd out 4 14` (注: 已 out, 跳过), 或 `ceph osd purge 4 --yes-i-really-mean-it` (永久删除) | 中: purge 后数据回填其他 OSD |
| 配 OSD 节点的 scrub 周期 7d / deep 30d | P1 | `ceph config set osd osd_scrub_min_interval 604800` `osd_deep_scrub_interval 2592000` | 低 |

### 3.2 MinIO

| 建议 | 优先级 | 命令/步骤 | 风险 |
|---|---|---|---|
| 用 root key 写一个读桶脚本来定时 du | P1 | 在 host 上用 `mc` + root key, cron 每天 `mc du minio/milvus minio/dify minio/weknora minio/harbor > /var/log/minio-usage.log` | 无 |
| MinIO 副本 rebalance 到 25 节点补到 3 | P2 | scale 17→18, 再缩 16 (rolling) — 用 mc admin rebalance | 中: 短暂 EC 重写 |
| MinIO 加 prometheus 抓取 (现成有 `minio/metrics`) | P0 | 加 ServiceMonitor, 见 §4 | 无 |
| MinIO 配 lifecycle 清理 milvus bucket 30d+ 旧对象 | P1 | `mc ilm add milvus/milvus --expire-days 30` | 中: 注意不要清掉 active binlog |

### 3.3 Pod QoS (Milvus 教训扩展)

| 建议 | 优先级 | 命令/步骤 | 风险 |
|---|---|---|---|
| **rook-ceph mgr/mon**: 补 requests/limits | **P0** | 见 3.1 | 中 |
| rook-ceph-tools: 显式 BestEffort + 不健康时驱逐 (现状 OK) | P3 | 无需操作 | – |
| Milvus datanode/querynode/indexnode: 补 requests/limits | P1 | helm values 加 `resources:` | 中: 重启 datanode 可能 5-10min 重建索引段 |
| Milvus pulsar bookie/broker/zookeeper: 补 requests/limits | P1 | 同上 | 中 |
| node41-gpu 上的 workoad 调度约束 | P1 | 给 daemonset 加 `nodeAffinity` 避开 41-gpu, 或在 etcd/mgr 上加 toleration + nodeSelector 强制分散 | 低 |

### 3.4 监控 (核心短板)

见 §4 详细方案。

---

## 4. 监控方案

### 4.1 安装 metrics-server (P0)

```bash
# 加 metrics-server (kubectl top 才能用, HPA 才能工作)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
# 内网打不通外网镜像: 把镜像推到 Harbor 改 image 字段, 加 --kubelet-insecure-tls
```

### 4.2 加 ServiceMonitor (P0)

**Ceph — 用 rook-ceph 内置 exporter (端口 9283)**:

```bash
# rook-ceph mgr 默认开 prometheus exporter on port 9283, 但 ServiceMonitor 要自己建
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: rook-ceph-mgr
  namespace: rook-ceph
  labels: release: prometheus-stack
spec:
  selector:
    matchLabels:
      app: rook-ceph-mgr
  namespaceSelector:
    matchNames: [rook-ceph]
  endpoints:
  - port: http-metrics
    interval: 30s
EOF
```

**MinIO — 现成 metrics 端点**:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: minio
  namespace: minio
  labels: release: prometheus-stack
spec:
  selector:
    matchLabels:
      app: minio
      component: minio
  namespaceSelector:
    matchNames: [minio]
  endpoints:
  - port: minio
    path: /minio/v2/metrics/cluster
    interval: 30s
    basicAuth: { username: minio, password: { name: minio-credentials, key: consoleSecret }}
  - port: minio
    path: /minio/v2/metrics/node
    interval: 30s
    basicAuth: { username: minio, password: { name: minio-credentials, key: consoleSecret }}
  - port: minio
    path: /minio/v2/metrics/bucket
    interval: 60s
    basicAuth: { username: minio, password: { name: minio-credentials, key: consoleSecret }}
EOF
```

**Milvus — Milvus 暴露 :9090 metrics**:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: milvus
  namespace: milvus
  labels: release: prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: milvus
  namespaceSelector:
    matchNames: [milvus]
  endpoints:
  - port: metrics
    interval: 30s
EOF
```

### 4.3 配 PrometheusRule (P0)

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: infra-alerts
  namespace: prometheus
  labels: release: prometheus-stack
spec:
  groups:
  - name: ceph
    rules:
    - alert: CephOSDDown
      expr: ceph_osd_down > 0
      for: 5m
      labels: { severity: critical }
      annotations: { summary: "OSD 宕机 {{ $value }} 个" }
    - alert: CephHealthWarn
      expr: ceph_health_status != 0  # 0=OK
      for: 15m
      labels: { severity: critical }
    - alert: CephPGStale
      expr: increase(ceph_pg_stale[10m]) > 0
      labels: { severity: warning }
    - alert: CephUsageNearFull
      expr: (ceph_cluster_total_used_bytes / ceph_cluster_total_bytes) > 0.7
      for: 30m
      labels: { severity: warning }

  - name: minio
    rules:
    - alert: MinIOUsageNearFull
      expr: minio_node_disk_used_bytes / minio_node_disk_total_bytes > 0.75
      for: 30m
      labels: { severity: warning }
    - alert: MinIOPodDown
      expr: kube_statefulset_replicas_ready{statefulset="minio"} < 12
      for: 5m
      labels: { severity: critical }

  - name: milvus
    rules:
    - alert: MilvusEtcdSlowFsync
      expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.5
      for: 10m
      labels: { severity: warning }
    - alert: MilvusBinlogBloat  # 防 milvus 3TiB 复发
      expr: minio_bucket_usage_bytes{bucket="milvus"} > 1.5e12  # 1.5TB
      for: 1h
      labels: { severity: warning }
    - alert: MilvusDatanodeRestart
      expr: increase(kube_pod_container_status_restarts_total{pod=~"milvus-.*"}[30m]) > 0
      for: 1m
      labels: { severity: warning }
```

### 4.4 修 alertmanager (P0)

```bash
kubectl -n prometheus describe sts alertmanager-prometheus-stack-kube-prom-alertmanager
kubectl -n prometheus logs alertmanager-prometheus-stack-kube-prom-alertmanager-0
# 视错误信息处理: 大概率是 configSecret 缺失 / PVC 损坏 / 端口冲突
# 临时修: helm upgrade prometheus-stack + values 里 alertmanager.alertmanagerSpec 补全
```

### 4.5 Grafana Dashboards (P1)

导入社区 dashboard JSON:
- Ceph: dashboard id **2842** (ceph-cluster)
- MinIO: dashboard id **13502** (minio)
- Milvus: 自建 (用 milvus_exporter 的 metric prefix)
- Node: dashboard id **16098** (node-exporter full)

### 4.6 步骤汇总 (按依赖顺序)

1. 修 alertmanager 0/1 → 否则规则配了也发不出
2. 装 metrics-server → HPA + kubectl top 可用
3. 加 4 个 ServiceMonitor (ceph / minio cluster / minio bucket / milvus) → 30min 后 prometheus 有数据
4. 配 PrometheusRule infra-alerts → 1min 后开始评估
5. 导入 Grafana dashboards → 验证数据流通
6. 用 alertmanager 的 amtool 验证 receiver 配通 → 触发一个测试告警

---

## 5. 两个坏 OSD 恢复方案

### 关键先决条件

> **osd.4 和 osd.14 崩溃的根因是 Ceph 19.2.2 bluestore 已知软件 bug。**
> 销毁重建 OSD 后，新 OSD 还是 ceph-osd 19.2.2 进程，**会再崩**。在升级到 19.2.3+ 之前不能彻底修复。
> 当前必须做的：(a) 阻止这两个 OSD 持续在 crash 状态消耗 OSDMap 资源 (b) 升级 Ceph (c) 升级完后 OSD 重建。

### 方案 A: 升级 Ceph 后重建 (推荐)

**前置**: 备份 ceph 密钥 (`kubectl -n rook-ceph get secret rook-ceph-mon -o yaml > backup.yaml`)

```bash
# 1. 升级 rook (helm), 选 19.2.3+ chart
helm repo update
helm upgrade --install rook-ceph rook-release/rook-ceph \
  --version <chart-version-with-ceph-19.2.3> \
  -n rook-ceph -f <your-values.yaml>

# 2. 等所有 OSD pod 滚动升级到新版本 (kubectl -n rook-ceph get pods -l app=rook-ceph-osd -o wide)
# 3. 验证 ceph osd metadata 上 version
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph tell osd.* version
# 4. 触发 crash 归档
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph crash archive-all
# 5. 把 osd.4 / 14 重新 in (它们已被自动 out, 需在 CR 里删 osd 让 rook 重建)
#    编辑 CephCluster CR, 找到 storageClassDeviceSets, 删 osd 对应 device 块
#    或直接用 rook toolbox:
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 4 --yes-i-really-mean-it
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 14 --yes-i-really-mean-it
# 6. rook-ceph-operator 会自动在节点上发现空盘并创建新 OSD
# 7. 等 backfill 完成 (ceph -s 看 pg 状态, 大约 6-12h 因 ~80G 数据要 rebalance)
```

### 方案 B: 临时屏蔽 (在升级之前的 workaround)

```bash
# 1. 阻止 crash 模块继续记录 (告警会一直 WARN)
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph crash archive-all
# 2. 把 osd.4 / 14 标 down (已经是 out, 跳过) + 阻止 rook 自动重启
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd down 4
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd down 14
# 3. 缩 rook-ceph-osd-{4,14} 部署副本数到 0 (避免持续 crashloop)
# 找 osd.4 对应 deploy: rook-ceph-osd-4-*
kubectl -n rook-ceph scale deploy rook-ceph-osd-4-866b49894 --replicas=0
kubectl -n rook-ceph scale deploy rook-ceph-osd-14-866b49894 --replicas=0
# (deploy 名以实际为准: kubectl -n rook-ceph get deploy -l app=rook-ceph-osd)
# 4. 等升级后, scale 回 1, 触发重新拉起
# 风险: 数据有 degraded, 写性能下降
```

### 顺序与风险

| 步骤 | 必须的 | 风险 | 停机 |
|---|---|---|---|
| 备份密钥 | Y | 无 | 0 |
| 升级 rook (含 ceph 19.2.3) | Y | OSD 滚动重启 30min 内 | 0 (滚动) |
| 归档 crash | Y | 无 | 0 |
| purge osd 4 + 14 | Y | 触发 backfill ~80G 数据 | 0 (后台) |
| rook 重建 OSD | Y | backfill 期间 IO 降级 | 0 (后台) |
| 等待 backfill 完成 | Y | 部分 PG 短暂 degraded | 0 |

---

## 6. 行动优先级

| 序号 | 行动 | 优先级 | 预计耗时 | 阻塞依赖 | 风险 |
|---|---|---|---|---|---|
| 1 | 修 alertmanager (从 0/1 → 1/1) | **P0 当日** | 30min | 无 | 低 |
| 2 | 装 metrics-server | **P0 当日** | 15min | 无 | 低 |
| 3 | 归档 ceph crash 记录 | **P0 当日** | 1min | 无 | 无 |
| 4 | 配 4 个 ServiceMonitor (ceph/minio/milvus/...) | **P0 3 天内** | 1h | prometheus CRD namespaceSelector 要 `release: prometheus-stack` label | 无 |
| 5 | 配 PrometheusRule infra-alerts | **P0 3 天内** | 1h | #4 完成后 | 无 |
| 6 | 升级 rook-ceph → 19.2.3+ | **P0 1 周内** | 4h (含观察) | 备份密钥 (#0) | 中 (OSD 滚动) |
| 7 | 升级后 purge osd.4 / 14 + 重建 | **P0 1 周内** | 12h (含 backfill) | #6 | 中 |
| 8 | 修 rook-ceph mgr/mon QoS (加 resources) | **P0 1 周内** | 30min (随下次 helm upgrade 一起) | 备份 | 中 |
| 9 | 修 prometheus / grafana 频繁重启 | P1 | 2h | 看完日志 | 低 |
| 10 | 修 Milvus datanode/querynode/pulsar QoS | P1 | 1h (随 helm 升级) | 备份 | 中 |
| 11 | node41-gpu 调度约束 (避免 mgr/etcd 都挤这) | P1 | 1h | – | 低 |
| 12 | 导入 Grafana dashboard | P1 | 30min | #4 | 无 |
| 13 | MinIO 加 lifecycle 清 milvus 30d+ 旧 binlog | P1 | 30min | 验证 mc 有 root key | 中 (误清风险) |
| 14 | MinIO 副本 rebalance 到 25 补到 3 | P2 | 4h | 业务低峰 | 中 |
| 15 | 统一 6 节点 kernel 版本到 5.15.0-177 | P2 | 4h × 6 节点 (滚动) | 业务接受重启 | 中 |
| 16 | MinIO 用 root key 配定时 du 脚本入监控 | P2 | 1h | – | 无 |

---

## 附录 A: 关键命令清单 (速查)

```bash
# Ceph 健康
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health detail
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd df tree
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph crash ls
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph crash info <crash-id>
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph crash archive-all

# MinIO
kubectl -n minio get pods -l app.kubernetes.io/component=minio
kubectl -n minio exec minio-0 -- mc admin info
kubectl -n minio exec minio-0 -- mc du local/milvus  # 用 root key

# 监控
kubectl -n prometheus get prometheuses,servicemonitors,prometheusrules
kubectl -n prometheus logs alertmanager-prometheus-stack-kube-prom-alertmanager-0
kubectl -n prometheus logs prometheus-prometheus-stack-kube-prom-prometheus-0

# Pod QoS 审计
for ns in rook-ceph minio milvus; do
  echo "=== $ns ==="
  kubectl -n $ns get pods -o json | jq -r '.items[] | "\(.metadata.name)\t\(.status.qosClass)\t\(.spec.containers[0].resources.requests // "none")"'
done

# 节点压力
kubectl describe node xa-k8s-node41-gpu | grep -A 6 "Allocated resources"
```

## 附录 B: 已确认的事实清单 (用于复盘与知识沉淀)

- **Ceph 19.2.2 BlueStore bug**: `diff <= bytes_per_au[pos]` in `BlueStore::Blob::put_ref`, 触发路径 `_do_truncate`/`_do_remove`/`punch_hole`/`OldExtent::create`, 与 OSD 删除/恢复事务相关, 升级到 19.2.3+ 修复
- **Milvus 教训的同模式** (BestEffort + 严格 exec 探针) **未在 mgr/mon 上修复**, 必须处理
- **Milvus 升级后 etcd 已是 Burstable**, 教训已部分落地
- **监控盲区**: 0 ServiceMonitor + 0 PrometheusRule + alertmanager 0/1 = 完全的"黑盒"状态, 是 Milvus 3TiB 事件复发的结构性条件
- **节点负载不均**: 41-gpu 实际是 worker 中的"热点" (58% req / 104% lim), 不可再加 BestEffort 关键组件
- **OSD 13/14 down 真实原因不是硬件**, 重建前需先修软件

---

报告完毕。后续如需执行任何 P0 项 (修 alertmanager / 升级 Ceph / purge osd.4 14), 请单独下令, 本次只做只读审计。