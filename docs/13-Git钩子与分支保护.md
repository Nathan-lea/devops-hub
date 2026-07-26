# Git 钩子与分支保护方案

> 本文档说明 devops-hub 仓库的本地 Git 钩子（pre-commit / pre-push）与
> Gitea 远端分支保护策略，确保所有提交在"本地 + 远端"双重把关下符合
> `AGENTS.md` 中的代码风格、语法校验与安全要求。

---

## 一、设计目标

| 目标 | 实现 |
|------|------|
| 提交前自动校验语法/权限/密钥泄露 | 本地 `pre-commit` 钩子 |
| 推送前二次守卫，防止绕过/陈旧文件 | 本地 `pre-push` 钩子 |
| 团队克隆即共享钩子，无需手工配置 | 版本化 `hooks/` 目录 + `core.hooksPath` |
| 远端强制代码评审与状态检查 | Gitea 分支保护规则 |
| 主干历史线性、可追溯 | 禁止强制推送 + 禁止删除分支 |

遵循方法论（见 `12-方法论与设计原则.md`）：
- **基础设施即代码**：钩子随仓库版本化，配置即代码；
- **纵深防御**：本地钩子是第一层，Gitea 分支保护是第二层；
- **安全左移**：密钥泄露在提交前即被拦截，而非上线后才发现。

---

## 二、本地 Git 钩子

### 2.1 目录结构与启用

钩子位于仓库内版本化目录，通过 `core.hooksPath` 激活：

```
devops-hub/
└── hooks/
    ├── pre-commit   # 提交前校验
    └── pre-push     # 推送前守卫
```

**一次性启用**（克隆仓库后执行）：

```bash
git config core.hooksPath hooks
```

> 说明：`core.hooksPath` 配置存在 `.git/config`（本地，不随仓库走）。
> 团队成员克隆后需各自执行一次上述命令。后续可改为在 `AGENTS.md` 启动
> 脚本中自动设置，或用 `core.hooksPath` 配合 `husky`/`lefthook` 类工具。

### 2.2 pre-commit 钩子

提交（`git commit`）前自动触发，对**本次暂存文件**执行以下校验：

| 序号 | 检查项 | 工具 | 失败行为 |
|------|--------|------|---------|
| 1 | Shell 脚本语法 | `bash -n` | 中止提交 |
| 2 | Shell 静态分析 | `shellcheck`（若已安装）severity≥warning | 中止提交 |
| 3 | YAML 可解析 | `python3 yaml.safe_load` | 中止提交 |
| 4 | 脚本可执行权限 | `[ -x ]` | 中止提交 |
| 5 | 密钥/凭据泄露扫描 | `grep` 正则（私钥/API Key/密码） | 中止提交 |
| 6 | Ansible Playbook 语法 | `ansible-playbook --syntax-check`（若已安装） | 中止提交 |

**密钥扫描正则**覆盖：
- PEM/OpenSSH 私钥头（`BEGIN ... PRIVATE KEY`）
- `api_key=...`、`api-key: ...` 等长 token
- `password: "..."` 等明文密码

> 占位符（如 `ChangeMe!`、`ABUSEIPDB_KEY`、`example.com`）不会被误报，
> 因为正则要求值长度 ≥20 字符或匹配私钥头格式。

**跳过钩子**（仅紧急情况，不推荐）：

```bash
git commit --no-verify -m "..."
```

### 2.3 pre-push 钩子

推送（`git push`）前自动触发，对本次推送涉及的文件**复跑 pre-commit 校验**，
并打印推送摘要（分支名、提交数、文件数），防止：

- 用 `--no-verify` 跳过本地钩子后的脏提交混入远端；
- 陈旧文件（钩子启用前提交的）带病上线。

跳过推送钩子：`git push --no-verify`

### 2.4 已验证的拦截能力

| 场景 | 预期 | 实测 |
|------|------|------|
| 合法 Shell 脚本 | 通过 | ✅ 通过 |
| 语法错误 Shell（缺括号） | 拦截 | ✅ 拦截（bash -n + shellcheck） |
| 缩进错误的 YAML | 拦截 | ✅ 拦截（yaml.safe_load） |
| 缺可执行权限脚本 | 拦截 | ✅ 拦截（权限检查） |

---

## 三、Gitea 分支保护规则

在 Gitea Web 界面配置（仓库 -> Settings -> Branches -> Branch Protection Rules），
或通过 API 配置。

