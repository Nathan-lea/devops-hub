# 服务器运维系统方案

> 针对 100 台左右 Linux 服务器（多云异构）的全面运维方案
> 涵盖 Debian / Ubuntu / CentOS、MySQL / TiDB / Redis、K8s 集群
> 包含监控、日志、配置管理、数据库运维、K8s运维、安全合规、入侵检测、备份容灾、告警应急、自动化

## 快速导航

| 文档 | 内容 |
|------|------|
| [00-总体架构与方案概览](00-总体架构与方案概览.md) | 技术选型、架构分层、文档导航 |
| [01-监控体系方案](01-监控体系方案.md) | Prometheus + Grafana + exporter |
| [02-日志管理方案](02-日志管理方案.md) | Loki + Promtail 日志收集 |
| [03-配置管理方案](03-配置管理方案.md) | Ansible 主机分组与 Playbook |
| [04-数据库运维方案](04-数据库运维方案.md) | MySQL / TiDB / Redis 运维 |
| [05-K8s运维方案](05-K8s运维方案.md) | 集群管理、升级、故障排查 |
| [06-安全合规方案](06-安全合规方案.md) | 基线、漏洞、权限审计 |
| [07-备份与容灾方案](07-备份与容灾方案.md) | 多层次备份与恢复演练 |
| [08-告警与应急方案](08-告警与应急方案.md) | 告警规则、分级、应急 SOP |
| [09-自动化运维手册](09-自动化运维手册.md) | 巡检、批量操作、自愈脚本 |
| [10-实施路线图](10-实施路线图.md) | 分阶段落地计划 |
| **[11-入侵检测与网络安全方案](11-入侵检测与网络安全方案.md)** | **异常连接检测、网络攻击防护、Wazuh HIDS、Suricata NIDS、威胁情报、自动封禁、主机隔离** |
| [12-方法论与设计原则](12-方法论与设计原则.md) | 方法论与设计原则：思想/原理/原则/方法/标准/步骤、落地映射、项目模板复用、自检清单 |
| [13-Git钩子与分支保护](13-Git钩子与分支保护.md) | 本地 Git 钩子（pre-commit/pre-push）+ Gitea 分支保护规则、CI 状态检查 |
| [14-技能矩阵与能力评估](14-技能矩阵与能力评估.md) | 十一大技能域矩阵、五级能力评估、角色技能映射、缺口建设、复用自检 |

## 目录结构

```
devops-hub/
├── docs/                           # 方案文档（16 篇）
│   ├── 00-总体架构与方案概览.md
│   ├── 01-监控体系方案.md
│   ├── 02-日志管理方案.md
│   ├── 03-配置管理方案.md
│   ├── 04-数据库运维方案.md
│   ├── 05-K8s运维方案.md
│   ├── 06-安全合规方案.md
│   ├── 07-备份与容灾方案.md
│   ├── 08-告警与应急方案.md
│   ├── 09-自动化运维手册.md
│   ├── 10-实施路线图.md
│   ├── 11-入侵检测与网络安全方案.md
│   ├── 12-方法论与设计原则.md
│   ├── 13-Git钩子与分支保护.md
│   ├── 14-技能矩阵与能力评估.md
│   └── README.md
├── configs/                        # 配置文件
│   ├── prometheus.yml              # Prometheus 主配置
│   ├── alertmanager.yml           # 告警路由（4级 + 抑制）
│   ├── promtail.yml               # 日志采集
│   ├── blackbox.yml               # 探活配置
│   ├── docker-compose-monitoring.yml  # 监控平台一键部署
│   ├── rules/                     # 告警规则
│   │   ├── host.yml               # 主机告警
│   │   ├── mysql.yml              # MySQL 告警
│   │   ├── redis.yml              # Redis 告警
│   │   ├── k8s.yml                # K8s 告警
│   │   ├── network.yml            # 网络探活告警
│   │   └── security.yml           # 安全告警（入侵/异常连接/暴力破解/容器安全/审计）
│   ├── targets/                   # Prometheus 采集目标
│   │   ├── nodes.yml
│   │   ├── mysql.yml
│   │   ├── redis.yml
│   │   ├── nginx.yml
│   │   ├── blackbox_http.yml
│   │   ├── blackbox_tcp.yml
│   │   └── blackbox_icmp.yml
│   ├── grafana/                   # Grafana 配置
│   │   └── provisioning/
│   │       ├── datasources/
│   │       └── dashboards/
│   └── k8s/                       # K8s 策略配置
│       ├── network-policies.yaml
│       ├── resource-quotas.yaml
│       └── pod-security.yaml
├── playbooks/                     # Ansible Playbook
│   ├── ansible.cfg
│   ├── inventory_example.ini
│   ├── 00-init-host.yml           # 新机初始化
│   ├── 01-system-baseline.yml     # 安全基线加固
│   ├── 02-mysql-maintenance.yml   # MySQL 运维
│   ├── 03-k8s-node-maintenance.yml# K8s 节点维护
│   ├── 04-security-monitoring.yml # 安全监控部署（Wazuh+Suricata+fail2ban+入侵检测）
│   ├── deploy_node_exporter.yml   # 部署监控 agent
│   └── templates/
│       ├── chrony.conf.j2
│       └── wazuh-agent.conf.j2    # Wazuh Agent 配置（FIM/rootkit/主动响应）
└── scripts/                      # 自动化脚本
    ├── daily_health_check.sh      # 主机巡检
    ├── db_health_check.sh         # 数据库巡检
    ├── k8s_health_check.sh        # K8s 巡检
    ├── intrusion_detection.sh    # 入侵检测（反向Shell/rootkit/持久化后门/异常用户）
    ├── network_anomaly_check.sh   # 网络异常检测（异常出站/新增端口/威胁情报/横向移动）
    ├── threat_intel_update.sh    # 威胁情报更新（AbuseIPDB/OTX/矿池黑名单）
    ├── mysql_full_backup.sh       # MySQL 备份
    ├── redis_backup.sh            # Redis 备份
    ├── tidb_backup.sh             # TiDB 备份
    ├── etcd_backup.sh             # etcd 备份
    ├── cert_check.sh              # 证书检查
    └── log_cleanup.sh             # 日志清理
```

