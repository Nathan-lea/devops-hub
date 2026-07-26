#!/bin/bash
# ============================================================
# 网络异常检测脚本
# 检测项：异常出站连接、新增监听端口、非常规端口出站
#         威胁情报匹配、连接数突增、横向移动检测
# 推送指标到 node_exporter textfile
# 部署：每台主机 cron 每 5 分钟执行
# ============================================================

set -euo pipefail

METRICS_DIR="/var/lib/node_exporter/textfile"
METRICS_FILE="$METRICS_DIR/network_anomaly.prom"
LOG_FILE="/var/log/network_anomaly_check.log"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

# 出站白名单端口（正常业务端口）
STANDARD_OUTBOUND_PORTS="22 80 443 123 3306 5432 6379 9090 9093 9100 9104 9113 9121 2379 4000 3000 3100 8428 9000"

# 出站白名单目标网段（按需调整）
WHITELIST_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.0/8"

# 已知矿池/恶意 IP 段（示例，需定期更新）
MALICIOUS_IPS=""
MALICIOUS_DOMAINS="mining pool stratum xmr monero"

# 连接基线文件
CONN_BASELINE="/var/log/network_baseline/listening_ports.baseline"
mkdir -p "$(dirname "$CONN_BASELINE")"

mkdir -p "$METRICS_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_alert() {
  local msg="$1"
  log "ALERT: $msg"
  if [ -n "$SLACK_WEBHOOK" ]; then
    curl -s -X POST "$SLACK_WEBHOOK" -H 'Content-Type: application/json' \
      -d "{\"text\":\":rotating_light: 网络异常告警 ($(hostname)): $msg\"}" >/dev/null
  fi
}

# 初始化指标
cat > "$METRICS_FILE" <<METRICS_INIT
# HELP network_anomaly_outbound_total 异常出站连接数
# TYPE network_anomaly_outbound_total gauge
# HELP network_listening_ports_new 新增监听端口数
# TYPE network_listening_ports_new gauge
# HELP network_nonstandard_outbound_total 非常规端口出站连接数
# TYPE network_nonstandard_outbound_total gauge
# HELP network_established_connections 当前活跃连接数
# TYPE network_established_connections gauge
# HELP network_time_wait_connections TIME_WAIT连接数
# TYPE network_time_wait_connections gauge
# HELP network_anomaly_last_success_timestamp 上次检测时间戳
# TYPE network_anomaly_last_success_timestamp gauge
# HELP threat_intel_match_total 威胁情报命中数
# TYPE threat_intel_match_total gauge
METRICS_INIT

ANOMALY_OUTBOUND=0
NEW_PORTS=0
NONSTANDARD_OUTBOUND=0
THREAT_INTEL_HITS=0

log "===== 网络异常检测开始 ====="

# ========== 1. 异常出站连接检测 ==========
log "检测异常出站连接..."

# 获取所有 ESTABLISHED 出站连接
ss -tnp state established 2>/dev/null | tail -n +2 | while read -r line; do
  local_addr=$(echo "$line" | awk '{print $3}')
  peer_addr=$(echo "$line" | awk '{print $4}')
  proc=$(echo "$line" | awk '{print $6}')

  # 提取目标 IP 和端口
  dest_ip=$(echo "$peer_addr" | rev | cut -d: -f2- | rev)
  dest_port=$(echo "$peer_addr" | rev | cut -d: -f1 | rev)

  # 跳过本地回环
  if echo "$dest_ip" | grep -qE '^(127\.|::1)'; then
    continue
  fi

  # 检查是否为白名单网段
  in_whitelist=false
  for net in $WHITELIST_NETS; do
    if echo "$dest_ip" | grep -qE "^${net%%/*}"; then
      in_whitelist=true
      break
    fi
  done

  # 检查端口是否为标准出站端口
  is_standard_port=false
  for port in $STANDARD_OUTBOUND_PORTS; do
    if [ "$dest_port" = "$port" ]; then
      is_standard_port=true
      break
    fi
  done

  # 非白名单网段 + 非标准端口 = 可疑
  if [ "$in_whitelist" = "false" ] && [ "$is_standard_port" = "false" ]; then
    log "ANOMALY_OUTBOUND: dest=$dest_ip:$dest_port proc=$proc"
    echo "ANOMALY"
  fi

  # 非标准出站端口（即使目标在白名单内）
  if [ "$is_standard_port" = "false" ] && [ "$in_whitelist" = "true" ]; then
    log "NONSTANDARD_OUTBOUND_PORT: dest=$dest_ip:$dest_port proc=$proc"
    echo "NONSTANDARD"
  fi
done > /tmp/network_anomaly_results_$$

