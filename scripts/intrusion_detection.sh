#!/bin/bash
# ============================================================
# 主机入侵检测脚本
# 检测项：反向Shell、rootkit特征、异常进程、持久化后门
#         异常crontab、异常SSH密钥、异常用户、SUID变更
# 推送指标到 node_exporter textfile
# 部署：每台主机 cron 每 10 分钟执行
# ============================================================

set -euo pipefail

METRICS_DIR="/var/lib/node_exporter/textfile"
METRICS_FILE="$METRICS_DIR/intrusion_detection.prom"
LOG_FILE="/var/log/intrusion_detection.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

mkdir -p "$METRICS_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_alert() {
  local msg="$1"
  log "ALERT: $msg"
  if [ -n "$SLACK_WEBHOOK" ]; then
    curl -s -X POST "$SLACK_WEBHOOK" -H 'Content-Type: application/json' \
      -d "{\"text\":\":rotating_light: 入侵检测告警 ($(hostname)): $msg\"}" >/dev/null
  fi
}

# 初始化指标
echo "# HELP intrusion_detection_reverse_shell 反向Shell检测数" > "$METRICS_FILE"
echo "# TYPE intrusion_detection_reverse_shell gauge" >> "$METRICS_FILE"
echo "# HELP intrusion_detection_rootkit rootkit特征检测数" >> "$METRICS_FILE"
echo "# TYPE intrusion_detection_rootkit gauge" >> "$METRICS_FILE"
echo "# HELP intrusion_detection_anomaly_process 异常进程检测数" >> "$METRICS_FILE"
echo "# TYPE intrusion_detection_anomaly_process gauge" >> "$METRICS_FILE"
echo "# HELP intrusion_detection_persistence 持久化后门检测数" >> "$METRICS_FILE"
echo "# TYPE intrusion_detection_persistence gauge" >> "$METRICS_FILE"
echo "# HELP intrusion_detection_anomaly_user 异常用户检测数" >> "$METRICS_FILE"
echo "# TYPE intrusion_detection_anomaly_user gauge" >> "$METRICS_FILE"
echo "# HELP intrusion_detection_last_success_timestamp 上次检测时间戳" >> "$METRICS_FILE"
echo "# TYPE intrusion_detection_last_success_timestamp gauge" >> "$METRICS_FILE"

REVERSE_SHELL_COUNT=0
ROOTKIT_COUNT=0
ANOMALY_PROC_COUNT=0
PERSISTENCE_COUNT=0
ANOMALY_USER_COUNT=0

log "===== 入侵检测开始 ====="

# ========== 1. 反向 Shell 检测 ==========
log "检测反向 Shell..."

# 1.1 检测 shell 进程有网络连接
for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
  cmdline=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ' | head -c 200)
  if [ -z "$cmdline" ]; then
    continue
  fi

  # 检查是否为 shell/解释器 进程
  if echo "$cmdline" | grep -qiE '(bash|sh$|zsh|python[0-9.]*|perl|ruby|nc |ncat|socat|busybox)'; then
    # 检查是否有 socket 文件描述符
    socket_fds=$(ls -la /proc/$pid/fd 2>/dev/null | grep -c 'socket:')
    if [ "$socket_fds" -gt 0 ] 2>/dev/null; then
      # 排除已知正常进程（如 systemd, login, sshd 等）
      exe=$(readlink /proc/$pid/exe 2>/dev/null || echo "")
      if echo "$exe" | grep -qE '(systemd|dbus|sshd|login|agetty)'; then
        continue
      fi
      log "SUSPECTED_REVERSE_SHELL: pid=$pid exe=$exe cmd=$cmdline sockets=$socket_fds"
      REVERSE_SHELL_COUNT=$((REVERSE_SHELL_COUNT + 1))
    fi
  fi
done

# 1.2 检测 /dev/shm 下执行文件（常见反向 Shell 落地点）
dev_shm_bins=$(find /dev/shm -type f -executable 2>/dev/null | head -5)
if [ -n "$dev_shm_bins" ]; then
  log "SUSPECTED_MALWARE_IN_DEV_SHM: $dev_shm_bins"
  REVERSE_SHELL_COUNT=$((REVERSE_SHELL_COUNT + 1))
fi

