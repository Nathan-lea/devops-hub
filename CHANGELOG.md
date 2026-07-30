# 更新日志（CHANGELOG）

> 本文件由 changelog-generator skill 方法论自动生成并人工校订。
> 依据 [Keep a Changelog](https://keepachangelog.com/zh-CN/) 规范，
> 从 Git Conventional Commits 历史转换为用户友好的发布说明。

---

## [v0.4.0] - 2026-07-30

### ✨ 新功能
- **PostgreSQL 运维体系**：补充 PG 数据库纳管内容，与 MySQL/TiDB/Redis 达到同等覆盖度。
  - **告警规则**：新增 `configs/rules/postgresql.yml`，8 条规则覆盖实例宕机、
    流复制延迟、连接数过高、事务回滚率、idle in transaction、缓冲池命中率、
    死锁、临时文件溢出（告警规则总数 68 -> 76 条）。
  - **采集目标**：新增 `configs/targets/postgresql.yml`（postgres_exporter 端口 9187）。
  - **备份脚本**：新增 `scripts/postgresql_backup.sh`，支持逻辑备份
    （pg_dumpall + pg_dump -Fc）与物理备份（pg_basebackup），含 S3 上传校验
    与 textfile 指标推送。
  - **巡检脚本**：`scripts/db_health_check.sh` 新增 PostgreSQL 巡检段，检查
    实例存活、连接数、idle in transaction、流复制状态、死锁/回滚统计、
    缓冲池命中率、数据库大小。
  - **维护 Playbook**：新增 `playbooks/02-postgresql-maintenance.yml`，涵盖
    监控/备份账号创建、逻辑备份、S3 上传、过期清理、流复制检查、WAL 归档
    检查、VACUUM 死元组分析、长事务检查、事务 ID 回卷风险检查。
  - **Inventory**：`inventory_example.ini` 新增 `[postgresql]` 主机组
    （pg-primary + 2 replica）并纳入 `prod:children`。

### 📚 文档
- **数据库运维方案**（`docs/04`）：新增"四、PostgreSQL 运维"章节
  （架构建议 / 备份策略 / WAL 归档 / VACUUM 治理 / 关键参数基线 / 告警规则表），
  后续章节顺延编号。
- 同步更新 `docs/00`、`docs/12`、`docs/14`、`docs/README.md` 中数据库清单、
  告警规则计数与技能矩阵，统一纳入 PostgreSQL。

---

## [v0.3.0] - 2026-07-28

### 📚 文档
- **新增技能矩阵与能力评估**：建立十一大技能域、五级能力评估模型（L1-L5）、
  角色技能映射、缺口建设路径与项目复用能力自检清单，使项目经验转化为
  可评估、可建设、可复用的能力资产（`docs/14`，237 行）。

---

## [v0.2.0] - 2026-07-27

### ✨ 新功能
- **Git 钩子体系**：新增版本化 `hooks/` 目录，提交前自动校验 Shell 语法、
  shellcheck、YAML 解析、脚本可执行权限、密钥泄露扫描、Playbook 语法；
  推送前复跑校验并打印推送摘要。已通过 4 场景端到端拦截测试。
- **Gitea 分支保护方案**：提供 Web 界面与 API 两种配置方式，保护 `main`
  分支（禁止直接 push/force push/删除，强制 PR 评审），并规划 CI 状态检查
  演进方向（`docs/13`，204 行）。

### 🔧 改进
- 更新 `README.md` 与总体架构导航表，登记 13 号文档。

---

## [v0.1.0] - 2026-07-27

### 🎉 首次发布

devops-hub 运维系统方案首个完整版本，针对约 100 台多云异构 Linux 主机
（Debian/Ubuntu/CentOS）的全面运维体系，涵盖 16 篇方案文档、24 个声明式
配置、10 个 Ansible 文件、12 个自动化脚本。

#### ✨ 核心功能

- **总体架构**：七层分层架构（网络防护→入侵检测→存储处理→采集→安全分析→
  展示告警→主机），统一管控多云异构主机（`docs/00`）。
- **监控体系**：Prometheus + Grafana + node_exporter，68 条告警规则覆盖
  主机/MySQL/Redis/K8s/网络/安全六域，Alertmanager 四级路由与告警收敛
  （`docs/01`、`configs/rules/`）。
- **日志管理**：Loki + Promtail 轻量日志收集（`docs/02`）。
- **配置管理**：Ansible Agentless 纳管异构主机，6 个编号 Playbook + Jinja2
  模板，基础设施即代码（`docs/03`、`playbooks/`）。
- **数据库运维**：MySQL（xtrabackup）/ TiDB（BR）/ Redis 备份与巡检
  （`docs/04`）。
- **K8s 运维**：NetworkPolicy、RBAC、Pod Security、资源 Quota、kube-bench
  基线（`docs/05`、`configs/k8s/`）。
- **安全合规**：CIS 基线、Lynis、漏洞管理、权限审计（`docs/06`）。
- **入侵检测与网络安全**：Wazuh HIDS + Suricata NIDS + Falco 容器安全 +
  fail2ban 暴力破解防护 + ModSecurity WAF + 威胁情报（AbuseIPDB/OTX），
  覆盖 MITRE ATT&CK 战术矩阵，含主机隔离与自动封禁（`docs/11`，666 行）。
- **备份容灾**：3-2-1 原则分层备份（xtrabackup/BR/Velero/rclone→MinIO/S3），
  恢复演练常态化（`docs/07`）。
- **告警应急**：四级告警分级、应急 SOP（OODA 循环）、值班机制（`docs/08`）。
- **自动化运维**：巡检/备份/安全检测脚本化，AWX 编排（`docs/09`）。
- **实施路线图**：4 阶段 12 周落地计划，每阶段含里程碑与验收（`docs/10`）。
- **方法论沉淀**：思想/原理/原则/方法/标准/步骤六层方法论体系，含落地映射
  与自检清单，供后续项目套用（`docs/12`，487 行）。

#### 🔧 工程规范
- 新增 `AGENTS.md`（中文）与 `AGENTS-en.md` 仓库贡献指南。
- 新增 `.gitignore`（忽略编辑器临时文件、Ansible retry/vault、密钥）。

---

## 版本约定

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)：
- **主版本号**：不兼容的架构变更
- **次版本号**：向后兼容的新功能/新文档
- **修订号**：问题修复与小幅调整

## 生成方式

本文件依据 `changelog-generator` skill 方法论生成：
1. 扫描 Git 提交历史（`git log`）
2. 按 Conventional Commits 分类（feat/docs/chore/fix）
3. 将技术提交转换为用户友好语言
4. 按 Keep a Changelog 规范格式化
5. 人工校订后提交
