# WeKnora 部署与架构讨论记录

> 记录时间：2026-06-22
> 基于版本：WeKnora v0.6.2（main 分支，提交 `ddc54609`）
> 仓库：https://github.com/Tencent/WeKnora
> 本地路径：`/Users/shin/vs-code/WeKnora`
> 部署形态：K8S（Helm）+ 全部第三方模型
>
> 📌 2026-06-23 补充：第十二节新增「针对目标集群（control-plane 10.9.27.27，glodon 内网）的落地部署方案」，含集群摸底、复用决策与可执行 Helm values；原「相关原文档索引」顺延为第十三节。

本文档整理了关于 WeKnora 的部署、架构与选型讨论。每个主题末尾标注了所引用的仓库内原文档，可点击跳转。

---

## 目录

1. [项目概览](#一项目概览)
2. [一个实例能否创建多个互相独立的知识库](#二一个实例能否创建多个互相独立的知识库)
3. [在企微中使用（IM 渠道接入）](#三在企微中使用im-渠道接入)
4. [WeKnora API 具备哪些能力](#四weknora-api-具备哪些能力)
5. [能否接入企微数据作为知识库内容](#五能否接入企微数据作为知识库内容)
6. [全部第三方模型 + 中间件的准备清单](#六全部第三方模型--中间件的准备清单)
7. [数据库"三合一"与拆分方案](#七数据库三合一与拆分方案)
8. [paradedb 与 postgres 的区别](#八paradedb-与-postgres-的区别)
9. [paradedb 与 postgres 是否同一厂家](#九paradedb-与-postgres-是否同一厂家)
10. [K8S（Helm）部署](#十k8shelm部署)
11. [最终部署建议](#十一最终部署建议)
12. [针对目标集群（10.9.27.x）的落地部署方案](#十二针对目标集群109027x的落地部署方案)
13. [相关原文档索引](#十三相关原文档索引)

---

## 一、项目概览

WeKnora 是腾讯开源的企业级 LLM 知识框架，围绕三大核心能力：

| 能力 | 说明 |
|------|------|
| **RAG 快速问答** | 基于知识库的检索增强问答 |
| **ReAct 智能体** | 自主编排知识检索 + MCP 工具 + 网络搜索的多步推理 |
| **Wiki Mode** | 智能体把原始文档蒸馏成自维护、互联的 Markdown wiki + 知识图谱 |

**架构特点**：全模块化流水线（文档解析 → 向量化 → 检索 → LLM 推理），每个环节可替换。多租户 4 级 RBAC、全自托管、Langfuse 可观测。

**多进程拓扑**：
- **app**（Go/Gin，`cmd/server`）：主 API 服务，`/api/v1`
- **docreader**（Python，gRPC）：文档解析服务
- **mcp-server**（Python）：MCP 服务器，stdio/SSE/HTTP
- **cli**（独立 Go module `cli/`）：`weknora` 命令行，AI-agent 优先 wire contract
- **frontend**（Vue3 + Vite + TDesign + Pinia）：Web UI
- **miniprogram**：微信小程序客户端

**与同类产品差异**：Dify 偏 LLM 应用编排、RAGFlow 偏深度文档解析；WeKnora 差异点在**企业多租户 RBAC + Wiki Mode + 全自托管**。

> 📄 引用：[README.md](./README.md)、[docs/ROADMAP.md](./docs/ROADMAP.md)、[docs/开发指南.md](./docs/开发指南.md)

---

## 二、一个实例能否创建多个互相独立的知识库

**结论：可以。** 一个实例支持创建任意数量的知识库，在 5 个维度上相互独立：

1. **数据与索引隔离**：每个 KB 有独立的文档、分块、向量索引、FAQ、Wiki 页面（归属链 `chunk_id → knowledge_id → kb_id → creator_id`）
2. **模型隔离**：per-KB 可配 `embedding_model_id`、`summary_model_id`、`vlm_config`、`asr_config`
3. **存储与解析隔离**：`storage_provider_config`、`vector_store_id`、`chunking_config` 等每库独立，还支持 per-upload 覆盖
4. **检索范围隔离**：`hybrid-search` 针对单 KB；跨库需显式配置
5. **权限隔离**：每资源带 `creator_id`，`OwnedKBOrAdmin` 守卫——「Contributor 在自己 KB 里像 Owner，在别人 KB 里像 Viewer」

**关键约束**：`vector_store_id` **创建后不可修改**，选型要在建库时定好。

**更上层**：多租户隔离（`kb.tenant_id`）；跨租户/用户共享 KB 须经"共享空间(Organization)"显式配置，且不绕过租户 RBAC。

> 📄 引用：[docs/api/knowledge-base.md](./docs/api/knowledge-base.md)、[docs/RBAC说明.md](./docs/RBAC说明.md)、[docs/共享空间说明.md](./docs/共享空间说明.md)

---

## 三、在企微中使用（IM 渠道接入）

**前置**：WeKnora 已部署 + 已创建 Agent（配好模型和知识库）。企微接入绑定到 **Agent**（Agent 编辑器 → IM 集成 → 添加渠道）。

**两种模式**：

| 模式 | 适用 | 步骤要点 |
|------|------|---------|
| **WebSocket（智能机器人，推荐）** | 内网/快速验证，无需公网域名 | 企微工作台建智能机器人（长连接）拿 BotID/BotSecret → WeKnora 渠道填入 → 自动建长连接 |
| **Webhook（自建应用）** | 已有自建应用，需公网回调地址 | 企微建应用拿 CorpID/AgentID/Secret → WeKnora 渠道填入 + 自定义 Token/EncodingAESKey → 复制回调地址 `https://域名/api/v1/im/callback/{channel_id}` → 回企微「接收消息」配置 |

**注意**：这是"企微作为 IM 渠道"（在企微里问答 WeKnora），与"企微作为数据源"（见第五节）是两回事。

> 📄 引用：[docs/IM集成开发文档.md](./docs/IM集成开发文档.md)

---

## 四、WeKnora API 具备哪些能力

RESTful API，base path `/api/v1`，认证 `X-API-Key` 或 `Bearer JWT`。按功能分约 22 类，归并为 8 大能力域：

1. 知识库与知识内容（CRUD、拷贝、迁移、per-KB 配置、分块、标签、FAQ）
2. 检索与问答（hybrid search、RAG 聊天、Agent 问答、评估 BLEU/ROUGE）
3. 会话与消息（CRUD、流式、断点续传）
4. 模型管理（LLM/Embedding/VLM/Rerank/ASR、初始化）
5. 智能体与扩展（Agent CRUD、Skills、MCP 服务含审批）
6. 系统与基础设施（系统信息、解析/存储引擎、向量存储管理、网络搜索）
7. 认证、多租户与协作（注册/登录/OIDC、租户与成员 RBAC、组织共享）
8. 集成接入（IM 渠道、数据源导入）

**最权威参考**：Swagger UI（`http://localhost:8080/swagger/index.html`，非 release 模式挂载，随代码更新）。

> 📄 引用：[docs/api/README.md](./docs/api/README.md) 及其下各分类 md（auth/tenant/knowledge-base/knowledge/model/chunk/agent/session/chat/...）

---

## 五、能否接入企微数据作为知识库内容

**结论：目前不能。** 企微作为数据源（把企微内容导入知识库）当前未实现。

**已实现的数据源连接器**（源码目录证实）：
```
internal/datasource/connector/feishu   ✅ 飞书
internal/datasource/connector/notion   ✅ Notion
internal/datasource/connector/yuque     ✅ 语雀
```
没有 wecom/wework 连接器。

**文档歧义提醒**：[数据源导入开发文档](./docs/数据源导入开发文档.md) 开头写"支持飞书、企业微信、Notion、Confluence 等"是愿景性描述；README 特性表更准确——"Auto-sync from Feishu / Notion / Yuque (more coming soon)"。

**替代路径**：① 手动导出企微文档为 PDF/Word 上传；② 走已支持的飞书/Notion/语雀连接器；③ 自建企微连接器（`internal/datasource/connector.go` 的 `Connector` 接口可扩展，但企微开放平台文档 API 能力有限）。

**两个概念勿混淆**：企微作为 IM 渠道 ✅（见第三节）；企微作为数据源 ❌（本节）。

> 📄 引用：[docs/数据源导入开发文档.md](./docs/数据源导入开发文档.md)、[README.md](./README.md)

---

## 六、全部第三方模型 + 中间件的准备清单

默认配置下 PostgreSQL 用 ParadeDB 镜像（PG17 + pgvector + BM25），一个实例承担关系库 + 向量库 + 全文检索三合一；文件存储默认 `local`。

**必须准备（最小可用）**：

| 类别 | 组件 | 配置入口 |
|------|------|----------|
| 数据库 | PostgreSQL（paradedb） | `DB_HOST/PORT/USER/PASSWORD/NAME`，`DB_DRIVER=postgres` |
| 缓存/流 | Redis | `REDIS_ADDR/PASSWORD`，`STREAM_MANAGER_TYPE=redis` |
| 文档解析 | docreader（官方镜像） | Docker 起，无需额外配置 |
| 第三方 LLM | 任一 OpenAI 兼容 | `LLM_MODEL_NAME/BASE_URL/API_KEY/PROVIDER` |
| 第三方 Embedding | 任一 OpenAI 兼容 | `EMBEDDING_MODEL_NAME/BASE_URL/API_KEY/PROVIDER` |
| 部署环境 | Docker + Compose | — |
| 配置 | `.env`（`cp .env.example .env`） | 必须存在 |

**按需的第三方模型**：Rerank（`RERANK_*` env）、VLM/ASR（Web UI 配置）。

**按需启用的中间件（compose profile）**：MinIO、Neo4j、向量库替代（qdrant/milvus/weaviate/doris）、SearXNG、Sandbox、Dex(OIDC)、Langfuse。

> 📄 引用：[.env.example](./.env.example)、[docker-compose.yml](./docker-compose.yml)、[Makefile](./Makefile)

---

## 七、数据库"三合一"与拆分方案

默认三合一的角色归属：

| 角色 | 默认实现 | 在哪 | 能否换 |
|------|----------|------|--------|
| 元数据（关系库） | PostgreSQL（paradedb） | `DB_DRIVER=postgres` 硬编码 | ❌ 只能 PG |
| 向量检索 | pgvector（在 PG 内） | `RETRIEVE_DRIVER=postgres` 的 `VectorRetrieverType` | ✅ 可拆 |
| 全文检索（BM25） | pg_search 扩展（在 PG 内） | `KeywordsRetrieverType`，源码用 `paradedb.score()` | ✅ 可拆 |

**核心机制**：`RETRIEVE_DRIVER` 支持逗号分隔多驱动（`internal/types/tenant.go` 中 `strings.Split`），每个驱动声明支持哪些 `RetrieverType`。

**拆分方案**：

| 方案 | 配置 | 说明 |
|------|------|------|
| **A：三彻底拆** | `RETRIEVE_DRIVER=milvus,elasticsearch_v8` | 元数据普通 PG + Milvus 向量 + ES v8 全文 |
| **B：向量拆出** | `RETRIEVE_DRIVER=postgres,milvus` | 全文留 PG(paradedb)，向量拆 Milvus |
| **C：检索后端合一** | `RETRIEVE_DRIVER=elasticsearch_v8` | 元数据普通 PG + ES v8 同时做向量+全文 |

**关键约束**：
1. 元数据只能 PostgreSQL（`DB_DRIVER=postgres` 硬编码；lite 版才支持 SQLite）
2. `elasticsearch_v7` 只能做全文不能做向量（老版无 knn）；要同时承担必须用 `elasticsearch_v8`
3. `vector_store_id` 建库后不可改
4. 拆走全文后，元数据 PG 不必用 paradedb（普通 postgres + pgvector 即可）
5. 外部向量库/ES 地址若用私网 IP 或被拦截端口（9200/5432），需加 `SSRF_WHITELIST` / `SSRF_WHITELIST_EXTRA`

> 📄 引用：[.env.example](./.env.example)、[internal/types/tenant.go](./internal/types/tenant.go)、[internal/container/engine_factory.go](./internal/container/engine_factory.go)、[internal/application/repository/retriever/postgres/repository.go](./internal/application/repository/retriever/postgres/repository.go)

---

## 八、paradedb 与 postgres 的区别

**本质**：ParadeDB 不是新数据库，而是 **PostgreSQL + 搜索扩展的打包发行版**（Docker 镜像）。核心是它自家的 `pg_search` 扩展。

```
普通 PostgreSQL              ParadeDB 镜像 (paradedb/paradedb)
├── PG 内核                  ├── PG 内核（同一个，当前 PG17）
├── tsvector 全文检索         ├── pg_search  ← ParadeDB 自家扩展（BM25 倒排索引）
                             └── pgvector   ← 社区扩展（向量），只是顺带打包
```

**关键澄清**：`pgvector` 是独立社区扩展，**不是 ParadeDB 的能力**（官方："ParadeDB utilizes `pgvector` for vector search, which is managed independently"）。ParadeDB 的核心价值是 `pg_search`（BM25 全文检索）。

**对 WeKnora 的含义**：源码 `internal/application/repository/retriever/postgres/repository.go` 直接调用 `paradedb.score()` 和 `|||` 操作符（pg_search 语法）。因此：

| 场景 | 结果 |
|------|------|
| 用 paradedb 镜像 | pg_search + pgvector 都有 ✅ |
| 普通 postgres + 只装 pgvector | 向量能用，全文检索 SQL 报错 ❌ |
| 普通 postgres + 装 pg_search 扩展 | 也能用 ✅（pg_search 可独立装到自管 PG） |
| 云托管 PG（RDS/CloudSQL） | 装不了 pg_search → 全文不可用，必须拆到 ES/OpenSearch ❌ |

> 📄 引用：[internal/application/repository/retriever/postgres/repository.go](./internal/application/repository/retriever/postgres/repository.go)、ParadeDB 官方文档 https://docs.paradedb.com

---

## 九、paradedb 与 postgres 是否同一厂家

**结论：不是同一家。**

| | PostgreSQL | ParadeDB |
|---|---|---|
| **归属** | 开源社区项目，PostgreSQL Global Development Group 维护，无单一商业所有者 | 独立商业公司（ParadeDB 公司）产品，open-core 模式 |
| **性质** | 关系型数据库内核 | 构建在 PostgreSQL 之上的搜索扩展（依赖 PG 运行） |
| **许可** | PostgreSQL License（类 BSD，无 copyleft） | Community 版 **AGPL-3.0**（强 copyleft）+ Enterprise 版（商业许可） |

两者是**依赖关系**，不是从属关系：ParadeDB 把 PostgreSQL 当上游依赖，没有 PG 就不存在。官方文档还提到 ParadeDB 可作为 PostgreSQL 的逻辑复制订阅者，进一步印证。

**AGPL-3.0 对部署的含义**：
- WeKnora **纯使用未修改** paradedb 镜像作为依赖运行 → 通常**不触发** AGPL copyleft（触发点是"修改 + 网络分发"）
- 若企业**深度二次开发 paradedb 扩展本身**并对外提供服务 → 需法务评估 AGPL 义务
- 对 copyleft 敏感可买 ParadeDB Enterprise（waive copyleft）

> 📄 引用：ParadeDB 官方文档 https://docs.paradedb.com/welcome/introduction 、https://github.com/paradedb/paradedb

---

## 十、K8S（Helm）部署

**官方有完整 Helm chart**（`helm/`，version 0.1.0，appVersion v0.6.2，kubeVersion ≥1.25，helm ≥3.10）。覆盖 app/frontend/docreader/postgres(paradedb)/redis + 可选 minio/neo4j/qdrant。

**chart 关键事实**：
- 服务名**硬编码**：`DB_HOST=postgres`、`REDIS_ADDR=redis:6379`、`DOCREADER_ADDR=docreader:50051`、Service 名 `app`/`postgres`（frontend nginx 硬编码 `app`）
- **第三方模型 key 走 `app.extraEnv`**（模板 `{{- with .Values.app.extraEnv }}`）
- **chart 里没有 Milvus 模板**，只内置 qdrant 作可选向量库
- chart 的 paradedb 是 **v0.18.9**（compose 是 v0.22.2），建议部署时提到 v0.22.2-pg17
- **外部托管 DB 不友好**：服务名硬编码，接云 RDS 需改 chart 或用 Endpoints+headless Service 替换

**推荐 values 要点**：
```yaml
secrets:
  dbPassword / redisPassword / jwtSecret
  tenantAesKey / systemAesKey    # 32字节，务必显式设+备份，丢了数据不可恢复
app:
  env:
    RETRIEVE_DRIVER: postgres
    STORAGE_TYPE: local
  extraEnv:                       # 第三方模型 key（生产建议 secretKeyRef）
    - { name: LLM_MODEL_NAME, value: "..." }
    - { name: LLM_BASE_URL, value: "..." }
    - { name: LLM_API_KEY, value: "..." }
    - { name: LLM_PROVIDER, value: openai }
    - { name: EMBEDDING_MODEL_NAME, ... }
    - { name: EMBEDDING_BASE_URL, ... }
    - { name: EMBEDDING_API_KEY, ... }
    - { name: EMBEDDING_PROVIDER, value: openai }
postgresql:
  image: { tag: v0.22.2-pg17 }   # 提到最新
ingress:
  enabled: true
  host: weknora.example.com
  tls: { enabled: true }
```

**安装**：
```bash
helm install weknora ./helm \
  --namespace weknora --create-namespace \
  -f values-prod.yaml
```

**K8S 注意点**：PV provisioner 必需；AES key 备份；Service 名 `app` 别改；资源默认偏小需调大（尤其 app 和 postgres）；对外暴露需 Ingress+TLS。

> 📄 引用：[helm/README.md](./helm/README.md)、[helm/values.yaml](./helm/values.yaml)、[helm/templates/app.yaml](./helm/templates/app.yaml)、[helm/templates/postgres.yaml](./helm/templates/postgres.yaml)、[deploy/weknora-lite.service](./deploy/weknora-lite.service)

---

## 十一、最终部署建议

**针对场景**：K8S 部署 + 全部第三方模型 + 有 Milvus 但不熟 + 还没开始用。

**结论：仍推荐用 paradedb 起步部署。** 决策依据叠加：

1. 还没开始用 → 第一目标是验证产品，不是架构最优
2. paradedb 三合一开箱即用（chart 默认就是它，`helm install` 一次起齐）
3. Milvus 不熟 → 接入要配 driver/SSRF/vector_store_id，验证阶段叠加不熟变量风险高
4. AGPL 不构成障碍 → 纯使用未修改镜像通常不触发 copyleft

**唯一会换掉 paradedb 的两种情况**：

| 情况 | 应对 |
|------|------|
| 对 AGPL copyleft 极度敏感（金融/政务合规红线） | 买 Enterprise 许可，或一开始把全文拆到 ES/OpenSearch（向量留 pgvector） |
| 验证后数据量/并发起来，pgvector 吃力 | 向量拆到 Milvus（那时已熟悉 WeKnora），全文可留 paradedb 或一并拆走 |

**落地路径**：用官方 chart 内置 paradedb + redis，第三方模型 key 走 extraEnv（生产用 secretKeyRef），paradedb tag 提到 v0.22.2-pg17，4 个 secret 设好（dbPassword / redisPassword / jwtSecret / 两个 AES key 备份）。先 `helm install` 跑通、建测试知识库验证。验证阶段的库随时能删了重建，将来要切 Milvus 迁移成本也低——这正是现在用 paradedb 的底气。

---

## 十二、针对目标集群（10.9.27.x）的落地部署方案

> 补充时间：2026-06-23｜目标集群：control-plane `10.9.27.27`（glodon 内网）｜部署形态：K8S（官方 Helm chart）+ 全部第三方模型（外部 API）

本节是针对**具体目标集群**的可执行落地方案，与第十、十一节的通用讨论衔接：第十一节建议「用官方 chart 起步」，本节给出在该集群上的具体 values、复用决策与 gap 处理。本文档为方案讨论稿，**实际部署待逐项确认后再执行**。

### 12.1 目标集群摸底（已通过 kubectl 探明）

| 能力/资源 | 现状 | 本方案是否复用 |
|---|---|---|
| 集群 | v1.32.5，7 节点（3 control-plane + 2 worker + 2 GPU worker；GPU 未配 nvidia-device-plugin） | — |
| Harbor 镜像仓库 | `harbor.glodon.com`（HTTPS ingress） | ✅ 推送/拉取镜像 |
| ingress-nginx | IngressClass `nginx` 就绪 | ✅ 对外暴露 |
| cert-manager | 仅 `selfsigned-issuer`（ClusterIssuer），**内网无 ACME** | ✅ 签自签证书 |
| Rook-Ceph | `rook-ceph-block`（默认 RWO 可扩容）+ `rook-cephfs`（RWX 跨 Pod） | ✅ PVC |
| 现有 PostgreSQL | `postgresql-primary.postgresql:5432`，bitnami 17.5，**无 pgvector** | ❌ 独立部署 ParadeDB |
| 现有 MinIO | `minio.minio:9000`（凭证在 `minio-secrets`） | ✅ 复用对象存储 |
| 现有 Milvus | 不健康（indexnode 多次重启） | ❌ 走默认 postgres(pgvector) |
| 专用 Redis | 无 | chart 自带独立部署 |
| Xinference | `service-supervisor.xinference:9999` | 不涉及（本次用外部 API） |

### 12.2 复用 vs 独立决策

| 组件 | 决策 | 理由 |
|---|---|---|
| 命名空间 | `weknora` | 隔离 |
| 数据库 | chart 自带 ParadeDB（独立 StatefulSet） | 现有 bitnami PG 无 pgvector；chart 服务名硬编码 `postgres` 正好匹配 |
| Redis | chart 自带（独立） | 集群无专用实例 |
| 向量库 | `RETRIEVE_DRIVER=postgres`（pgvector） | 默认驱动；现有 Milvus 不健康 |
| 对象存储 | 复用集群 MinIO（`minio.enabled=false` + extraEnv 指向 `minio.minio:9000`） | 用户选定；省 PVC、多副本共享 |
| 暴露 | Ingress(nginx)+TLS(selfsigned) | 用户选定 |
| LLM/Embedding/Rerank | 外部 API（`app.extraEnv` + `secretKeyRef`） | 用户选定 |
| Sandbox | `disabled`（app 默认） | k8s 不跑 docker run；agent 代码执行技能关闭 |
| 数据库迁移 | app 自动迁移（`AUTO_MIGRATE` 默认开，app 镜像内置 migrate + migrations） | 无需独立 Job |

### 12.3 部署路径：官方 Helm chart + values-production.yaml

- **chart 位置**：`helm/`（appVersion v0.6.2，kubeVersion ≥1.25，helm ≥3.10）
- **为何走 chart**：官方维护、服务名硬编码（`postgres`/`redis`/`docreader`/`app`）正好匹配「独立部署 paradedb/redis/docreader」，与第十节衔接；比手写 Kustomize 省力且持续受官方维护
- **chart 能力契合点**：`global.storageClass` 接 Rook-Ceph、`global.imagePullSecrets` 接 Harbor、`app.extraEnv` 支持 `secretKeyRef`（安全注入 MinIO 凭证/LLM key）、`secrets.existingSecret` 支持预建 Secret、`ingress.className/tls.secretName` 接 cert-manager

### 12.4 values-production.yaml 关键覆盖（参考示例）

```yaml
global:
  storageClass: rook-ceph-block
  imagePullSecrets:
    - name: harbor-regcred

app:
  replicaCount: 1                 # 多副本前须补齐 CRYPTO_* key（见 12.8-3）
  image:
    repository: harbor.glodon.com/weknora/weknora-app
    tag: "<git-short-commit>"
  env:
    GIN_MODE: release
    RETRIEVE_DRIVER: postgres
    STORAGE_TYPE: minio           # 复用集群 MinIO
    STREAM_MANAGER_TYPE: redis
    TZ: Asia/Shanghai
    WEKNORA_LANGUAGE: zh-CN
  extraEnv:
    # —— 复用集群 MinIO ——
    - { name: MINIO_ENDPOINT, value: "minio.minio:9000" }
    - { name: MINIO_USE_SSL, value: "false" }
    - { name: MINIO_BUCKET_NAME, value: "weknora" }
    - name: MINIO_ACCESS_KEY_ID
      valueFrom: { secretKeyRef: { name: weknora-minio, key: accessKey } }
    - name: MINIO_SECRET_ACCESS_KEY
      valueFrom: { secretKeyRef: { name: weknora-minio, key: secretKey } }
    # —— 外部 LLM（示例：DeepSeek，OpenAI 兼容）——
    - { name: LLM_PROVIDER, value: "openai" }
    - { name: LLM_MODEL_NAME, value: "deepseek-chat" }
    - { name: LLM_BASE_URL, value: "https://api.deepseek.com/v1" }
    - name: LLM_API_KEY
      valueFrom: { secretKeyRef: { name: weknora-llm, key: apiKey } }
    # —— 外部 Embedding（示例）——
    - { name: EMBEDDING_PROVIDER, value: "openai" }
    - { name: EMBEDDING_MODEL_NAME, value: "text-embedding-3-large" }
    - name: EMBEDDING_API_KEY
      valueFrom: { secretKeyRef: { name: weknora-llm, key: embeddingApiKey } }
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits:   { cpu: "2",   memory: 4Gi }

frontend:
  replicaCount: 2
  image: { repository: harbor.glodon.com/weknora/weknora-ui, tag: "<git-short-commit>" }

docreader:
  image: { repository: harbor.glodon.com/weknora/weknora-docreader, tag: "<git-short-commit>" }
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits:   { cpu: "2",   memory: 4Gi }

postgresql:
  image: { repository: paradedb/paradedb, tag: "v0.22.2-pg17" }   # chart 默认 v0.18.9，对齐 compose
  persistence: { size: 50Gi }
  resources:
    requests: { cpu: 500m, memory: 1Gi }
    limits:   { cpu: "2",   memory: 4Gi }

redis:
  persistence: { size: 5Gi }

dataFiles:
  persistence: { size: 20Gi }

minio:
  enabled: false                  # 复用集群现有 MinIO
qdrant:
  enabled: false                  # 用默认 postgres(pgvector)
neo4j:
  enabled: false                 # GraphRAG 关闭

ingress:
  enabled: true
  className: nginx
  host: <YOUR_DOMAIN>            # 内网 DNS 解析到 ingress LB
  tls:
    enabled: true
    secretName: weknora-tls      # 由 cert-manager selfsigned 签发（见 12.6）

secrets:
  existingSecret: weknora-secrets  # 预建 Secret（见 12.7）
```

### 12.5 镜像构建与推送

```bash
# 1) 前端先出 dist（frontend/Dockerfile 要求）
VITE_IS_DOCKER=true ./scripts/build_frontend_dist.sh
# 2) 构建全部镜像（生成 wechatopenai/weknora-{app,docreader,ui,sandbox}）
./scripts/build_images.sh -a
# 3) 重新 tag + push 到 Harbor（sandbox 不推，disabled 模式不用）
COMMIT=$(git rev-parse --short HEAD)
for c in app docreader ui; do
  docker tag wechatopenai/weknora-$c:latest harbor.glodon.com/weknora/weknora-$c:$COMMIT
  docker push harbor.glodon.com/weknora/weknora-$c:$COMMIT
done
# 4) 建镜像拉取凭证
kubectl -n weknora create secret docker-registry harbor-regcred \
  --docker-server=harbor.glodon.com --docker-username=<user> --docker-password=<pass>
```

> 📄 引用：[scripts/build_images.sh](./scripts/build_images.sh)、[docker/Dockerfile.app](./docker/Dockerfile.app)、[frontend/Dockerfile](./frontend/Dockerfile)

### 12.6 证书（cert-manager selfsigned）

集群只有 `selfsigned-issuer`，内网无公网入口无法走 ACME。用 selfsigned Issuer 签发：

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: weknora-tls, namespace: weknora }
spec:
  secretName: weknora-tls
  dnsNames: [ "<YOUR_DOMAIN>" ]
  issuerRef: { name: selfsigned-issuer, kind: ClusterIssuer }
```

- 浏览器访问会告警，需手动信任自签 CA，或后续替换为内部 CA Issuer / 自有 tls Secret。
- 生产若公司有统一内部 CA，建议改用基于内部 CA 的 Issuer 签发。

### 12.7 Secret 准备（预建，供 `existingSecret` 引用）

```bash
# 加密密钥（务必备份，丢失不可恢复）
JWT=$(openssl rand -hex 32); TENANT=$(openssl rand -hex 16); SYSTEM=$(openssl rand -hex 16)
DBPW=$(openssl rand -hex 16); RDPW=$(openssl rand -hex 16)
kubectl -n weknora create secret generic weknora-secrets \
  --from-literal=DB_USER=postgres --from-literal=DB_PASSWORD=$DBPW \
  --from-literal=DB_NAME=weknora --from-literal=REDIS_PASSWORD=$RDPW \
  --from-literal=JWT_SECRET=$JWT --from-literal=TENANT_AES_KEY=$TENANT \
  --from-literal=SYSTEM_AES_KEY=$SYSTEM
# MinIO 凭证（从集群 minio-secrets 取或建专用 access key）+ bucket weknora
kubectl -n weknora create secret generic weknora-minio \
  --from-literal=accessKey=<...> --from-literal=secretKey=<...>
# 外部 LLM key
kubectl -n weknora create secret generic weknora-llm \
  --from-literal=apiKey=<...> --from-literal=embeddingApiKey=<...>
```

> ⚠️ `TENANT_AES_KEY`/`SYSTEM_AES_KEY` 必须备份；丢失后租户 api_key、模型 key、向量库凭证等加密字段不可恢复（UI 会显示 `enc:v1:...` 密文）。

### 12.8 chart 的 gap 及处理（待讨论）

1. **docreader `/tmp/docreader` 共享卷缺失**
   - 现象：chart 的 `docreader` Deployment 未挂载、`app` 未只读挂载 `/tmp/docreader`；而 `docker-compose.yml` 里 docreader RW 挂载、app RO 挂载该卷（解析产物跨容器共享）。
   - 直接用 chart 部署会导致 app 读不到 docreader 解析产物。三个处理方向：

     | 方向 | 做法 | 评价 |
     |---|---|---|
     | (a) post-render patch | `helm --post-renderer` + kustomize 给 docreader/app 补 cephfs RWX 共享卷（docreader RW / app RO） | 不改 chart，部署命令稍复杂；**推荐起步** |
     | (b) fork chart | 给 chart 加 `docreader/app.extraVolumes` 支持再挂共享卷 | 最干净，但要维护 fork |
     | (c) 走对象存储 | 确认 docreader 把解析产物写 MinIO、app 从 MinIO 读 | 需查 `docreader/config.py`、`DOCREADER_IMAGE_OUTPUT_DIR` 逻辑；若支持则无需共享卷 |

   - **待讨论定方向**（见 12.9-5）。
2. **paradedb tag**：chart 默认 `v0.18.9-pg17`，values 覆盖 `v0.22.2-pg17`（对齐 compose）。
3. **CRYPTO_MASTER_KEY / CRYPTO_SALT**：chart 未注入这两个 env；crypto_state 落 `/data/files` 文件。单副本可正常工作；**多副本前**须在 `app.extraEnv` 显式设齐 `CRYPTO_MASTER_KEY`/`CRYPTO_SALT`，否则各副本 crypto_state 不一致。

### 12.9 前置项清单（需用户确认/提供）

1. **Ingress 域名**：内网 DNS 解析到 ingress-nginx LB
2. **Harbor 项目 + push 账号**：建 `weknora` 项目并提供可 push 账号
3. **外部 LLM provider + key**：选定 provider（DeepSeek / OpenAI / 智谱 / 火山…）及 key、embedding 模型
4. **MinIO bucket**：在现有 MinIO 建 bucket `weknora` + 取/建专用 access key
5. **docreader 共享卷方向**：12.8-1 的 (a)/(b)/(c) 选一

### 12.10 安装与验证

**安装**：
```bash
helm install weknora ./helm -n weknora --create-namespace \
  -f deploy/values-production.yaml
  # 若采用 gap-1(a)，追加： --post-renderer ./deploy/post-render.sh
```

**验证**：
1. `kubectl -n weknora get pods` 全 Running；app pod `kubectl exec ... -- wget -qO- http://localhost:8080/health` 返回 ok
2. app 日志确认 124 个迁移执行成功（`AUTO_MIGRATE` 默认开）
3. MinIO console 见 bucket `weknora` 有上传对象
4. 上传 PDF/Word → 触发 docreader 解析 → 知识库入库（验证 12.8 共享卷 gap 是否处理好）
5. 建知识库选 pgvector → 检索问答正常
6. 外部 LLM 会话问答返回正常
7. 浏览器访问 `https://<域名>` → 前端加载、登录、问答全链路通

### 12.11 风险与备注

- **docreader 共享卷**：见 12.8-1，必须先定方向再部署，否则解析链路断
- **自签证书**：浏览器告警，需信任或换内部 CA
- **app 多副本**：必须先补齐 `CRYPTO_MASTER_KEY`/`CRYPTO_SALT`/`TENANT_AES_KEY`/`SYSTEM_AES_KEY`
- **cephfs RWX 性能**：docreader 解析大 PDF 产生大量临时图片，cephfs 弱于本地盘；若成瓶颈可改 docreader 作 app sidecar + emptyDir（但牺牲独立扩缩容）
- **proto 冲突**：本次用预构建镜像 + 默认 postgres(pgvector)，不引入 milvus，无 qdrant/milvus proto 冲突

> 📄 引用：[helm/README.md](./helm/README.md)、[helm/values.yaml](./helm/values.yaml)、[helm/templates/app.yaml](./helm/templates/app.yaml)、[helm/templates/docreader.yaml](./helm/templates/docreader.yaml)、[docker-compose.yml](./docker-compose.yml)、[.env.example](./.env.example)

---

## 十三、相关原文档索引

**项目文档**
- [README.md](./README.md) — 项目总览、特性、快速开始
- [README_CN.md](./README_CN.md) — 中文版
- [CHANGELOG.md](./CHANGELOG.md) — 版本变更
- [docs/开发指南.md](./docs/开发指南.md) — 开发环境快速启动
- [docs/ROADMAP.md](./docs/ROADMAP.md) — 产品路线图
- [docs/QA.md](./docs/QA.md) — 故障排查 FAQ

**API 文档**
- [docs/api/README.md](./docs/api/README.md) — API 概览
- [docs/api/knowledge-base.md](./docs/api/knowledge-base.md) — 知识库管理 API
- [docs/api/auth.md](./docs/api/auth.md) · [tenant.md](./docs/api/tenant.md) · [knowledge.md](./docs/api/knowledge.md) · [model.md](./docs/api/model.md) · [chunk.md](./docs/api/chunk.md) · [agent.md](./docs/api/agent.md) · [session.md](./docs/api/session.md) · [chat.md](./docs/api/chat.md) · [vector-store.md](./docs/api/vector-store.md) · [mcp-service.md](./docs/api/mcp-service.md) · [system.md](./docs/api/system.md) — 各分类 API

**集成与安全**
- [docs/IM集成开发文档.md](./docs/IM集成开发文档.md) — 企微/飞书/Slack 等 IM 接入
- [docs/数据源导入开发文档.md](./docs/数据源导入开发文档.md) — 飞书/Notion/语雀数据源连接器
- [docs/RBAC说明.md](./docs/RBAC说明.md) — 租户 RBAC 与资源归属
- [docs/共享空间说明.md](./docs/共享空间说明.md) — 跨租户共享空间
- [docs/Langfuse集成.md](./docs/Langfuse集成.md) — 可观测性集成

**部署与配置**
- [.env.example](./.env.example) — 全部环境变量配置项
- [docker-compose.yml](./docker-compose.yml) — Docker Compose 编排
- [Makefile](./Makefile) — 构建/测试/迁移/开发命令
- [.golangci.yml](./.golangci.yml) — Go lint 配置（v2，lll 120）
- [helm/README.md](./helm/README.md) · [helm/values.yaml](./helm/values.yaml) · [helm/templates/](./helm/templates/) — K8S Helm chart
- [deploy/weknora-lite.service](./deploy/weknora-lite.service) — Lite 版 systemd 服务

**客户端**
- [cli/README.md](./cli/README.md) · [cli/AGENTS.md](./cli/AGENTS.md) — `weknora` CLI 与 AI agent wire contract
- [mcp-server/README.md](./mcp-server/README.md) · [mcp-server/MCP_CONFIG.md](./mcp-server/MCP_CONFIG.md) — MCP 服务器
- [miniprogram/README.md](./miniprogram/README.md) — 微信小程序

**关键源码（架构依据）**
- [cmd/server/main.go](./cmd/server/main.go) — 服务入口，DI 容器装配
- [internal/container/container.go](./internal/container/container.go) — DI 装配根（`BuildContainer`）
- [internal/types/tenant.go](./internal/types/tenant.go) — 检索引擎映射（`RETRIEVE_DRIVER` → RetrieverType）
- [internal/container/engine_factory.go](./internal/container/engine_factory.go) — 检索引擎工厂
- [internal/application/repository/retriever/postgres/repository.go](./internal/application/repository/retriever/postgres/repository.go) — postgres 检索引擎（含 `paradedb.score()` BM25）
- [internal/datasource/connector.go](./internal/datasource/connector.go) — 数据源连接器接口

**外部参考**
- ParadeDB 官方文档：https://docs.paradedb.com
- ParadeDB GitHub：https://github.com/paradedb/paradedb
- WeKnora 官网：https://weknora.weixin.qq.com
