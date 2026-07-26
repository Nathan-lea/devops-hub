#!/bin/bash
# ============================================================
# Redis 备份脚本（RDB + AOF）
# 每日 02:00 执行
# ============================================================

set -euo pipefail

BACKUP_BASE="/data/backup/redis"
S3_BUCKET="s3://db-backup/redis"
RETENTION_DAYS=7
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASS="${REDIS_PASS:-}"
REDIS_DATA_DIR="${REDIS_DATA_DIR:-/var/lib/redis}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

DATE=$(date +%Y%m%d)
BACKUP_DIR="$BACKUP_BASE/$(hostname)/$DATE"
LOG_FILE="/var/log/redis_backup.log"
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
      -d "{\"text\":\":rotating_light: Redis 备份告警 ($(hostname)): $msg\"}" >/dev/null
  fi
}

AUTH_ARG=""
[ -n "$REDIS_PASS" ] && AUTH_ARG="-a $REDIS_PASS"

log "===== Redis 备份开始 ====="

# 1. 触发 BGSAVE
log "触发 BGSAVE..."
LASTSAVE_BEFORE=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" $AUTH_ARG LASTSAVE 2>/dev/null | tr -d '\r')
if [ -z "$LASTSAVE_BEFORE" ]; then
  send_alert "无法连接 Redis 或执行命令失败"
  exit 1
fi

redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" $AUTH_ARG BGSAVE >/dev/null 2>&1

# 2. 等待 BGSAVE 完成
log "等待 BGSAVE 完成..."
TIMEOUT=300
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  LASTSAVE_AFTER=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" $AUTH_ARG LASTSAVE 2>/dev/null | tr -d '\r')
  if [ "$LASTSAVE_AFTER" != "$LASTSAVE_BEFORE" ]; then
    log "BGSAVE 完成"
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
  send_alert "BGSAVE 超时（${TIMEOUT}s）"
  exit 1
fi

# 3. 复制 RDB 文件
RDB_FILE="$REDIS_DATA_DIR/dump.rdb"
if [ -f "$RDB_FILE" ]; then
  log "复制 RDB 文件..."
  cp "$RDB_FILE" "$BACKUP_DIR/dump.rdb"
else
  send_alert "RDB 文件不存在: $RDB_FILE"
  exit 1
fi

# 4. 复制 AOF 文件（如果存在）
AOF_DIR="$REDIS_DATA_DIR/appendonlydir"
if [ -d "$AOF_DIR" ]; then
  log "复制 AOF 文件..."
  cp -r "$AOF_DIR" "$BACKUP_DIR/"
elif [ -f "$REDIS_DATA_DIR/appendonly.aof" ]; then
  cp "$REDIS_DATA_DIR/appendonly.aof" "$BACKUP_DIR/"
fi

# 5. 复制配置文件
log "复制配置文件..."
cp /etc/redis/redis.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/redis/sentinel.conf "$BACKUP_DIR/" 2>/dev/null || true

# 6. 计算大小
BACKUP_SIZE=$(du -sb "$BACKUP_DIR" | cut -f1)
log "备份大小: $(numfmt --to=iec "$BACKUP_SIZE")"

# 7. 压缩
log "压缩备份..."
tar -czf "$BACKUP_DIR.tar.gz" -C "$BACKUP_BASE/$(hostname)" "$DATE"
rm -rf "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR.tar.gz"

# 8. 上传 S3
log "上传到对象存储..."
if ! rclone copy "$BACKUP_FILE" "$S3_BUCKET/$(hostname)/" 2>>"$LOG_FILE"; then
  send_alert "上传 S3 失败"
  exit 1
fi

# 9. 清理过期备份
log "清理 ${RETENTION_DAYS} 天前的本地备份..."
find "$BACKUP_BASE/$(hostname)" -name "*.tar.gz" -mtime +"$RETENTION_DAYS" -delete

# 10. 清理 S3 过期备份
rclone delete "$S3_BUCKET/$(hostname)/" \
  --max-age "$((RETENTION_DAYS * 24))h" 2>>"$LOG_FILE" || true

# 11. 推送监控指标
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
METRICS_DIR="/var/lib/node_exporter/textfile"
mkdir -p "$METRICS_DIR"
cat > "$METRICS_DIR/redis_backup.prom" <<METRICS
# HELP redis_backup_last_success_timestamp 上次成功备份时间
# TYPE redis_backup_last_success_timestamp gauge
redis_backup_last_success_timestamp $(date +%s)
# HELP redis_backup_status 备份状态
# TYPE redis_backup_status gauge
redis_backup_status 1
# HELP redis_backup_duration_seconds 备份耗时
# TYPE redis_backup_duration_seconds gauge
redis_backup_duration_seconds $DURATION
# HELP redis_backup_size_bytes 备份大小
# TYPE redis_backup_size_bytes gauge
redis_backup_size_bytes $BACKUP_SIZE
METRICS

log "===== Redis 备份成功完成 ====="
log "耗时: ${DURATION}s  大小: $(numfmt --to=iec "$BACKUP_SIZE")"

exit 0
