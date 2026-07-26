#!/bin/bash
# ============================================================
# 日志清理脚本
# 定时执行，防止磁盘空间不足
# ============================================================

set -euo pipefail

LOG_FILE="/var/log/log_cleanup.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "===== 日志清理开始 ====="

# 1. 系统日志文件（超过 30 天的 .log.* 和 .gz）
log "清理 /var/log 旧日志..."
deleted=$(find /var/log -type f \( -name "*.log.*" -o -name "*.gz" -o -name "*.old" \) -mtime +30 -delete -print 2>/dev/null | wc -l)
log "删除 $deleted 个旧日志文件"

# 2. journald 日志（保留 7 天）
log "清理 journald..."
journalctl --vacuum-time=7d >>"$LOG_FILE" 2>&1 || true

# 3. Ansible 临时文件
log "清理 Ansible 临时文件..."
find /tmp -maxdepth 1 -name "ansible_*" -mtime +7 -delete 2>/dev/null || true

# 4. 容器/容器运行时日志
log "清理容器日志..."
# containerd 日志
find /var/log/containers -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true
find /var/log/pods -type f -name "*.log" -mtime +7 -delete 2>/dev/null || true

# 5. MySQL 慢查询日志（保留 7 天）
if [ -d /var/log/mysql ]; then
  log "清理 MySQL 日志..."
  find /var/log/mysql -name "slow.log.*" -mtime +7 -delete 2>/dev/null || true
  find /var/log/mysql -name "error.log.*" -mtime +7 -delete 2>/dev/null || true
fi

# 6. Nginx 日志（保留 15 天）
if [ -d /var/log/nginx ]; then
  log "清理 Nginx 日志..."
  find /var/log/nginx -name "*.log.*" -mtime +15 -delete 2>/dev/null || true
fi

# 7. 备份临时文件
log "清理临时备份..."
find /tmp -name "*.tar.gz" -mtime +1 -delete 2>/dev/null || true

# 8. 报告清理（保留 90 天）
find /var/log/health_check -type f -mtime +90 -delete 2>/dev/null || true
find /var/log/db_health -type f -mtime +90 -delete 2>/dev/null || true
find /var/log/k8s_health -type f -mtime +90 -delete 2>/dev/null || true

# 9. 推送指标
METRICS_DIR="/var/lib/node_exporter/textfile"
mkdir -p "$METRICS_DIR"
cat > "$METRICS_DIR/log_cleanup.prom" <<METRICS
log_cleanup_last_success_timestamp $(date +%s)
log_cleanup_status 1
METRICS

log "===== 日志清理完成 ====="
