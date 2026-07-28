# 新人 Onboarding 指南

> 本指南由 understand-onboard skill 方法论生成，基于项目知识图谱
> (`.understand-anything/knowledge-graph.json`) 自动提取架构图层、导览路径、
> 文件地图与复杂度热点，帮助新成员快速理解 devops-hub 运维系统。

---

## 一、项目概览

| 维度 | 内容 |
|------|------|
| **项目名** | devops-hub |
| **定位** | 约 100 台多云异构 Linux 主机的全面运维系统方案 |
| **语言** | Markdown、YAML、Shell、Jinja2、INI、Conf |
| **技术框架** | Prometheus、Grafana、Loki、Ansible、Wazuh、Suricata、Docker Compose、Kubernetes |
| **规模** | 67 个文件，16 篇方案文档 + 24 个配置 + 10 个 Ansible 文件 + 12 个脚本 |
| **复杂度** | moderate（中等，主复杂度集中在安全域） |

---

## 二、架构图层（10 层）

知识图谱将项目分解为 10 个架构图层，每层职责清晰、可独立演进：

| 图层 | 节点数 | 职责 | 关键文件 |
|------|--------|------|---------|
| **方案文档层** | 18 | 定义系统设计意图与规范 | `docs/00`-`14`、`README.md`、`AGENTS.md` |
| **监控告警层** | 19 | 采集+告警规则+路由+展示 | `prometheus.yml`、`rules/*.yml`、`alertmanager.yml` |
| **日志采集层** | 2 | 日志收集与清理 | `promtail.yml`、`log_cleanup.sh` |
| **配置管理层** | 9 | Ansible IaC 纳管异构主机 | `playbooks/00-04`、`ansible.cfg`、`inventory` |
| **安全防护层** | 7 | 入侵检测+威胁情报+HIDS+K8s 安全 | `wazuh/ossec.conf`、`intrusion_detection.sh` |
| **备份容灾层** | 4 | 多层次数据库备份 | `mysql/tidb/redis/etcd_backup.sh` |
| **自动化巡检层** | 3 | 主机/数据库/K8s 日常巡检 | `daily/db/k8s_health_check.sh` |
| **工程规范层** | 5 | Git 钩子+贡献指南，质量闸门 | `hooks/pre-commit`、`AGENTS.md` |
| **部署编排层** | 1 | Docker Compose 一键部署 | `docker-compose-monitoring.yml` |
| **K8s 治理层** | 3 | 网络策略+Pod 安全+资源配额 | `k8s/network-policies.yaml` |

---

## 三、关键概念与设计决策

| 概念 | 说明 | 出处 |
|------|------|------|
| **七层分层架构** | 网络防护->IDS->存储->采集->分析->告警->主机，各层独立演进 | `docs/00` |
| **纵深防御** | 多层独立安全控制，不押注单点 | `docs/00`、`docs/11` |
| **基础设施即代码** | 全配置进 Git，Ansible 幂等，变更可追溯 | `docs/03` |
| **四大黄金信号** | 延迟/流量/错误/饱和度全覆盖告警 | `configs/rules/` |
| **3-2-1 备份** | 3 份副本/2 种介质/1 份异地 | `docs/07` |
| **MITRE ATT&CK 覆盖** | 入侵检测覆盖初始访问/持久化/横向移动等战术 | `docs/11` |
| **双层质量闸门** | 本地 Git 钩子(第一层)+Gitea 分支保护(第二层) | `docs/13` |
| **方法论六层体系** | 思想/原理/原则/方法/标准/步骤 | `docs/12` |

---

## 四、引导式导览（9 步学习路径）

按以下顺序阅读，从全局到细节，逐步建立完整认知：

| 步 | 主题 | 阅读文件 | 目标 |
|----|------|---------|------|
| 1 | **全局鸟瞰** | `docs/00`、`docs/README.md` | 理解七层架构与设计意图 |
| 2 | **方法论根基** | `docs/12` | 理解方案背后的思想/原理/原则 |
| 3 | **监控告警主线** | `prometheus.yml`、`rules/host.yml`、`rules/security.yml`、`alertmanager.yml` | 理解采集->规则->路由完整链路 |
| 4 | **安全纵深防御** | `docs/11`、`wazuh/ossec.conf`、`intrusion_detection.sh`、`04-security-monitoring.yml` | 理解七层防御与 ATT&CK 覆盖 |
| 5 | **配置管理 IaC** | `docs/03`、`inventory_example.ini`、`00-init-host.yml`、`01-system-baseline.yml` | 理解 Ansible 如何纳管异构主机 |
| 6 | **备份容灾体系** | `docs/07`、`mysql_full_backup.sh`、`tidb_backup.sh` | 理解 3-2-1 备份的脚本化实现 |
| 7 | **质量保障闸门** | `docs/13`、`hooks/pre-commit`、`hooks/pre-push` | 理解 Git 钩子如何守住质量 |
| 8 | **能力与复用** | `docs/14` | 理解技能矩阵与项目复用自检 |
| 9 | **落地路线** | `docs/10` | 理解 4 阶段 12 周如何分步落地 |

---

## 五、文件地图（按图层组织）

