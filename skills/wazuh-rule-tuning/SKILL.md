---
name: wazuh-rule-tuning
description: >
  Tune Wazuh HIDS and Suricata NIDS detection rules to reduce false positives
  and improve detection accuracy. Use when alert noise is too high, specific
  legitimate traffic triggers repeated alerts, or when adding custom detection
  rules for new threat patterns. Covers rule decoders, local_rules.xml,
  Suricata thresholding, fail2ban jail tuning, and Prometheus alert threshold
  adjustment. Reuses configs/rules/security.yml and docs/11.
tools_allowed:
  - bash
  - python3
  - vim
  - vi
safety: read-only-tuning
---

# Wazuh & Suricata Rule Tuning

调优入侵检测规则，降低误报率，提升检测精度。
本 skill 复用 `configs/rules/security.yml` 告警规则与 `docs/11` 方案文档。

## 适用场景

- 安全告警噪音过大，大量误报淹没真实威胁
- 特定合法流量频繁触发告警需抑制
- 新增威胁模式需自定义检测规则
- 客户差异化安全基线需调整阈值

## 前置条件

```bash
# Wazuh manager 可达
curl -s -u <WAZUH_API_USER>:<WAZUH_API_PASS> -k https://WAZUH_MANAGER:55000/agents/summary | head -5

# Suricata 规则目录
ls /etc/suricata/rules/ 2>/dev/null || echo "Suricata 规则目录不存在"

# fail2ban 状态
fail2ban-client status 2>/dev/null || echo "fail2ban 未运行"

# 本仓库安全告警规则
ls configs/rules/security.yml
```

> 所有 IP、密钥均为占位符。

## 调优流程

### 步骤 1 - 识别高频误报

```bash
# Wazuh: 统计最近 24h 告警 Top 规则
# 在 Wazuh manager 上执行：
cat /var/ossec/logs/alerts/alerts.log | \
  awk -F'rule: ' '{print $2}' | awk -F';' '{print $1}' | \
  sort | uniq -c | sort -rn | head -20

# Prometheus: 查询高频安全告警
curl -s 'http://prometheus:9090/api/v1/query?query=ALERTS{team="security"}' | \
  python3 -m json.tool | grep alertname | sort | uniq -c | sort -rn

# fail2ban: 查看 ban 统计
fail2ban-client status sshd
fail2ban-client status nginx-limit-req 2>/dev/null
```

### 步骤 2 - 抑制 Wazuh 误报

编辑 Wazuh `local_rules.xml` 添加规则覆盖：

```xml
<!-- /var/ossec/etc/rules/local_rules.xml -->

<!-- 示例: 抑制特定监控服务器对 SSH 的合法扫描告警 -->
<rule id="100100" level="0">
  <if_sid>5710, 5715</if_sid>
  <srcip>10.0.0.10|10.0.0.11</srcip>
  <description>监控服务器合法 SSH 探测，忽略</description>
</rule>

<!-- 示例: 提升特定 rootkit 检测告警级别 -->
<rule id="100101" level="15">
  <if_sid>510</if_sid>
  <match>rootkit</match>
  <description>Rootkit 检测 - 立即隔离</description>
</rule>
```

重载 Wazuh 规则：

```bash
systemctl restart wazuh-manager
# 验证规则加载
/var/ossec/bin/ossec-logtest  # 交互式测试规则
```

### 步骤 3 - 调整 Suricata 阈值

编辑 Suricata `threshold.conf`：

```bash
# /etc/suricata/threshold.conf

# 抑制内网监控探测器的端口扫描告警
threshold event_filter gen_id 1, sig_id 2002910, track by_src, count 100, seconds 60

# 对已知安全扫描器降低告警频率
threshold event_filter gen_id 1, sig_id 2100498, track by_src, ip 10.0.0.19, count 0, seconds 60
```

重载 Suricata：

```bash
suricata --build-info | grep "Rule files"
kill -USR2 $(pidof suricata)  # 规则热加载
```

### 步骤 4 - 调整 fail2ban 封禁参数

按客户 SLA 差异化调整（复用 `group_vars` 变量）：

