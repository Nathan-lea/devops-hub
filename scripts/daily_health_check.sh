#!/bin/bash
# ============================================================
# 每日主机健康巡检脚本
# 检查项：负载、磁盘、内存、进程、日志、NTP、网络
# 输出：巡检报告（文本），可推送到企微/钉钉/邮件
# ============================================================

set -euo pipefail

REPORT_FILE="/var/log/health_check/$(date +%Y%m%d)_health_report.txt"
mkdir -p "$(dirname "$REPORT_FILE")"

HOSTNAME=$(hostname)
DATE=$(date '+%Y-%m-%d %H:%M:%S')
WARN_COUNT=0
CRIT_COUNT=0

# 阈值
DISK_THRESHOLD=80
MEM_THRESHOLD=90
LOAD_THRESHOLD_FACTOR=2    # load5 > 核数×2 告警
ZOMBIE_THRESHOLD=5

echo "============================================================"
echo "  主机健康巡检报告"
echo "  主机: $HOSTNAME"
echo "  时间: $DATE"
echo "============================================================"
echo ""

# ---------- 1. 系统负载 ----------
echo "【1. 系统负载】"
LOAD1=$(awk '{print $1}' /proc/loadavg)
LOAD5=$(awk '{print $2}' /proc/loadavg)
LOAD15=$(awk '{print $3}' /proc/loadavg)
CPU_CORES=$(nproc)
LOAD_LIMIT=$((CPU_CORES * LOAD_THRESHOLD_FACTOR))
if (( $(echo "$LOAD5 > $LOAD_LIMIT" | bc -l) )); then
  echo "  [WARN] load5=${LOAD5} 超过阈值 ${LOAD_LIMIT}（CPU核心数=${CPU_CORES}）"
  ((WARN_COUNT++))
else
  echo "  [OK] load1=${LOAD1} load5=${LOAD5} load15=${LOAD15}（核心数=${CPU_CORES}）"
fi
echo ""

# ---------- 2. 内存使用 ----------
echo "【2. 内存使用】"
MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo)
MEM_AVAIL=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
MEM_USED_PCT=$((MEM_USED * 100 / MEM_TOTAL))
if (( MEM_USED_PCT > MEM_THRESHOLD )); then
  echo "  [WARN] 内存使用 ${MEM_USED_PCT}% 超过阈值 ${MEM_THRESHOLD}%"
  ((WARN_COUNT++))
else
  echo "  [OK] 内存使用 ${MEM_USED_PCT}%（总计=$((MEM_TOTAL/1024))MB 可用=$((MEM_AVAIL/1024))MB）"
fi
echo ""

# ---------- 3. 磁盘空间 ----------
echo "【3. 磁盘空间】"
df -h | grep -E '^/dev' | while read -r line; do
  PART=$(echo "$line" | awk '{print $1}')
  MOUNT=$(echo "$line" | awk '{print $6}')
  USAGE=$(echo "$line" | awk '{print $5}' | tr -d '%')
  if (( USAGE > DISK_THRESHOLD )); then
    echo "  [WARN] ${MOUNT} 使用 ${USAGE}% 超过阈值 ${DISK_THRESHOLD}%"
    echo "  [WARN] ${MOUNT} 使用 ${USAGE}% 超过阈值 ${DISK_THRESHOLD}%" >> /tmp/disk_warn_$$
  else
    echo "  [OK] ${MOUNT} 使用 ${USAGE}%"
  fi
done
[ -f /tmp/disk_warn_$$ ] && { WARN_COUNT=$((WARN_COUNT+1)); rm -f /tmp/disk_warn_$$; }
echo ""

# ---------- 4. 磁盘 inode ----------
echo "【4. 磁盘 inode】"
df -i | grep -E '^/dev' | while read -r line; do
  MOUNT=$(echo "$line" | awk '{print $6}')
  USAGE=$(echo "$line" | awk '{print $5}' | tr -d '%')
  if (( USAGE > DISK_THRESHOLD )); then
    echo "  [WARN] ${MOUNT} inode 使用 ${USAGE}%"
    echo "  [WARN] ${MOUNT} inode 使用 ${USAGE}%" >> /tmp/inode_warn_$$
  else
    echo "  [OK] ${MOUNT} inode 使用 ${USAGE}%"
  fi
