# Repository Guidelines（仓库贡献指南）

本仓库为服务器运维系统（`devops-hub`）的方案与产物集合，包含文档、声明式配置、Ansible Playbook 及 Shell 脚本，用于纳管约 100 台多云异构 Linux 主机。本文档为贡献者规范。

## 项目结构与模块组织

```
devops-hub/
├── docs/        # 18 篇编号文档（00 总览 → 12 方法论）+ README
├── configs/     # 声明式配置：rules/、targets/、grafana/、k8s/、wazuh/、customer-profiles/
├── playbooks/   # Ansible：ansible.cfg、inventory、group_vars/、编号 *.yml、templates/
├── scripts/     # 可执行 bash 脚本（备份、巡检、入侵检测、迁移）
└── skills/      # 自研运维 skills（prometheus-rules-lint 等 6 个）
```

文档按领域编号（`00-` 总览、`01-` 监控 … `12-` 方法论、`13-` Git 钩子、`14-` 技能矩阵、`16-` 多客户差异化）。新增文档须使用下一个序号，并在 `docs/README.md` 与 `00-` 导航表中登记。

## 构建、测试与本地运行命令

无编译步骤。提交前请执行校验：

```bash
bash -n scripts/*.sh                    # Shell 语法检查
python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('configs/**/*.y*ml',recursive=True)+glob.glob('playbooks/*.yml')]"
chmod +x scripts/*.sh                   # 保证脚本可执行
ansible-playbook playbooks/00-init-host.yml --syntax-check   # Playbook 语法检查
```

## 代码风格与命名约定

- **YAML**：2 空格缩进；`configs/rules/` 按域一文件（`host.yml`、`mysql.yml`、`security.yml`）。
- **Shell**：以 `#!/bin/bash` 开头，启用 `set -euo pipefail`，顶部注释块写明用途/输入/输出；命名用 `snake_case`。
- **Playbook**：编号前缀对齐路线图阶段（`00-` … `04-`）；仅使用幂等模块。
- **密钥**：禁止硬编码，使用 Ansible Vault；部署前替换占位 IP/域名/密钥。

## 测试指南

无单元测试框架。最低门槛：每个脚本 `bash -n` 通过、每个 YAML `yaml.safe_load` 通过、每个 Playbook `--syntax-check` 通过。编辑文档后须核验跨文档引用完整性。

## 提交与 Pull Request 规范

- 采用 Conventional Commits：`docs: 新增 X`、`config: 调整告警规则`、`scripts: 修复备份重试`。
- 每个 PR 只关注一件事；Playbook/配置/脚本的修改分属不同提交。
- PR 描述须列出：受影响文件、已执行的校验命令、需替换的占位值。
- 涉及监控/安全/备份逻辑的改动，须关联对应文档编号。

## 安全与配置提示

所有 IP（`10.0.x.x`）、域名（`example.com`）、密钥（`ChangeMe!`、`ABUSEIPDB_KEY`）均为占位符。禁止提交真实凭据——使用 Vault 与 `.vault_pass`。安全类脚本（`intrusion_detection.sh`、`network_anomaly_check.sh`）由 cron 调度；启用阻断模式前须复核规则阈值。

## 架构概览

分层架构与设计原则见 `docs/00-总体架构与方案概览.md`；统领全局的思想/原理/原则/方法/标准见 `docs/12-方法论与设计原则.md`（SRE、纵深防御、IaC、渐进式落地等）。
