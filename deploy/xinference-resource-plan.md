# Xinference GPU 资源规划

> 2026-07-07 · 基于 4× NVIDIA A40（48GB，node41/42 各 2 块）+ HAMi v2.9.0（hami-core 模式）

## HAMi v2.9.0 分配行为（实测）

- `nvidia.com/gpu: 1`（不指定 gpumem）= **整块物理 A40**（48GB + 100% 算力），多个 pod 会超分挤在同一卡。
- 要让多个 worker 共享一块 A40，必须在 resources 里加 `nvidia.com/gpumem-percentage`（百分比）+ `nvidia.com/gpucores`，HAMi 才按比例切片。
- `devicesplitcount`（ConfigMap）只控制每卡最多报告几个 vGPU，**不切显存**。B2 改的 per-node splitcount 会被 helm upgrade 覆盖回 chart 默认（`your-node-name`/10），所以别依赖它，用 gpumem-percentage。
- launch 指定 worker：`xinference launch ... --worker-ip <pod-ip>`（v1.9.0 支持）；指定 worker 内 GPU：`--gpu-idx 0,1`。

## 规划模型清单

| 模型 | 类型 | 大小 | 镜像版本要求 |
|---|---|---|---|
| bge-m3 | 文本嵌入 | ~2GB | v1.9.0 ✅ |
| bge-reranker-v2-m3 | 文本排序 | ~2GB | v1.9.0 ✅ |
| jina-clip-v2 | 多模态嵌入（文+图） | ~2GB | v2.x（v2.11 待试） |
| Qwen3-VL-Reranker-8B | 多模态排序 | ~16GB(AWQ) | v2.x（v2.11 待试） |
| 27B 紧凑模型 | LLM | ~16GB(AWQ Int4) | v2.x 或 v1.9 |

## 目标布局（接近方案 B：node41 共享小模型，node42 给大模型+预留）

```
node41 GPU0 [48GB]  worker-0 (gpumem 25%≈12GB) → bge-m3          文本嵌入
                    worker-1 (gpumem 25%≈12GB) → bge-reranker-v2-m3  文本排序
node41 GPU1 [48GB]  worker-2 (gpumem 25%≈12GB) → jina-clip-v2    多模态嵌入 [v2.11]
                    worker-3 (gpumem 40%≈19GB) → Qwen3-VL-Reranker-8B 多模态排序 [v2.11]
node42 GPU0 [48GB]  worker-4 (整卡)            → 27B 紧凑模型     LLM [v2.11/待定]
node42 GPU1 [48GB]  worker-5 (整卡)            → 预留
```

- node41 两块 A40 共享 4 个小/中模型（gpumem-percentage 切片，2 个/卡）。bge-m3+reranker 各 12GB（远大于 2GB 本体，留 KV/批量余量）；VL-Reranker-8B 19GB（够 16GB AWQ）。
- node42：27B AWQ(~16GB) 独占 GPU0 整卡（留 KV cache 余量）；GPU1 整卡预留（未来 BF16 27B 或其它）。
- 6 个 worker 一次性 helm upgrade 部署齐（per #3740 chart），launch 时用 `--worker-ip` 把模型钉到对应 worker。

## 执行节奏

- **今晚（v1.9.0）**：2 worker（worker-0/1）跑 bge-m3 + bge-reranker，WeKnora 接入。已在跑。
- **明天（v2.11.0）**：helm upgrade 到 v2.11 + 6 worker 布局（values 已备好，多模态/27B worker 取消注释）→ launch jina-clip-v2 / Qwen3-VL-Reranker-8B / 27B。v2.11 若也有 torchcodec bug，再回退或修镜像。
- 多模态嵌入/排序的**消费方**仍待定：WeKnora 入库管线不消费多模态嵌入（VLM-OCR→文本嵌入），Dify 的 Xinference provider 也纯文本。部署后若要真正用，需改 WeKnora 入库代码或 Dify plugin（见 xinference-upgrade-plan.md 第 4 节）。

## values 落地（deploy/xinference-values.yaml）

6 worker 布局写在 `config.workers`，node41 的 4 个用 `vgpu.resources` 带 `nvidia.com/gpumem-percentage`/`gpucores`，node42 的 2 个整卡（`nvidia.com/gpu: 1` 不带 gpumem）。多模态/27B 的 worker 先注释（今晚不启用），明天 v2.11 取消注释。
