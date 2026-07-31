#!/bin/bash
# ============================================================
# 迁移前环境检查脚本
# 用途：在任何迁移操作前执行，自动检查源端/目标端前置条件
# 检查项：磁盘空间、网络连通性、备份状态、服务状态、数据量、
#         复制延迟、连接数、端口占用、时间同步
# 用法：bash pre_migration_check.sh --source <ip> --target <ip> [--type db|k8s|web]
# ============================================================

set -euo pipefail

# ---------- 参数解析 ----------
SOURCE_IP=""
TARGET_IP=""
MIGR_TYPE="db"
CHECKS_PASSED=0
CHECKS_FAILED=0
REPORT_FILE="/var/log/migration/pre_migration_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$REPORT_FILE")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)  SOURCE_IP="$2"; shift 2;;
    --target)  TARGET_IP="$2"; shift 2;;
    --type)    MIGR_TYPE="$2"; shift 2;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

if [ -z "$SOURCE_IP" ] || [ -z "$TARGET_IP" ]; then
  echo "用法: $0 --source <源IP> --target <目标IP> [--type db|k8s|web]"
  exit 1
fi

# ---------- 工具函数 ----------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$REPORT_FILE"
}

pass() {
  echo "  [✓ PASS] $1" | tee -a "$REPORT_FILE"
  ((CHECKS_PASSED++))
}

fail() {
  echo "  [✗ FAIL] $1" | tee -a "$REPORT_FILE"
  ((CHECKS_FAILED++))
}

warn() {
  echo "  [! WARN] $1" | tee -a "$REPORT_FILE"
}

remote_exec() {
  local ip="$1"; shift
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "ops@$ip" "$@" 2>/dev/null
}

# ---------- 报告头 ----------
log "============================================================"
log "  迁移前环境检查报告"
log "  源端: $SOURCE_IP    目标端: $TARGET_IP"
log "  迁移类型: $MIGR_TYPE"
log "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
log "============================================================"

# ============================================================
# 1. 通用检查（所有迁移类型）
# ============================================================
log ""
log "【1. 通用检查】"

# 1.1 网络连通性
log "检查源端 -> 目标端网络连通性..."
if ping -c 3 -W 2 "$TARGET_IP" >/dev/null 2>&1; then
  pass "源端可 ping 通目标端"
else
  fail "源端无法 ping 通目标端，请检查网络/安全组"
fi

# 1.2 SSH 可达性
log "检查 SSH 可达性..."
if remote_exec "$SOURCE_IP" "echo ok" 2>/dev/null | grep -q ok; then
  pass "源端 SSH 可达"
else
  fail "源端 SSH 不可达"
fi
if remote_exec "$TARGET_IP" "echo ok" 2>/dev/null | grep -q ok; then
  pass "目标端 SSH 可达"
else
  fail "目标端 SSH 不可达"
fi

# 1.3 磁盘空间（目标端剩余空间需 > 源端数据量 * 1.5）
log "检查目标端磁盘空间..."
TARGET_DISK_AVAIL=$(remote_exec "$TARGET_IP" "df -BG /data 2>/dev/null | tail -1 | awk '{print \$4}' | tr -d 'G'" 2>/dev/null || echo 0)
if [ "$TARGET_DISK_AVAIL" -gt 50 ]; then
  pass "目标端 /data 可用空间: ${TARGET_DISK_AVAIL}GB"
else
  fail "目标端 /data 可用空间不足: ${TARGET_DISK_AVAIL}GB（需 >50GB）"
fi

# 1.4 时间同步
log "检查时间同步..."
SOURCE_TIME=$(remote_exec "$SOURCE_IP" "date +%s" 2>/dev/null || echo 0)
TARGET_TIME=$(remote_exec "$TARGET_IP" "date +%s" 2>/dev/null || echo 0)
TIME_DIFF=$((SOURCE_TIME - TARGET_TIME))
[ "$TIME_DIFF" -lt 0 ] && TIME_DIFF=$((-TIME_DIFF))
if [ "$TIME_DIFF" -lt 5 ]; then
  pass "时间同步偏差: ${TIME_DIFF}s"
else
  fail "时间同步偏差过大: ${TIME_DIFF}s（需 <5s，检查 chrony/ntp）"
fi

# 1.5 备份状态确认
log "检查源端最新备份状态..."
SOURCE_BACKUP_METRIC=$(remote_exec "$SOURCE_IP" \
  "cat /var/lib/node_exporter/textfile/*backup*.prom 2>/dev/null | grep '_status ' | awk '{print \$2}'" 2>/dev/null || echo "")
if [ "$SOURCE_BACKUP_METRIC" = "1" ]; then
  pass "源端最近备份状态: 成功"
