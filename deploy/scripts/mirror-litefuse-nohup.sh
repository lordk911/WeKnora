#!/usr/bin/env bash
# LiteFuse + Doris DDC + FDB + Redis + mysql 镜像同步（单文件 nohup 后台脱机版）。
# 这个脚本是自包含的：镜像列表内置，无外部依赖，单独拷到任意 Linux 服务器即可跑。
# 日志写脚本所在目录 mirror-<时间>.log，断网自动重试（每镜像最多 5 次），仓库已有则 skip。
#
# 用法：
#   export HARBOR=<your-registry>/data-stack   # 目标镜像仓库（必填）
#   export HARBOR_USER=<账号>                  # 推送需要（拉取匿名）
#   export HARBOR_PASS=<密码>
#   export https_proxy=http://127.0.0.1:7897   # 拉 docker.io 需代理时设；能直连 docker.io 则不设
#   nohup bash mirror-litefuse-nohup.sh > /dev/null 2>&1 &
#   tail -f mirror-*.log
set -uo pipefail   # 不用 -e：单镜像失败不退出，最后汇总

: "${HARBOR:?需 export HARBOR=<your-registry>/data-stack}"    # 目标仓库，从环境读（单文件脚本不 source .env）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 日志写脚本所在目录（拷到哪都行，不依赖仓库结构）
LOG="${SCRIPT_DIR}/mirror-$(date +%Y%m%d-%H%M%S).log"

# 全部输出进日志（带时间戳），同时 tee 到 stdout（nohup 后 stdout 已重定向到 /dev/null 也没关系）
exec > >(while IFS= read -r line; do printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$line"; done | tee -a "$LOG") 2>&1

echo "======================================================"
echo "LiteFuse 镜像同步  $(date)"
echo "harbor: ${HARBOR}"
echo "log:    ${LOG}"
[ -n "${https_proxy:-}" ] && echo "proxy:  ${https_proxy}"
echo "======================================================"

# 源镜像（docker.io 拉取）→ harbor 目标名（去掉首个 repo 前缀）
images=(
  "litefuse/litefuse-web:26.0.1"
  "litefuse/litefuse-worker:26.0.1"
  "apache/doris:fe-4.1.3"
  "apache/doris:be-4.1.3"
  "apache/doris:ms-4.1.3"
  "apache/doris:operator-latest"
  "redis:7-alpine"
  "mysql:5.7"
  "foundationdb/fdb-kubernetes-operator:v1.46.0"
  "foundationdb/foundationdb-kubernetes-sidecar:7.1.46-1"
  "foundationdb/foundationdb:7.1.38"
  "foundationdb/foundationdb-kubernetes-sidecar:7.1.38-1"
)

# —— docker login ——
if [ -n "${HARBOR_USER:-}" ] && [ -n "${HARBOR_PASS:-}" ]; then
  echo "docker login ${HARBOR%/*} ..."
  echo "${HARBOR_PASS}" | docker login "${HARBOR%/*}" -u "${HARBOR_USER}" --password-stdin \
    && echo "login OK" || { echo "login 失败，退出"; exit 1; }
else
  echo "未设 HARBOR_USER/HARBOR_PASS，假设已 docker login 或用现有 ~/.docker/config.json"
fi

command -v docker >/dev/null || { echo "缺 docker"; exit 1; }

# —— 工具函数 ——
harbor_exists() { docker manifest inspect "$1" >/dev/null 2>&1; }

MAX_TRY=5
declare -a FAILED=()
ok=0; skipped=0; failed=0

sync_one() {
  local src="$1"
  local dst="${HARBOR}/${src#*/}"
  echo "---- ${src}"
  if harbor_exists "$dst"; then
    echo "  ✓ 已存在  ${dst}  (skip)"; skipped=$((skipped+1)); return 0
  fi
  local try=1
  for try in $(seq 1 $MAX_TRY); do
    echo "  [try ${try}] pull ${src}"
    if docker pull --platform linux/amd64 "$src" 2>&1 | sed 's/^/      /'; then
      docker tag "$src" "$dst"
      echo "  [try ${try}] push ${dst}"
      if docker push "$dst" 2>&1 | sed 's/^/      /' | tail -3; then
        docker rmi "$src" "$dst" >/dev/null 2>&1 || true
        echo "  ✓ ${dst}"; ok=$((ok+1)); return 0
      fi
    fi
    echo "  ✗ [try ${try}] 失败，${try}/${MAX_TRY}，sleep 15s 重试"
    sleep 15
  done
  echo "  ✗✗ ${src} 同步失败（${MAX_TRY} 次重试均失败）"
  FAILED+=("$src"); failed=$((failed+1)); return 1
}

for img in "${images[@]}"; do sync_one "$img"; done

echo
echo "======================================================"
echo "完成  $(date)  成功 ${ok}  跳过 ${skipped}  失败 ${failed}"
if [ ${failed} -gt 0 ]; then
  echo "失败列表："
  printf '  %s\n' "${FAILED[@]}"
  echo "可重跑本脚本（已成功/跳过的不重复）。"
  exit 1
fi
echo "全部就绪 ✓  日志: ${LOG}"
echo
echo "验证："
echo "  docker manifest inspect ${HARBOR}/litefuse-web:26.0.1"
echo "  docker manifest inspect ${HARBOR}/doris:fe-4.1.3"
echo "  docker manifest inspect ${HARBOR}/doris:operator-latest"
echo "  docker manifest inspect ${HARBOR}/foundationdb:7.1.38"
echo "======================================================"