### 方案文档层（docs/）
| 文件 | 作用 | 复杂度 |
|------|------|--------|
| `00-总体架构与方案概览.md` | 七层架构、技术选型、导航 | ★★★★ |
| `01-监控体系方案.md` | Prometheus+Grafana 部署 | ★★★ |
| `02-日志管理方案.md` | Loki+Promtail 日志 | ★★★ |
| `03-配置管理方案.md` | Ansible IaC 实践 | ★★★★ |
| `04-数据库运维方案.md` | MySQL/TiDB/Redis 运维 | ★★★★ |
| `05-K8s运维方案.md` | 集群管理与加固 | ★★★★ |
| `06-安全合规方案.md` | 基线/漏洞/权限审计 | ★★★★ |
| `07-备份与容灾方案.md` | 3-2-1 备份与演练 | ★★★★ |
| `08-告警与应急方案.md` | 四级告警+OODA 应急 | ★★★★ |
| `09-自动化运维手册.md` | 巡检/自愈/AWX | ★★★ |
| `10-实施路线图.md` | 4 阶段 12 周计划 | ★★★ |
| `11-入侵检测与网络安全方案.md` | IDS/NIDS/威胁情报/WAF | ★★★★★ |
| `12-方法论与设计原则.md` | 六层方法论体系 | ★★★★ |
| `13-Git钩子与分支保护.md` | 钩子+分支保护+CI | ★★★ |
| `14-技能矩阵与能力评估.md` | 技能域+能力评估 | ★★★ |

### 监控告警层（configs/）
| 文件 | 作用 | 复杂度 |
|------|------|--------|
| `prometheus.yml` | 主配置，挂载全部规则与目标 | ★★★★ |
| `alertmanager.yml` | 四级路由+抑制 | ★★★ |
| `rules/security.yml` | 27 条安全告警 | ★★★★★ |
| `rules/host.yml` | 11 条主机告警 | ★★★ |
| `docker-compose-monitoring.yml` | 监控平台一键部署 | ★★★★ |

### 配置管理层（playbooks/）
| 文件 | 作用 | 复杂度 |
|------|------|--------|
| `04-security-monitoring.yml` | 安全监控部署(Wazuh+Suricata) | ★★★★★ |
| `00-init-host.yml` | 新机初始化 | ★★★★ |
| `01-system-baseline.yml` | 安全基线加固(CIS) | ★★★★ |

### 安全防护层（scripts/）
| 文件 | 作用 | 复杂度 |
|------|------|--------|
| `intrusion_detection.sh` | 反向Shell/rootkit/后门检测 | ★★★★★ |
| `network_anomaly_check.sh` | 异常出站/威胁情报/横向移动 | ★★★★★ |
| `threat_intel_update.sh` | AbuseIPDB/OTX 情报更新 | ★★★★ |

### 备份容灾层（scripts/）
| 文件 | 作用 | 复杂度 |
|------|------|--------|
| `mysql_full_backup.sh` | xtrabackup+S3+指标 | ★★★★ |
| `tidb_backup.sh` | BR+S3 | ★★★ |

---

## 六、复杂度热点（需谨慎处理）

以下文件复杂度最高，修改时需格外谨慎，建议充分理解上下文：

| 文件 | 复杂度 | 风险提示 |
|------|--------|---------|
| `docs/11-入侵检测与网络安全方案.md` | ★★★★★ | 安全方案核心，改动影响检测覆盖面 |
| `configs/rules/security.yml` | ★★★★★ | 27 条告警规则，阈值调整影响告警噪声 |
| `playbooks/04-security-monitoring.yml` | ★★★★★ | 安全组件部署，涉及 Wazuh/Suricata/fail2ban 联动 |
| `scripts/intrusion_detection.sh` | ★★★★★ | 检测逻辑核心，误报/漏报风险高 |
| `scripts/network_anomaly_check.sh` | ★★★★★ | 网络异常判定逻辑，阻断模式影响生产 |

> 修改这些文件前，务必：① 阅读对应 `docs/11`；② 在测试环境验证；
> ③ 走 PR 评审流程（见 `docs/13` 分支保护）。

---

## 七、快速上手 Checklist

新成员加入后的前三天建议：

### Day 1：环境与认知
- [ ] 克隆仓库：`git clone <仓库地址>`
- [ ] 启用 Git 钩子：`git config core.hooksPath hooks`
- [ ] 阅读 `AGENTS.md` 了解贡献规范
- [ ] 按导览第 1-2 步阅读 `docs/00`、`docs/12`

### Day 2：监控与配置
- [ ] 按导览第 3 步阅读监控告警主线
- [ ] 按导览第 5 步阅读配置管理，理解 inventory 分组
- [ ] 运行校验命令：`bash -n scripts/*.sh`、`python3 -c "import yaml..."`

### Day 3：安全与备份
- [ ] 按导览第 4 步阅读安全纵深防御
- [ ] 按导览第 6 步阅读备份容灾
- [ ] 按导览第 7 步理解质量保障闸门
- [ ] 阅读复杂度热点文件，找到可参与的改进点

---

## 八、可视化探索

本指南基于项目知识图谱生成。如需交互式可视化探索架构与组件关系：

```bash
# 启动 understand-dashboard 可视化看板
# （需安装 understand-anything 插件，见 docs/14 安装指引）
```

知识图谱文件位置：`.understand-anything/knowledge-graph.json`（67 节点/52 边/10 图层/9 步导览）

---

> **生成方式**：本文件由 understand-onboard skill 方法论生成。
> 当项目结构变化后，可重新运行 understand 更新知识图谱，再重新生成本指南。