else
  warn "源端备份状态未确认，迁移前必须完成一次完整备份"
fi

# ============================================================
# 2. 数据库迁移专项检查
# ============================================================
if [ "$MIGR_TYPE" = "db" ]; then
  log ""
  log "【2. 数据库迁移专项检查】"

  # 2.1 源端数据库连接数
  log "检查源端数据库连接数..."
  for PORT in 3306 5432 4000; do
    CONN=$(remote_exec "$SOURCE_IP" "ss -tn state established '( sport = :$PORT )' 2>/dev/null | wc -l" 2>/dev/null || echo 0)
    if [ "$CONN" -gt 0 ]; then
      if [ "$CONN" -gt 200 ]; then
        warn "端口 ${PORT} 活跃连接 ${CONN}（较高，建议低峰迁移）"
      else
        pass "端口 ${PORT} 活跃连接 ${CONN}"
      fi
    fi
  done

  # 2.2 源端复制延迟
  log "检查源端复制延迟..."
  REPL_LAG=$(remote_exec "$SOURCE_IP" \
    "mysqladmin -umonitor -p\${MYSQL_PASS} extended-status 2>/dev/null | grep Seconds_Behind | awk '{print \$4}' || echo -1" 2>/dev/null || echo -1)
  if [ "$REPL_LAG" = "-1" ]; then
    warn "无法获取复制延迟（非从库或无权限）"
  elif [ "$REPL_LAG" -lt 10 ]; then
    pass "复制延迟: ${REPL_LAG}s"
  else
    fail "复制延迟过大: ${REPL_LAG}s（需 <10s 再开始迁移）"
  fi

  # 2.3 目标端端口占用
  log "检查目标端端口占用..."
  for PORT in 3306 5432 4000 9104 9187; do
    if remote_exec "$TARGET_IP" "ss -tln | grep -q ':$PORT '" 2>/dev/null; then
      warn "目标端端口 ${PORT} 已被占用"
    else
      pass "目标端端口 ${PORT} 空闲"
    fi
  done

  # 2.4 源端大表检查
  log "检查源端大表（>10GB）..."
  BIG_TABLES=$(remote_exec "$SOURCE_IP" \
    "mysql -umonitor -p\${MYSQL_PASS} -BN 2>/dev/null -e \"SELECT count(*) FROM information_schema.TABLES WHERE (DATA_LENGTH+INDEX_LENGTH)/1024/1024/1024 > 10\" || echo 0" 2>/dev/null || echo 0)
  if [ "$BIG_TABLES" -gt 0 ]; then
    warn "源端有 ${BIG_TABLES} 张大表(>10GB)，全量迁移耗时较长，建议使用增量同步"
  else
    pass "无超大表，全量迁移耗时可控"
  fi

  # 2.5 源端长事务检查
  log "检查源端长事务..."
  LONG_TXN=$(remote_exec "$SOURCE_IP" \
    "mysql -umonitor -p\${MYSQL_PASS} -BN 2>/dev/null -e \"SELECT count(*) FROM information_schema.innodb_trx WHERE TIME_TO_SEC(TIMEDIFF(NOW(), trx_started)) > 60\" || echo 0" 2>/dev/null || echo 0)
  if [ "$LONG_TXN" -gt 0 ]; then
    fail "源端存在 ${LONG_TXN} 个长事务(>60s)，迁移前需清理"
  else
    pass "无长事务阻塞"
  fi

