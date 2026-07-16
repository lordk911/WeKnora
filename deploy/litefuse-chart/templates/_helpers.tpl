{{/*
Expand the chart name.
*/}}
{{- define "litefuse.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Release name already contains chart name → use it.
*/}}
{{- define "litefuse.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "litefuse.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.AppVersion | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "litefuse.labels" -}}
helm.sh/chart: {{ include "litefuse.chart" . }}
{{ include "litefuse.selectorLabels" . }}
app.kubernetes.io/part-of: litefuse
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "litefuse.selectorLabels" -}}
app.kubernetes.io/name: {{ include "litefuse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "litefuse.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "litefuse.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "litefuse.secretName" -}}
{{- default (include "litefuse.fullname" .) .Values.secrets.existingSecret }}
{{- end }}

{{/*
Redis host: 本 chart 独立部署时用 <fullname>-redis.<ns>.svc；外部模式用 values。
*/}}
{{- define "litefuse.redisHost" -}}
{{- if .Values.redis.enabled }}
{{- printf "%s-redis.%s.svc.cluster.local" (include "litefuse.fullname" .) .Release.Namespace }}
{{- else }}
{{- required "redis.external.host is required when redis.enabled=false" .Values.redis.external.host }}
{{- end }}
{{- end }}

{{/*
Web/Worker 共享的环境变量块（对应 docker-compose production 的 &litefuse-web-env anchor）。
渲染为 env 列表，web 与 worker 都 include。
*/}}
{{- define "litefuse.appEnv" -}}
# —— 认证 / 加密（Secret）——
- name: NEXTAUTH_SECRET
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: NEXTAUTH_SECRET } }
- name: SALT
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: SALT } }
- name: ENCRYPTION_KEY
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: ENCRYPTION_KEY } }
- name: NEXTAUTH_URL
  value: {{ .Values.litefuse.nextauthUrl | quote }}
# —— 遥测 / 特性开关 ——
- name: TELEMETRY_ENABLED
  value: {{ .Values.litefuse.telemetryEnabled | quote }}
- name: LITEFUSE_ENABLE_EXPERIMENTAL_FEATURES
  value: {{ .Values.litefuse.enableExperimentalFeatures | quote }}
- name: NEXT_PUBLIC_ENABLE_LOGGING
  value: {{ .Values.litefuse.nextPublicEnableLogging | quote }}
# —— 首次启动预置 org/project/user ——
{{- if eq .Values.litefuse.init.enabled "true" }}
- name: LITEFUSE_INIT_ORG_ID
  value: {{ .Values.litefuse.init.orgId | quote }}
- name: LITEFUSE_INIT_ORG_NAME
  value: {{ .Values.litefuse.init.orgName | quote }}
- name: LITEFUSE_INIT_PROJECT_ID
  value: {{ .Values.litefuse.init.projectId | quote }}
- name: LITEFUSE_INIT_PROJECT_NAME
  value: {{ .Values.litefuse.init.projectName | quote }}
- name: LITEFUSE_INIT_PROJECT_PUBLIC_KEY
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: LITEFUSE_INIT_PROJECT_PUBLIC_KEY } }
- name: LITEFUSE_INIT_PROJECT_SECRET_KEY
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: LITEFUSE_INIT_PROJECT_SECRET_KEY } }
- name: LITEFUSE_INIT_USER_EMAIL
  value: {{ .Values.litefuse.init.userEmail | quote }}
- name: LITEFUSE_INIT_USER_NAME
  value: {{ .Values.litefuse.init.userName | quote }}
- name: LITEFUSE_INIT_USER_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: LITEFUSE_INIT_USER_PASSWORD } }
{{- end }}
# —— Postgres 元数据（DATABASE_URL 整串，Secret）——
- name: DATABASE_URL
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: DATABASE_URL } }
# —— Redis 队列/缓存 ——
- name: REDIS_HOST
  value: {{ include "litefuse.redisHost" . | quote }}
- name: REDIS_PORT
  value: "6379"
- name: REDIS_AUTH
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: REDIS_AUTH } }
- name: REDIS_TLS_ENABLED
  value: "false"
# —— S3 事件上传（复用集群 MinIO）——
- name: LITEFUSE_S3_EVENT_UPLOAD_BUCKET
  value: {{ .Values.minio.bucket | quote }}
- name: LITEFUSE_S3_EVENT_UPLOAD_REGION
  value: {{ .Values.minio.region | quote }}
- name: LITEFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: MINIO_ACCESS_KEY_ID } }
- name: LITEFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: MINIO_SECRET_ACCESS_KEY } }
- name: LITEFUSE_S3_EVENT_UPLOAD_ENDPOINT
  value: {{ .Values.minio.endpoint | quote }}
- name: LITEFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE
  value: {{ .Values.minio.forcePathStyle | quote }}
- name: LITEFUSE_S3_EVENT_UPLOAD_PREFIX
  value: {{ .Values.s3.eventUpload.prefix | quote }}
# —— Doris 分析后端 ——
- name: LITEFUSE_ANALYTICS_BACKEND
  value: {{ .Values.litefuse.analyticsBackend | quote }}
- name: LITEFUSE_AUTO_DORIS_MIGRATION_DISABLED
  value: {{ .Values.litefuse.autoDorisMigrationDisabled | quote }}
- name: DORIS_URL
  value: {{ .Values.doris.feHttpUrl | quote }}
- name: DORIS_FE_HTTP_URL
  value: {{ .Values.doris.feHttpUrl | quote }}
- name: DORIS_FE_QUERY_PORT
  value: {{ .Values.doris.feQueryPort | quote }}
- name: DORIS_DB
  value: {{ .Values.doris.database | quote }}
- name: DORIS_USER
  value: {{ .Values.doris.user | quote }}
- name: DORIS_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ include "litefuse.secretName" . }}, key: DORIS_PASSWORD, optional: true } }
- name: DORIS_MAX_OPEN_CONNECTIONS
  value: "100"
- name: DORIS_REQUEST_TIMEOUT_MS
  value: "30000"
# —— ClickHouse 兼容占位（已关，Doris 作分析后端）——
- name: CLICKHOUSE_MIGRATION_URL
  value: "clickhouse://dummy:dummy@localhost:9000"
- name: CLICKHOUSE_URL
  value: "http://localhost:8123"
- name: CLICKHOUSE_USER
  value: "dummy"
- name: CLICKHOUSE_PASSWORD
  value: "dummy"
- name: CLICKHOUSE_CLUSTER_ENABLED
  value: "false"
- name: LITEFUSE_ENABLE_BACKGROUND_MIGRATIONS
  value: {{ .Values.litefuse.enableBackgroundMigrations | quote }}
# —— 运行时 ——
- name: HOSTNAME
  value: "0.0.0.0"
- name: TZ
  value: {{ .Values.litefuse.timezone | quote }}
{{- end }}
