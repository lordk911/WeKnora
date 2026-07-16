# LiteFuse k8s 部署文档（WeKnora LLM trace 后端）

> 目标集群 <cluster-api-ip>（内网）。LiteFuse 26.0.1，存算分离 Doris 4.1 作分析后端。
> 官方无 helm/k8s 文档，本套脚本基于官方 docker-compose + Doris Operator 存算分离文档自制。

## 0. 背景与对接原理

LiteFuse 是 [langfuse/langfuse](https://github.com/litefuse/litefuse) 的 fork，把分析后端 ClickHouse→Apache Doris，**与上游 Langfuse API 线协议兼容**（README 明确声明）。因此：

- WeKnora 现有 tracing（[internal/tracing/langfuse/](../internal/tracing/langfuse/)，client 打 `/api/public/ingestion`）**不改代码**，把 `LANGFUSE_HOST` 指向 LiteFuse ingress 即可。
- LiteFuse 也暴露 OTLP 端点 `/api/public/otel`（HTTP/JSON + HTTP/protobuf，**不支持 gRPC**），Basic Auth `pk-lf-<pub>:sk-lf-<sec>`，供任何 Langfuse 兼容 OTLP exporter 用。

依赖：Postgres（元数据，Prisma 自迁移，无扩展）/ Redis（队列缓存）/ MinIO（事件上传 + S3 batch export）/ Doris（分析）。

## 1. 产物结构

```
deploy/
├── litefuse-chart/              # Helm chart（web + worker + redis + ingress + cert）
├── litefuse-values-production.yaml
├── doris/                       # 公共 Doris DDC（ns=doris）
│   ├── fdb-cluster.yaml        # FoundationDB（dev single 副本）
│   ├── ddc-cluster.yaml         # DorisDisaggregatedCluster（FE×2 + MS + CG×2）
│   ├── create-storage-vault.yaml# Job：建 MinIO Vault + 设默认
│   ├── fetch-vendored.sh        # 下载上游 CRD/operator YAML
│   ├── patch-images.sh          # 改写镜像 → harbor
│   ├── vendored/                # 上游 YAML（fetch 后生成，建议 .gitignore）
│   └── README.md
├── scripts/
│   ├── mirror-litefuse-images.sh
│   └── litefuse-bootstrap.sh     # 一键编排
└── litefuse-k8s-deploy.md       # 本文件
```

## 2. 镜像清单（全部推 <your-registry>/data-stack，匿名拉）

| 用途 | 镜像 | 备注 |
|---|---|---|
| LiteFuse web | `litefuse/litefuse-web:26.0.1` | linux/amd64 |
| LiteFuse worker | `litefuse/litefuse-worker:26.0.1` | |
| Doris FE | `apache/doris:fe-4.1.3` | |
| Doris BE | `apache/doris:be-4.1.3` | |
| Doris MetaService | `apache/doris:ms-4.1.3` | docker hub 已确认存在 |
| Doris Operator | `apache/doris:operator-latest` | 26.0.0 operator 源码对应；docker hub 无 operator-26.0.0 tag |
| FDB operator | `foundationdb/fdb-kubernetes-operator:v1.46.0` | operator pod |
| FDB operator pod sidecar/init | `foundationdb/foundationdb-kubernetes-sidecar:7.1.46-1` | |
| FDB 集群 server | `foundationdb/foundationdb:7.1.38` | 集群 version 7.1.38 |
| FDB 集群 sidecar/init | `foundationdb/foundationdb-kubernetes-sidecar:7.1.38-1` | 集群 version 7.1.38 |
| Redis | `redis:7-alpine` | 独立部署 |
| mysql | `mysql:5.7` | 建 Vault Job |

## 3. 部署步骤

### 3.1 镜像同步
```bash
# 内网拉 docker.io 可能需代理
https_proxy=http://127.0.0.1:7897 bash deploy/scripts/mirror-litefuse-images.sh
```
需先 `docker login <your-registry>`（data-stack 项目匿名拉、推送需账号）。脚本幂等，harbor 已有则 skip。

### 3.2 下载并 patch Doris 上游 YAML
```bash
cd deploy/doris
https_proxy=http://127.0.0.1:7897 bash fetch-vendored.sh      # 下载 doris-operator 26.0.0 + fdb CRD
bash patch-images.sh                                            # 镜像改写 harbor + 生成 *.patched.yaml
```
> Doris fe/be/ms 用 4.1.3（docker hub 已确认存在）。换 Doris 版本时三处 tag 同步改 [ddc-cluster.yaml](doris/ddc-cluster.yaml)。

### 3.3 预置 MinIO bucket + 用户

LiteFuse 用独立 bucket `litefuse`（与 weknora 隔离），三处共用、前缀分开：`events/`（事件上传）/ `exports/`（S3 batch export）/ `doris/ddc`（Doris Storage Vault）。套用 weknora 的 `add_minio_user.sh` 模式，建 user `litefuse` + `rw-litefuse` 策略。

在 node29（mc 已装）或 Mac（`brew install minio/stable/mc`）执行：

```bash
# 凭据放 deploy/.env（本地，不进 git；模板见 deploy/.env.example）：
#   MINIO_ROOT_USER / MINIO_ROOT_PASS   # 集群 MinIO root
#   LF_USER=litefuse / LF_PASS          # litefuse 专用用户
#   MINIO_ENDPOINT                     # 默认 https://<minio-endpoint>
# provision-minio.sh 自动 source deploy/.env；在 node29 单跑则 export 这些变量
bash deploy/scripts/provision-minio.sh
```

> 建 user `litefuse` + bucket `litefuse` + `rw-litefuse` 策略。bootstrap 用同一对凭据（从 deploy/.env 读 LF_MINIO_AK/SK，须与 provision-minio.sh 的 LF_USER/LF_PASS 一致）。

### 3.4 一键部署

```bash
# 凭据放 deploy/.env（bootstrap 自动 source）：
#   PG_SUPERUSER_PASS   # 集群 PG postgres 超管密码（kubectl exec 进 pod，本机无需装 psql）
#   LF_MINIO_AK/SK      # MinIO litefuse 用户凭据（须与 3.3 一致）
# 集群已装 cert-manager + 公司 *.<your-domain> 通配证书（bootstrap 从 weknora-company-tls 拷贝）
bash deploy/scripts/litefuse-bootstrap.sh
```
脚本串行执行：ns → FDB → Doris Operator → DDC 集群 → PG 库+用户（kubectl exec 进 postgres pod）→ MinIO bucket+用户（调 provision-minio.sh，需 mc）→ Storage Vault → Secret → helm install → 健康检查。

生成的密钥写到 `~/Downloads/litefuse/secrets.env`（mode 600，repo 外，**务必备份**，丢失=加密数据不可恢复，同 weknora `TENANT_AES_KEY`）。

### 3.4 等价的手工分步（脚本失败时按此排障）

见 [doris/README.md](doris/README.md) 的「部署顺序」。关键 wait 点：
- `kubectl get fdb -n doris` AVAILABLE=true
- `kubectl -n doris get pod -l app.kubernetes.io/name=doris-operator` Running
- `kubectl get ddc -n doris` CLUSTERHEALTH=green
- `kubectl -n doris logs job/create-storage-vault` 看到 `SHOW STORAGE VAULTS` 输出 `minio_vault` IsDefault=true
- `kubectl -n litefuse get pods` 全 Running

## 4. 验证

```bash
# 健康端点
kubectl -n litefuse port-forward svc/litefuse-web 13000:3000 &
curl http://127.0.0.1:13000/api/public/health          # → {"status":"OK","version":"26.0.1"}

# Doris 端到端
kubectl run mysql-client --image=<your-registry>/data-stack/mysql:5.7 -it --rm --restart=Never -- \
  mysql -h litefuse-doris-fe.doris -P 9030 -u root -e 'SHOW STORAGE VAULTS; SHOW BACKENDS;'

# 浏览器
# https://<litefuse-host>  → 用 init 用户登录（email admin@weknora.local，密码见 secrets.env）
# 在项目设置确认 public/secret key == secrets.env 里的 LITEFUSE_INIT_PROJECT_PUBLIC_KEY/SECRET_KEY
```

## 5. DNS / Ingress / 证书

`<litefuse-host>` 内网 DNS 需解析到 ingress-nginx LB（与 `<weknora-host>` 同段）。TLS 用**公司 `*.<your-domain>` 通配证书**（与 weknora/dify 同张，已确认 SAN 覆盖 `*.<your-domain>`，有效期至 2026-09-16）：

- [litefuse-values-production.yaml](litefuse-values-production.yaml) 设 `ingress.tls.selfSignedIssuer=false`、`secretName=litefuse-tls`。
- bootstrap 在 helm install 前从 `weknora-company-tls`（ns=weknora）拷贝 → `litefuse-tls`（ns=litefuse）；可用 `TLS_SRC_NS`/`TLS_SRC_SECRET` env 覆盖源（如 `dify-tls-secret`@dify）。
- 证书续期：公司换证书后 weknora/dify 会更新各自 secret，LiteFuse 需重拷（重跑 bootstrap 拷贝段，或手动 `kubectl get secret weknora-company-tls -n weknora -o yaml | ... | kubectl apply -f-`）。

## 6. WeKnora 对接（零代码改动）

LiteFuse Langfuse 线协议兼容 → WeKnora 的 [langfuse client](../internal/tracing/langfuse/client.go)（打 `/api/public/ingestion`）直接可用。在 [deploy/values-production.yaml](values-production.yaml) 的 `app.extraEnv` 追加：

```yaml
    - { name: LANGFUSE_HOST, value: "https://<litefuse-host>" }
    - name: LANGFUSE_PUBLIC_KEY
      valueFrom: { secretKeyRef: { name: litefuse-secrets, key: LITEFUSE_INIT_PROJECT_PUBLIC_KEY } }
    - name: LANGFUSE_SECRET_KEY
      valueFrom: { secretKeyRef: { name: litefuse-secrets, key: LITEFUSE_INIT_PROJECT_SECRET_KEY } }
    - { name: LANGFUSE_ENVIRONMENT, value: "production" }
```

注意：
- `litefuse-secrets` 在 ns=`litefuse`，WeKnora app 在 ns=`weknora`，**跨 ns 不能直接 secretKeyRef**。两种做法：① 在 weknora ns 手动 copy 一份（`kubectl get secret litefuse-secrets -n litefuse -o yaml | sed 's/namespace: litefuse/namespace: weknora/' | kubectl apply -f-`，改 name 避免冲突）；② 用 ExternalSecret。本部署先把 pk/sk 直接填进 weknora 的 `weknora-secrets`（值取自 `~/Downloads/litefuse/secrets.env`）最省事。
- langfuse client 用独立 `http.Client`（[client.go:27](../internal/tracing/langfuse/client.go#L27)），**不经** [internal/utils/security.go](../internal/utils/security.go) SSRF 守卫 → 无需加 `SSRF_WHITELIST_EXTRA`（verify：weknora app 日志出现 langfuse flush 成功）。

```bash
helm -n weknora upgrade weknora ./helm -f deploy/values-production.yaml
```

## 7. 关键风险与 verify 项

1. **FDB 集群镜像 override**：[fdb-cluster.yaml](doris/fdb-cluster.yaml) 在 podTemplate 显式指 harbor 镜像（air-gapped 必须）。若 fdb-kubernetes-operator v1.46.0 用 `spec.mainContainer.image`/`spec.sidecarContainer.image` 字段覆盖 podTemplate（导致仍从 docker.io 拉），改用那两个字段指 harbor，verify fdb pod 不再 ImagePullBackOff。
2. **LiteFuse 是否尊重自定义 `LITEFUSE_INIT_PROJECT_PUBLIC_KEY/SECRET_KEY`** → 部署后从 UI 确认项目 key 与注入一致；不一致则从 UI 复制生成 key 回填 weknora env。
3. **Storage Vault SQL 字段名**（`s3.use_path_style`）→ Job 失败则按 Doris 4.x *Managing Storage Vault* 删/改该字段（MinIO path-style 也可由 endpoint 自动识别）。**Vault 必须在 LiteFuse helm install 前设默认**，否则 LiteFuse auto Doris migration 建的表无后端。
4. **FDB 单 replica 仅 dev** → 生产改 `redundancy_mode=double` + `log:3 storage:3`（需 ≥3 worker 节点）。
5. **RWO PVC 滚动死锁**（本集群 Harbor/weknora app 同坑）→ web/redis 已用 Recreate；Doris operator 26.0.0 默认 Recreate，verify。
6. **FE 1-host-1-instance 硬约束** → FE×2 需 2 个不同 node；GPU 节点 taint 可能挡调度，扩 HA 前 verify。

## 8. 运维

- 改配置：编辑 [litefuse-values-production.yaml](litefuse-values-production.yaml) → `helm -n litefuse upgrade litefuse deploy/litefuse-chart -f deploy/litefuse-values-production.yaml`。
- 升级 LiteFuse：mirror 新 tag → 改 values `web/worker.image.tag` → helm upgrade。
- 备份：PG 元数据 `pg_dump`（连 postgresql-primary）；MinIO bucket `litefuse`；Doris 数据在 MinIO `doris/ddc` 前缀下。
- 卸载：`helm -n litefuse uninstall litefuse`；Doris `kubectl delete ddc -n doris litefuse-doris`；FDB `kubectl delete fdb -n doris litefuse-fdb`。`down -v` 等价：删 PVC + MinIO bucket（**不可逆**）。

## 9. 不在本任务范围

- WeKnora 代码改动（线协议兼容，无需改）。
- Doris 生产 HA 扩容（3 FE/3 BE + FDB 2-replica，待节点/流量确认后另做）。
- LiteFuse 自身升级流程（见第 8 节）。
