# 公共 Doris（存算分离 DDC）部署 — WeKnora LiteFuse 分析后端

LiteFuse 26.0.1 基于 Apache Doris 3.0+（VARIANT 列 / group commit / 向量化）。本目录用 **存算分离（DorisDisaggregatedCluster, DDC）** 模式部署 **Doris 4.1**，作为集群公共分析后端：FE + MetaService(依赖 FDB) + Compute Group(BE 无状态) + FoundationDB(元数据) + Storage Vault(S3 = 集群 MinIO)。BE 无本地数据盘，数据落 MinIO，弹性好、省本地盘。

> 官方文档：
> - 存算分离部署 https://doris.apache.org/docs/4.x/install/deploy-on-kubernetes/separating-storage-compute/install-doris-cluster
> - 架构 https://doris.apache.org/docs/4.x/compute-storage-decoupled/intro
> - Operator 概念 https://doris.apache.org/docs/4.x/install/deploy-on-kubernetes/doris-operator/intro
> - 源码（参考/验证） https://github.com/apache/doris-operator/tree/26.0.0

## 组件与镜像

| 组件 | 镜像 | 来源 |
|---|---|---|
| FoundationDB CRD | `apps.foundationdb.org/v1beta2` `FoundationDBCluster` | fdb-kubernetes-operator v1.46.0 |
| fdb-kubernetes-operator | `foundationdb/fdb-kubernetes-operator:v1.46.0` | mirror → harbor |
| FDB server + 集群 sidecar/init | `foundationdb:7.1.38` + `foundationdb-kubernetes-sidecar:7.1.38-1`（集群 version 7.1.38） | mirror |
| operator pod sidecar/init | `foundationdb/foundationdb-kubernetes-sidecar:7.1.46-1` | mirror |
| Doris Operator | `apache/doris:operator-latest`（26.0.0 operator 源码对应；docker hub 无 operator-26.0.0 tag） | mirror |
| Doris DDC CRD | `disaggregated.cluster.doris.com/v1` `DorisDisaggregatedCluster` | doris-operator 26.0.0 |
| Doris FE | `apache/doris:fe-4.1.3` | mirror |
| Doris BE | `apache/doris:be-4.1.3` | mirror |
| Doris MetaService | `apache/doris:ms-4.1.3` | mirror（docker hub 已确认存在） |
| mysql client | `mysql:5.7` | mirror（建 Vault Job 用） |

## 文件

| 文件 | 作用 |
|---|---|
| `fetch-vendored.sh` | 从 doris-operator 26.0.0 tag + fdb-kubernetes-operator main 下载上游 CRD/operator YAML 到 `vendored/`（离线/审计，不进 git） |
| `patch-images.sh` | 把 `vendored/` 里 operator YAML 镜像改写 harbor → `*.patched.yaml` |
| `fdb-cluster.yaml` | 手写 FDB 集群（name=litefuse-fdb, ns=doris, single 副本 dev） |
| `ddc-cluster.yaml` | DorisDisaggregatedCluster CR（FE×2 + MS + CG×2，镜像指 harbor） |
| `create-storage-vault.yaml` | Job：连 FE 建指向集群 MinIO 的 Storage Vault 并设默认 |
| `vendored/` | 上游 YAML（fetch 后生成，`.gitignore` 建议忽略） |

## 部署顺序（由 `deploy/scripts/litefuse-bootstrap.sh` 自动编排，严格串行）

1. `kubectl create ns doris litefuse`
2. **FDB**：`vendored/fdb-crds.yaml` → `vendored/fdb-operator.patched.yaml` → `fdb-cluster.yaml`。等 `kubectl get fdb -n doris` AVAILABLE=true。生成 ConfigMap `litefuse-fdb-config`。
3. **Doris Operator**：`vendored/crds.yaml` → `vendored/disaggregated-operator.patched.yaml`（ns=doris）。等 `doris-operator` pod Running。
4. **DDC 集群**：`ddc-cluster.yaml`。等 `kubectl get ddc -n doris` CLUSTERHEALTH=green 且 CGAVAILABLECOUNT=CGCOUNT。FE service：`litefuse-doris-fe.doris:9030`(mysql)/`:8030`(http)。
5. **Storage Vault**：先在 ns=doris 建 Secret `doris-vault-creds`（MinIO ak/sk），再 `kubectl apply -f create-storage-vault.yaml`。等 Job 完成，`SHOW STORAGE VAULTS` 里 `minio_vault` IsDefault=true。

> Vault 必须在 LiteFuse helm install 之前设为默认——LiteFuse `LITEFUSE_AUTO_DORIS_MIGRATION_DISABLED=false` 启动即在 Doris 建库表，数据落"默认 Vault"。

## 验证

```bash
kubectl get fdb -n doris                       # AVAILABLE=true
kubectl -n doris get pods                      # doris-operator / fdb / fe / ms / be 全 Running
kubectl get ddc -n doris                       # CLUSTERHEALTH=green
# 连 FE 验证 Vault + 读写
kubectl run mysql-client --image=<your-registry>/data-stack/mysql:5.7 -it --rm --restart=Never -- /bin/sh -c \
  "mysql -h litefuse-doris-fe.doris -P 9030 -u root -e 'SHOW STORAGE VAULTS; SHOW BACKENDS;'"
```

## HA / 生产

- 当前 dev：FDB single 副本、FE×2、CG×2。
- 生产 HA：FDB `redundancy_mode=double` + `log:3 storage:3`（**需 ≥3 worker 节点**）；FE replicas=3（1-host-1-instance 硬约束）；CG replicas=3。
- 集群现状（2 worker + 2 GPU worker）：GPU 节点若有 taint 会挡 FE/CG 调度，扩 HA 前先 verify 节点亲和/污点。

## 已知坑（与集群历史同源）

1. **RWO PVC 滚动更新死锁**：本集群 Harbor / weknora app 踩过（新 pod 调度到别的 node 拿不到 RWO 卷）。Doris operator 26.0.0 默认 Recreate 策略，verify；BE/FE 的 cache/log PVC 是 RWO（rook-ceph-block）。
2. **FE 1-host-1-instance 硬约束**：多 FE 必须不同 node，operator 默认 podAntiAffinity，**勿关**。
3. **时钟同步 <5s**：k8s 节点若没装 chrony，FDB/Doris FE BDBJE 可能切主。verify 集群 NTP。
4. **ms 镜像**：用 `ms-4.1.3`（docker hub 已确认存在）。若后续换 Doris 版本，fe/be/ms 三处 tag 同步改 [ddc-cluster.yaml](ddc-cluster.yaml)。
5. **Storage Vault SQL 字段名**：`s3.use_path_style` 若被 Doris 4.1 拒，删该行（MinIO path-style 也可由 endpoint 自动识别）。字段以官方 *Managing Storage Vault* 为准。
