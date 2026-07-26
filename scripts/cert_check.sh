#!/bin/bash
# ============================================================
# TLS 证书有效期检查脚本
# 检查指定域名的证书过期时间
# 推送告警到 node_exporter textfile + IM
# ============================================================

set -euo pipefail

# 待检查的域名列表（从配置文件或环境变量）
DOMAINS="${CERT_DOMAINS:-api.example.com www.example.com}"
WARN_DAYS="${CERT_WARN_DAYS:-30}"
CRIT_DAYS="${CERT_CRIT_DAYS:-7}"
METRICS_DIR="/var/lib/node_exporter/textfile"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

mkdir -p "$METRICS_DIR"
METRICS_FILE="$METRICS_DIR/cert_check.prom"
> "$METRICS_FILE"

echo "# HELP cert_expiry_days 证书剩余有效天数（负值=已过期）" >> "$METRICS_FILE"
echo "# TYPE cert_expiry_days gauge" >> "$METRICS_FILE"

ALERTS=""

for domain in $DOMAINS; do
  # 获取证书
  expiry=$(echo | timeout 10 openssl s_client -servername "$domain" -connect "$domain:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)

  if [ -z "$expiry" ]; then
    echo "cert_expiry_days{domain=\"$domain\"} -1" >> "$METRICS_FILE"
    ALERTS="$ALERTS\n⚠️ $domain: 无法获取证书信息"
    continue
  fi

  expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

  echo "cert_expiry_days{domain=\"$domain\"} $days_left" >> "$METRICS_FILE"

  if [ "$days_left" -lt "$CRIT_DAYS" ]; then
    ALERTS="$ALERTS\n🔴 $domain: 证书将在 ${days_left} 天后过期（紧急！）"
  elif [ "$days_left" -lt "$WARN_DAYS" ]; then
    ALERTS="$ALERTS\n🟡 $domain: 证书将在 ${days_left} 天后过期"
  fi
done

# 发送告警
if [ -n "$ALERTS" ] && [ -n "$SLACK_WEBHOOK" ]; then
  curl -s -X POST "$SLACK_WEBHOOK" -H 'Content-Type: application/json' \
    -d "{\"text\":\":lock: 证书过期提醒:$ALERTS\"}" >/dev/null
fi

echo -e "$ALERTS"
exit 0
