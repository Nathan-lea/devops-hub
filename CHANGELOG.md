# 更新日志（CHANGELOG）

> 本文件由 changelog-generator skill 方法论自动生成并人工校订。
> 依据 [Keep a Changelog](https://keepachangelog.com/zh-CN/) 规范，
> 从 Git Conventional Commits 历史转换为用户友好的发布说明。

---

## [v0.6.0] - 2026-08-02

### ✨ 新功能
- **多客户差异化运维体系**：从"单一扁平环境"升级为"默认基线 + 客户 Profile 覆盖"
  模式，支持纳管多个 SLA 等级、告警渠道、安全基线、备份策略各异的客户。
  - **客户 Profile 体系**（`configs/customer-profiles/`）：以客户 Profile（YAML）为
    统一数据源，定义 8 大维度（基本信息/监控/告警/安全/备份/变更窗口/访问控制/报告），
    驱动 group_vars、Prometheus 标签、Alertmanager 路由、备份策略差异化。
  - **三层 Inventory 分组**（`playbooks/inventory_multi_customer_example.ini`）：
    第一层按客户（`customer_<id>`）-> 第二层按角色（`customer_<id>_<role>`）
    -> 第三层跨客户聚合（`role_<role>` / `<cloud>` / `<distro>`）。
  - **多客户告警路由**（`configs/alertmanager_multi_customer.yml`）：按 `customer`
    标签 matchers 分流到各自接收者，`group_by` 加入 `customer` 维度，抑制规则
    加入 `customer` 防止跨客户误抑制，3 个示例客户（premium/standard/basic）。
  - **多客户监控目标**（`configs/targets/nodes_multi_customer.yml`）：targets
    携带 `customer` 标签，告警自动继承并路由。
  - **group_vars 差异化**（`playbooks/group_vars/customer_*/vars.yml`）：3 个
    示例客户（acme-premium / globex-standard / initech-basic），覆盖监控阈值、
    安全基线、备份保留、变更窗口等差异化变量。
  - **方案文档**（`docs/16-多客户差异化运维方案.md`）：架构设计、Profile 体系、
    监控/告警/安全/备份/变更/访问控制差异化详解、4 项操作 SOP、落地步骤。

### 📐 架构改进
- 新增客户只需"一个 Profile + 一段 Inventory + 一段 Alertmanager 路由"，
  80% 配置继承全局默认值，实现低门槛纳管新客户。
- 原有单客户配置（`alertmanager.yml` / `nodes.yml`）保留不动，多客户版为
  独立文件，可验证后切换，平滑过渡无风险。

## [v0.5.0] - 2026-07-31

### ✨ 新功能
- **迁移方案 SOP 体系**（`docs/migration/`，7 篇独立 SOP 文档 + 3 个脚本）：
  将数据库迁移、K8s 跨云迁移、Web 服务器迁移拆为**独立 SOP 文档**，每次迁移
  按统一结构操作（适用场景->角色分工->编号步骤->检查清单->回滚->异常处理->记录模板），
  确保多次操作一致、可追溯、降低风险。
  - **00-迁移总则与方法论**：风险分级（P0/P1/P2）、六大阶段模型、七大铁律、
    灰度切换通用模型、SOP 统一结构。
  - **01-MySQL迁移至TiDB-SOP**：DM 全量+增量同步、sync-diff-inspector 校验、
    灰度切换（10%->50%->100%）。
  - **02-PostgreSQL迁移至TiDB-SOP**：Schema 转换（类型映射表）、CSV 导入、
    序列同步、应用层双写追平。
  - **03-数据库跨云迁移-SOP**：网络打通（专线/VPN/对等连接）、DM/CDC 同步、
    DNS 切换、TiDB BR+CDC 跨云。
  - **04-K8s跨云迁移-SOP**：GitOps 重建（无状态）+ Velero 备份恢复（有状态 PV）+
    Ingress Canary 灰度、逐服务迁移。
  - **05-Web服务器迁移-SOP**：配置/证书/资源同步、rsync 增量追平、DNS 加权灰度。
  - **06-迁移通用保障与检查清单**：迁移前检查清单（按类型）、数据一致性校验方法、
    回滚预案模板、迁移期临时告警规则。

### 🔧 新增脚本（`scripts/migration/` 独立目录）
- `pre_migration_check.sh`：迁移前环境检查（网络/磁盘/备份/连接/端口/复制延迟/
  集群状态/PV/镜像/Velero/SSL 证书），支持 db/k8s/web 三种类型。
- `migration_data_verify.sh`：迁移后数据一致性校验（MySQL 行数+CRC32、
  PG 行数+序列、文件级 rsync dry-run），支持 mysql/pg/file 三种类型。
- `migration_rollback.sh`：迁移回滚辅助（DNS 回切/同步停止/状态检查）。

### 📐 架构改进
- 迁移脚本从 `scripts/` 根目录归入独立 `scripts/migration/` 目录，与其他运维
  脚本分离，职责清晰。
- 迁移文档从单个大文件拆为 `docs/migration/` 独立 SOP 目录，每次迁移只需
  打开对应 SOP 按步骤执行打勾，大幅降低遗漏与出错风险。

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
