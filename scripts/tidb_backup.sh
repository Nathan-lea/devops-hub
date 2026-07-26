#!/bin/bash
# ============================================================
# TiDB 全量备份脚本（BR 工具）
# 部署在 TiDB 管控节点或 PD 节点
# 每日 03:00 执行
# ============================================================

set -euo pipefail

PD_ENDPOINT="${PD_ENDPOINT:-10.0.4.10:2379}"
S3_BUCKET="${S3_BUCKET:-s3://tidb-backup}"
S3_ENDPOINT="${S3_ENDPOINT:-http://minio:9000}"
RETENTION_DAYS=7
LOG_FILE="/var/log/tidb_backup.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
START_TIME=$(date +%s)

DATE=$(date +%Y%m%d)
S3_PATH="$S3_BUCKET/full-$DATE"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_alert() {
  local msg="$1"
  log "ALERT: $msg"
  if [ -n "$SLACK_WEBHOOK" ]; then
    curl -s -X POST "$SLACK_WEBHOOK" -H 'Content-Type: application/json' \
      -d "{\"text\":\":rotating_light: TiDB 备份告警: $msg\"}" >/dev/null
  fi
}

log "===== TiDB 全量备份开始 ====="
log "PD: $PD_ENDPOINT  路径: $S3_PATH"

# 1. 检查 br 工具
if ! command -v br >/dev/null 2>&1; then
  send_alert "br 命令未找到，请安装 TiDB BR 工具"
  exit 1
fi

# 2. 执行全量备份
log "执行 BR 全量备份..."
if ! br backup full \
  --pd "$PD_ENDPOINT" \
  --storage "$S3_PATH" \
  --s3.endpoint "$S3_ENDPOINT" \
  --log-file="$LOG_FILE" \
  --concurrency=4; then
  send_alert "BR 备份失败！"
  exit 1
fi

# 3. 校验备份
log "校验备份完整性..."
if ! br validate restore \
  --pd "$PD_ENDPOINT" \
  --storage "$S3_PATH" \
  --s3.endpoint "$S3_ENDPOINT" \
  --log-file="$LOG_FILE"; then
  send_alert "BR 备份校验失败！"
  exit 1
fi

# 4. 清理过期备份（通过 S3 lifecycle 或手动）
log "清理 ${RETENTION_DAYS} 天前的 S3 备份..."
for old_date in $(rclone lsd "$S3_BUCKET/" | grep "full-" | awk '{print $NF}'); do
  old_epoch=$(date -d "${old_date#full-}" +%s 2>/dev/null || continue)
  now_epoch=$(date +%s)
  age_days=$(( (now_epoch - old_epoch) / 86400 ))
  if [ "$age_days" -gt "$RETENTION_DAYS" ]; then
    log "删除过期备份: $old_date (${age_days}天前)"
    rclone purge "$S3_BUCKET/$old_date" 2>>"$LOG_FILE" || true
  fi
done

# 5. 推送监控指标
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
METRICS_DIR="/var/lib/node_exporter/textfile"
mkdir -p "$METRICS_DIR"
cat > "$METRICS_DIR/tidb_backup.prom" <<METRICS
# HELP tidb_backup_last_success_timestamp 上次成功备份时间
# TYPE tidb_backup_last_success_timestamp gauge
tidb_backup_last_success_timestamp $(date +%s)
# HELP tidb_backup_status 备份状态
# TYPE tidb_backup_status gauge
tidb_backup_status 1
# HELP tidb_backup_duration_seconds 备份耗时
# TYPE tidb_backup_duration_seconds gauge
tidb_backup_duration_seconds $DURATION
METRICS

log "===== TiDB 备份成功完成 ====="
log "耗时: ${DURATION}s  S3 路径: $S3_PATH"

exit 0