# 1.3 检测 /tmp 下从内存执行的进程
tmp_execs=$(find /tmp -type f -executable 2>/dev/null | head -5)
if [ -n "$tmp_execs" ]; then
  log "SUSPECTED_EXEC_IN_TMP: $tmp_execs"
fi

# ========== 2. Rootkit 特征检测 ==========
log "检测 Rootkit 特征..."

# 2.1 检测异常的 LKM（内核模块）
SUSPICIOUS_MODULES="sae|kbeaver|mod_rootme|enyelkm|knark|adore|sebek|kernsock"
loaded_modules=$(lsmod 2>/dev/null | awk '{print $1}' | tail -n +2)
for mod in $loaded_modules; do
  if echo "$mod" | grep -qiE "$SUSPICIOUS_MODULES"; then
    log "SUSPECTED_ROOTKIT_MODULE: $mod"
    ROOTKIT_COUNT=$((ROOTKIT_COUNT + 1))
  fi
done

# 2.2 检测隐藏进程（对比 /proc 和 ps）
proc_count=$(ls /proc | grep -E '^[0-9]+$' | wc -l)
ps_count=$(ps -e --no-headers | wc -l)
if [ "$proc_count" -ne "$ps_count" ]; then
  log "HIDDEN_PROCESS_DETECTED: proc=$proc_count ps=$ps_count (差异=$((proc_count - ps_count)))"
  ROOTKIT_COUNT=$((ROOTKIT_COUNT + 1))
fi

# 2.3 检测异常的 SUID 二进制（对比基线）
SUID_BASELINE="/var/log/suid_sgid_baseline.txt"
if [ -f "$SUID_BASELINE" ]; then
  current_suid=$(find / -perm -4000 -type f 2>/dev/null | sort)
  baseline_suid=$(cat "$SUID_BASELINE")
  new_suid=$(diff <(echo "$baseline_suid") <(echo "$current_suid") | grep '^>' | head -10)
  if [ -n "$new_suid" ]; then
    log "NEW_SUID_FILES_DETECTED:"
    echo "$new_suid" | sed 's/^/  /' >> "$LOG_FILE"
    ROOTKIT_COUNT=$((ROOTKIT_COUNT + 1))
    send_alert "发现新增 SUID 文件:\n$new_suid"
  fi
else
  # 首次运行，建立基线
  find / -perm -4000 -type f 2>/dev/null | sort > "$SUID_BASELINE"
  log "SUID 基线已建立"
fi

# 2.4 检测异常的网络接口（混杂模式可能被嗅探）
if ip link show 2>/dev/null | grep -q PROMISC; then
  log "INTERFACE_IN_PROMISCUOUS_MODE"
  ROOTKIT_COUNT=$((ROOTKIT_COUNT + 1))
fi

# 2.5 检测 /etc/ld.so.preload（LD_PRELOAD rootkit 常用）
if [ -f /etc/ld.so.preload ]; then
  preload_content=$(cat /etc/ld.so.preload)
  if [ -n "$preload_content" ]; then
    log "LD_PRELOAD_ROOTKIT_SUSPECTED: /etc/ld.so.preload = $preload_content"
    ROOTKIT_COUNT=$((ROOTKIT_COUNT + 1))
    send_alert "/etc/ld.so.preload 被篡改: $preload_content"
  fi
fi

# ========== 3. 异常进程检测 ==========
log "检测异常进程..."

# 3.1 检测已知挖矿进程
MINING_PROCS="xmrig|minerd|kdevtmpfsi|kinsing|cnrig|ethminer|minexmr|crypto-pool|stratum"
for proc in $MINING_PROCS; do
  if pgrep -f "$proc" >/dev/null 2>&1; then
    pid=$(pgrep -f "$proc" | head -1)
    log "MINING_PROCESS_DETECTED: proc=$proc pid=$pid"
    ANOMALY_PROC_COUNT=$((ANOMALY_PROC_COUNT + 1))
    send_alert "检测到挖矿进程: $proc (pid=$pid)"
  fi
done

# 3.2 检测从 /tmp 或 /dev/shm 运行的进程
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  exe=$(readlink /proc/$pid/exe 2>/dev/null || echo "")
  if echo "$exe" | grep -qE '^(/tmp|/dev/shm|/var/tmp)'; then
    log "SUSPECTED_MALWARE_PROCESS: pid=$pid exe=$exe"
    ANOMALY_PROC_COUNT=$((ANOMALY_PROC_COUNT + 1))
  fi
