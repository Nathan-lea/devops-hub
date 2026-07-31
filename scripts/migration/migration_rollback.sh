#!/bin/bash
# ============================================================
# 迁移回滚辅助脚本
# 用途：迁移异常时辅助执行回滚操作（DNS 回切/同步停止/状态检查）
# 用法：bash migration_rollback.sh --type dns|sync|check --action rollback|status
# ============================================================

set -euo pipefail

ROLLBACK_TYPE=""
ACTION="rollback"
REPORT_FILE="/var/log/migration/rollback_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$REPORT_FILE")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --type)   ROLLBACK_TYPE="$2"; shift 2;;
    --action) ACTION="$2"; shift 2;;
    *) echo "未知参数: $1"; echo "用法: $0 --type dns|sync|check --action rollback|status"; exit 1;;
  esac
done

if [ -z "$ROLLBACK_TYPE" ]; then
  echo "用法: $0 --type dns|sync|check --action rollback|status"
  exit 1
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$REPORT_FILE"; }

log "============================================================"
log "  迁移回滚辅助脚本"
log "  类型: $ROLLBACK_TYPE    动作: $ACTION"
log "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
log "============================================================"

# ============================================================
# DNS 回滚：将 DNS 权重回切至源端
# ============================================================
if [ "$ROLLBACK_TYPE" = "dns" ]; then
  if [ "$ACTION" = "rollback" ]; then
    log "【DNS 回滚】将 DNS 权重切回源端"
    log ""
    log "操作步骤："
    log "  1. 登录 DNS 管理控制台（Route53/阿里云DNS）"
    log "  2. 将源端记录权重设为 100，目标端设为 0"
    log "  3. 确认 DNS TTL = 60s"
    log "  4. 等待 DNS 生效（最多 60s）"
    log ""
    log "验证命令："
    log "  dig app.example.com +short    # 确认解析回源端 IP"
    log "  curl -sI https://app.example.com/health"
    log ""
    log "⚠️  DNS 回滚后，确认源端服务正常后再通知业务方"
    log ""
    read -p "确认已执行 DNS 回滚？(y/N) " CONFIRM
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
      log "✓ DNS 回滚已确认执行"
    else
      log "✗ DNS 回滚未确认，请手动执行后重新运行"
      exit 1
    fi

  elif [ "$ACTION" = "status" ]; then
    log "【DNS 状态检查】"
    log "当前 DNS 解析结果："
    if command -v dig >/dev/null 2>&1; then
      dig app.example.com +short 2>/dev/null | tee -a "$REPORT_FILE" || \
        log "  无法解析，请检查域名配置"
    else
      log "  dig 不可用，使用 nslookup"
      nslookup app.example.com 2>/dev/null | tee -a "$REPORT_FILE" || \
        log "  无法解析"
    fi
  fi

# ============================================================
# 同步停止：停止增量同步工具（DM/CDC）
# ============================================================
elif [ "$ROLLBACK_TYPE" = "sync" ]; then
  if [ "$ACTION" = "rollback" ]; then
    log "【同步停止】停止增量同步工具"
    log ""
    log "操作步骤（按实际使用的工具执行）："
    log ""
    log "  # DM 停止同步"
    log "  tiup dm --prefix dm-prod task stop mysql-to-tidb-01"
    log ""
    log "  # TiDB CDC 停止同步"
    log "  tiup cdc cli changefeed pause --pd <PD>:2379 --changefeed-id <feed-id>"
    log ""
    log "  # 应用双写停止（修改配置中心，关闭双写开关）"
    log ""
    read -p "确认已停止同步工具？(y/N) " CONFIRM
    if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
      log "✓ 同步工具已停止"
    else
      log "✗ 请先停止同步工具再继续"
      exit 1
    fi

  elif [ "$ACTION" = "status" ]; then
    log "【同步状态检查】"
    log "DM 任务状态："
    tiup dm --prefix dm-prod task query 2>/dev/null | tee -a "$REPORT_FILE" || \
      log "  DM 不可用或无任务"
  fi

# ============================================================
# 综合检查：检查源端/目标端服务状态
# ============================================================
elif [ "$ROLLBACK_TYPE" = "check" ]; then
  log "【综合状态检查】"
  log ""

  # 检查常见服务端口
  log "--- 服务端口检查 ---"
  for PORT in 80 443 3306 4000 5432 6379 9100 9090; do
    if ss -tln | grep -q ":$PORT " 2>/dev/null; then
      log "  [✓] 端口 $PORT 监听中"
    fi
  done

  # 检查 Nginx
  if command -v systemctl >/dev/null 2>&1; then
    log ""
    log "--- 服务状态检查 ---"
    for SVC in nginx mysqld postgresql redis-server; do
      if systemctl is-active "$SVC" >/dev/null 2>&1; then
        log "  [✓] $SVC 运行中"
      fi
    done
  fi

  # 检查磁盘空间
  log ""
  log "--- 磁盘空间 ---"
  df -h / /data 2>/dev/null | tee -a "$REPORT_FILE" || true

  log ""
  log "请人工确认源端服务正常后，继续回滚操作"
fi

log ""
log "============================================================"
log "  回滚操作记录已完成，请保存日志：$REPORT_FILE"
log "============================================================"

exit 0