ANOMALY_OUTBOUND=$(grep -c "ANOMALY" /tmp/network_anomaly_results_$$ 2>/dev/null || echo 0)
NONSTANDARD_OUTBOUND=$(grep -c "NONSTANDARD" /tmp/network_anomaly_results_$$ 2>/dev/null || echo 0)
rm -f /tmp/network_anomaly_results_$$

if [ "$ANOMALY_OUTBOUND" -gt 0 ]; then
  send_alert "发现 $ANOMALY_OUTBOUND 个异常出站连接（非白名单+非标准端口）"
fi

# ========== 2. 新增监听端口检测 ==========
log "检测新增监听端口..."

current_listening=$(ss -tlnp 2>/dev/null | tail -n +2 | awk '{print $4}' | sort -u)

if [ -f "$CONN_BASELINE" ]; then
  baseline_listening=$(cat "$CONN_BASELINE")
  new_listening=$(diff <(echo "$baseline_listening") <(echo "$current_listening") | grep '^>' | sed 's/^> //')

  if [ -n "$new_listening" ]; then
    log "NEW_LISTENING_PORTS:"
    echo "$new_listening" | sed 's/^/  /' >> "$LOG_FILE"
    NEW_PORTS=$(echo "$new_listening" | wc -l)
    send_alert "发现 $NEW_PORTS 个新增监听端口:\n$(echo "$new_listening" | head -5)"
  fi
else
  # 首次运行，建立基线
  echo "$current_listening" > "$CONN_BASELINE"
  log "监听端口基线已建立: $(echo "$current_listening" | wc -l) 个端口"
fi

# 更新基线（每次运行后更新，用于下次对比新增）
# 注意：这里只记录新增，不自动更新基线，避免基线被篡改
# 基线更新应由运维人工确认后执行

# ========== 3. 非常规端口出站连接（更细粒度） ==========
# 已在第 1 步中检测，此处统计

# ========== 4. 威胁情报匹配 ==========
log "匹配威胁情报..."

# 4.1 获取所有出站连接的目标 IP
outbound_ips=$(ss -tnp state established 2>/dev/null | tail -n +2 | \
  awk '{print $4}' | rev | cut -d: -f2- | rev | \
  grep -vE '^(127\.|10\.|172\.|192\.168\.|::1)' | sort -u)

if [ -n "$MALICIOUS_IPS" ]; then
  for ip in $outbound_ips; do
    if echo "$MALICIOUS_IPS" | grep -qw "$ip"; then
      log "THREAT_INTEL_MATCH: ip=$ip"
      THREAT_INTEL_HITS=$((THREAT_INTEL_HITS + 1))
      send_alert "威胁情报命中: 出站连接到恶意 IP $ip"
    fi
  done
fi

# 4.2 检查 DNS 查询是否匹配恶意域名
# 通过检查 /var/log/dnsmasq.log 或 systemd journal
if command -v journalctl >/dev/null 2>&1; then
  recent_dns=$(journalctl -u systemd-resolved --since "5 min ago" --no-pager 2>/dev/null | \
    grep -oP '(?<=query\[A\] )\S+' | sort -u | head -100)

  if [ -n "$recent_dns" ] && [ -n "$MALICIOUS_DOMAINS" ]; then
    for domain in $recent_dns; do
      for mal_domain in $MALICIOUS_DOMAINS; do
        if echo "$domain" | grep -qi "$mal_domain"; then
          log "MALICIOUS_DNS_QUERY: domain=$domain"
          THREAT_INTEL_HITS=$((THREAT_INTEL_HITS + 1))
          send_alert "威胁情报命中: DNS 查询恶意域名 $domain"
        fi
      done
    done
  fi
fi

# ========== 5. 连接数统计 ==========
log "统计连接数..."

established_count=$(ss -tn state established 2>/dev/null | wc -l)
time_wait_count=$(ss -tn state time-wait 2>/dev/null | wc -l)
total_outbound=$(ss -tnp state established 2>/dev/null | tail -n +2 | \
  awk '{print $4}' | grep -vE '^(127\.|::1)' | wc -l)

log "连接统计: ESTABLISHED=$established_count TIME_WAIT=$time_wait_count 出站=$total_outbound"

# 5.1 连接数突增检测（超过基线 3 倍）
CONN_HISTORY="/var/log/network_baseline/connection_history.txt"
mkdir -p "$(dirname "$CONN_HISTORY")"
echo "$(date +%s) $established_count" >> "$CONN_HISTORY"

# 保留最近 288 条记录（24小时，每 5 分钟一次）
tail -288 "$CONN_HISTORY" > "${CONN_HISTORY}.tmp" && mv "${CONN_HISTORY}.tmp" "$CONN_HISTORY"