## 技术栈一览

| 能力 | 技术选型 |
|------|----------|
| 监控 | Prometheus + Grafana + node_exporter |
| 日志 | Loki + Promtail |
| 链路 | Tempo + OpenTelemetry |
| 配置 | Ansible + Git |
| 调度 | AWX / Semaphore |
| 备份 | xtrabackup + BR + Velero + rclone |
| 安全基线 | Lynis + Trivy + kube-bench + auditd |
| **入侵检测(HIDS)** | **Wazuh（FIM + rootkit检测 + 主动响应）** |
| **网络入侵检测(NIDS)** | **Suricata（ET规则集 + 自定义规则）** |
| **暴力破解防护** | **fail2ban（SSH/Nginx/MySQL/Redis + 递归封禁）** |
| **威胁情报** | **AbuseIPDB + AlienVault OTX + 矿池黑名单** |
| **容器安全** | **Falco + Trivy + kube-bench** |
| **Web防护** | **ModSecurity + OWASP CRS** |
| 告警 | Alertmanager + 企微/钉钉/飞书 |
| 存储 | VictoriaMetrics（长期） + MinIO（对象存储） |

## 安全检测能力覆盖

```
┌──────────────────────────────────────────────────────────┐
│                    安全运营中心 (SOC)                      │
│   Wazuh看板 │ Grafana安全看板 │ 告警通知(企微/钉钉/飞书)    │
├──────────────────────────────────────────────────────────┤
│                    安全分析与响应层                        │
│   日志关联分析 │ 威胁情报关联 │ 自动封禁 │ 应急响应SOP      │
├──────────────────────────────────────────────────────────┤
│                    入侵检测层 (IDS)                        │
│   Wazuh(HIDS) │ Suricata(NIDS) │ auditd │ fail2ban       │
│   异常连接检测 │ 暴力破解防护 │ 权限提升检测                │
├──────────────────────────────────────────────────────────┤
│                    网络防护层                              │
│   防火墙 │ 安全组 │ WAF(ModSecurity) │ DDoS防护            │
│   网络分段 │ 入站/出站管控 │ 端口最小化                    │
├──────────────────────────────────────────────────────────┤
│                    被保护主机层                            │
│   公有云 │ 私有云 │ 物理机 │ K8s │ MySQL/TiDB/Redis       │
└──────────────────────────────────────────────────────────┘
```

| 检测类型 | 检测方法 | 工具 | 响应动作 |
|----------|----------|------|----------|
| 异常出站连接 | 白名单对比 + 进程关联 | auditd + Suricata + 脚本 | 告警 + 隔离 |
| 反向 Shell | shell进程网络连接 + /dev/shm检测 | 自定义脚本 + Wazuh | 告警 + 隔离 |
| 端口扫描 | 多端口连接尝试 | Suricata + fail2ban | 封禁 IP |
| SSH 暴力破解 | 登录失败频率 | fail2ban + auditd | 自动封禁 |
| Web 暴力破解 | HTTP 401/403 频率 | Nginx日志 + Wazuh | 自动封禁 |
| SQL注入/XSS | WAF规则匹配 | ModSecurity + OWASP CRS | 拦截 + 告警 |
| C2回连 | 威胁情报匹配 | Wazuh + Suricata + 情报源 | 告警 + 隔离 |
| 挖矿木马 | 矿池域名/IP + 进程检测 | 威胁情报 + 脚本 | 清除 + 隔离 |
| 数据外泄 | 大流量非常规端口出站 | Suricata + nftables | 告警 + 阻断 |
| 横向移动 | 内网多端口连接 | Suricata + auditd | 告警 + 封禁 |
| Rootkit | LKM检测 + 隐藏进程 + SUID基线 | Wazuh rootcheck + 脚本 | 告警 + 隔离 |
| 持久化后门 | crontab/systemd/SSH密钥审计 | 自定义脚本 + Wazuh FIM | 告警 + 清除 |
| 容器逃逸 | 特权容器 + hostPath检测 | kube-bench + Falco | 告警 + 阻断 |
| 文件篡改 | 关键文件完整性监控 | Wazuh FIM | 告警 + 回滚 |
| 勒索软件 | 批量文件加密操作 | auditd + 文件监控 | 立即隔离 |

## 快速开始

1. **阅读总体方案**：从 `00-总体架构与方案概览.md` 开始
2. **部署监控平台**：参考 `configs/docker-compose-monitoring.yml`
3. **纳管主机**：配置 `playbooks/inventory_example.ini`，执行 `00-init-host.yml`
4. **安全基线**：执行 `01-system-baseline.yml` 完成全量加固
5. **部署安全监控**：执行 `04-security-monitoring.yml`（Wazuh + Suricata + fail2ban + 入侵检测脚本）
6. **配置告警**：部署 `configs/alertmanager.yml` + `configs/rules/`（含 `security.yml`）
7. **启动备份**：部署 `scripts/` 下的备份脚本到 cron
8. **启动安全检测**：部署 `intrusion_detection.sh` + `network_anomaly_check.sh` + `threat_intel_update.sh` 到 cron
9. **按路线图实施**：参考 `10-实施路线图.md` 分阶段推进