### 3.1 保护 main 分支

| 配置项 | 推荐值 | 说明 |
|--------|--------|------|
| Rule name | `protect-main` | 规则名 |
| Apply to branch | `main` | 主干 |
| **Block push** | ✅ 开启 | 除非通过 PR，禁止直接 push |
| Enable push whitelist | 视情况 | 仅放行紧急维护账号（如 admin） |
| **Block merge** | ✅ 至少 1 人审批 | 强制代码评审 |
| Approval count required | `1`（核心仓库建议 `2`） | 最少审批数 |
| Block merge on rejected reviews | ✅ | 有人拒绝则不可合并 |
| Dismiss stale approvals | ✅ | 新提交后旧审批失效 |
| Require signed commits | 视情况 | 有 GPG 签名基础设施则开启 |
| **Block force push** | ✅ | 禁止 `git push --force`，保护历史 |
| **Block branch delete** | ✅ | 禁止删除 main |
| Require status checks | ✅（CI 就绪后） | 校验通过方可合并 |
| Status check list | `lint`、`syntax-check` | 接入 CI 后填写 |

### 3.2 通过 API 配置（脚本化）

```bash
# 变量（替换为实际值）
GITEA_URL="http://localhost/gitea"
OWNER="admin"
REPO="devops-hub"
TOKEN="<your_gitea_token>"   # 在 Gitea -> Settings -> Applications 生成

# 创建分支保护规则
curl -sS -X POST \
  "$GITEA_URL/api/v1/repos/$OWNER/$REPO/branch_protections" \
  -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "rule_name": "protect-main",
    "enable_push": false,
    "enable_push_whitelist": false,
    "required_approvals": 1,
    "enable_status_check": false,
    "block_on_rejected_reviews": true,
    "dismiss_stale_approvals": true,
    "block_on_official_review_requests": true,
    "can_force_push": false,
    "allow_force_pushes": false,
    "enable_merge_whitelist": true,
    "merge_whitelist_teams": [],
    "protected_branch": true
  }'
```

> 字段名随 Gitea 版本略有差异，请对照 `GET /api/v1/repos/{owner}/{repo}/branch_protections` 返回值调整。

### 3.3 查询当前保护规则

```bash
curl -sS "$GITEA_URL/api/v1/repos/$OWNER/$REPO/branch_protections" \
  -H "Authorization: token $TOKEN" | python3 -m json.tool
```

---

## 四、CI/CD 状态检查（演进方向）

当接入 CI（Gitea Actions / Drone / Jenkins）后，在分支保护中启用
"Require status checks to pass before merging"，强制以下任务通过：

| 检查任务 | 内容 | 对应本地钩子项 |
|---------|------|--------------|
| `lint` | shellcheck + YAML lint | pre-commit 1-2 |
| `syntax-check` | bash -n + yaml.safe_load + ansible --syntax-check | pre-commit 1,3,6 |
| `secret-scan` | gitleaks/truffleHog 全量扫描 | pre-commit 5 |

实现"本地钩子 + 远端 CI"纵深防御：本地钩子快速反馈，CI 兜底全量校验。

---

## 五、运维操作速查

| 需求 | 命令 |
|------|------|
| 启用钩子 | `git config core.hooksPath hooks` |
| 查看是否启用 | `git config core.hooksPath` |
| 手动运行 pre-commit | `bash hooks/pre-commit` |
| 跳过提交钩子（紧急） | `git commit --no-verify` |
| 跳过推送钩子（紧急） | `git push --no-verify` |
| 查看远端保护规则 | `curl .../branch_protections` |
| shellcheck 单文件 | `shellcheck scripts/foo.sh` |

---

## 六、与其他文档的关系

| 文档 | 关系 |
|------|------|
| `AGENTS.md` | 钩子实现 AGENTS.md 中的"测试指南""安全提示"要求 |
| `03-配置管理方案.md` | 配合 IaC 原则，钩子本身即版本化基础设施 |
| `08-告警与应急方案.md` | 钩子拦截的密钥泄露属安全事件，纳入应急 SOP |
| `12-方法论与设计原则.md` | 体现纵深防御、安全左移、IaC 原则 |

---

> **总结**：本地钩子是"第一道闸门"，Gitea 分支保护是"第二道闸门"。
> 两层协同，确保进入主干的每一行代码都经过语法、权限、密钥、评审四重把关，
> 让仓库质量从"靠自觉"升级为"靠机制"。