# ============================================================
# 3. K8s 迁移专项检查
# ============================================================
elif [ "$MIGR_TYPE" = "k8s" ]; then
  log ""
  log "【3. K8s 迁移专项检查】"

  # 3.1 源端集群状态
  log "检查源端集群节点状态..."
  SOURCE_NODES=$(remote_exec "$SOURCE_IP" "kubectl get nodes --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo 0)
  SOURCE_NOTREADY=$(remote_exec "$SOURCE_IP" \
    "kubectl get nodes --no-headers 2>/dev/null | grep -v ' Ready' | wc -l" 2>/dev/null || echo 0)
  if [ "$SOURCE_NOTREADY" -eq 0 ] && [ "$SOURCE_NODES" -gt 0 ]; then
    pass "源端集群 ${SOURCE_NODES} 节点全部 Ready"
  else
    fail "源端集群有 ${SOURCE_NOTREADY} 个节点 NotReady"
  fi

  # 3.2 目标端集群状态
  log "检查目标端集群节点状态..."
  TARGET_NODES=$(remote_exec "$TARGET_IP" "kubectl get nodes --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo 0)
  TARGET_NOTREADY=$(remote_exec "$TARGET_IP" \
    "kubectl get nodes --no-headers 2>/dev/null | grep -v ' Ready' | wc -l" 2>/dev/null || echo 0)
  if [ "$TARGET_NOTREADY" -eq 0 ] && [ "$TARGET_NODES" -gt 0 ]; then
    pass "目标端集群 ${TARGET_NODES} 节点全部 Ready"
  else
    fail "目标端集群有 ${TARGET_NOTREADY} 个节点 NotReady"
  fi

  # 3.3 PV 数量与容量
  log "检查源端 PV 数量..."
  PV_COUNT=$(remote_exec "$SOURCE_IP" "kubectl get pv --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo 0)
  if [ "$PV_COUNT" -gt 0 ]; then
    warn "源端有 ${PV_COUNT} 个 PV，持久化数据迁移需重点关注"
  else
    pass "源端无 PV，迁移复杂度较低"
  fi

  # 3.4 镜像可用性
  log "检查目标端镜像拉取能力..."
  if remote_exec "$TARGET_IP" "crictl pull busybox:latest 2>/dev/null && crictl rmi busybox:latest 2>/dev/null"; then
    pass "目标端镜像拉取正常"
  else
    warn "目标端镜像拉取测试失败，检查镜像仓库连通性"
  fi

  # 3.5 Velero 安装状态
  log "检查 Velero 安装状态..."
  if remote_exec "$SOURCE_IP" "kubectl get deployment velero -n velero 2>/dev/null" | grep -q velero; then
    pass "源端已安装 Velero"
  else
    fail "源端未安装 Velero，备份恢复迁移方案不可用"
  fi

# ============================================================
# 4. Web 服务器迁移专项检查
# ============================================================
elif [ "$MIGR_TYPE" = "web" ]; then
  log ""
  log "【4. Web 服务器迁移专项检查】"

  # 4.1 源端 Web 服务状态
  log "检查源端 Web 服务状态..."
  for PORT in 80 443 8080; do
    if remote_exec "$SOURCE_IP" "ss -tln | grep -q ':$PORT '" 2>/dev/null; then
      pass "源端监听端口 ${PORT}"
    fi
  done

  # 4.2 目标端端口占用
  log "检查目标端端口占用..."
  for PORT in 80 443 8080; do
    if remote_exec "$TARGET_IP" "ss -tln | grep -q ':$PORT '" 2>/dev/null; then
      fail "目标端端口 ${PORT} 已被占用"
    else
      pass "目标端端口 ${PORT} 空闲"
    fi
  done

  # 4.3 SSL 证书有效期
  log "检查 SSL 证书有效期..."
  CERT_DAYS=$(remote_exec "$SOURCE_IP" \
    "openssl s_client -connect localhost:443 </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 | xargs -I{} date -d '{} +%s' 2>/dev/null" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [ "$CERT_DAYS" -gt 0 ]; then
    REMAINING=$(( (CERT_DAYS - NOW) / 86400 ))
    if [ "$REMAINING" -gt 30 ]; then
      pass "SSL 证书剩余有效期: ${REMAINING} 天"
    else
      warn "SSL 证书剩余有效期: ${REMAINING} 天（<30天，迁移后需续期）"
    fi
  fi

  # 4.4 配置文件备份
  log "检查 Nginx 配置文件..."
  if remote_exec "$SOURCE_IP" "test -d /etc/nginx && ls /etc/nginx/conf.d/*.conf 2>/dev/null | wc -l" 2>/dev/null | grep -qE '[0-9]'; then
    pass "源端 Nginx 配置文件存在"
  else
    warn "未检测到 Nginx 配置目录，请确认 Web 服务类型"
  fi

  # 4.5 静态资源数据量
  log "检查静态资源数据量..."
  WEB_SIZE=$(remote_exec "$SOURCE_IP" "du -sBG /var/www 2>/dev/null | awk '{print \$1}' | tr -d 'G'" 2>/dev/null || echo 0)
  if [ "$WEB_SIZE" -gt 0 ]; then
    pass "静态资源大小: ${WEB_SIZE}GB"
  else
    warn "未检测到 /var/www，请确认静态资源路径"
  fi
fi

# ============================================================
# 汇总
# ============================================================
log ""
log "============================================================"
log "  检查汇总: ${CHECKS_PASSED} 通过, ${CHECKS_FAILED} 失败"
if [ "$CHECKS_FAILED" -gt 0 ]; then
  log "  结论: ❌ 存在失败项，请修复后再启动迁移"
  log "============================================================"
  exit 1
else
  log "  结论: ✅ 前置检查全部通过，可以启动迁移"
  log "============================================================"
  exit 0
fi
