# Xinference 升级 + GPU 资源重划 + 嵌入/排序自建方案

> 评审文档 · 2026-07-06 · 分支 `feat/k8s-deploy-v0.6.3`
> 目标集群：`xa-k8s.local`（control-plane 10.9.27.27），namespace `xinference` / `weknora` / `dify`
> 范围：升级 Xinference、重划 HAMi GPU、下线自建 LLM、自建文本嵌入/排序、WeKnora 接入。**不含多模态嵌入/rerank**（决策依据见第 4 节）。

---

## 1. 背景与目标

WeKnora 知识库需要嵌入与排序模型（文本）。当前自建 Xinference 已 224 天未维护，GPU 虚拟化（HAMi）划分不合理导致：自建 LLM 塞不进小 vGPU 靠显存超分页换出（极慢）、bge-reranker 被挤到 CPU。同时误以为"阿里多模态嵌入/排序 WeKnora 不支持接入"是 provider 问题，实测根因在 WeKnora 入库管线本身不消费多模态嵌入（见第 4 节）。

**目标**：
- LLM 与 VLM 走百炼 API（GPU 少，不自建好模型）；
- 自建**文本嵌入 + 文本排序**（够用，4× A40 绰绰有余）；
- 释放错配给自建 LLM 的 GPU、给 rerank 回 GPU；
- WeKnora 通过 OpenAI 兼容 provider 接入（零代码改动，与现网一致）。

## 2. 现状基线

### 2.1 硬件与 HAMi
- GPU 节点：`xa-k8s-node41-gpu`、`xa-k8s-node42-gpu`，各 **2× NVIDIA A40（48 GB）**，共 4× A40 / 192 GB。
- 驱动：`580.65.06`（R580，支持 CUDA 12.x/13.x）。
- HAMi：上游 `Project-HAMi/HAMi`，镜像 `harbor-dev.glodon.com/data-stack/projecthami/hami:v2.6.1`（2025-08-04，**落后上游 v2.9.0 三个小版本**）。ConfigMap `kube-system/hami-device-plugin`：
  ```json
  {"config.json":"{
    \"nodeconfig\": [
      {\"name\":\"m5-cloudinfra-online02\",\"operatingmode\":\"hami-core\",
       \"devicememoryscaling\":1.8,\"devicesplitcount\":10,\"migstrategy\":\"none\",
       \"filterdevices\":{\"uuid\":[],\"index\":[]}}
    ]
  }"}
  ```
  - `m5-cloudinfra-online02` 是不存在的节点（配置拷贝残留）→ `devicesplitcount:10` 作为全局默认作用于所有 GPU 节点。
  - 每块 A40 切 10 个 vGPU，单 vGPU ≈ 4914 MiB / 10% 算力。
  - `devicememoryscaling:1.8` = 显存超分 1.8×（HAMI 显存页换出），这是 qwen3-32B（~18 GB）能"塞进"4.8 GB vGPU 但极慢的根因。