done

# 3.3 检测已删除但仍在运行的进程（常见 rootkit 手法）
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  exe=$(readlink /proc/$pid/exe 2>/dev/null || echo "")
  if echo "$exe" | grep -q '(deleted)'; then
    cmdline=$(cat /proc/$pid/cmdline 2>/dev/null | tr '\0' ' ')
    # 排除已知正常情况（如更新中的进程）
    if ! echo "$cmdline" | grep -qE '(apt|yum|dnf|package|update)'; then
      log "DELETED_BINARY_RUNNING: pid=$pid exe=$exe cmd=$cmdline"
      ANOMALY_PROC_COUNT=$((ANOMALY_PROC_COUNT + 1))
    fi
  fi
done

# ========== 4. 持久化后门检测 ==========
log "检测持久化后门..."

# 4.1 检测异常 crontab
for user in $(awk -F: '$3>=1000 {print $1}' /etc/passwd) root; do
  crontab_content=$(crontab -u "$user" -l 2>/dev/null || true)
  if [ -n "$crontab_content" ]; then
    # 检测可疑的 crontab 条目
    if echo "$crontab_content" | grep -qiE '(curl|wget|nc |ncat|bash -i|python -c|perl -e|/dev/tcp)'; then
      log "SUSPICIOUS_CRONTAB: user=$user content=$(echo "$crontab_content" | tr '\n' ';')"
      PERSISTENCE_COUNT=$((PERSISTENCE_COUNT + 1))
    fi
  fi
done

# 4.2 检测异常的系统 cron 文件
system_crons=$(find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly -type f 2>/dev/null)
for cron_file in $system_crons; do
  if grep -qiE '(curl|wget|nc |ncat|bash -i|python -c|perl -e|/dev/tcp|base64 -d)' "$cron_file" 2>/dev/null; then
    log "SUSPICIOUS_SYSTEM_CRON: file=$cron_file"
    PERSISTENCE_COUNT=$((PERSISTENCE_COUNT + 1))
    send_alert "检测到可疑系统 cron 文件: $cron_file"
  fi
done

