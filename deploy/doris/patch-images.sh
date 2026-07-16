#!/usr/bin/env bash
# 把 vendored/ 下上游 operator YAML 里的镜像改写为你的镜像仓库（HARBOR，从 deploy/.env 读），
# 产出 *.patched.yaml。幂等：以未 patch 的源文件为输入重新生成。
#
# 上游默认镜像（apache/doris-operator 26.0.0 tag）：
#   doris-operator  → apache/doris:operator-latest
#   fdb-operator    → foundationdb/fdb-kubernetes-operator:v1.46.0
#   fdb-sidecar     → foundationdb/foundationdb-kubernetes-sidecar:7.1.46-1
#   fdb-server      → foundationdb:7.1.46  （FoundationDBCluster imageType=split，operator 解析）
#
# 前置：deploy/scripts/mirror-litefuse-images.sh 已把上述镜像推到你的仓库。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "${REPO}/deploy/.env" ] && { set -a; . "${REPO}/deploy/.env"; set +a; }
: "${HARBOR:?需 HARBOR（放 deploy/.env，如 <your-registry>/data-stack）}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/vendored"
# HARBOR 从 deploy/.env 读（顶部已 source）

# doris-operator 镜像：docker hub 无 operator-26.0.0 tag，26.0.0 operator 源码对应 operator-latest。
# mirror 脚本已同步 operator-latest 到你的仓库。
OP_TAG="${DORIS_OPERATOR_TAG:-operator-latest}"
echo "==> doris-operator → ${HARBOR}/doris:${OP_TAG}"
sed -E "s|apache/doris:operator-latest|${HARBOR}/doris:${OP_TAG}|g" \
  "${SRC}/disaggregated-operator.yaml" > "${SRC}/disaggregated-operator.patched.yaml"

echo "==> fdb-operator / sidecar → harbor"
# operator pod：fdb-kubernetes-operator:v1.46.0 + sidecar 7.1.46-1（vendored/fdb-operator.yaml）
# 同时修上游 kustomize 输出的两个坑（apply 时必须 -n doris）：
#   1. ClusterRoleBinding subject 残留 namespace: metadata.namespace（无效）→ 改 doris
#      （fieldPath: metadata.namespace 是 downward api，不动）
sed -E \
  -e "s|foundationdb/fdb-kubernetes-operator:v1.46.0|${HARBOR}/fdb-kubernetes-operator:v1.46.0|g" \
  -e "s|foundationdb/foundationdb-kubernetes-sidecar:7.1.46-1|${HARBOR}/foundationdb-kubernetes-sidecar:7.1.46-1|g" \
  -e 's|^  namespace: metadata.namespace$|  namespace: doris|' \
  "${SRC}/fdb-operator.yaml" > "${SRC}/fdb-operator.patched.yaml"

# FDB 集群镜像（version 7.1.38）已在本仓库手写的 ${HERE}/fdb-cluster.yaml 里直接指 harbor，
# 不 patch 上游 cluster-single（多 metadata: 段 sed 易误改）。

echo
echo "Done. Apply order (see deploy/scripts/litefuse-bootstrap.sh 编排):"
echo "  kubectl apply -f ${SRC}/fdb-crds.yaml"
echo "  kubectl apply -f ${SRC}/fdb-operator.patched.yaml"
echo "  kubectl apply -f ${HERE}/fdb-cluster.yaml                # 等 kubectl get fdb -n doris AVAILABLE=true"
echo "  kubectl apply -f ${SRC}/crds.yaml"
echo "  kubectl apply -f ${SRC}/disaggregated-operator.patched.yaml # 等 doris-operator pod Running"
echo "  kubectl apply -f ${HERE}/ddc-cluster.yaml                  # 等 kubectl get ddc -n doris → green"
echo "  kubectl apply -f ${HERE}/create-storage-vault.yaml         # 建 MinIO Vault + 设默认"
echo
echo "NOTE: fdb-cluster.yaml 里 foundationdb server/sidecar 镜像已直接写 harbor 名（mirror 脚本已推）。"
