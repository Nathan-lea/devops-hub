# 自研 Skill 社区贡献指南

> **文档编号**：17
> **目标**：指导将本仓库 `skills/` 目录下的 6 个自研运维 skill 贡献到开源社区，
> 使更多团队受益，同时建立 skill 的持续维护机制。

---

## 一、为什么要贡献

| 维度 | 不贡献（仅自用） | 贡献到社区 |
|------|----------------|-----------|
| 受益范围 | 仅本项目 | 全网 SRE/Ops 团队 |
| 质量提升 | 单一场景验证 | 多场景反馈驱动迭代 |
| 维护负担 | 独力维护 | 社区 PR 协同维护 |
| 行业影响力 | 无 | 建立团队/个人技术品牌 |
| 缺口闭环 | 自补但不可复用 | 缺口永久填补，惠及生态 |

本仓库 `docs/14` 第 9.4 节识别出 7 项运维垂直缺口，第 9.8.5 节自研了 6 个 skill。
**自用只是第一步，贡献才能让缺口永久闭环。**

---

## 二、四大贡献渠道

### 渠道总览

| 渠道 | 仓库 | 适合的 skill | 门槛 | 影响力 |
|------|------|-------------|------|--------|
| **A. skills.sh 生态** | `npx skills` 包管理器 | 全部 6 个 | 中（需独立仓库+格式适配） | ★★★★★ |
| **B. awesome-codex-skills** | [ComposioHQ/awesome-codex-skills](https://github.com/ComposioHQ/awesome-codex-skills) | 全部 6 个 | 低（提 PR 加入清单） | ★★★★☆ |
| **C. devops-sre-skills** | [bregman-arie/devops-sre-skills](https://github.com/bregman-arie/devops-sre-skills) | 偏 SRE 的 4 个 | 中（需符合其模板规范） | ★★★★★ |
| **D. 独立仓库** | 自建 GitHub 仓库 | 全部 6 个集合 | 低 | ★★★☆☆ |

### 各 skill 最佳贡献渠道

| Skill | 首选渠道 | 理由 |
|-------|---------|------|
| `prometheus-rules-lint` | A + B | 通用监控工具链，受众广 |
| `tidb-br-backup` | A + B | TiDB 生态，skills.sh 有分发渠道 |
| `wazuh-rule-tuning` | A + B + C | 安全 SRE 域，devops-sre-skills 有 security 分类 |
| `mysql-xtrabackup-verify` | A + B + C | 数据库 SRE 域，devops-sre-skills 有数据库分类 |
| `pg-backup-verify` | A + B + C | 同上 |
| `migration-verify` | A + B | 迁移校验较特殊，skills.sh 独立分发更灵活 |

> **推荐策略**：先建独立仓库（渠道 D），再通过 skills.sh 发布（渠道 A），
> 然后向 awesome-codex-skills 提 PR 收录（渠道 B），最后向 devops-sre-skills
> 提 PR 贡献 SRE 类 skill（渠道 C）。

---

## 三、贡献前置准备（关键！）

### 3.1 问题：当前 skill 含项目特定引用

当前 `skills/` 下的 SKILL.md 大量引用本仓库内部路径：

```
scripts/tidb_backup.sh          →  社区用户没有这个文件
configs/rules/security.yml      →  社区用户没有这个配置
docs/07-备份与容灾方案.md        →  社区用户没有这篇文档
playbooks/02-mysql-maintenance  →  社区用户没有这个 Playbook
```

**贡献前必须泛化**：将项目特定引用改为通用描述 + 可选参数。

### 3.2 泛化清单

| 当前写法 | 泛化为 |
|---------|--------|
| `校验本仓库 configs/rules/*.yml` | `校验指定目录下的 Prometheus 告警规则文件` |
| `复用 scripts/tidb_backup.sh` | `可配合任何 BR 备份脚本使用，附带参考脚本` |
| `bash scripts/mysql_full_backup.sh` | `bash <your-backup-script.sh>` |
| `docs/07-备份与容灾方案.md` | `（移除项目内部文档引用）` |
| `playbooks/02-mysql-maintenance.yml` | `（移除或改为通用 Ansible 示例）` |
| `configs/customer-profiles/` | `（移除多客户特定配置引用）` |

### 3.3 泛化操作步骤

```bash
# 1. 创建贡献专用副本（不修改仓库原文件）
mkdir -p /tmp/devops-skills-contrib
cp -r skills/ /tmp/devops-skills-contrib/

# 2. 逐个 skill 泛化
cd /tmp/devops-skills-contrib

# 3. 替换项目特定路径为通用占位符
#    - scripts/xxx.sh  ->  <your-script-path>
#    - configs/rules/  ->  <your-rules-dir>
#    - docs/0X-xxx.md  ->  移除或改为通用说明
#    - playbooks/xxx   ->  移除或改为通用示例

# 4. 移除"与本仓库的关系"章节（项目特定）
# 5. 保留核心：适用场景/前置条件/步骤/验证/回滚/异常处理
# 6. 为每个 skill 补充独立的 README.md
```

### 3.4 必须添加的文件

```
devops-skills/                      # 独立仓库名
├── LICENSE                         # MIT 许可证
├── README.md                       # 仓库说明
├── CONTRIBUTING.md                 # 贡献者指南
├── prometheus-rules-lint/
│   ├── SKILL.md
│   └── README.md                   # 单 skill 说明
├── tidb-br-backup/
│   ├── SKILL.md
│   └── README.md
├── wazuh-rule-tuning/
│   ├── SKILL.md
│   └── README.md
├── mysql-xtrabackup-verify/
│   ├── SKILL.md
│   └── README.md
├── pg-backup-verify/
│   ├── SKILL.md
│   └── README.md
└── migration-verify/
    ├── SKILL.md
    └── README.md
```

---

## 四、渠道 A：通过 skills.sh 发布

### 4.1 什么是 skills.sh

[skills.sh](https://skills.sh/) 是开源 agent skills 生态的包管理器，通过 `npx skills`
安装/发现/更新 skill。已安装的 `find-skills` skill 就是基于此生态。

### 4.2 发布步骤

```bash
# 步骤 1 - 创建独立 GitHub 仓库
#   仓库名建议: devops-sre-skills 或 ops-verify-skills
#   在 GitHub 上创建空仓库后:
cd /tmp/devops-skills-contrib
git init
git add -A
git commit -m "feat: 6 个运维 SRE skill 初始版本"
git remote add origin https://github.com/<your-org>/devops-sre-skills.git
git push -u origin main

# 步骤 2 - 初始化 skills.sh 元数据
npx skills init
# 这会在仓库根目录生成 skills.json 或 .skills/ 配置

# 步骤 3 - 验证 skill 格式
npx skills validate ./prometheus-rules-lint
npx skills validate ./tidb-br-backup
# ... 逐个验证

# 步骤 4 - 发布到 skills.sh
npx skills publish
# 或通过 GitHub 仓库自动注册（skills.sh 会扫描仓库）

# 步骤 5 - 验证可被搜索到
npx skills find "prometheus rules"
npx skills find "tidb backup"
npx skills find "migration verify"
```

### 4.3 用户安装方式

```bash
# 社区用户安装
npx skills add <your-org>/devops-sre-skills@prometheus-rules-lint
npx skills add <your-org>/devops-sre-skills@tidb-br-backup
# 或一次安装全部
npx skills add <your-org>/devops-sre-skills -g -y
```

---

## 五、渠道 B：向 awesome-codex-skills 提 PR

### 5.1 操作步骤

```bash
# 步骤 1 - Fork 仓库
#   在 GitHub 上 Fork ComposioHQ/awesome-codex-skills
git clone https://github.com/<your-fork>/awesome-codex-skills.git
cd awesome-codex-skills

# 步骤 2 - 创建分支
git checkout -b add-devops-sre-skills

# 步骤 3 - 添加 skill 目录
#   将泛化后的 skill 目录复制到仓库中
cp -r /tmp/devops-skills-contrib/prometheus-rules-lint ./
cp -r /tmp/devops-skills-contrib/tidb-br-backup ./
# ... 其他 4 个

# 步骤 4 - 更新 README 清单
#   在 README.md 的 skill 列表中添加条目

# 步骤 5 - 提交 PR
git add -A
git commit -m "feat: 新增 6 个运维 SRE skill (prometheus-rules-lint, tidb-br-backup, ...)"
git push origin add-devops-sre-skills
# 在 GitHub 上创建 PR，描述中列出 6 个 skill 及其用途
```

### 5.2 PR 描述模板

```markdown
## 新增 6 个运维 SRE Skill

### 背景
devops-hub 项目识别出运维 SRE 垂直域无已安装 skill 的缺口（监控/数据库/安全/备份/迁移），
自研了 6 个 skill 填补，现贡献回社区。

### Skill 清单
| Skill | 用途 | safety |
|-------|------|--------|
| prometheus-rules-lint | Prometheus 告警规则校验 | read-only |
| tidb-br-backup | TiDB BR 备份与恢复 | destructive-if-restore |
| wazuh-rule-tuning | Wazuh/Suricata 规则调优 | read-only-tuning |
| mysql-xtrabackup-verify | MySQL xtrabackup 备份验证 | read-only-verify |
| pg-backup-verify | PostgreSQL 备份验证 | read-only-verify |
| migration-verify | 迁移数据一致性校验 | read-only-verify |

### 规范
- 每个 skill 含 YAML frontmatter（name/description/tools_allowed/safety）
- 正文含：适用场景/前置条件/编号步骤/验证/回滚指引/异常处理
- 无真实密钥，所有 IP/密码均为占位符
- 已泛化，不依赖特定项目结构

### 验证
- [x] YAML frontmatter 可被 yaml.safe_load 解析
- [x] 每个 skill 含回滚指引
- [x] 无真实凭据/IP
```

---

## 六、渠道 C：向 devops-sre-skills 提 PR

### 6.1 为什么选这个仓库

`bregman-arie/devops-sre-skills` 是最契合的仓库（见 `docs/14` 第 9.8.2 节）：
- 设计理念一致（Safe by default、No secrets、含验证与回滚）
- 分类覆盖核心域（observability/kubernetes/security/incident/cost）
- 格式标准（YAML frontmatter + Markdown 步骤）
- 作者权威（Arie Bregman，知名 SRE）

### 6.2 操作步骤

```bash
# 步骤 1 - Fork 仓库
git clone https://github.com/<your-fork>/devops-sre-skills.git
cd devops-sre-skills

# 步骤 2 - 研究其 skill 模板
cat skills/_template/SKILL.md    # 了解其 frontmatter 规范
ls skills/                        # 了解分类结构

# 步骤 3 - 适配格式
#   确认 frontmatter 字段名与其规范一致
#   确认 safety 字段值在其已有枚举范围内
#   确认正文结构与其 _template 一致

# 步骤 4 - 添加 skill 到对应分类
#   prometheus-rules-lint -> skills/observability/prometheus-rules-lint/
#   mysql-xtrabackup-verify -> skills/database/mysql-xtrabackup-verify/
#   pg-backup-verify -> skills/database/pg-backup-verify/
#   wazuh-rule-tuning -> skills/security/wazuh-rule-tuning/

git checkout -b add-ops-verify-skills
# 复制适配后的 skill 目录
# 更新 README 分类清单

# 步骤 5 - 提交 PR
git add -A
git commit -m "feat: add prometheus-rules-lint, mysql/pg backup verify, wazuh tuning"
git push origin add-ops-verify-skills
```

### 6.3 注意事项

- devops-sre-skills 可能没有 `database` 分类，需先在 Issue 中提议新增分类
- 建议先提 Issue 讨论，获得维护者认可后再提 PR
- 每个 skill 建议单独提 PR，便于 review

---

## 七、渠道 D：建立独立仓库

### 7.1 仓库初始化

```bash
# 步骤 1 - 创建仓库
mkdir devops-sre-skills && cd devops-sre-skills
git init

# 步骤 2 - 创建目录结构
mkdir -p prometheus-rules-lint tidb-br-backup wazuh-rule-tuning \
         mysql-xtrabackup-verify pg-backup-verify migration-verify

# 步骤 3 - 复制泛化后的 skill
cp /tmp/devops-skills-contrib/*/SKILL.md ./*/

# 步骤 4 - 创建 LICENSE (MIT)
cat > LICENSE << 'LICEOF'
MIT License

Copyright (c) 2026 <your-name>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
LICEOF

# 步骤 5 - 创建 README.md
# 步骤 6 - 创建 CONTRIBUTING.md
# 步骤 7 - 提交并推送到 GitHub
```

### 7.2 仓库 README.md 模板

```markdown
# DevOps SRE Skills

> 6 个运维 SRE 垂直域 skill，填补监控/数据库/安全/备份/迁移缺口。
> 每个 skill 遵循 devops-sre-skills 规范，含 safety 契约与回滚指引。

## Skills

| Skill | 用途 | safety |
|-------|------|--------|
| prometheus-rules-lint | Prometheus 告警规则校验 | read-only |
| tidb-br-backup | TiDB BR 备份与恢复 | destructive-if-restore |
| wazuh-rule-tuning | Wazuh/Suricata 规则调优 | read-only-tuning |
| mysql-xtrabackup-verify | MySQL 备份验证 | read-only-verify |
| pg-backup-verify | PostgreSQL 备份验证 | read-only-verify |
| migration-verify | 迁移数据一致性校验 | read-only-verify |

## 安装

### Codex / Claude (agent skills)
\`\`\`bash
git clone https://github.com/<org>/devops-sre-skills.git
for s in prometheus-rules-lint tidb-br-backup wazuh-rule-tuning \
         mysql-xtrabackup-verify pg-backup-verify migration-verify; do
  ln -sf "$(pwd)/$s" ~/.agents/skills/$s
done
\`\`\`

### skills.sh
\`\`\`bash
npx skills add <org>/devops-sre-skills -g -y
\`\`\`

## License
MIT
```

---

## 八、贡献前检查清单

```
提交前逐项确认：

[ ] 泛化完成
    [ ] 移除了所有项目特定路径引用（scripts/、configs/、docs/、playbooks/）
    [ ] 移除了"与本仓库的关系"章节
    [ ] 命令示例使用通用占位符（<your-path>）
    [ ] 不依赖特定项目目录结构即可独立使用

[ ] 安全检查
    [ ] 无真实 IP 地址（全部为 10.0.x.x 或 <your-ip> 占位符）
    [ ] 无真实密码/密钥（全部为环境变量或 <ChangeMe> 占位符）
    [ ] 无真实邮箱地址
    [ ] 无内部业务信息

[ ] 格式规范
    [ ] YAML frontmatter 含 name/description/tools_allowed/safety 四字段
    [ ] name 与目录名一致
    [ ] 正文含：适用场景/前置条件/步骤/验证/回滚指引/异常处理
    [ ] YAML frontmatter 可被 yaml.safe_load 解析

[ ] 法律文件
    [ ] LICENSE 文件已添加（推荐 MIT）
    [ ] 无第三方版权代码（或已获得授权）

[ ] 文档
    [ ] 仓库 README.md 含 skill 清单与安装方式
    [ ] CONTRIBUTING.md 含贡献规范
    [ ] 每个 skill 有独立 README.md（可选但推荐）

[ ] 测试
    [ ] 在干净环境中（无本项目）测试 skill 可独立运行
    [ ] safety 契约与实际行为一致
```

---

## 九、贡献后的维护

### 9.1 双向同步策略

```
本仓库 skills/（项目自用版）          社区仓库（泛化版）
    │                                      │
    │  修复 bug / 新增功能                    │  社区反馈 / PR
    │───────────── 同步 ──────────────────────│
    │                                      │
    ▼                                      ▼
  保持项目特定引用                        保持通用化
  （可复用本项目脚本/配置）                  （独立可用）
```

- **本仓库版本**：保留项目特定引用（方便本项目使用），作为"上游开发版"
- **社区版本**：泛化后独立可用，作为"下游发布版"
- **同步规则**：本仓库 skill 修复 bug 或新增功能后，cherry-pick 到社区仓库（去除项目特定部分）

### 9.2 社区反馈处理

| 反馈类型 | 处理方式 |
|---------|---------|
| Bug 报告 | 在社区仓库修复，同步回本仓库 |
| 功能建议 | 评估后在本仓库开发，泛化后推送社区 |
| 社区 PR | Review 后合并到社区仓库，评估是否同步回本仓库 |
| 新 skill 建议 | 参照 `docs/14` 第 9.8.5 节流程自研后贡献 |

### 9.3 版本管理

```bash
# 社区仓库使用语义化版本
git tag v1.0.0    # 6 个 skill 初始发布
git tag v1.1.0    # 新增功能（如 prometheus-rules-lint 支持 VictoriaMetrics）
git tag v1.0.1    # Bug 修复

# skills.sh 用户可通过 npx skills update 更新
```

---

## 十、执行路线图

| 阶段 | 内容 | 预计耗时 |
|------|------|---------|
| **阶段 1** | 泛化 6 个 skill（移除项目特定引用） | 2 小时 |
| **阶段 2** | 创建独立 GitHub 仓库 + LICENSE + README | 1 小时 |
| **阶段 3** | 通过 skills.sh 发布 | 1 小时 |
| **阶段 4** | 向 awesome-codex-skills 提 PR | 1 小时 |
| **阶段 5** | 向 devops-sre-skills 提 Issue + PR | 2 小时 |
| **阶段 6** | 本仓库建立同步机制（脚本/文档） | 1 小时 |

---

## 十一、注意事项

1. **不要直接推送本仓库的 skill**：本仓库 skill 含项目内部路径，社区用户无法使用，必须先泛化。
2. **License 兼容性**：本仓库使用 MIT（见仓库根 LICENSE），社区仓库也用 MIT，兼容无冲突。
3. **不泄露客户信息**：skill 中的 IP/域名/邮箱全部是占位符，贡献前再次确认无真实信息。
4. **尊重目标仓库规范**：提 PR 前务必阅读目标仓库的 CONTRIBUTING.md，按其规范适配格式。
5. **先 Issue 后 PR**：对于 devops-sre-skills 等有维护者的仓库，建议先提 Issue 讨论再提 PR。
6. **持续维护承诺**：贡献后需定期处理社区 Issue/PR，不要"一贡献了之"。
