#!/usr/bin/env bash
# 把 LiteFuse + Doris DDC + FDB + Redis + mysql 全部镜像从 docker.io 拉取并推到
# 你的镜像仓库（HARBOR，从 deploy/.env 读）。
# 幂等：仓库已存在该 tag 则 skip（docker manifest inspect 探测）。
#
# 企业内网拉 docker.io 可能需代理：https_proxy=http://127.0.0.1:7897 bash deploy/scripts/mirror-litefuse-images.sh
# 仅 linux/amd64。凭据/仓库地址放 deploy/.env（不进 git），本脚本自动 source。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "${REPO}/deploy/.env" ] && { set -a; . "${REPO}/deploy/.env"; set +a; }
: "${HARBOR:?需 HARBOR（放 deploy/.env，如 <your-registry>/data-stack）}"

# 源镜像 → harbor 目标名:tag（目标仓库名与源同名，便于 patch 脚本引用）
images=(
  "litefuse/litefuse-web:26.0.1"
  "litefuse/litefuse-worker:26.0.1"
  "apache/doris:fe-4.1.3"
  "apache/doris:be-4.1.3"
  "apache/doris:ms-4.1.3"
  "apache/doris:operator-latest"          # 26.0.0 operator 源码对应的镜像（docker hub 无 operator-26.0.0 tag）
  "redis:7-alpine"
  "mysql:5.7"
  # FoundationDB（Doris DDC 元数据后端）
  "foundationdb/fdb-kubernetes-operator:v1.46.0"        # operator pod（vendored/fdb-operator.yaml）
  "foundationdb/foundationdb-kubernetes-sidecar:7.1.46-1"  # operator pod 的 init/sidecar
  "foundationdb/foundationdb:7.1.38"                    # FDB 集群 server（version 7.1.38）
  "foundationdb/foundationdb-kubernetes-sidecar:7.1.38-1"  # FDB 集群 sidecar/init（version 7.1.38）
)

harbor_exists() { docker manifest inspect "$1" >/dev/null 2>&1; }

push_one() {
  local src="$1"
  local dst="${HARBOR}/${src#*/}"          # litefuse/litefuse-web:26.0.1 → .../litefuse-web:26.0.1
  if harbor_exists "$dst"; then
    echo "  ✓ exists  $dst"
    return
  fi
  echo "  pull      $src"
  docker pull --platform linux/amd64 "$src"
  docker tag "$src" "$dst"
  echo "  push      $dst"
  docker push "$dst"
  docker rmi "$src" "$dst" >/dev/null 2>&1 || true
}

echo "==> 同步镜像（linux/amd64）"
for img in "${images[@]}"; do push_one "$img"; done

# 无回退：所有 tag 已在 docker hub 核实存在（fe/be/ms-4.1.3 ✓、operator-latest ✓、foundationdb 7.1.38/7.1.46-1 ✓）。
# 若 docker.io 某镜像后续下架，单独 docker pull <src> 失败时再人工处理。

echo
echo "Done. 验证："
echo "  docker manifest inspect ${HARBOR}/litefuse-web:26.0.1"
echo "  docker manifest inspect ${HARBOR}/doris:fe-4.1.3"
echo "  docker manifest inspect ${HARBOR}/doris:operator-latest"
echo "  docker manifest inspect ${HARBOR}/foundationdb:7.1.38"
echo
echo "下一步："
echo "  cd deploy/doris && https_proxy=http://127.0.0.1:7897 bash fetch-vendored.sh && bash patch-images.sh"
echo "  bash deploy/scripts/litefuse-bootstrap.sh"
