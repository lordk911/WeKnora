#!/usr/bin/env python3
# Milvus 端到端压测: 768d 向量, 100k insert + HNSW + 1k search
# 跑: /app/api/.venv/bin/python /tmp/bench_milvus.py
import time, sys
import numpy as np
from pymilvus import MilvusClient

URI = "http://milvus.milvus:19530"
TOKEN = "dify:dify@admin"    # admin 角色, default 库可建/删集合
DIM = 768
N = 100000
BATCH = 5000
COLL = "bench_perf"

print("connecting...", flush=True)
client = MilvusClient(uri=URI, token=TOKEN)
print("connected", flush=True)

# 清旧
if client.has_collection(COLL):
    client.drop_collection(COLL)
    print("dropped old", flush=True)

# quick-create: auto_id PK + 单 vector 字段(dim 768, COSINE)
client.create_collection(collection_name=COLL, dimension=DIM, metric_type="COSINE", auto_id=True)
print("collection created dim=%d" % DIM, flush=True)

# 造数据 (float32, 100k x 768 = 307 MiB)
rng = np.random.default_rng(42)
vecs = rng.random((N, DIM), dtype=np.float32)
print("data ready shape=%s size=%.1f MiB" % (vecs.shape, vecs.nbytes/1024/1024), flush=True)

# ---- INSERT ----
t0 = time.time()
total = 0
for i in range(0, N, BATCH):
    batch = vecs[i:i+BATCH]
    rows = [{"vector": vecs[j]} for j in range(i, i+len(batch))]
    client.insert(collection_name=COLL, data=rows)
    total += len(batch)
    if (i // BATCH) % 4 == 0:
        print("  inserted %d, elapsed %.1fs" % (total, time.time()-t0), flush=True)
dt = time.time() - t0
print("=== INSERT DONE: %d vecs in %.2fs => %.0f vec/s, %.1f MiB/s ===" % (
    total, dt, total/dt, (vecs.nbytes/1024/1024)/dt), flush=True)

# ---- INDEX (HNSW) ----
# quick-create 自动建了名为 "vector" 的默认 index 且自动 loaded, 先 release 再删再建 HNSW
try:
    client.release_collection(COLL)
    print("released collection", flush=True)
except Exception as e:
    print("release skip: %s" % str(e)[:60], flush=True)
print("listing existing indexes...", flush=True)
try:
    idxs = client.list_indexes(collection_name=COLL)
    print("  existing: %s" % idxs, flush=True)
    for ixn in idxs:
        try:
            client.drop_index(collection_name=COLL, index_name=ixn)
            print("  dropped %s" % ixn, flush=True)
        except Exception as e:
            print("  drop %s skip: %s" % (ixn, str(e)[:60]), flush=True)
except Exception as e:
    print("  list skip: %s" % str(e)[:80], flush=True)
print("creating HNSW index...", flush=True)
t0 = time.time()
ip = client.prepare_index_params()
ip.add_index(field_name="vector", index_name="vec_hnsw", index_type="HNSW",
             metric_type="COSINE", params={"M": 16, "efConstruction": 200})
client.create_index(collection_name=COLL, index_params=ip)
print("index built in %.2fs" % (time.time()-t0), flush=True)

# ---- LOAD ----
t0 = time.time()
client.load_collection(COLL)
print("loaded in %.2fs" % (time.time()-t0), flush=True)

# ---- SEARCH ----
Q = 1000
qs = rng.random((Q, DIM), dtype=np.float32)
sp = {"metric_type": "COSINE", "params": {"ef": 64}}
# warmup (触发并等待 segment 就绪)
for _ in range(3):
    try:
        client.search(COLL, data=[qs[0].tolist()], limit=10, search_params=sp)
    except Exception as e:
        print("warmup wait: %s" % str(e)[:60], flush=True)
        time.sleep(2)
t0 = time.time()
for i in range(Q):
    client.search(COLL, data=[qs[i].tolist()], limit=10, search_params=sp)
dt = time.time() - t0
print("=== SEARCH DONE: %d q in %.2fs => %.1f QPS, %.1f ms/q ===" % (
    Q, dt, Q/dt, dt*1000/Q), flush=True)

# 清理
client.drop_collection(COLL)
print("cleaned up", flush=True)