done
[ -f /tmp/inode_warn_$$ ] && { WARN_COUNT=$((WARN_COUNT+1)); rm -f /tmp/inode_warn_$$; }
echo ""

# ---------- 5. 关键进程 ----------
echo "【5. 关键进程】"
CRITICAL_PROCS=("sshd" "systemd-journald" "cron" "systemd-udevd")
for proc in "${CRITICAL_PROCS[@]}"; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    echo "  [OK] $proc 运行中"
  else
    echo "  [CRIT] $proc 未运行！"
    ((CRIT_COUNT++))
  fi
done
echo ""

# ---------- 6. 僵尸进程 ----------
echo "【6. 僵尸进程】"
ZOMBIES=$(ps aux | awk '$8=="Z"' | wc -l)
if (( ZOMBIES > ZOMBIE_THRESHOLD )); then
  echo "  [WARN] 发现 ${ZOMBIES} 个僵尸进程（阈值=${ZOMBIE_THRESHOLD}）"
  ((WARN_COUNT++))
else
  echo "  [OK] 僵尸进程数=${ZOMBIES}"
fi
echo ""

# ---------- 7. NTP 同步 ----------
echo "【7. 时间同步】"
if command -v chronyc >/dev/null 2>&1; then
  SYNC_STATUS=$(chronyc tracking 2>/dev/null | grep "Sync status" || echo "未知")
  echo "  chronyc: $SYNC_STATUS"
elif command -v ntpstat >/dev/null 2>&1; then
  if ntpstat >/dev/null 2>&1; then
    echo "  [OK] NTP 同步正常"
  else
    echo "  [WARN] NTP 未同步"
    ((WARN_COUNT++))
  fi
else
  echo "  [INFO] 未找到 chronyc/ntpstat"
fi
echo ""

# ---------- 8. 最近系统错误 ----------
echo "【8. 最近系统错误（最近1小时）】"
if command -v journalctl >/dev/null 2>&1; then
  ERR_COUNT=$(journalctl --since "1 hour ago" -p err --no-pager 2>/dev/null | grep -c . || true)
  if (( ERR_COUNT > 50 )); then
    echo "  [WARN] 最近1小时系统错误 ${ERR_COUNT} 条"
    ((WARN_COUNT++))
  else
    echo "  [OK] 最近1小时系统错误 ${ERR_COUNT} 条"
  fi
else
  echo "  [INFO] journalctl 不可用"
fi
echo ""

# ---------- 9. 网络连接数 ----------
echo "【9. 网络连接】"
ESTABLISHED=$(ss -tn state established | wc -l)
TIME_WAIT=$(ss -tn state time-wait | wc -l)
echo "  ESTABLISHED=${ESTABLISHED}  TIME_WAIT=${TIME_WAIT}"
echo ""

# ---------- 10. SSH 登录失败（安全） ----------
echo "【10. SSH 登录失败（最近24小时）】"
if [ -f /var/log/auth.log ]; then
  SSH_FAIL=$(grep "Failed password" /var/log/auth.log 2>/dev/null | grep "$(date +%b\ %e)" | wc -l || echo 0)
elif [ -f /var/log/secure ]; then
  SSH_FAIL=$(grep "Failed password" /var/log/secure 2>/dev/null | grep "$(date +%b\ %e)" | wc -l || echo 0)
else
  SSH_FAIL=0
fi
if (( SSH_FAIL > 100 )); then
  echo "  [WARN] SSH 登录失败 ${SSH_FAIL} 次（可能爆破）"
  ((WARN_COUNT++))
else
  echo "  [OK] SSH 登录失败 ${SSH_FAIL} 次"
fi
echo ""

# ---------- 汇总 ----------
echo "============================================================"
echo "  巡检汇总：告警 ${WARN_COUNT} 项，严重 ${CRIT_COUNT} 项"
echo "  生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"

# 保存报告
tee "$REPORT_FILE" <<REPORT_EOF
$(cat)
REPORT_EOF

# 如果有告警，推送到通知（示例：企微机器人）
if (( WARN_COUNT > 0 || CRIT_COUNT > 0 )); then
  # 此处可对接企微/钉钉 webhook
  echo "存在异常，建议人工确认" >&2
  exit 1
fi

exit 0
