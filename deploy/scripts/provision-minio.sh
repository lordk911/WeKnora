#!/usr/bin/env bash
# 给 LiteFuse 建 MinIO bucket + 专用用户（套用 weknora 的 add_minio_user.sh 模式）。
# bucket litefuse 三处共用、前缀分开：events/（LiteFuse 事件上传）/ exports/（batch export）/ doris/ddc（Doris Vault）。
#
# 在哪跑：Mac（brew install minio/stable/mc）或已有 mc 的 Linux 服务器（如 xa-k8s-node29）。
# 凭据：放 deploy/.env（本地，不进 git；模板见 deploy/.env.example），本脚本自动 source。
#   也可用环境变量覆盖：MINIO_ROOT_PASS=... LF_PASS=... bash provision-minio.sh
set -eu    # 不用 pipefail：兼容 node29 的 sh(dash)。mc 命令的幂等失败见各处 || 处理

# 自动加载 deploy/.env（本地凭据，不进 git）。脚本在 deploy/scripts/，.env 在 deploy/
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; }

# ======= 配置（默认值，可用环境变量覆盖；密码为必填，无默认）=======
MINIO_ALIAS="${MINIO_ALIAS:-minio-prd}"
MINIO_ENDPOINT="${MINIO_ENDPOINT:?需 MINIO_ENDPOINT（放 deploy/.env，如 https://<minio-endpoint>）}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-root}"                    # 用户名（非敏感）

# LiteFuse 专用 user / bucket
LF_USER="${LF_USER:-litefuse}"                                # 用户名（非敏感）
BUCKET_NAME="${BUCKET_NAME:-litefuse}"
POLICY_NAME="rw-${BUCKET_NAME}"
# ==================================================

# 密码必填（从 .env 或 env 来）
[ -n "${MINIO_ROOT_PASS:-}" ] || { echo "需 MINIO_ROOT_PASS（放 deploy/.env 或 export）" >&2; exit 1; }
[ -n "${LF_PASS:-}" ]         || { echo "需 LF_PASS（放 deploy/.env 或 export）" >&2; exit 1; }

command -v mc >/dev/null || { echo "缺 mc（Mac: brew install minio/stable/mc）"; exit 1; }

echo "==> mc alias set ${MINIO_ALIAS} ${MINIO_ENDPOINT}"
mc alias set "$MINIO_ALIAS" "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASS" >/dev/null

echo "==> 创建用户 ${LF_USER}"
if mc admin user info "$MINIO_ALIAS" "$LF_USER" >/dev/null 2>&1; then
  echo "  用户已存在，跳过（密码沿用首次创建时的 LF_PASS）"
else
  mc admin user add "$MINIO_ALIAS" "$LF_USER" "$LF_PASS"
fi

echo "==> bucket ${BUCKET_NAME}"
if mc ls "$MINIO_ALIAS/$BUCKET_NAME" >/dev/null 2>&1; then
  echo "  bucket 已存在，跳过创建"
else
  mc mb "$MINIO_ALIAS/$BUCKET_NAME"
fi

echo "==> 策略 ${POLICY_NAME}"
POLICY_FILE="$(mktemp -t "${POLICY_NAME}.XXXX.json")"
cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": ["s3:GetBucketLocation","s3:ListBucket","s3:ListBucketMultipartUploads"],
      "Effect": "Allow",
      "Resource": ["arn:aws:s3:::${BUCKET_NAME}"]
    },
    {
      "Action": ["s3:AbortMultipartUpload","s3:DeleteObject","s3:GetObject","s3:ListMultipartUploadParts","s3:PutObject"],
      "Effect": "Allow",
      "Resource": ["arn:aws:s3:::${BUCKET_NAME}/*"]
    }
  ]
}
EOF
# 策略存在则跳过创建（policy create 不幂等）
mc admin policy info "$MINIO_ALIAS" "$POLICY_NAME" >/dev/null 2>&1 \
  || mc admin policy create "$MINIO_ALIAS" "$POLICY_NAME" "$POLICY_FILE"
rm -f "$POLICY_FILE"

echo "==> 绑定策略到 ${LF_USER}"
mc admin policy attach "$MINIO_ALIAS" --user="$LF_USER" "$POLICY_NAME" || true   # 已绑定时返回非 0，忽略

echo
echo "✅ 完成：bucket=${BUCKET_NAME}  user=${LF_USER}  policy=${POLICY_NAME}"
echo "   endpoint=${MINIO_ENDPOINT}"
echo "   access_key=${LF_USER}"
echo "   secret_key=${LF_PASS}"
