#!/bin/bash
# ============================================================
# MySQL 全量备份脚本（xtrabackup）
# 部署在 MySQL 服务器，每日 02:00 执行
# ============================================================

set -euo pipefail

# 配置
BACKUP_BASE="/data/backup/mysql"
S3_BUCKET="s3://db-backup/mysql"
RETENTION_DAYS=7
BACKUP_USER="${BACKUP_USER:-backup}"
BACKUP_PASS="${BACKUP_PASS:-}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

DATE=$(date +%Y%m%d)
BACKUP_DIR="$BACKUP_BASE/$(hostname)/$DATE"
LOG_FILE="/var/log/mysql_backup.log"
START_TIME=$(date +%s)

mkdir -p "$BACKUP_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_alert() {
  local msg="$1"
  log "ALERT: $msg"
  if [ -n "$SLACK_WEBHOOK" ]; then
    curl -s -X POST "$SLACK_WEBHOOK" -H 'Content-Type: application/json' \
      -d "{\"text\":\":rotating_light: MySQL 备份告警 ($(hostname)): $msg\"}" >/dev/null
  fi
}

if [ -z "$BACKUP_PASS" ]; then
  log "ERROR: 未设置 BACKUP_PASS 环境变量"
  exit 1
fi

log "===== MySQL 全量备份开始 ====="
log "主机: $(hostname)  日期: $DATE  目录: $BACKUP_DIR"

# 1. 全量备份
log "执行 xtrabackup 全量备份..."
if ! xtrabackup --backup \
  --user="$BACKUP_USER" --password="$BACKUP_PASS" \
  --host="$MYSQL_HOST" --port="$MYSQL_PORT" \
  --target-dir="$BACKUP_DIR" \
  --parallel=4 --compress --compress-threads=4 \
  >>"$LOG_FILE" 2>&1; then
  send_alert "xtrabackup 备份失败！"
  exit 1
fi

# 2. 验证备份
log "验证备份完整性..."
if [ ! -f "$BACKUP_DIR/xtrabackup_info" ]; then
  send_alert "备份验证失败：xtrabackup_info 不存在"
  exit 1
fi

# 3. 计算大小
BACKUP_SIZE=$(du -sb "$BACKUP_DIR" | cut -f1)
log "备份大小: $(numfmt --to=iec "$BACKUP_SIZE")"

# 4. 上传 S3
log "上传到对象存储..."
if ! rclone copy "$BACKUP_DIR" "$S3_BUCKET/$(hostname)/$DATE/" \
  --progress --transfers=4 2>>"$LOG_FILE"; then
  send_alert "备份上传 S3 失败！"
  exit 1
fi

# 5. 校验 S3
log "校验 S3 文件..."
if ! rclone check "$BACKUP_DIR" "$S3_BUCKET/$(hostname)/$DATE/" \
  --one-way 2>>"$LOG_FILE"; then
  send_alert "S3 校验失败！"
  exit 1
fi

# 6. 清理过期本地备份
log "清理 ${RETENTION_DAYS} 天前的本地备份..."
find "$BACKUP_BASE/$(hostname)" -maxdepth 1 -type d -name "20*" \
  -mtime +"$RETENTION_DAYS" -exec rm -rf {} \;

# 7. 清理过期 S3 备份（如未配置 lifecycle）
log "清理 S3 过期备份..."
rclone delete "$S3_BUCKET/$(hostname)/" \
  --max-age "$((RETENTION_DAYS * 24))h" \
  --rmdirs 2>>"$LOG_FILE" || true

# 8. 推送监控指标
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
METRICS_DIR="/var/lib/node_exporter/textfile"
mkdir -p "$METRICS_DIR"
cat > "$METRICS_DIR/mysql_backup.prom" <<METRICS
# HELP mysql_backup_last_success_timestamp 上次成功备份时间
# TYPE mysql_backup_last_success_timestamp gauge
mysql_backup_last_success_timestamp $(date +%s)
# HELP mysql_backup_status 备份状态 1=成功 0=失败
# TYPE mysql_backup_status gauge
mysql_backup_status 1
# HELP mysql_backup_duration_seconds 备份耗时
# TYPE mysql_backup_duration_seconds gauge
mysql_backup_duration_seconds $DURATION
# HELP mysql_backup_size_bytes 备份大小
# TYPE mysql_backup_size_bytes gauge
mysql_backup_size_bytes $BACKUP_SIZE
METRICS

log "===== MySQL 全量备份成功完成 ====="
log "耗时: ${DURATION}s  大小: $(numfmt --to=iec "$BACKUP_SIZE")"
log "S3 路径: $S3_BUCKET/$(hostname)/$DATE/"

exit 0