### 2.2 Xinference（Helm 管理）
- Helm release `xinference` @ ns `xinference`，chart `xinference-v0.14.0`，revision 1（2025-08-23 装的）。**helm values 为 null**，镜像 `v1.9.0-cu128` 是部署后 kubectl 改的（非 values 控制）——升级时要注意这点。
- Chart 来源：上游 `xorbitsai/xinference-helm-charts`。上游 chart 版本方案是 `0.0.1-vX.Y.Z`（跟 app 版本走），最新 `0.0.1-v2.12.0`（2026-07-04）。本集群装的 `xinference-v0.14.0` 版本号对不上上游 → **是基于上游 chart 改过、自定了版本号**。定制内容见 issue [xorbitsai/inference#3740](https://github.com/xorbitsai/inference/issues/3740)（"k8s 部署，每个 worker 可以单独指定 GPU 资源需求"，作者 lordk911/Kevin.Shin）：给 `values.yaml` 加 `config.workers: []` 列表，每个 worker 单独配 resources（含 HAMi 的 `nvidia.com/gpumem-percentage` / `nvidia.com/gpucores`），`deployment-worker.yaml` 用 `range` 动态生成 Deployment。**这就是当前 5 个独立 worker Deployment（worker-0..4）的由来**。升级需把此定制 rebase 到 `0.0.1-v2.12.0`（见阶段 A2）。
- 镜像：`harbor.glodon.com/data-stack/xprobe/xinference:v1.9.0-cu128`（自定义 CUDA 12.8 构建）。上游最新 **v2.12.0（2026-07-04）**，落后一个大版本（v2.0.0 于 2026-01-31）。
- 形态：supervisor 1 + worker-0..4（5 个独立 Deployment，每 worker limit `nvidia.com/gpu:1` / 32cpu / 128Gi）。
- 模型源 `XINFERENCE_MODEL_SRC=modelscope`；共享缓存 PVC `xinference-shared-volume-claim` 200Gi RWX（rook-cephfs）。
- Service：`service-supervisor.xinference:9997`（REST/OpenAI 兼容）、`:9999`（supervisor 内部）、NodePort `30003`。

### 2.3 当前已加载模型
| 模型 | 类型 | worker | 显存 | 状态 |
|---|---|---|---|---|
| qwen3-32B (AWQ Int4) | LLM | worker-2 | ~18 GB | 塞 4.8 GB vGPU，靠超分页换出，**极慢/半残** |
| qwen3-8B (AWQ Int4) | LLM | worker-3 | ~5 GB | 勉强 |
| DeepAnalyze 8B | LLM | worker-1 | ~5 GB | deepseek-r1-0528-qwen3 衍生 |
| bge-m3 (1024d, 8192tok) | 文本嵌入 | worker-4 | ~2 GB | replica 6，正常 |
| bge-reranker-v2-m3 | 文本 rerank | worker-4 | ~2 GB | replica 2，`accelerators=[]` → **跑在 CPU** |

### 2.4 WeKnora 接入现状（现网）
- LLM 走 UI 路径：设置→模型管理加 OpenAI 兼容 provider，百炼 qwen-plus + text-embedding-v3。不启用 builtin_models.yaml。
- 详见 `deploy/values-production.yaml` 与 memory `weknora-k8s-deployment-live`。

### 2.5 Dify（同集群）
- ns `dify`，v1.14.2（`harbor.glodon.com/data-stack/langgenius/dify-api:1.14.2`）。pod 调度在 node41/42。有多模态知识库管线（`dataset.is_multimodal`、`vector.create_multimodal`）。

## 3. 目标架构

| 卡 | HAMi 划分 | 用途 |
|---|---|---|
| node41 A40 #0 | 6× ~8 GB（`splitcount=6, memscaling=1.0`） | bge-m3 文本嵌入多副本 |
| node41 A40 #1 | 6× ~8 GB | bge-reranker-v2-m3 + 备用 |
| node42 A40 #0 | 整卡（`splitcount=1`） | 预留（未来自建中型模型/VLM） |
| node42 A40 #1 | 整卡（`splitcount=1`） | 预留 |

- node41 共 12 个 ~8 GB vGPU 给嵌入/rerank（远超需求，留余量）；node42 两整卡预留（VLM/LLM 走 API，暂不启用）。
- `devicememoryscaling` 改 1.0，关闭显存超分，避免"塞不下却页换出"的假可用。
- 自建 LLM 全部下线（qwen3-32B/8B/DeepAnalyze），LLM 走百炼。

## 4. 多模态嵌入/rerank 不做的决策依据

调研结论：**自建 Xinference 不部署多模态嵌入/rerank**，因为两个消费方都接不上。

### 4.1 WeKnora 侧
- [internal/models/embedding/aliyun.go](../internal/models/embedding/aliyun.go) 有"多模态嵌入"分支（模型名含 `vision`/`multimodal` 时路由 DashScope 多模态端点），但 `AliyunContent` 只有 `Text` 字段（[aliyun.go:65-67](../internal/models/embedding/aliyun.go#L65-L67)），`BatchEmbed` 只填文本 → **从未传图片**，是空壳。
- 入库管线 [internal/application/service/image_multimodal.go](../internal/application/service/image_multimodal.go) 对图片是：VLM-OCR/caption → 生成文本子 chunk → 走文本嵌入。**没有"图片→向量"的调用点**。
- 结论：WeKnora 根本不在用多模态嵌入，"阿里多模态嵌入接不进去"的根因在管线，不在 provider。要上多模态嵌入需改 WeKnora 入库代码 + 向量库 schema 加图片向量列，是特性项目，本轮不做。

### 4.2 Xinference 侧能力（供参考，不部署）
- 多模态嵌入内置模型：**jina-clip-v2**（文本+图片，0.9B，1024d）。API 收图片用 `input={"image":...}` 字典格式（非 OpenAI 兼容），见 `xinference/model/embedding/vllm/core.py`。
- 多模态 rerank 内置模型：**Qwen3-VL-Reranker-8B**（~16 GB，VL reranker）。
- 自定义模型（如 Multimodal-Embedding-one-peace-v1）可注册，但要写 spec。

### 4.3 Dify 侧
- Dify v1.14.2 有多模态知识库管线，但其 Xinference provider（`dify-official-plugins/models/xinference/models/text_embedding/text_embedding.py`）是纯文本：
  ```python
  embeddings = handle.create_embedding(input=texts)  # 只传文本
  ```
  `dify-official-plugins` 里无任何 provider 实现 `embed_image`。Dify 多模态嵌入走的是它自有 Jina cloud 等 provider，**不消费自建 Xinference 的多模态能力**。
- 结论：即便部署 jina-clip-v2，Dify 也用不上（除非改 Dify 的 Xinference plugin，又是代码活）。

### 4.4 GitHub issue 核查
无"阿里多模态嵌入不支持"的专门 issue。相关：
- [#1893](https://github.com/Tencent/WeKnora/issues/1893) open — rerank 配置 404（用户把 LLM 模型名填进 rerank，配置误用）
- [#1133](https://github.com/Tencent/WeKnora/issues/1133) open — 期望 UI 直接选 Xinference 已 running 的模型（功能请求）
- [#1487](https://github.com/Tencent/WeKnora/issues/1487) open — Xinference 上 Qwen3-VL/Qwen3.5 集成 bug
- [#172](https://github.com/Tencent/WeKnora/issues/172) / [#180](https://github.com/Tencent/WeKnora/issues/180) / [#593](https://github.com/Tencent/WeKnora/issues/593) closed

## 5. 分步执行计划

> 原则：每步可独立验证；影响现网服务的步骤（HAMi 重配、下线模型）前先确认；先在单 worker 验证镜像再全量。

### 阶段 A：镜像准备（不碰运行中服务）
**A1. 拉取上游 v2.12.0 并推到 Harbor**
```bash
# 走 China 镜像源（国内直连，无需代理；DaoCloud/1panel 已验证 manifest 200）
docker pull docker.m.daocloud.io/xprobe/xinference:v2.12.0
# 或: docker pull docker.1panel.live/xprobe/xinference:v2.12.0
docker tag  docker.m.daocloud.io/xprobe/xinference:v2.12.0 \
           harbor.glodon.com/data-stack/xprobe/xinference:v2.12.0
docker push harbor.glodon.com/data-stack/xprobe/xinference:v2.12.0
```
- 镜像 ~12.4 GB（CUDA 自带）。阿里云 ACR 无公开 `xprobe` 镜像（非 dockerhub 代理）；华为 SWR 有代理但要 SWR 账号登录。DaoCloud/1panel 匿名可拉，最省事。
- 驱动 580.65.06 兼容上游镜像自带的 CUDA（无需重建 cu128）。
- 若 Harbor 需匿名可拉，push 到 `data-stack` 项目（与现网镜像同项目）。
- **回退点**：若 v2.12.0 在 A40 上启动异常（罕见），改用 `docker build` 基于 `xinference:v2.12.0` 加 cu128 层重建，tag `v2.12.0-cu128`。

**A2. Rebase 自定义 chart 到上游 `0.0.1-v2.12.0`**（✅ 已完成，产物在 repo）

已基于上游 tag `0.0.1-v2.12.0` 源码 + issue [xorbitsai/inference#3740](https://github.com/xorbitsai/inference/issues/3740) 的 per-worker 方案，在 repo 内重建定制 chart：
- [deploy/xinference-chart/](../deploy/xinference-chart/) — 定制 chart（`Chart.yaml` version `0.0.1-weknora.1`/appVersion `v2.12.0`；`templates/deployment-worker.yaml` 重写为 `range config.workers` 生成 per-worker Deployment；`deployment-supervisor.yaml` 的 PVC 去 selector + 加 `resource-policy: keep` 支持 rook-cephfs 动态绑定；`values.yaml` 加 `config.workers`/`config.persistence.createPV` 字段）。
- [deploy/xinference-values.yaml](../deploy/xinference-values.yaml) — 本集群部署值（image v2.12.0、modelscope、rook-cephfs 100Gi、worker-0/1 钉 node41、node42 预留、supervisor 去 GPU）。
- `helm lint` 通过；`helm template` 干净渲染出 1 supervisor + 2 worker Deployment + PVC（rook-cephfs/100Gi/无 selector），名字与现网一致（`xinference-supervisor`/`worker-0`/`worker-1`）→ helm upgrade 原地更新不重命名。
- 升级时 worker-2/3/4（现网有，新 values 没定义）会被 helm 删除——预期行为（缩到 2 worker，都在 node41）。先做 C1 终止 LLM，再 helm upgrade。

**A3. 在 node42 一台整卡 worker 上验证镜像**（不影响 node41 在跑的 bge-m3/rerank）
```bash
# 临时起一个验证 pod，挂同一个 image，跑 bge-m3 自测
kubectl -n xinference run xinf-smoke --rm -i --restart=Never \
  --image=harbor.glodon.com/data-stack/xprobe/xinference:v2.12.0 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"xa-k8s-node42-gpu"},"resources":{"limits":{"nvidia.com/gpu":1}}}}' \
  -- xinference launch --model-name bge-m3 --model-type embedding
# 确认能从 modelscope 拉模型、能正常 serve、返回向量
```

### 阶段 B：HAMi 升级 + 异构重划（影响所有 GPU workload，需窗口）
**B1. HAMi 升级 v2.6.1 → v2.9.0**
```bash
# 备份当前配置
kubectl -n kube-system get cm hami-device-plugin -o yaml > /tmp/hami-device-plugin.yaml.bak.$(date +%s)
# 用上游 v2.9.0 chart 升级
helm repo add hami https://project-hami.github.io/HAMi 2>/dev/null || true
helm search repo hami/hami --version 2.9.0
helm -n kube-system upgrade hami hami/hami --version 2.9.0 \
  -f <你们当初的 HAMi 定制 values> --dry-run   # 先 --dry-run 看 diff，确认后去掉
```
- v2.9.0 对你们用的 `hami-core` 模式有性能优化，新增 DRA/CDI/webhook 配额检查等。
- **风险**：HAMi 是 GPU 虚拟化底座，升级期间 device-plugin/scheduler 重启会短暂影响所有 GPU pod（Dify/Xinference）。务必维护窗口，备好 GPU pod 重启预案。
- **若当初不是 helm 装的**（裸 YAML）：用 `kubectl apply -f` 上游 `hami-2.9.0` 资源，先 diff 现有资源。

**B2. 改 ConfigMap（异构重划）**
```bash
cat > /tmp/hami-config.json <<'EOF'
{
  "nodeconfig": [
    {"name":"xa-k8s-node41-gpu","operatingmode":"hami-core","devicememoryscaling":1.0,"devicesplitcount":6,"migstrategy":"none","filterdevices":{"uuid":[],"index":[]}},
    {"name":"xa-k8s-node42-gpu","operatingmode":"hami-core","devicememoryscaling":1.0,"devicesplitcount":1,"migstrategy":"none","filterdevices":{"uuid":[],"index":[]}}
  ]
}
EOF
kubectl -n kube-system edit cm hami-device-plugin   # 把 config.json 替换为上面内容
```
**B3. 滚动重启 hami-device-plugin 让配置生效**
```bash
kubectl -n kube-system rollout restart ds hami-device-plugin
kubectl -n kube-system rollout status ds hami-device-plugin
# 确认 node annotation 更新：node41 nvidia.com/gpu=12, node42 nvidia.com/gpu=2
kubectl get nodes -l gpu=on -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
```
- `devicememoryscaling` 1.8→1.0 关闭显存超分；node41 6 切（~8 GB/vGPU）给 embed/rerank，node42 整卡预留。
- **注意**：重启 device-plugin 会让该节点所有使用 GPU 的 pod 重新注册设备。建议维护窗口执行，盯 Dify/Xinference pod 状态。
- **影响**：node41 上现有 Xinference worker（各占 1 个 4.8 GB vGPU）会被重新评估为 8 GB vGPU；node42 上 worker 拿到整卡。下线 LLM 后这些 worker 才重新调度。
- **必须先做 C1（下线自建 LLM）再做 B**——否则占着超分显存的 qwen3-32B 在 scaling 收回时会 OOM。

### 阶段 C：Xinference 升级 + 下线自建 LLM
**C1. 下线自建 LLM（释放 GPU）**
```bash
# 经 supervisor REST API terminate（保留 bge-m3 / bge-reranker）
XINF=http://service-supervisor.xinference:9997
for m in qwen3-32B qwen3-8B DeepAnalyze; do
  kubectl -n xinference exec deploy/xinference-supervisor -- \
    curl -s -X DELETE "$XINF/v1/models/$m"
done
kubectl -n xinference exec deploy/xinference-supervisor -- curl -s "$XINF/v1/models" | jq '.data[].id'
```
**C2. 用新 chart helm upgrade**
```bash
# 先 dry-run 看差异（worker-2/3/4 会被删，worker-0/1 改 image+resources+nodeSelector）
helm -n xinference diff upgrade xinference deploy/xinference-chart -f deploy/xinference-values.yaml 2>/dev/null \
  || helm -n xinference template xinference deploy/xinference-chart -f deploy/xinference-values.yaml | less
# 执行
helm -n xinference upgrade xinference deploy/xinference-chart -f deploy/xinference-values.yaml
kubectl -n xinference rollout status deploy/xinference-supervisor
for d in xinference-worker-0 xinference-worker-1; do
  kubectl -n xinference rollout status deploy/$d
done
```
- v1.9.0 → v2.12.0 跨大版本：模型注册/元数据格式可能变，已 launch 模型 UID 可能失效 → 需在阶段 D 重新 launch。共享 PVC 权重缓存可复用；launch 时显式指定 `--model-engine-format sentence_transformers`。
- 把镜像 tag 与定制写进 `deploy/xinference-values.yaml` 固化，避免再次 helm 漂移。

**C3. 重新调度 worker 到目标节点（按第 3 节布局）**
- 给 embed worker（跑 bge-m3）加 `nodeSelector: kubernetes.io/hostname=xa-k8s-node41-gpu`；
- node42 上的 worker 暂时缩到 0 或保留 1 个整卡 worker 偙备（视实际 embed 吞吐需求）。
- 具体：编辑 worker Deployment 的 nodeSelector / 副本数，或 helm values。

### 阶段 D：部署文本嵌入 + 排序
**D1. launch 模型**
```bash
XINF=http://service-supervisor.xinference:9997
kubectl -n xinference exec deploy/xinference-supervisor -- sh -c '
  xinference launch --model-name bge-m3 --model-type embedding --model-engine-format sentence_transformers &&
  xinference launch --model-name bge-reranker-v2-m3 --model-type rerank
'
# 验证
kubectl -n xinference exec deploy/xinference-supervisor -- curl -s "$XINF/v1/models" | jq '.data[] | {id,model_type,accelerators,address}'
```
- 确认 bge-reranker 的 `accelerators` 不再为 `[]`（拿到 GPU）。
- bge-m3 replica 数按需（6 够，可降到 3-4 省显存）。

**D2. 自测嵌入/排序 API**
```bash
# 嵌入
curl -s "$XINF/v1/embeddings" -H 'Content-Type: application/json' \
  -d '{"model":"bge-m3","input":"测试文本"}' | jq '.data[0].embedding | length'
# 排序
curl -s "$XINF/v1/rerank" -H 'Content-Type: application/json' \
  -d '{"model":"bge-reranker-v2-m3","query":"向量数据库","documents":["Milvus是向量数据库","今天天气不错"]}' | jq '.results'
```

### 阶段 E：WeKnora 接入（零代码，UI 路径）
1. WeKnora 控制台 → 设置 → 模型管理 → 新增供应商（OpenAI 兼容）：
   - Base URL：`http://service-supervisor.xinference:9997/v1`
   - API Key：任意（Xinference 未开鉴权则填 `sk-xinference` 占位）
2. 嵌入模型：`bge-m3`（维度 1024）→ 测试通过后设为知识库默认嵌入。
3. Rerank 模型：`bge-reranker-v2-m3` → 测试通过后绑定到智能体。
4. VLM（图片 OCR/caption）：走百炼 qwen-vl（已定）。
5. LLM：走百炼 qwen-plus（已定，不变）。
- 与现网百炼 text-embedding-v3 切换时，**维度不同（v3=1024 或可配，bge-m3=1024）**：若切嵌入模型需重建知识库向量索引（存量数据重嵌入）。建议新知识库用 bge-m3，存量按需迁移。

## 6. 影响评估

| 组件 | 影响 | 缓解 |
|---|---|---|
| Dify（node41/42） | HAMi 重配期间 device-plugin 重启，GPU pod 可能短暂重新注册 | 维护窗口执行；Dify 用 GPU 的 pod（dify-api/worker）观察状态，CrashLoop 则手动重启 |
| WeKnora（ns weknora） | 无直接影响（不依赖 GPU node）；嵌入模型从百炼 v3 切到自建 bge-m3 需重嵌存量 | 新库用 bge-m3；存量迁移单独评估 |
| Harbor / Keycloak 等 | 无 | — |
| 自建 LLM 用户 | qwen3-32B/8B/DeepAnalyze 下线 | 提前通知；LLM 走百炼 qwen-plus |
| Xinference 共享 PVC | 升级后模型权重缓存可复用；UID 重置需重新 launch | 不清缓存 |

## 7. 回滚方案

| 已执行阶段 | 回滚动作 |
|---|---|
| A（镜像/chart） | 删新镜像 tag，未动运行服务，无需回滚 |
| B1（HAMi 升级） | `helm -n kube-system rollback hami <旧 revision>` 或重新 apply v2.6.1 资源 |
| B2/B3（HAMi 重配） | `kubectl -n kube-system apply -f /tmp/hami-device-plugin.yaml.bak.<ts>` 还原 CM，再 `rollout restart ds hami-device-plugin` |
| C1（下线 LLM） | 重新 `xinference launch` 对应模型（权重缓存仍在 PVC） |
| C2（Xinference 升级） | `helm -n xinference rollback xinference <旧 revision>`；或 `kubectl set image` 改回 `v1.9.0-cu128` |
| D（launch embed/rerank） | `xinference terminate` 新模型 |
| E（WeKnora 接入） | UI 改回百炼 text-embedding-v3 / 百炼 rerank |

## 8. 风险与未决项

1. **v1.9.0 → v2.12.0 跨大版本兼容性**：模型注册/元数据格式可能变化，升级后已 launch 模型 UID 可能失效，需重新 launch。共享 PVC 缓存（权重）应可复用，但引擎格式（sentence_transformers vs vllm）若有默认值变化需在 launch 时显式指定 `--model-engine-format`。
2. **自定义 chart rebase（定制长期必需，非临时）**：上游 `0.0.1-v2.12.0` **未采纳** issue [xorbitsai/inference#3740](https://github.com/xorbitsai/inference/issues/3740) 的 per-worker 方案——`deployment-worker.yaml` 仍是单个 Deployment + `replicas: worker_num`，所有副本共用一份 `resources`（`charts.worker.resources` helper）。上游只新增了**全局** `vgpu` 开关（`xinferenceWorker.worker.vgpu` + `nvidia.com/gpumem-percentage`/`gpucores`），不能 per-worker 差异化。要保留 embed/rerank/node42 预留的差异化布局，**必须继续维护 #3740 的 chart 补丁**（`config.workers` 列表 + range 生成 N 个独立 Deployment），在 `0.0.1-v2.12.0` 上重新实现。借此把镜像 tag/model_src/worker 布局写进 `deploy/xinference-values.yaml` 固化，根治 helm 漂移。
3. **HAMi 升级 v2.6.1→v2.9.0 风险**：HAMi 是 GPU 虚拟化底座，升级重启 device-plugin/scheduler 期间所有 GPU pod（Dify/Xinference）短暂受影响。v2.9.0 的 hami-core 模式有改动，升级后须验证 `operatingmode: hami-core` 仍正常工作（A40 上）。建议先在维护窗口做 HAMi 升级，验证 Dify GPU pod 正常后再做 HAMi 重配。
4. **HAMi 重配对 Dify 的影响**：`devicememoryscaling` 1.8→1.0 收回超分显存时，占着超分显存的 pod 会 OOM。**务必先下线自建 LLM（C1）再做 HAMi 重配（B2）**——顺序调整为 A → C1 → B1 → B2/B3 → C2/C3 → D → E。
5. **Helm vs kubectl 漂移**：现网镜像被人 kubectl 改过（helm values=null）。本轮通过把定制写进 `deploy/xinference-values.yaml` 固化，根治漂移。
6. **节点 node42 整卡预留是否浪费**：4× A40 中 2 张整卡闲置。若嵌入/排序吞吐需求高，可把 node42 也切 6×8。本轮保守预留。
7. **bge-m3 vs 百炼 text-embedding-v3 切换**：维度/模型不同，存量知识库需重嵌。是否切、何时切由业务定。
8. **未做多模态嵌入**：若未来 WeKnora 要图片向量检索，需 (a) 写 Xinference 多模态 embedder provider（发 `input={"image":...}`），(b) 改入库管线存图+图片嵌入，(c) 向量库加图片向量列。届时再单独立项。Dify 的多模态嵌入同理走自有 provider，不消费 Xinference。

## 9. 修订后的执行顺序

鉴于风险 3/4，顺序调整为：

```
A（镜像 + chart rebase，不动现网）
  → C1（下线自建 LLM，释放 GPU/超分显存）
  → B1（HAMi 升级 v2.6.1→v2.9.0，维护窗口，验证 Dify GPU pod 正常）
  → B2/B3（HAMi 异构重划，此时无大模型占超分显存，OOM 风险最低）
  → C2/C3（helm upgrade Xinference + 重调度 worker）
  → D（launch bge-m3 + bge-reranker-v2-m3，给 GPU）
  → E（WeKnora UI 接入）
  → 验收：rerank 在 GPU、bge-m3 可用、WeKnora 知识库问答正常、Dify 正常
```

---

*本文档基于 2026-07-06 集群实况调研。执行前请再次核对镜像 tag、HAMi ConfigMap、worker 调度状态。*
