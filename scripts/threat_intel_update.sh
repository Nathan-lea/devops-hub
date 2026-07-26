#!/bin/bash
# ============================================================
# 威胁情报更新脚本
# 定时拉取恶意 IP/域名列表，更新到本地检测系统
# 部署在管控节点或监控服务器，每日 03:00 执行
# ============================================================

set -euo pipefail

INTEL_DIR="/var/lib/threat_intel"
LOG_FILE="/var/log/threat_intel_update.log"
METRICS_DIR="/var/lib/node_exporter/textfile"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

# 威胁情报源配置
ABUSEIPDB_KEY="${ABUSEIPDB_KEY:-}"
OTX_API_KEY="${OTX_API_KEY:-}"

mkdir -p "$INTEL_DIR" "$METRICS_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

send_alert() {
  local msg="$1"
  log "ALERT: $msg"
  if [ -n "$SLACK_WEBHOOK" ]; then
    curl -s -X POST "$SLACK_WEBHOOK" -H 'Content-Type: application/json' \
      -d "{\"text\":\":shield: 威胁情报更新: $msg\"}" >/dev/null
  fi
}

log "===== 威胁情报更新开始 ====="

MALICIOUS_IPS=""
MALICIOUS_DOMAINS=""
TOTAL_IPS=0
TOTAL_DOMAINS=0

# ========== 1. AbuseIPDB 恶意 IP ==========
if [ -n "$ABUSEIPDB_KEY" ]; then
  log "拉取 AbuseIPDB 恶意 IP 列表..."
  if curl -s -G "https://api.abuseipdb.com/api/v2/blacklist" \
    -H "Key: $ABUSEIPDB_KEY" \
    -H "Accept: application/json" \
    --data-urlencode "confidenceMinimum=90" \
    --max-time 30 \
    -o "$INTEL_DIR/abuseipdb.json" 2>/dev/null; then

    if command -v jq >/dev/null 2>&1; then
      jq -r '.data[] | .ipAddress' "$INTEL_DIR/abuseipdb.json" 2>/dev/null \
        > "$INTEL_DIR/abuseipdb_ips.txt" || true
      abuseipdb_count=$(wc -l < "$INTEL_DIR/abuseipdb_ips.txt" 2>/dev/null || echo 0)
      log "AbuseIPDB: $abuseipdb_count 条恶意 IP"
      TOTAL_IPS=$((TOTAL_IPS + abuseipdb_count))
    fi
  else
    log "WARN: AbuseIPDB 拉取失败"
  fi
fi

# ========== 2. AlienVault OTX IoC ==========
if [ -n "$OTX_API_KEY" ]; then
  log "拉取 AlienVault OTX IoC..."
  # 拉取最近活跃的 pulse
  if curl -s "https://otx.alienvault.com/api/v1/indicators/export" \
    -H "X-OTX-API-KEY: $OTX_API_KEY" \
    --max-time 30 \
    -o "$INTEL_DIR/otx_export.json" 2>/dev/null; then

    if command -v jq >/dev/null 2>&1; then
      # 提取恶意 IP
      jq -r '.results[] | select(.type=="IPv4") | .indicator' "$INTEL_DIR/otx_export.json" 2>/dev/null \
        > "$INTEL_DIR/otx_ips.txt" || true
      # 提取恶意域名
      jq -r '.results[] | select(.type=="domain") | .indicator' "$INTEL_DIR/otx_export.json" 2>/dev/null \
        > "$INTEL_DIR/otx_domains.txt" || true

      otx_ip_count=$(wc -l < "$INTEL_DIR/otx_ips.txt" 2>/dev/null || echo 0)
      otx_domain_count=$(wc -l < "$INTEL_DIR/otx_domains.txt" 2>/dev/null || echo 0)
      log "OTX: $otx_ip_count 条 IP, $otx_domain_count 条域名"
      TOTAL_IPS=$((TOTAL_IPS + otx_ip_count))
      TOTAL_DOMAINS=$((TOTAL_DOMAINS + otx_domain_count))
    fi
  else
    log "WARN: OTX 拉取失败"
  fi
fi

# ========== 3. 开源矿池黑名单 ==========
log "拉取矿池 IP/域名黑名单..."
# 使用开源矿池黑名单列表
curl -s "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wikipedia-mining.txt" \
  --max-time 15 -o "$INTEL_DIR/mining_domains.txt" 2>/dev/null || true
