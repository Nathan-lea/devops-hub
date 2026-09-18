# devops-hub

面向约 **100 台多云异构 Linux 主机**的服务器运维系统——方案文档、声明式配置、Ansible Playbook、运维脚本与 AI 运维 Skills 的完整集合。

覆盖：Prometheus/Grafana 监控、Loki 日志、Ansible 配置管理、MySQL/TiDB/Redis/PostgreSQL 数据库运维、K8s 集群运维、安全合规与入侵检测（Wazuh/Suricata）、备份容灾、告警应急与自动化落地。

## 文档导航

完整导航见 [docs/README.md](docs/README.md)。核心文档按编号组织：

- `docs/00-总体架构与方案概览.md` — 技术选型与分层架构
- `docs/01-09` — 监控/日志/配置管理/数据库/K8s/安全/备份/告警/自动化
- `docs/10-实施路线图.md` / `docs/11-入侵检测与网络安全方案.md` / `docs/12-方法论与设计原则.md`
- `docs/13-17` — Git 钩子与分支保护、技能矩阵、迁移索引、多客户、skill 贡献

## 目录结构

```
devops-hub/
├── docs/        # 18 篇编号文档（00 总览 → 17 skill 贡献）+ README
├── configs/     # 声明式配置：rules/、targets/、grafana/、k8s/、wazuh/、customer-profiles/
├── playbooks/   # Ansible：ansible.cfg、inventory、group_vars/、编号 *.yml、templates/
├── scripts/     # 可执行 bash 脚本（备份、巡检、入侵检测、迁移）
├── hooks/       # 本地 Git 钩子（pre-commit/pre-push，提交前自动校验）
└── skills/      # 自研运维 skills（6 个 + LICENSE + CONTRIBUTING）
```

## 快速开始

```bash
git clone <repo-url>
cd devops-hub
git config core.hooksPath hooks   # 激活提交前自动校验（语法/密钥/隐私扫描）
```

提交前校验（详见 [AGENTS.md](AGENTS.md)）：

```bash
bash -n scripts/*.sh
python3 -c "import yaml,glob;[yaml.safe_load(open(f)) for f in glob.glob('configs/**/*.y*ml',recursive=True)+glob.glob('playbooks/*.yml')]"
```

## 约定与安全

- 所有 IP（`10.0.x.x`）、域名（`example.com`）、密钥（`ChangeMe!`、`ABUSEIPDB_KEY`）均为**占位符**，部署前须替换真实值。
- 提交受 `pre-commit` / `pre-push` 钩子保护：Shell/YAML 语法、可执行权限、密钥扫描、**本机隐私信息扫描**（本机绝对路径、个人邮箱）、Playbook 语法。
- 贡献规范见 [AGENTS.md](AGENTS.md)。

## License

MIT License，见 [LICENSE](LICENSE)。