# 4.3 检测异常 SSH authorized_keys
for home_dir in /root /home/*; do
  user=$(basename "$home_dir")
  auth_keys="$home_dir/.ssh/authorized_keys"
  if [ -f "$auth_keys" ]; then
    key_count=$(grep -c '^ssh-' "$auth_keys" 2>/dev/null || echo 0)
    if [ "$key_count" -gt 5 ]; then
      log "MANY_SSH_KEYS: user=$user count=$key_count"
      PERSISTENCE_COUNT=$((PERSISTENCE_COUNT + 1))
    fi
    # 检测最近 24 小时内新增的密钥
    recent_keys=$(find "$auth_keys" -mtime -1 2>/dev/null)
    if [ -n "$recent_keys" ]; then
      log "RECENT_SSH_KEY_ADDED: user=$user"
      PERSISTENCE_COUNT=$((PERSISTENCE_COUNT + 1))
    fi
  fi
done

# 4.4 检测异常 systemd 服务
for svc in $(systemctl list-unit-files --type=service --state=enabled 2>/dev/null | awk '{print $1}'); do
  svc_file=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2)
  if [ -n "$svc_file" ] && [ -f "$svc_file" ]; then
    if grep -qiE '(curl|wget|nc |ncat|bash -i|python -c|/dev/tcp|base64)' "$svc_file" 2>/dev/null; then
      log "SUSPICIOUS_SYSTEMD_SERVICE: svc=$svc file=$svc_file"
      PERSISTENCE_COUNT=$((PERSISTENCE_COUNT + 1))
    fi
  fi
done

# 4.5 检测异常 .bashrc/.profile 后门
for rc_file in /root/.bashrc /root/.profile /root/.bash_profile /home/*/.bashrc /home/*/.profile; do
  if [ -f "$rc_file" ]; then
    if grep -qiE '(nc |ncat|bash -i >&|/dev/tcp|python -c|perl -e|base64 -d|curl.*\|.*sh|wget.*\|.*sh)' "$rc_file" 2>/dev/null; then
      log "SUSPICIOUS_RC_FILE: file=$rc_file"
      PERSISTENCE_COUNT=$((PERSISTENCE_COUNT + 1))
      send_alert "检测到可疑 shell 配置文件后门: $rc_file"
    fi
  fi
done

# ========== 5. 异常用户检测 ==========
log "检测异常用户..."

# 5.1 检测 UID=0 的非 root 用户
uid_zero=$(awk -F: '$3==0 && $1!="root" {print $1}' /etc/passwd)
if [ -n "$uid_zero" ]; then
  log "ANOMALY_UID_ZERO_USER: $uid_zero"
  ANOMALY_USER_COUNT=$((ANOMALY_USER_COUNT + 1))
  send_alert "检测到 UID=0 的非 root 用户: $uid_zero"
fi

# 5.2 检测空密码用户
empty_pass=$(awk -F: '($2=="!" || $2=="*" || $2=="") {print $1}' /etc/shadow 2>/dev/null | head -10)
if [ -n "$empty_pass" ]; then
  log "EMPTY_PASSWORD_USERS: $empty_pass"
  ANOMALY_USER_COUNT=$((ANOMALY_USER_COUNT + 1))
fi

# 5.3 检测最近 24 小时新增用户
recent_users=$(awk -F: '{print $1}' /etc/passwd | while read -r user; do
  if id "$user" >/dev/null 2>&1; then
    home_dir=$(eval echo "~$user" 2>/dev/null)
    if [ -d "$home_dir" ]; then
      created=$(stat -c %Y "$home_dir" 2>/dev/null || echo 0)
      now=$(date +%s)
      age=$(( (now - created) / 86400 ))
      if [ "$age" -lt 1 ]; then
        echo "$user"
      fi
    fi
  fi
done)
if [ -n "$recent_users" ]; then
  log "RECENT_NEW_USERS: $recent_users"
  ANOMALY_USER_COUNT=$((ANOMALY_USER_COUNT + 1))
  send_alert "最近24小时新增用户: $recent_users"
fi

# 5.4 检测 sudoers 中的异常配置
if [ -d /etc/sudoers.d ]; then
  for sudo_file in /etc/sudoers.d/*; do
    if [ -f "$sudo_file" ]; then
      # 检测 NOPASSWD 且 ALL 权限
      if grep -qiE 'NOPASSWD.*ALL' "$sudo_file" 2>/dev/null; then
        user=$(basename "$sudo_file")
        log "SUDO_NOPASSWD_ALL: file=$sudo_file"
        ANOMALY_USER_COUNT=$((ANOMALY_USER_COUNT + 1))
      fi
    fi
  done
fi

# ========== 写入指标 ==========
TOTAL=$((REVERSE_SHELL_COUNT + ROOTKIT_COUNT + ANOMALY_PROC_COUNT + PERSISTENCE_COUNT + ANOMALY_USER_COUNT))

echo "intrusion_detection_reverse_shell $REVERSE_SHELL_COUNT" >> "$METRICS_FILE"
echo "intrusion_detection_rootkit $ROOTKIT_COUNT" >> "$METRICS_FILE"
echo "intrusion_detection_anomaly_process $ANOMALY_PROC_COUNT" >> "$METRICS_FILE"
echo "intrusion_detection_persistence $PERSISTENCE_COUNT" >> "$METRICS_FILE"
echo "intrusion_detection_anomaly_user $ANOMALY_USER_COUNT" >> "$METRICS_FILE"
echo "intrusion_detection_last_success_timestamp $(date +%s)" >> "$METRICS_FILE"

log "===== 入侵检测完成 ====="
log "反向Shell: $REVERSE_SHELL_COUNT  Rootkit: $ROOTKIT_COUNT  异常进程: $ANOMALY_PROC_COUNT  持久化后门: $PERSISTENCE_COUNT  异常用户: $ANOMALY_USER_COUNT  总计: $TOTAL"

# 如果有严重发现，发送汇总告警
if [ "$TOTAL" -gt 0 ]; then
  send_alert "入侵检测发现异常: 反向Shell=$REVERSE_SHELL_COUNT Rootkit=$ROOTKIT_COUNT 异常进程=$ANOMALY_PROC_COUNT 持久化后门=$PERSISTENCE_COUNT 异常用户=$ANOMALY_USER_COUNT"
  exit 1
fi

exit 0
