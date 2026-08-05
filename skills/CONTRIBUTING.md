# 贡献指南 - 自研运维 Skills

感谢您对 devops-hub 运维 skills 的贡献！本指南帮助您规范地新增或修改 skill。

## Skill 规范

### 必须包含

1. **YAML frontmatter**（`---` 包裹）：

```yaml
---
name: <skill-name>           # 必须与目录名一致
description: >               # 一句话说明用途与触发场景
  <描述>
tools_allowed:               # 允许调用的工具白名单
  - bash
  - python3
safety: <safety-level>       # 安全契约
---
```

2. **safety 契约**（四选一）：

| 值 | 含义 |
|----|------|
| `read-only` | 纯读取/校验，不修改任何系统状态 |
| `read-only-verify` | 读取+临时验证环境，验证后自动清理 |
| `read-only-tuning` | 读取+调优建议，实际变更需人工确认 |
| `destructive-if-restore` | 恢复操作会覆盖数据，需明确警告 |

3. **正文结构**（按顺序）：

```
# Skill 标题
## 适用场景          -- 什么情况下使用
## 前置条件          -- 工具/环境/凭据检查
## 操作步骤          -- 编号步骤，含可执行命令
### 步骤 1 - xxx
### 步骤 2 - xxx
## 验证              -- 如何确认操作成功
## 回滚指引          -- 出错后如何恢复
## 异常处理          -- 常见故障表（故障/排查/处置）
```

### 禁止

- ❌ 硬编码真实 IP/密码/密钥（使用占位符或环境变量）
- ❌ 引用项目特定路径（如 `scripts/`、`configs/`，贡献社区时需泛化）
- ❌ 无回滚指引的破坏性操作
- ❌ 无 safety 契约的 skill

## 新增 Skill 流程

```bash
# 1. 创建目录
mkdir -p skills/<your-skill-name>

# 2. 编写 SKILL.md（参照上述规范）
vi skills/<your-skill-name>/SKILL.md

# 3. 校验
python3 -c "
import re, yaml
c = open('skills/<your-skill-name>/SKILL.md').read()
m = re.match(r'^---\n(.*?)\n---\n', c, re.DOTALL)
meta = yaml.safe_load(m.group(1))
assert 'name' in meta and 'safety' in meta
assert '回滚' in c or 'rollback' in c.lower()
print('校验通过')
"

# 4. 更新 skills/README.md 清单

# 5. 提交
git add -A
git commit -m "feat: 新增 <your-skill-name> skill"
```

## 贡献到社区

详见 `docs/17-自研skill社区贡献指南.md`。
