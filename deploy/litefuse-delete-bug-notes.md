# Litefuse trace 删除 bug 来龙去脉 + 升级跟踪项

> 记录于 2026-07-17。涉及 Litefuse 26.0.1 → 26.1.1 升级 + trace 删除链路修复。
> **每次升级 Litefuse worker/web 镜像前，先读本文档第 4 节「升级前必查的上游跟踪项」。**

## 0. 背景

WeKnora 用 Litefuse（langfuse fork，Doris 后端）作 LLM trace 后端，走 **OTLP ingestion**（`/api/public/otel`，WeKnora tracing client 基于 OTel SDK）。trace 数据落 Doris `events_full` 表（V4 单表模型，替代旧 `traces`+`observation_source`）。init 项目 API key 的值见本地 `secrets.env` 的 `LITEFUSE_INIT_PROJECT_PUBLIC_KEY` / `LITEFUSE_INIT_PROJECT_SECRET_KEY`（gitignore，不进 git）。

## 1. 现象（26.0.1，用户最初报告）

调 `DELETE /api/public/traces/{traceId}` 返回 200（入队成功），但 trace 不消失。worker 日志报：
```
errCode = 2, detailMessage = Table [observations] does not exist in database [litefuse].(line 15, pos 13)
```
pending_deletions 表对应行不标 `is_deleted=true` → 队列重试（bullmq 重试一次后进 failed，周期清理器默认关）→ 永久积压。

## 2. 根因（GitHub 源码核实）

Litefuse 把表名搞混了，三处不一致：

| 位置 | 引用的表名 | 实际存在？ |
|---|---|---|
| migration `0002_observations.up.sql` | 建表叫 `observation_source` | ✓ 存在（0 行，没用） |
| V4 model（migration `0037_create_events_full`） | 用 `events_full` 存 trace+observation | ✓ 存在（真实数据在这） |
| 代码里多处（读/写/删） | 引用 `observations`（沿用上游 Langfuse ClickHouse 名） | ✗ **不存在** → 报错 |

