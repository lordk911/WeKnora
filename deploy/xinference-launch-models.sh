#!/usr/bin/env bash
# Launch all WeKnora self-hosted models on the Xinference v2.12.0 cluster.
# Managed script — keeps the exact launch params that work on this cluster
# (HAMi vGPU slices on node41, whole-card on node42, vLLM engine everywhere).
#
# Run from anywhere; uses kubectl to find the supervisor pod and worker IPs.
#   bash deploy/xinference-launch-models.sh          # launch all
#   bash deploy/xinference-launch-models.sh status    # just list
#
# Prereqs: Xinference helm release up (supervisor + worker-0..5), HAMi v2.9.0,
# model weights cached on the shared PVC (modelscope src).
#
# Why these flags:
#   --model-engine vllm            — bypasses v2.12.0 sentence_transformers
#                                    torchcodec bug (#4960); works for all 5.
#   --replica 2 --gpu-idx 0,1       — INTRA-WORKER multi-replica: each node41
#                                    worker has nvidia.com/gpu:2 (2 vGPUs),
#                                    so --replica 2 launches 2 independent vLLM
#                                    instances per worker, one per vGPU (data-
#                                    parallel, NOT tensor-parallel — no NCCL
#                                    cross-GPU cooperation, so HAMi's multi-
#                                    vGPU-per-pod bug that broke 27B TP=2 does
#                                    NOT apply). 2× throughput per model.
#   --disable-virtual-env          — text embed/rerank + 27B run on the base
#                                    image vllm directly (no venv needed).
#                                    OMIT for VL-Reranker (its model_spec
#                                    requires a venv for vllm-engine deps;
#                                    venv is cached at /data/virtualenv/v4/).
#   --max_model_len 32768          — VL-Embedding/Reranker-2B default
#                                    max_seq_len is 256K → KV cache OOM on a
#                                    12GB vGPU slice; cap at 32K.
#   --runner pooling               — VL-Reranker-2B under vLLM needs pooling
#                                    mode for LLM.score() (rerank API),
#                                    else "LLM.score() is only supported for
#                                    pooling models".
#   --kv_cache_dtype fp8 +         — 27B FP8 weights ~29GB on a 48GB A40;
#   --enforce_eager True +           vLLM v1 profiling overshoots to 46GB and
#   --env PYTORCH_CUDA_ALLOC_CONF    OOMs at KV allocation. enforce_eager skips
#      expandable_segments:True       graph capture, expandable_segments stops
#                                    fragmentation. 32K context (not 128K) —
#                                    model recommends ≥128K but single A40
#                                    can't fit it; 128K needs node42 dual-card
#                                    (see deploy/xinference-upgrade-plan.md).
set -euo pipefail

NS=xinference
SUP_POD=$(kubectl -n "$NS" get pod -l app=xinference-supervisor -o jsonpath='{.items[0].metadata.name}')
SUP_IP=$(kubectl  -n "$NS" get pod -l app=xinference-supervisor -o jsonpath='{.items[0].status.podIP}')
ENDPOINT="http://$SUP_IP:9997"
XINF="kubectl -n $NS exec $SUP_POD -- xinference launch -e $ENDPOINT"

worker_ip() { kubectl -n "$NS" get pod -l "worker-name=$1" -o jsonpath="{.items[0].status.podIP}"; }

wait_worker_registered() {
  local ip=$1 name=$2
  for _ in $(seq 1 20); do
    kubectl -n "$NS" exec "$SUP_POD" -- curl -s "$ENDPOINT/v1/workers" 2>/dev/null \
      | grep -q "$ip" && { echo "$name registered ($ip)"; return 0; }
    sleep 3
  done
  echo "ERROR: $name ($ip) not registered with supervisor" >&2; return 1
}

launch() {  # launch <flag-string...> — prints + runs
  echo "+ xinference launch $*"
  $XINF "$@"
}

status() {
  echo "=== /v1/models ==="
  kubectl -n "$NS" exec "$SUP_POD" -- curl -s "$ENDPOINT/v1/models" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);[print(f'  {m[\"id\"]:30s} {m[\"model_type\"]}') for m in d.get('data',[])]" 2>/dev/null \
    || kubectl -n "$NS" exec "$SUP_POD" -- curl -s "$ENDPOINT/v1/models"
}

if [[ "${1:-}" == "status" ]]; then status; exit 0; fi

echo "=== supervisor: $SUP_POD ($SUP_IP) ==="

# --- node41: text embed + rerank, 2 replicas each (worker-0/1, each 2 vGPUs) ---
W0=$(worker_ip worker-0); wait_worker_registered "$W0" worker-0
W1=$(worker_ip worker-1); wait_worker_registered "$W1" worker-1
launch --model-name Qwen3-Embedding-0.6B --model-type embedding --model-engine vllm \
  --model-uid Qwen3-Embedding-0.6B --worker-ip "$W0" --replica 2 --gpu-idx 0,1 --disable-virtual-env
launch --model-name Qwen3-Reranker-0.6B --model-type rerank --model-engine vllm \
  --model-uid Qwen3-Reranker-0.6B --worker-ip "$W1" --replica 2 --gpu-idx 0,1 --disable-virtual-env

# --- node41: multimodal embed + rerank, 2 replicas each (worker-2/3, each 2 vGPUs) ---
W2=$(worker_ip worker-2); wait_worker_registered "$W2" worker-2
W3=$(worker_ip worker-3); wait_worker_registered "$W3" worker-3
launch --model-name Qwen3-VL-Embedding-2B --model-type embedding --model-engine vllm \
  --model-uid Qwen3-VL-Embedding-2B --worker-ip "$W2" --replica 2 --gpu-idx 0,1 --disable-virtual-env --max_model_len 32768
# VL-Reranker: vLLM engine requires the virtualenv (model_spec conditional
# vllm_dependencies); do NOT pass --disable-virtual-env. venv is cached on PVC.
launch --model-name Qwen3-VL-Reranker-2B --model-type rerank --model-engine vllm \
  --model-uid Qwen3-VL-Reranker-2B --worker-ip "$W3" --replica 2 --gpu-idx 0,1 --max_model_len 32768 --runner pooling

# --- node42: 27B LLM (whole A40, single card, 32K) ---
W5=$(worker_ip worker-5); wait_worker_registered "$W5" worker-5
launch --model-name qwen3.6 --size-in-billions 27 --model-format fp8 --model-type LLM \
  --model-engine vllm --model-uid qwen3.6-27B-32k \
  --n-gpu 1 --worker-ip "$W5" --disable-virtual-env \
  --max_model_len 32768 --kv_cache_dtype fp8 --enforce_eager True \
  --env PYTORCH_CUDA_ALLOC_CONF expandable_segments:True

echo
echo "=== launch submitted; models load async (27B ~3min, others <1min) ==="
status