# 计算历史平均值
if [ "$(wc -l < "$CONN_HISTORY")" -gt 10 ]; then
  avg_conn=$(awk '{sum+=$2; count++} END {if(count>0) print int(sum/count)}' "$CONN_HISTORY")
  threshold=$((avg_conn * 3))
  if [ "$established_count" -gt "$threshold" ]; then
    log "CONNECTION_SPIKE: current=$established_count avg=$avg_conn threshold=$threshold"
    send_alert "连接数突增: 当前 $established_count（平均 $avg_conn）"
  fi
fi

# ========== 6. 横向移动检测 ==========
log "检测横向移动痕迹..."

# 检测本机向内网其他主机发起的 SSH 连接（非运维跳板机）
internal_ssh=$(ss -tnp state established 2>/dev/null | \
  grep ':22 ' | \
  awk '{print $4}' | rev | cut -d: -f2- | rev | \
  grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | \
  grep -v "$(hostname -I | awk '{print $1}')" | sort -u)

if [ -n "$internal_ssh" ]; then
  # 检查是否为已知运维操作（从跳板机发起）
  my_ip=$(hostname -I | awk '{print $1}')
  for ip in $internal_ssh; do
    if [ "$ip" != "$my_ip" ]; then
      # 记录但不一定告警（可能是正常运维）
      log "INTERNAL_SSH_CONNECTION: dest=$ip (检查是否授权)"
    fi
  done
fi

# 检测本机向内网其他主机发起的端口扫描行为
# 同一目标 IP 的多端口连接
scan_targets=$(ss -tnp state established 2>/dev/null | tail -n +2 | \
  awk '{print $4}' | rev | cut -d: -f2- | rev | \
  grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | \
  grep -v "$(hostname -I | awk '{print $1}')" | sort | uniq -c | sort -rn | \
  awk '$1 > 5 {print $2}')

if [ -n "$scan_targets" ]; then
  log "POSSIBLE_INTERNAL_PORT_SCAN: targets=$scan_targets"
  send_alert "疑似内网端口扫描: 向 $scan_targets 建立了多端口连接"
fi

# ========== 7. DNS 查询异常检测 ==========
log "检测 DNS 异常..."

# 检测异常长的 DNS 查询（DNS 隧道特征）
if [ -f /var/log/dnsmasq.log ]; then
  long_queries=$(grep "query\[A\]" /var/log/dnsmasq.log 2>/dev/null | \
    awk '{print $NF}' | awk 'length > 50' | sort -u | head -10)
  if [ -n "$long_queries" ]; then
    log "SUSPECTED_DNS_TUNNELING: $(echo "$long_queries" | tr '\n' ', ')"
    send_alert "疑似 DNS 隧道: 检测到异常长域名查询"
  fi
fi

# ========== 8. 流量统计 ==========
log "统计网络流量..."

# 读取网卡流量
for iface in $(ip -o link show 2>/dev/null | awk '{print $2}' | cut -d: -f1 | grep -v lo); do
  rx_bytes=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo 0)
  tx_bytes=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo 0)
  echo "network_interface_rx_bytes{iface=\"$iface\"} $rx_bytes" >> "$METRICS_FILE"
  echo "network_interface_tx_bytes{iface=\"$iface\"} $tx_bytes" >> "$METRICS_FILE"
done

# ========== 写入指标 ==========
echo "network_anomaly_outbound_total $ANOMALY_OUTBOUND" >> "$METRICS_FILE"
echo "network_listening_ports_new $NEW_PORTS" >> "$METRICS_FILE"
echo "network_nonstandard_outbound_total $NONSTANDARD_OUTBOUND" >> "$METRICS_FILE"
echo "network_established_connections $established_count" >> "$METRICS_FILE"
echo "network_time_wait_connections $time_wait_count" >> "$METRICS_FILE"
echo "network_total_outbound_connections $total_outbound" >> "$METRICS_FILE"
echo "threat_intel_match_total $THREAT_INTEL_HITS" >> "$METRICS_FILE"
echo "network_anomaly_last_success_timestamp $(date +%s)" >> "$METRICS_FILE"

log "===== 网络异常检测完成 ====="
log "异常出站: $ANOMALY_OUTBOUND  新增端口: $NEW_PORTS  非标准端口: $NONSTANDARD_OUTBOUND  威胁情报命中: $THREAT_INTEL_HITS"
log "连接数: ESTABLISHED=$established_count TIME_WAIT=$time_wait_count"

# 汇总告警
TOTAL=$((ANOMALY_OUTBOUND + NEW_PORTS + NONSTANDARD_OUTBOUND + THREAT_INTEL_HITS))
if [ "$TOTAL" -gt 0 ]; then
  log "检测到 $TOTAL 项网络异常，请关注"
fi

exit 0