```ini
# /etc/fail2ban/jail.local

# premium 客户：更严格
[sshd]
enabled = true
maxretry = 3
findtime = 300
bantime = 3600
# 递归封禁（3 次封禁后永久拉黑）
recidive_maxretry = 3

# basic 客户：适度放宽
[sshd]
enabled = true
maxretry = 5
findtime = 600
bantime = 1800
```

重载 fail2ban：

```bash
fail2ban-client reload
fail2ban-client status sshd
```

### 步骤 5 - 调整 Prometheus 告警阈值

编辑 `configs/rules/security.yml`，根据误报统计调整 `for` 持续时间和阈值：

```yaml
# 调整前（误报多）
- alert: SshBruteForce
  expr: increase(fail2ban_banned_total{jail="sshd"}[5m]) > 3
  labels:
    severity: major

# 调整后（提高阈值+延长观察窗口）
- alert: SshBruteForce
  expr: increase(fail2ban_banned_total{jail="sshd"}[10m]) > 10
  for: 5m
  labels:
    severity: major
```

校验并重载：

```bash
# 校验（复用 prometheus-rules-lint skill）
python3 -c "import yaml; yaml.safe_load(open('configs/rules/security.yml'))"
promtool check rules configs/rules/security.yml 2>/dev/null

# 在 Prometheus 服务器重载
curl -X POST http://prometheus:9090/-/reload
```

### 步骤 6 - 多客户差异化阈值

根据客户 Profile（`configs/customer-profiles/`）中的 `security` 配置，为不同客户设置不同阈值：

```yaml
# premium 客户 (CIS L2) - 严格阈值
# security_baseline_level: cis-l2
# 适用更低的告警阈值，更快的响应

# basic 客户 (CIS L1) - 宽松阈值
# security_baseline_level: cis-l1
# 适用更高的告警阈值，减少噪音
```

## 验证

```bash
# 1. 规则语法校验
python3 -c "import yaml; list(yaml.safe_load_all(open('configs/rules/security.yml')))"
echo "YAML 校验: $?"

# 2. 观察调优后 24h 告警量变化
# 在 Grafana 安全看板对比调优前后告警趋势

# 3. 确认关键告警未被误抑制
curl -s 'http://prometheus:9090/api/v1/query?query=ALERTS{severity="critical",team="security"}' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Critical 安全告警数: {len(d[\"data\"][\"result\"])}')"
```

## 回滚指引

- Wazuh 规则回滚：注释或删除 `local_rules.xml` 中新增的规则，`systemctl restart wazuh-manager`
- Suricata 回滚：删除 `threshold.conf` 新增行，`kill -USR2 $(pidof suricata)`
- fail2ban 回滚：恢复 `jail.local` 原值，`fail2ban-client reload`
- Prometheus 回滚：`git checkout configs/rules/security.yml && curl -X POST http://prometheus:9090/-/reload`
- **所有调优变更必须通过 Git 提交**，确保可追溯回滚

## 异常处理

| 故障 | 排查 | 处置 |
|------|------|------|
| 调优后遗漏真实攻击 | 对比调优前后告警日志 | 恢复被抑制的规则，缩小抑制范围 |
| Wazuh 规则加载失败 | `/var/ossec/logs/ossec.log` | 检查 XML 语法，修复后重启 |
| Suricata 规则加载失败 | `/var/log/suricata/suricata.log` | `suricata -T -c /etc/suricata/suricata.yaml` 测试 |
| fail2ban 封禁过激 | `fail2ban-client status` | `fail2ban-client unban <IP>` 手动解封 |

## 与本仓库的关系

| 产物 | 关系 |
|------|------|
| `configs/rules/security.yml` | 被调优的 Prometheus 安全告警规则 |
| `docs/11-入侵检测与网络安全方案.md` | 入侵检测体系设计文档 |
| `docs/06-安全合规方案.md` | 安全基线与合规要求 |
| `configs/customer-profiles/` | 多客户差异化安全基线配置 |
| `scripts/intrusion_detection.sh` | 入侵检测脚本（受规则调优影响） |
| `scripts/network_anomaly_check.sh` | 网络异常检测脚本 |
