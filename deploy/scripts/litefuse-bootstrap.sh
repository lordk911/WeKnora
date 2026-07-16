#!/usr/bin/env bash
# LiteFuse 一键部署编排（凭据 + 集群特定域名从 deploy/.env 读，不进 git）。
# 串行：ns → Doris DDC(FDB→operator→cluster→vault) → 依赖(PG库/MinIO bucket) →
#       secret → helm install litefuse → 健康检查。
#
# 前置（由人工/前置脚本完成，本脚本不替你做）：
#   1. 镜像已推 harbor（deploy/scripts/mirror-litefuse-images.sh 或 nohup 版）
#   2. cd deploy/doris && bash fetch-vendored.sh && bash patch-images.sh
#   3. 本机 kubectl context 指向目标集群（docker login 不需要：本脚本不 push 镜像）
#   4. MinIO：先在 node29 或 Mac(brew install minio/stable/mc) 跑 deploy/scripts/provision-minio.sh
#      （建 bucket litefuse + user litefuse）
#
# 凭据：放 deploy/.env（本地，不进 git；模板见 deploy/.env.example），本脚本自动 source。
#   也可用环境变量覆盖。需要：PG_SUPERUSER_PASS / LF_MINIO_AK / LF_MINIO_SK。
#   DORIS_NS=doris  LITEFUSE_NS=litefuse（默认值）
#
# 不需要本机装 psql（PG 用 kubectl exec 进 postgres pod）。
# 生成的密钥写 ~/Downloads/litefuse/secrets.env（mode 600，与 weknora secrets 备份同模式，repo 外）。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 自动加载 deploy/.env（本地凭据 + 集群特定值，不进 git）
[ -f "${REPO}/deploy/.env" ] && { set -a; . "${REPO}/deploy/.env"; set +a; }
DORIS="${DORIS_NS:-doris}"
LF="${LITEFUSE_NS:-litefuse}"
SECRET_DIR="${HOME}/Downloads/litefuse"
SECRET_FILE="${SECRET_DIR}/secrets.env"
CHART="${REPO}/deploy/litefuse-chart"
VALUES="${REPO}/deploy/litefuse-values-production.yaml"
DORIS_DIR="${REPO}/deploy/doris"
: "${HARBOR:?需 HARBOR（放 deploy/.env）}"          # __HARBOR__ 占位 sed 替换用
: "${INGRESS_HOST:?需 INGRESS_HOST（放 deploy/.env）}" # banner 显示用
# apply 静态 YAML 前 sed 替换 __HARBOR__ → $HARBOR（ddc/fdb/vault YAML 用占位，不直接含仓库地址）
apply_h() { sed "s|__HARBOR__|${HARBOR}|g" "$1" | kubectl apply -f -; }
VENDORED="${DORIS_DIR}/vendored"

log() { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
wait_for() { # desc cmd
  local desc="$1"; shift
  log "等待 $desc"; local i
  for i in $(seq 1 "${WAIT_TRIES:-120}"); do
    if "$@" >/dev/null 2>&1; then echo "  ✓ $desc"; return 0; fi
    sleep 5
  done
  echo "  ✗ $desc 超时" >&2; return 1
}

# —— 0. 前置检查 ——
log "前置检查"
command -v kubectl >/dev/null || { echo "缺 kubectl" >&2; exit 1; }
command -v helm >/dev/null    || { echo "缺 helm" >&2; exit 1; }
[ -f "${VENDORED}/disaggregated-operator.patched.yaml" ] || {
  echo "缺 ${VENDORED}/*.patched.yaml，先跑 deploy/doris/fetch-vendored.sh + patch-images.sh" >&2; exit 1; }
[ -n "${PG_SUPERUSER_PASS:-}" ] || { echo "需 PG_SUPERUSER_PASS（放 deploy/.env 或 export）" >&2; exit 1; }
LF_MINIO_AK="${LF_MINIO_AK:-litefuse}"
[ -n "${LF_MINIO_SK:-}" ] || { echo "需 LF_MINIO_SK（放 deploy/.env 或 export，须与 provision-minio.sh 的 LF_PASS 一致）" >&2; exit 1; }

# —— 1. namespace ——
log "创建 ns ${DORIS} ${LF}"
kubectl get ns "${DORIS}" >/dev/null 2>&1 || kubectl create ns "${DORIS}"
kubectl get ns "${LF}"    >/dev/null 2>&1 || kubectl create ns "${LF}"

# —— 2. 生成密钥（幂等：已存在则复用） ——
log "生成/复用密钥 → ${SECRET_FILE}"
mkdir -p "${SECRET_DIR}"; chmod 700 "${SECRET_DIR}"
if [ ! -f "${SECRET_FILE}" ]; then
  gen() { openssl rand -hex "${1:-32}"; }
  cat > "${SECRET_FILE}" <<EOF
# LiteFuse secrets（生成于 $(date '+%Y-%m-%d')，repo 外，mode 600）
NEXTAUTH_SECRET=$(openssl rand -base64 48)
SALT=$(openssl rand -base64 48)
ENCRYPTION_KEY=$(gen 32)
REDIS_AUTH=$(gen 16)
PG_USER=litefuse
PG_PASSWORD=$(gen 16)
MINIO_ACCESS_KEY_ID="${LF_MINIO_AK}"
MINIO_SECRET_ACCESS_KEY="${LF_MINIO_SK}"
DORIS_PASSWORD=
LITEFUSE_INIT_PROJECT_PUBLIC_KEY=pk-lf-$(gen 16)
LITEFUSE_INIT_PROJECT_SECRET_KEY=sk-lf-$(gen 16)
LITEFUSE_INIT_USER_PASSWORD=$(gen 12)
EOF
  chmod 600 "${SECRET_FILE}"
  echo "  ✓ 生成（请备份 ${SECRET_FILE}，丢失=加密数据不可恢复，同 weknora TENANT_AES_KEY）"
else
  echo "  ✓ 复用现有 ${SECRET_FILE}"
fi
# shellcheck disable=SC1090
set -a; . "${SECRET_FILE}"; set +a
DATABASE_URL="postgresql://${PG_USER}:${PG_PASSWORD}@postgresql-primary.postgresql:5432/litefuse"

# —— 3. Doris DDC：FDB → operator → cluster ——
log "FDB CRD + operator + cluster"
kubectl apply --server-side --force-conflicts -f "${VENDORED}/fdb-crds.yaml"
kubectl apply -n "${DORIS}" -f "${VENDORED}/fdb-operator.patched.yaml"   # 必须 -n doris：operator WATCH_NAMESPACE=metadata.namespace(downward api)，落 doris 才看 doris
apply_h "${DORIS_DIR}/fdb-cluster.yaml"
wait_for "FDB AVAILABLE" bash -c "kubectl get fdb -n ${DORIS} -o jsonpath='{.items[0].status.health.available}' | grep -q true"

log "Doris Operator CRD + deployment"
# CRD 用 server-side apply：上游 CRD schema 大，普通 apply 会写 last-applied-configuration 注解超 256KB 被拒
kubectl apply --server-side --force-conflicts -f "${VENDORED}/crds.yaml"
kubectl apply -n "${DORIS}" -f "${VENDORED}/disaggregated-operator.patched.yaml"
wait_for "doris-operator Running" bash -c "kubectl -n ${DORIS} get pod --no-headers | grep -E 'doris-operator|controller-manager' | grep -q Running"

log "DorisDisaggregatedCluster"
apply_h "${DORIS_DIR}/ddc-cluster.yaml"
# CLUSTERHEALTH 列字段名因 operator 版本可能不同，用表输出 grep 为准
wait_for "DDC CLUSTERHEALTH=green" bash -c "kubectl get ddc -n ${DORIS} --no-headers 2>/dev/null | grep -q green"
kubectl get ddc -n "${DORIS}"

# —— 4. 依赖：PG 库（kubectl exec 进 postgres pod，本机无需 psql）+ MinIO bucket/user ——
log "PG：建库 litefuse + 用户（exec 进 postgresql-primary pod）"
# 找 primary pod（bitnami postgresql chart：label app.kubernetes.io/component=primary）
PG_POD="$(kubectl -n postgresql get pod -l app.kubernetes.io/component=primary \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "${PG_POD}" ] || PG_POD="$(kubectl -n postgresql get pod -o name 2>/dev/null \
  | grep -E 'postgresql-primary|postgresql-' | head -1 | sed 's|pod/||')"
[ -n "${PG_POD}" ] || { echo "  ✗ 找不到 postgresql primary pod（ns=postgresql）" >&2; exit 1; }
echo "  pod: ${PG_POD}"
pg_exec() { kubectl -n postgresql exec "${PG_POD}" -- env "PGPASSWORD=${PG_SUPERUSER_PASS}" psql -U postgres -tAc "$1"; }
exists="$(pg_exec "SELECT 1 FROM pg_database WHERE datname='litefuse'" 2>/dev/null || true)"
if [ "${exists}" != "1" ]; then
  kubectl -n postgresql exec "${PG_POD}" -- env "PGPASSWORD=${PG_SUPERUSER_PASS}" psql -U postgres \
    -c "CREATE DATABASE litefuse;" \
    -c "CREATE USER ${PG_USER} WITH PASSWORD '${PG_PASSWORD}';" \
    -c "GRANT ALL ON DATABASE litefuse TO ${PG_USER};" \
    -c "ALTER DATABASE litefuse OWNER TO ${PG_USER};"     # PG15+ public schema 默认不给 CREATE，库 owner 才能建表
  echo "  ✓ PG 库 litefuse + 用户 ${PG_USER} 已建（owner=${PG_USER}）"
else
  echo "  ✓ PG 库 litefuse 已存在（复用）"
fi
# 无论新建还是复用，确保 schema public 权限（Prisma 建表需要；PG15+ 必须显式给）
kubectl -n postgresql exec "${PG_POD}" -- env "PGPASSWORD=${PG_SUPERUSER_PASS}" psql -U postgres -d litefuse \
  -c "ALTER DATABASE litefuse OWNER TO ${PG_USER};" \
  -c "ALTER SCHEMA public OWNER TO ${PG_USER};" \
  -c "GRANT ALL ON SCHEMA public TO ${PG_USER};" >/dev/null 2>&1 || true
echo "  ✓ schema public 权限已授予 ${PG_USER}"

log "MinIO：建 bucket litefuse + 用户（provision-minio.sh，套 weknora 模式）"
if command -v mc >/dev/null; then
  MINIO_ALIAS=minio-prd MINIO_ENDPOINT="${MINIO_ENDPOINT}" \
    bash "${REPO}/deploy/scripts/provision-minio.sh"
else
  echo "  ⚠ 本机无 mc——假设 MinIO 已在别处（如 node29）跑过 provision-minio.sh（bucket litefuse + user litefuse）。" >&2
  echo "    若没跑：LiteFuse/Doris 写 MinIO 会失败。在 Mac(brew install minio/stable/mc) 或 node29 执行 deploy/scripts/provision-minio.sh 后重跑。" >&2
fi

# —— 5. Storage Vault（Doris → MinIO）——
log "建 Doris Storage Vault（指向 MinIO bucket litefuse）"
kubectl -n "${DORIS}" create secret generic doris-vault-creds \
  --from-literal=MINIO_ACCESS_KEY_ID="${MINIO_ACCESS_KEY_ID}" \
  --from-literal=MINIO_SECRET_ACCESS_KEY="${MINIO_SECRET_ACCESS_KEY}" \
  --from-literal=DORIS_PASSWORD="${DORIS_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${DORIS}" delete job create-storage-vault --ignore-not-found
apply_h "${DORIS_DIR}/create-storage-vault.yaml"
wait_for "Storage Vault Job 完成" bash -c "kubectl -n ${DORIS} get job create-storage-vault -o jsonpath='{.status.succeeded}' | grep -q 1"
kubectl -n "${DORIS}" logs job/create-storage-vault --tail=20 || true

# —— 6. Secret（litefuse-secrets）——
log "建 Secret litefuse-secrets（ns ${LF}）"
kubectl -n "${LF}" create secret generic litefuse-secrets \
  --from-literal=NEXTAUTH_SECRET="${NEXTAUTH_SECRET}" \
  --from-literal=SALT="${SALT}" \
  --from-literal=ENCRYPTION_KEY="${ENCRYPTION_KEY}" \
  --from-literal=DATABASE_URL="${DATABASE_URL}" \
  --from-literal=REDIS_AUTH="${REDIS_AUTH}" \
  --from-literal=MINIO_ACCESS_KEY_ID="${MINIO_ACCESS_KEY_ID}" \
  --from-literal=MINIO_SECRET_ACCESS_KEY="${MINIO_SECRET_ACCESS_KEY}" \
  --from-literal=DORIS_PASSWORD="${DORIS_PASSWORD}" \
  --from-literal=LITEFUSE_INIT_PROJECT_PUBLIC_KEY="${LITEFUSE_INIT_PROJECT_PUBLIC_KEY}" \
  --from-literal=LITEFUSE_INIT_PROJECT_SECRET_KEY="${LITEFUSE_INIT_PROJECT_SECRET_KEY}" \
  --from-literal=LITEFUSE_INIT_USER_PASSWORD="${LITEFUSE_INIT_USER_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

# —— 7. helm install ——
log "TLS 证书：litefuse-tls（公司通配证书（*.<your-domain>））"
TLS_SRC_NS="${TLS_SRC_NS:-weknora}"
TLS_SRC_SECRET="${TLS_SRC_SECRET:-weknora-company-tls}"
if kubectl -n "${LF}" get secret litefuse-tls >/dev/null 2>&1; then
  echo "  ✓ litefuse-tls 已存在（手动建的或上次拷贝的），跳过拷贝"
else
  kubectl get secret "${TLS_SRC_SECRET}" -n "${TLS_SRC_NS}" -o json 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(json.dumps({'apiVersion':d.get('apiVersion','v1'),'kind':'Secret','metadata':{'name':'litefuse-tls','namespace':'${LF}'},'type':d.get('type','kubernetes.io/tls'),'data':d.get('data',{})}))
" | kubectl apply -f -
  echo "  ✓ litefuse-tls 已从 ${TLS_SRC_NS}/${TLS_SRC_SECRET} 拷贝"
  echo "    （或手动：kubectl create secret tls litefuse-tls -n ${LF} --cert=<your-cert-chain>.pem --key=<your-key>.key）"
fi

log "helm install litefuse"
helm -n "${LF}" upgrade --install litefuse "${CHART}" -f "${VALUES}"

log "等待 litefuse-web Ready（Prisma 迁移 + Doris 连接，~60-90s）"
wait_for "litefuse-web Running" bash -c "kubectl -n ${LF} get pod -l app.kubernetes.io/component=web -o jsonpath='{.items[0].status.phase}' | grep -q Running"

# —— 8. 健康检查 ——
log "健康检查"
kubectl -n "${LF}" port-forward svc/litefuse-web 13000:3000 >/dev/null 2>&1 &
WEB_PF=$!; trap 'kill ${WEB_PF} 2>/dev/null || true' EXIT; sleep 3
curl -s http://127.0.0.1:13000/api/public/health && echo || echo "  ⚠ health 未就绪，查日志：kubectl -n ${LF} logs deploy/litefuse-web"

cat <<EOF

✅ LiteFuse 部署完成（ns=${LF}, Doris ns=${DORIS}）
   Web:      https://${INGRESS_HOST}   （内网 DNS 需解析到 ingress LB）
   Init 用户: ${LITEFUSE_INIT_USER_EMAIL:-admin@weknora.local}  密码见 ${SECRET_FILE}
   项目 key（WeKnora 对接用）:
     public  = ${LITEFUSE_INIT_PROJECT_PUBLIC_KEY}
     secret  = ${LITEFUSE_INIT_PROJECT_SECRET_KEY}
   密钥备份:  ${SECRET_FILE}  （mode 600，务必妥善保存）

下一步（WeKnora 对接，零代码改动）：
   在 deploy/values-production.yaml 的 app.extraEnv 追加 LANGFUSE_HOST/PUBLIC_KEY/SECRET_KEY
   （详见 deploy/litefuse-k8s-deploy.md 第 6 节），然后：
   helm -n weknora upgrade weknora ./helm -f deploy/values-production.yaml
EOF