mining_count=$(wc -l < "$INTEL_DIR/mining_domains.txt" 2>/dev/null || echo 0)
log "矿池域名: $mining_count 条"
TOTAL_DOMAINS=$((TOTAL_DOMAINS + mining_count))

# ========== 4. 合并所有恶意 IP ==========
log "合并恶意 IP 列表..."
cat "$INTEL_DIR"/abuseipdb_ips.txt "$INTEL_DIR"/otx_ips.txt 2>/dev/null \
  | sort -u > "$INTEL_DIR/malicious_ips_all.txt"
TOTAL_MERGED_IPS=$(wc -l < "$INTEL_DIR/malicious_ips_all.txt" 2>/dev/null || echo 0)

# 合并恶意域名
cat "$INTEL_DIR"/otx_domains.txt "$INTEL_DIR"/mining_domains.txt 2>/dev/null \
  | sort -u > "$INTEL_DIR/malicious_domains_all.txt"
TOTAL_MERGED_DOMAINS=$(wc -l < "$INTEL_DIR/malicious_domains_all.txt" 2>/dev/null || echo 0)

log "合并后: $TOTAL_MERGED_IPS 条恶意 IP, $TOTAL_MERGED_DOMAINS 条恶意域名"

# ========== 5. 更新 Suricata 规则 ==========
if [ -d /etc/suricata/rules ]; then
  log "生成 Suricata 威胁情报规则..."

  # 生成 IP 黑名单规则
  > /etc/suricata/rules/threat_intel.rules
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    echo "alert ip [${ip}] any -> $HOME_NET any (msg:\"Threat Intel Match - $ip\"; classtype:trojan-activity; sid:$((9000000 + RANDOM % 1000000)); rev:1;)" \
      >> /etc/suricata/rules/threat_intel.rules
  done < "$INTEL_DIR/malicious_ips_all.txt"

  intel_rules=$(wc -l < /etc/suricata/rules/threat_intel.rules 2>/dev/null || echo 0)
  log "生成 $intel_rules 条 Suricata 规则"

  # 重载 Suricata
  if systemctl is-active --quiet suricata 2>/dev/null; then
    systemctl reload suricata 2>/dev/null || true
    log "Suricata 规则已重载"
  fi
fi

# ========== 6. 更新 Wazuh CDB（威胁情报数据库）=========
if [ -d /var/ossec ]; then
  log "更新 Wazuh 威胁情报 CDB..."
  # 转换为 Wazuh CDB 格式
  > /tmp/threat_intel_cdb.txt
  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    echo "${ip}:threat_intel:match" >> /tmp/threat_intel_cdb.txt
  done < "$INTEL_DIR/malicious_ips_all.txt"

  # 更新 CDB（需要 Wazuh 管理端权限）
  if [ -d /var/ossec/etc/list ]; then
    cp /tmp/threat_intel_cdb.txt /var/ossec/etc/list/threat_intel
    /var/ossec/bin/manage_lists -u /var/ossec/etc/list/threat_intel 2>/dev/null || true
    /var/ossec/bin/wazuh-control restart 2>/dev/null || true
    log "Wazuh 威胁情报 CDB 已更新"
  fi
  rm -f /tmp/threat_intel_cdb.txt
fi

# ========== 7. 推送监控指标 ==========
cat > "$METRICS_DIR/threat_intel.prom" <<METRICS
# HELP threat_intel_total_ips 威胁情报恶意 IP 总数
# TYPE threat_intel_total_ips gauge
threat_intel_total_ips $TOTAL_MERGED_IPS
# HELP threat_intel_total_domains 威胁情报恶意域名总数
# TYPE threat_intel_total_domains gauge
threat_intel_total_domains $TOTAL_MERGED_DOMAINS
# HELP threat_intel_last_update_timestamp 上次更新时间戳
# TYPE threat_intel_last_update_timestamp gauge
threat_intel_last_update_timestamp $(date +%s)
# HELP threat_intel_update_status 更新状态 1=成功 0=失败
# TYPE threat_intel_update_status gauge
threat_intel_update_status 1
METRICS

log "===== 威胁情报更新完成 ====="
log "总计: $TOTAL_MERGED_IPS 条 IP, $TOTAL_MERGED_DOMAINS 条域名"

if [ "$TOTAL_MERGED_IPS" -lt 100 ]; then
  send_alert "威胁情报数量异常少 ($TOTAL_MERGED_IPS 条)，请检查情报源"
fi

exit 0
