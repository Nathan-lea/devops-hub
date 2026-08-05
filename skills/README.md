# 自研 Skills 目录

> 本目录存放基于 `docs/14` 第 9.8.5 节自研建议创建的运维垂直域 skill。
> 每个 skill 遵循 devops-sre-skills 规范：YAML frontmatter（含 `tools_allowed`/`safety` 契约）
> + Markdown 正文（含验证步骤与回滚指引），示例中无真实密钥。

## Skill 清单

| Skill | 填补缺口 | 复用产物 | safety |
|-------|---------|---------|--------|
| [prometheus-rules-lint](prometheus-rules-lint/SKILL.md) | Prometheus 告警规则校验 | `hooks/pre-commit`、`configs/rules/*.yml` | read-only |
| [tidb-br-backup](tidb-br-backup/SKILL.md) | TiDB BR 备份与恢复 | `scripts/tidb_backup.sh` | destructive-if-restore |
| [wazuh-rule-tuning](wazuh-rule-tuning/SKILL.md) | 入侵检测规则调优 | `configs/rules/security.yml`、`docs/11` | read-only-tuning |
| [mysql-xtrabackup-verify](mysql-xtrabackup-verify/SKILL.md) | MySQL xtrabackup 备份验证 | `scripts/mysql_full_backup.sh` | read-only-verify |
| [pg-backup-verify](pg-backup-verify/SKILL.md) | PostgreSQL 备份验证 | `scripts/postgresql_backup.sh` | read-only-verify |
| [migration-verify](migration-verify/SKILL.md) | 迁移数据一致性校验 | `scripts/migration/migration_data_verify.sh` | read-only-verify |

## 安装到 Codex/Claude

```bash
# 软链接到 agents skills 目录（Codex 自动扫描加载）
for s in prometheus-rules-lint tidb-br-backup wazuh-rule-tuning \
         mysql-xtrabackup-verify pg-backup-verify migration-verify; do
  ln -sf "$(pwd)/skills/$s" ~/.agents/skills/$s
done

# 验证
ls ~/.agents/skills/*/SKILL.md | grep -E "prometheus|tidb|wazuh|mysql|pg-backup|migration"
```

## 设计规范

- **YAML frontmatter**：`name` + `description` + `tools_allowed` + `safety` 四字段
- **safety 契约**：`read-only` / `read-only-verify` / `read-only-tuning` / `destructive-if-restore`
- **正文结构**：适用场景 -> 前置条件 -> 编号步骤 -> 验证 -> 回滚指引 -> 异常处理 -> 与仓库关系
- **占位符**：所有 IP（`10.0.x.x`）、密码（`BACKUP_PASS`）、密钥均为占位符，禁止真实凭据
- **复用导向**：每个 skill 明确列出复用的仓库产物（脚本/配置/文档），保持 skill 与产物同步

## 与 docs/14 的关系

详见 `docs/14-技能矩阵与能力评估.md` 第 9.8.5 节"自研建议"。