上游 issue：
- [litefuse/litefuse#30](https://github.com/litefuse/litefuse/issues/30)（open，2026-06-23）：报 fresh install `Table [observations] does not exist`。
- [litefuse/litefuse#31](https://github.com/litefuse/litefuse/pull/31)（open，**未合并**）：`fix(doris): rename observation_source to observations`——只改 migration `0002/0031/0033` + `DorisWriter.TableName.Observations`，**覆盖不到**下面第 3 节的残留。

## 3. 26.0.1 → 26.1.1 升级：只修了一半

升级到 `litefuse/litefuse-worker:26.1.1`（Docker Hub 现成 tag，含 amd64，无需自制镜像）。main HEAD（2026-07-14 commit `6a1977cf9` 起的 events_full 迁移）已把**主数据删除**改对：

```js
// worker/src/features/traces/processDorisTraceDelete.ts
await Promise.all([
  env.LITEFUSE_ENABLE_BLOB_STORAGE_FILE_LOG === "true"
    ? removeIngestionEventsFromS3AndDeleteDorisRefsForTraces({...})  // ← 仍坏（见下）
    : Promise.resolve(),
  deleteTraces(...),                          // traces 表 ✅
  deleteObservationsByTraceIds(...),          // → DELETE FROM events_full ✅（已修，observations.ts:1138）
  deleteScoresByTraceIds(...),               // scores 表 ✅
  ...
]);
```

**修好的部分**：`deleteObservationsByTraceIds`（`packages/shared/src/server/repositories/observations.ts:1138`）已改 `DELETE FROM events_full`。trace 数据能从 events_full 真删（实测：删 trace，events_full 4→0 行）。**用户最初的"API 成功但数据还在"问题已解决。**

**残留未修的部分**（main HEAD 同处未修，#31 覆盖不到）：trace 删除流程里清理 S3 blob 引用那步——`removeIngestionEventsFromS3AndDeleteDorisRefsForTraces` → `blobStorageLog.ts:127` 的 `filtered_observations` CTE 仍 `from observations`：

```sql
-- packages/shared/src/server/repositories/blobStorageLog.ts:122-127
filtered_observations as (
  select distinct id as entity_id, project_id, 'observation' as entity_type
  from observations                       -- ← 表不存在，抛错
  where project_id = ... and trace_id in (...)
)
```

这条查询在 `LITEFUSE_ENABLE_BLOB_STORAGE_FILE_LOG === "true"`（Litefuse **默认 true**，`worker/src/env.ts:172`）时执行 → 抛错 → `Promise.all` reject → pending_deletions 不标 isDeleted → 积压。

## 4. ⚠️ 升级前必查的上游跟踪项

升级 Litefuse worker/web 镜像前，对照下表核实上游状态。**全部修好后，可考虑重新打开 `LITEFUSE_ENABLE_BLOB_STORAGE_FILE_LOG=true`**（见第 5 节）。

| 上游位置 | 当前状态（2026-07-17） | 怎么查 |
|---|---|---|
| `blobStorageLog.ts:127` 的 `from observations` → `from events_full` | **未修**（main HEAD 同处仍 `from observations`） | `curl raw.githubusercontent.com/litefuse/litefuse/main/packages/shared/src/server/repositories/blobStorageLog.ts` grep `from observations` |
| issue [#30](https://github.com/litefuse/litefuse/issues/30) | **open** | `gh issue view 30 --repo litefuse/litefuse` 看 state |
| PR [#31](https://github.com/litefuse/litefuse/pull/31) | **open，未合并** | `gh pr view 31 --repo litefuse/litefuse` 看 merged |
| `otelIngestionQueue.ts:223` 的 `// TODO: Do we need to add these files into the blob_storage_file_log?` | **未实现**（OTLP 路径不写 file_log） | grep 该文件 `blob_storage_file_log` 是否已被实现 |

> #31 即使合并，也只改 migration + DorisWriter，**不会修 blobStorageLog.ts:127**。所以 #31 合并 ≠ 本残留修复。必须单独确认 blobStorageLog.ts 那行已改。

## 5. 当前部署的解法：关掉 flag

在 worker env 设 `LITEFUSE_ENABLE_BLOB_STORAGE_FILE_LOG=false`（覆盖默认 true），跳过那个坏的 blob 清理查询。

**为什么对 WeKnora 零代价**：
- `blob_storage_file_log` 表的作用是给 **S3 里的 ingestion 事件文件**建 Doris 索引（用于 retention + 删 trace 时清 S3 文件）。**不是把 trace 本体放 S3**——本体永远在 `events_full`。
- **只有经典 `/api/public/ingestion` 路径写 file_log**（`ingestionQueue.ts:70`）；**OTLP 路径（WeKnora 用的 `/api/public/otel`）根本不写**（`otelIngestionQueue.ts:223` 的 TODO 未实现）。
- 实测 `blob_storage_file_log` 0 行、events_full 无 >1MB 大 payload → 这个 feature 从未触发。
- 关掉后：file_log 不建（本来就没建）、坏查询不跑、删 trace 报错消失。零数据/功能损失。

**实现**（chart 已配）：
- `deploy/litefuse-chart/values.yaml` → `worker.enableBlobStorageFileLog: false`（含注释）
- `deploy/litefuse-chart/templates/worker-deployment.yaml` → 渲染 `LITEFUSE_ENABLE_BLOB_STORAGE_FILE_LOG`
- `deploy/litefuse-values-production.yaml` → 同显式设 `false`

**实测验证（2026-07-17，flag 关后）**：
1. DELETE API → HTTP 200（不变）
2. events_full 该 trace 行数 → 0（不变，主数据删除一直 OK）
3. **pending_deletions `is_deleted` f→t** ✅（之前永远 false，现正常标完成）
4. **worker 日志不再刷 `Table [observations] does not exist`** ✅
5. **积压清空**：之前 70 条 pending，flag 关后一次 delete job 把全部 71 条（70 积压 + 1 新删）标 done，pending 70→0。

## 6. Latent 隐患（和本 flag 无关，但要知道）

OTLP 路径若往 S3 `litefuse/events/` 写了事件文件（`LITEFUSE_S3_EVENT_UPLOAD_BUCKET` 已配 = MinIO bucket `litefuse` prefix `events/`），那些文件**不被 file_log 追踪、删 trace 时不清**——长期可能孤儿堆积在 MinIO。这是上游 OTLP TODO 未实现的通病，flag 开关解决不了它。要彻底治理：等上游补 TODO，或定期手动清 MinIO `events/` 前缀。

> 待办：确认 OTLP 是否真往 `events/` 写文件（需列 MinIO bucket）。本次未查。

## 7. auth 流程备忘（排查时易踩坑）

Litefuse public API Basic Auth（`pk:sk`）流程（`web/src/features/public-api/server/apiAuth.ts`）：
1. `fast_hash = createShaHash(secret, SALT)`（**带 SALT 的 sha，不是纯 sha256(sk)**）查 key——命中即过，不查 bcrypt。
2. 没命中才 fallback `verifySecretKey(secret, bcrypt_hash)`（bcrypt）——过则把 fast_hash 补写进 DB；不过则 401。

排查 auth：① 先 bcrypt 验证 sk 是否对（`python3 -c "import bcrypt; print(bcrypt.checkpw(b'<sk>',b'<hashed_secret_key from api_keys 表>'))"`）；② sk 别手抄——从 secret 的 base64 精确解码，曾因抄错 sk 字符导致 401 误判 auth 回归、浪费排查时间。port-forward 到 `svc/litefuse-web:3000` 测 REST API 可行（Host 头不影响 Basic Auth）。
