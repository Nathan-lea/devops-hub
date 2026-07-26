#!/bin/bash
# ============================================================
# etcd 快照备份脚本
# 部署在 K8s master 节点，每日定时执行
# ============================================================

set -euo pipefail

# 配置
BACKUP_DIR="/data/backup/etcd"
S3_BUCKET="s3://k8s-backup/etcd"
RETENTION_DAYS=14
ETCD_ENDPOINT="https://127.0.0.1:2379"
ETCD_CACERT="/etc/kubernetes/pki/etcd/ca.crt"
ETCD_CERT="/etc/kubernetes/pki/etcd/peer.crt"
ETCD_KEY="/etc/kubernetes/pki/etcd/peer.key"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

# 创建目录
mkdir -p "$BACKUP_DIR"

DATE=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_FILE="$BACKUP_DIR/snapshot-$DATE.db"
LOG_FILE="/var/log/etcd_backup.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_alert() {
  local msg="$1"
  log "ALERT: $msg"
  if [ -n "$SLACK_WEBHOOK" ]; then
    curl -s -X POST "$SLACK_WEBHOOK" -H 'Content-Type: application/json' \
      -d "{\"text\":\":rotating_light: etcd 备份告警: $msg\"}" >/dev/null
  fi
}

log "===== etcd 备份开始 ====="

# 1. 创建快照
log "创建 etcd 快照: $SNAPSHOT_FILE"
if ! ETCDCTL_API=3 etcdctl \
  --endpoints="$ETCD_ENDPOINT" \
  --cacert="$ETCD_CACERT" \
  --cert="$ETCD_CERT" \
  --key="$ETCD_KEY" \
  snapshot save "$SNAPSHOT_FILE" >>"$LOG_FILE" 2>&1; then
  send_alert "etcd 快照创建失败！"
  exit 1
fi

# 2. 校验快照
log "校验快照完整性..."
if ! ETCDCTL_API=3 etcdctl \
  --endpoints="$ETCD_ENDPOINT" \
  --cacert="$ETCD_CACERT" \
  snapshot status "$SNAPSHOT_FILE" \
  --write-out=json >"$BACKUP_DIR/snapshot-$DATE.meta" 2>>"$LOG_FILE"; then
  send_alert "etcd 快照校验失败！"
  exit 1
fi

# 3. 压缩快照
log "压缩快照..."
gzip "$SNAPSHOT_FILE"
SNAPSHOT_FILE="${SNAPSHOT_FILE}.gz"

# 4. 上传 S3
log "上传到对象存储..."
if ! rclone copy "$SNAPSHOT_FILE" "$S3_BUCKET/" 2>>"$LOG_FILE"; then
  send_alert "etcd 快照上传 S3 失败！"
  exit 1
fi

# 5. 上传元数据
rclone copy "$BACKUP_DIR/snapshot-$DATE.meta" "$S3_BUCKET/" 2>>"$LOG_FILE"

# 6. 校验上传
log "校验 S3 文件..."
if ! rclone check "$SNAPSHOT_FILE" "$S3_BUCKET/$(basename "$SNAPSHOT_FILE")" \
  --one-way 2>>"$LOG_FILE"; then
  send_alert "etcd 快照 S3 校验失败！"
  exit 1
fi

# 7. 清理本地过期备份
log "清理 ${RETENTION_DAYS} 天前的本地备份..."
find "$BACKUP_DIR" -name "snapshot-*.db*" -mtime +"$RETENTION_DAYS" -delete

# 8. 清理 S3 过期备份（如未配置 lifecycle）
log "清理 S3 过期备份..."
rclone delete "$S3_BUCKET/" \
  --max-age "$((RETENTION_DAYS * 24))h" \
  --include "snapshot-*.db.gz" 2>>"$LOG_FILE" || true

# 9. 推送监控指标（node_exporter textfile）
METRICS_DIR="/var/lib/node_exporter/textfile"
mkdir -p "$METRICS_DIR"
cat > "$METRICS_DIR/etcd_backup.prom" <<METRICS
# HELP etcd_backup_last_success_timestamp 上次成功备份时间戳
# TYPE etcd_backup_last_success_timestamp gauge
etcd_backup_last_success_timestamp $(date +%s)
# HELP etcd_backup_status 备份状态 1=成功 0=失败
# TYPE etcd_backup_status gauge
etcd_backup_status 1
# HELP etcd_backup_size_bytes 备份文件大小
# TYPE etcd_backup_size_bytes gauge
etcd_backup_size_bytes $(stat -c%s "$SNAPSHOT_FILE")
METRICS

log "===== etcd 备份成功完成 ====="
log "快照大小: $(du -h "$SNAPSHOT_FILE" | cut -f1)"
log "S3 路径: $S3_BUCKET/$(basename "$SNAPSHOT_FILE")"

exit 0
