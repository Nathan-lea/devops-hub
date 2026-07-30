#!/bin/bash
# ============================================================
# PostgreSQL 备份脚本
# - 逻辑备份：pg_dumpall（全局对象）+ pg_dump（逐库 custom 格式）
# - 物理备份：pg_basebackup（可选，通过 BACKUP_MODE=physical 启用）
# 部署在 PostgreSQL 服务器，每日 02:30 执行
# ============================================================

set -euo pipefail

# ---------- 配置 ----------
BACKUP_BASE="/data/backup/postgresql"
S3_BUCKET="s3://db-backup/postgresql"
RETENTION_DAYS=7
PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"
PG_USER="${PG_USER:-backup}"
PG_PASS="${PG_PASS:-}"            # 对应 .pgpass 或环境变量
BACKUP_MODE="${BACKUP_MODE:-logical}"   # logical | physical
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

DATE=$(date +%Y%m%d)
BACKUP_DIR="$BACKUP_BASE/$(hostname)/$DATE"
LOG_FILE="/var/log/postgresql_backup.log"
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
      -d "{\"text\":\":rotating_light: PostgreSQL 备份告警 ($(hostname)): $msg\"}" >/dev/null
  fi
}

# ---------- 前置校验 ----------
export PGPASSWORD="${PG_PASS}"
if [ -z "$PG_PASS" ]; then
  log "ERROR: 未设置 PG_PASS 环境变量"
  exit 1
fi

if ! command -v pg_dump >/dev/null 2>&1; then
  log "ERROR: 未找到 pg_dump，请安装 postgresql-client"
  exit 1
fi

log "===== PostgreSQL 备份开始 ====="
log "主机: $(hostname)  日期: $DATE  模式: $BACKUP_MODE  目录: $BACKUP_DIR"

# ---------- 备份执行 ----------
if [ "$BACKUP_MODE" = "physical" ]; then
  # ===== 物理备份（pg_basebackup）=====
  log "执行 pg_basebackup 物理全量备份..."
  if ! pg_basebackup \
    -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
    -D "$BACKUP_DIR/base" -Ft -z -P \
    --wal-method=stream >>"$LOG_FILE" 2>&1; then
    send_alert "pg_basebackup 备份失败！"
    exit 1
  fi
  BACKUP_SIZE=$(du -sb "$BACKUP_DIR/base" | cut -f1)
  log "物理备份完成，大小: $(numfmt --to=iec "$BACKUP_SIZE")"

else
  # ===== 逻辑备份 =====
  # 1. 全局对象（角色、表空间）
  log "导出全局对象（pg_dumpall --globals-only）..."
  if ! pg_dumpall -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
    --globals-only --no-password \
    | gzip > "$BACKUP_DIR/globals.sql.gz"; then
    send_alert "pg_dumpall 全局对象导出失败！"
    exit 1
  fi

  # 2. 逐库 logical 备份（custom 格式，自带压缩）
  log "逐库执行 pg_dump（custom 格式）..."
  DATABASES=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Atqc \
    "SELECT datname FROM pg_database WHERE datistemplate = false" 2>/dev/null)

  for DB in $DATABASES; do
    log "  备份数据库: $DB"
    if ! pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" \
      -d "$DB" -Fc -Z6 --no-password \
      -f "$BACKUP_DIR/${DB}.dump"; then
      send_alert "pg_dump 数据库 $DB 备份失败！"
      exit 1
    fi
  done

  BACKUP_SIZE=$(du -sb "$BACKUP_DIR" | cut -f1)
  log "逻辑备份完成，大小: $(numfmt --to=iec "$BACKUP_SIZE")"
fi

# ---------- 验证 ----------
log "验证备份文件..."
BACKUP_FILE_COUNT=$(find "$BACKUP_DIR" -type f | wc -l)
if [ "$BACKUP_FILE_COUNT" -eq 0 ]; then
  send_alert "备份验证失败：备份目录为空"
  exit 1
fi
log "备份文件数: $BACKUP_FILE_COUNT"

# ---------- 上传 S3 ----------
log "上传到对象存储..."
if ! rclone copy "$BACKUP_DIR" "$S3_BUCKET/$(hostname)/$DATE/" \
  --progress --transfers=4 2>>"$LOG_FILE"; then
  send_alert "备份上传 S3 失败！"
  exit 1
fi

# ---------- 校验 S3 ----------
log "校验 S3 文件..."
if ! rclone check "$BACKUP_DIR" "$S3_BUCKET/$(hostname)/$DATE/" \
  --one-way 2>>"$LOG_FILE"; then
  send_alert "S3 校验失败！"
  exit 1
fi

# ---------- 清理过期备份 ----------
log "清理 ${RETENTION_DAYS} 天前的本地备份..."
find "$BACKUP_BASE/$(hostname)" -maxdepth 1 -type d -name "20*" \
  -mtime +"$RETENTION_DAYS" -exec rm -rf {} \;

log "清理 S3 过期备份..."
rclone delete "$S3_BUCKET/$(hostname)/" \
  --max-age "$((RETENTION_DAYS * 24))h" \
  --rmdirs 2>>"$LOG_FILE" || true

# ---------- 推送监控指标 ----------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
METRICS_DIR="/var/lib/node_exporter/textfile"
mkdir -p "$METRICS_DIR"
cat > "$METRICS_DIR/postgresql_backup.prom" <<METRICS
# HELP postgresql_backup_last_success_timestamp 上次成功备份时间
# TYPE postgresql_backup_last_success_timestamp gauge
postgresql_backup_last_success_timestamp $(date +%s)
# HELP postgresql_backup_status 备份状态 1=成功 0=失败
# TYPE postgresql_backup_status gauge
postgresql_backup_status 1
# HELP postgresql_backup_duration_seconds 备份耗时
# TYPE postgresql_backup_duration_seconds gauge
postgresql_backup_duration_seconds $DURATION
# HELP postgresql_backup_size_bytes 备份大小
# TYPE postgresql_backup_size_bytes gauge
postgresql_backup_size_bytes $BACKUP_SIZE
METRICS

log "===== PostgreSQL 备份成功完成 ====="
log "耗时: ${DURATION}s  大小: $(numfmt --to=iec "$BACKUP_SIZE")"
log "S3 路径: $S3_BUCKET/$(hostname)/$DATE/"

# 清理密码变量
unset PGPASSWORD

exit 0
