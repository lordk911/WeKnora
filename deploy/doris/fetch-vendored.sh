#!/usr/bin/env bash
# 从 apache/doris-operator 26.0.0 tag 下载 DDC 部署所需的上游 YAML 到 vendored/（不进 git，离线/审计用）。
# 企业内网拉 raw.githubusercontent 需代理，按需 inline 前缀代理：
#   https_proxy=http://127.0.0.1:7897 bash deploy/doris/fetch-vendored.sh
set -euo pipefail

TAG="${1:-26.0.0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/vendored"
mkdir -p "$OUT"

BASE="https://raw.githubusercontent.com/apache/doris-operator/${TAG}"

files=(
  "config/crd/bases/crds.yaml|crds.yaml"
  "config/operator/disaggregated-operator.yaml|disaggregated-operator.yaml"
  "config/operator/fdb-operator.yaml|fdb-operator.yaml"
  "doc/examples/disaggregated/fdb/cluster-single.yaml|fdb-cluster-single.yaml"
)

# FDB CRDs（3 个，合并存一个文件）
fdb_crd_base="https://raw.githubusercontent.com/FoundationDB/fdb-kubernetes-operator/main/config/crd/bases"

echo "==> doris-operator ${TAG} → $OUT"
for entry in "${files[@]}"; do
  src="${entry%%|*}"; dst="${entry##*|}"
  echo "  $src → $dst"
  curl -fsSL "${BASE}/${src}" -o "${OUT}/${dst}"
done

echo "==> FoundationDB CRDs → fdb-crds.yaml"
: > "${OUT}/fdb-crds.yaml"
for crd in foundationdbclusters foundationdbbackups foundationdbrestores; do
  echo "  ${crd}"
  curl -fsSL "${fdb_crd_base}/apps.foundationdb.org_${crd}.yaml" >> "${OUT}/fdb-crds.yaml"
  echo "---" >> "${OUT}/fdb-crds.yaml"
done

echo
echo "Done. Next: bash deploy/doris/patch-images.sh   (把上游镜像改写为 <your-registry>/data-stack)"
echo "Apply: kubectl apply -f ${OUT}/fdb-crds.yaml -f ${OUT}/fdb-operator.yaml ..."
