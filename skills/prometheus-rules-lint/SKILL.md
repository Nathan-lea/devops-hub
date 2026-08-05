---
name: prometheus-rules-lint
description: >
  Validate Prometheus alert rule YAML files for syntax, expression correctness,
  naming conventions, and label completeness. Use when writing or modifying
  configs/rules/*.yml alert rules, before committing to Git, or when debugging
  "rule group failed to load" errors. Checks YAML parse, PromQL syntax (via
  promtool if available), alert naming, severity labels, for-durations, and
  annotation completeness.
tools_allowed:
  - bash
  - python3
  - promtool
safety: read-only
---

# Prometheus Rules Lint

校验本仓库 `configs/rules/*.yml` 告警规则文件的正确性，防止无效规则导致
Prometheus 拒绝加载或误告警。

## 适用场景

- 新增或修改告警规则后提交前
- Prometheus 日志出现 `rule group failed to load` 错误时
- CI 流水线中作为规则变更的门禁

## 前置条件

```bash
# 必需
python3 -c "import yaml; print('yaml ok')"

# 可选（有则执行 PromQL 语法检查，无则跳过）
promtool --version 2>/dev/null && echo "promtool ok" || echo "promtool 未安装，将跳过 PromQL 检查"
```

## 校验步骤

### 步骤 1 — YAML 语法校验

确保每个规则文件可被 `yaml.safe_load_all` 解析（部分文件含多文档 `---`）：

```bash
python3 -c "
import yaml, glob, sys
errors = []
for f in sorted(glob.glob('configs/rules/*.yml')):
    try:
        list(yaml.safe_load_all(open(f)))
        print(f'  [PASS] {f}')
    except Exception as e:
        errors.append(f'{f}: {e}')
        print(f'  [FAIL] {f}: {e}')
sys.exit(1 if errors else 0)
"
```

### 步骤 2 — 结构完整性校验

检查每个文件是否包含 `groups` -> `rules` 结构，每条规则是否有 `alert`/`expr`/`labels.severity`/`annotations`：

```bash
python3 -c "
import yaml, glob, sys
errors = []
for f in sorted(glob.glob('configs/rules/*.yml')):
    data = yaml.safe_load(open(f))
    if not data or 'groups' not in data:
        errors.append(f'{f}: 缺少顶层 groups 字段')
        continue
    for g in data['groups']:
        name = g.get('name', '(unnamed)')
        for r in g.get('rules', []):
            alert = r.get('alert', '')
            if not alert:
                errors.append(f'{f}/{name}: 规则缺少 alert 名称')
            if 'expr' not in r:
                errors.append(f'{f}/{name}/{alert}: 缺少 expr')
            sev = r.get('labels', {}).get('severity')
            if sev and sev not in ('critical', 'major', 'minor', 'warning', 'info'):
                errors.append(f'{f}/{name}/{alert}: severity={sev} 不在标准值内')
            ann = r.get('annotations', {})
            if 'summary' not in ann:
                errors.append(f'{f}/{name}/{alert}: 缺少 annotations.summary')
            for_dur = r.get('for')
            if for_dur is None:
                # recording rules 无 for，但 alert rules 必须有
                if alert:
                    print(f'  [WARN] {f}/{name}/{alert}: 未设置 for 持续时间')
if errors:
    for e in errors: print(f'  [FAIL] {e}')
    sys.exit(1)
print('  结构完整性校验通过')
"
```

### 步骤 3 — 告警名称规范检查

告警名称应使用 CamelCase 且全局唯一：

```bash
python3 -c "
import yaml, glob, re, sys
from collections import Counter
names = Counter()
for f in sorted(glob.glob('configs/rules/*.yml')):
    data = yaml.safe_load(open(f))
    for g in data.get('groups', []):
        for r in g.get('rules', []):
            n = r.get('alert', '')
            if n:
                names[n] += 1
                if not re.match(r'^[A-Z][a-zA-Z0-9]+$', n):
                    print(f'  [WARN] 告警名称不符合 CamelCase: {n}')
dups = {k: v for k, v in names.items() if v > 1}
if dups:
    for k, v in dups.items():
        print(f'  [FAIL] 重复告警名称: {k} (出现 {v} 次)')
    sys.exit(1)
print(f'  共 {len(names)} 个告警名称，无重复')
"
```

### 步骤 4 — PromQL 语法校验（需 promtool）

如果有 `promtool`，执行规则单元测试：

```bash
if command -v promtool >/dev/null 2>&1; then
  for f in configs/rules/*.yml; do
    promtool check rules "$f" && echo "  [PASS] $f" || echo "  [FAIL] $f"
  done
else
  echo "  [SKIP] promtool 未安装，跳过 PromQL 语法检查"
  echo "  安装: https://prometheus.io/docs/prometheus/latest/installation/"
fi
```

### 步骤 5 — 生成校验报告

```bash
echo "===== Prometheus 规则校验报告 ====="
echo "规则文件数: $(ls configs/rules/*.yml | wc -l)"
echo "告警规则总数:"
python3 -c "
import yaml, glob
total = 0
for f in sorted(glob.glob('configs/rules/*.yml')):
    data = yaml.safe_load(open(f))
    for g in data.get('groups', []):
        total += len([r for r in g.get('rules', []) if 'alert' in r])
print(f'  {total}')
"
```

## 回滚指引

- 如果校验发现问题，**不要提交**，修正后重新校验。
- 如果已提交并导致 Prometheus 拒绝加载规则：
  ```bash
  git revert HEAD --no-edit
  git push origin main
  # 在 Prometheus 服务器上 reload
  curl -X POST http://prometheus:9090/-/reload
  ```
- 检查 Prometheus 规则加载状态：
  ```bash
  curl -s http://prometheus:9090/api/v1/rules | python3 -m json.tool | head -20
  ```

## 与本仓库的关系

| 产物 | 关系 |
|------|------|
| `configs/rules/*.yml` | 被校验的告警规则文件 |
| `hooks/pre-commit` | 步骤 1 复用了 pre-commit 的 YAML 校验逻辑 |
| `AGENTS.md` | 校验命令对齐 AGENTS.md 测试指南 |
| `docs/01-监控体系方案.md` | 规则文件的设计文档 |
