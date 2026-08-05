---
name: tidb-br-backup
description: >
  Guide TiDB cluster backup and restore using BR (Backup & Restore) tool.
  Use when performing scheduled full backups, verifying backup integrity,
  restoring from backup after data loss, or troubleshooting backup failures.
  Covers BR full backup to S3, validation, retention cleanup, and monitoring
  metrics. Reuses scripts/tidb_backup.sh workflow.
tools_allowed:
  - bash
  - br
  - rclone
  - tikv-br
safety: destructive-if-restore
---

# TiDB BR Backup & Restore

使用 TiDB BR 工具执行全量备份、校验、恢复，以及过期清理。
本 skill 复用并增强 `scripts/tidb_backup.sh` 的工作流。

## 适用场景

- 定时全量备份（每日 03:00）
- 备份完整性校验
- 灾难恢复（从 S3 恢复到新集群）
- 备份失败排查

## 前置条件

```bash
# 1. BR 工具已安装
br --version 2>/dev/null || echo "BR 未安装: https://docs.pingcap.com/tidb/stable/backup-and-restore-tool"

# 2. S3/MinIO 可达
rclone lsd s3://tidb-backup/ 2>/dev/null || echo "S3 不可达，请检查 rclone 配置"

# 3. PD 端点可达
curl -s http://PD_ENDPOINT:2379/pd/api/v1/cluster >/dev/null && echo "PD 可达" || echo "PD 不可达"

# 4. 环境变量
echo "PD_ENDPOINT=${PD_ENDPOINT:-10.0.4.10:2379}"
echo "S3_BUCKET=${S3_BUCKET:-s3://tidb-backup}"
echo "S3_ENDPOINT=${S3_ENDPOINT:-http://minio:9000}"
```

> 所有 IP、密钥均为占位符，实际使用前替换为真实值或通过环境变量注入。

## 备份操作

### 步骤 1 - 执行全量备份

```bash
# 复用仓库脚本
bash scripts/tidb_backup.sh

# 或手动执行
DATE=$(date +%Y%m%d)
S3_PATH="s3://tidb-backup/full-$DATE"

br backup full \
  --pd "10.0.4.10:2379" \
  --storage "$S3_PATH" \
  --s3.endpoint "http://minio:9000" \
  --concurrency 4 \
  --log-file /var/log/tidb_backup.log
```

### 步骤 2 - 校验备份完整性

```bash
# BR 内置校验
br validate restore \
  --pd "10.0.4.10:2379" \
  --storage "$S3_PATH" \
  --s3.endpoint "http://minio:9000" \
  --log-file /var/log/tidb_validate.log

# 检查备份文件数与大小
rclone size "$S3_PATH"
```

> 校验通过后，脚本会自动推送 `tidb_backup_status=1` 指标到 node_exporter textfile。

### 步骤 3 - 推送监控指标

脚本会自动生成 `/var/lib/node_exporter/textfile/tidb_backup.prom`：

```prometheus
tidb_backup_last_success_timestamp 1690900000
tidb_backup_status 1
tidb_backup_duration_seconds 300
```

在 Prometheus 中配置告警规则（已在 `configs/rules/` 中）：

```yaml
- alert: TiDBBackupFailed
  expr: tidb_backup_status == 0 or absent(tidb_backup_status)
  for: 1h
  labels:
    severity: critical
```

### 步骤 4 - 清理过期备份

```bash
RETENTION_DAYS=7
for old_date in $(rclone lsd s3://tidb-backup/ | grep "full-" | awk '{print $NF}'); do
  old_epoch=$(date -d "${old_date#full-}" +%s 2>/dev/null || continue)
  now_epoch=$(date +%s)
  age_days=$(( (now_epoch - old_epoch) / 86400 ))
  if [ "$age_days" -gt "$RETENTION_DAYS" ]; then
    echo "删除过期备份: $old_date (${age_days}天)"
    rclone purge "s3://tidb-backup/$old_date"
  fi
done
```

## 恢复操作

> **警告**：恢复操作会覆盖目标集群数据，属于破坏性操作！

### 步骤 1 - 确认恢复点

```bash
# 列出可用备份
rclone lsd s3://tidb-backup/ | grep "full-"

# 确认目标集群
echo "目标 PD: 10.0.4.20:2379"
echo "恢复备份: s3://tidb-backup/full-20260731"
```

### 步骤 2 - 停止写入

```bash
# 停止应用写入 TiDB（通过 Ansible）
ansible customer_acme_tidb -m shell -a "systemctl stop tidb-app"
```

### 步骤 3 - 执行恢复

```bash
br restore full \
  --pd "10.0.4.20:2379" \
  --storage "s3://tidb-backup/full-20260731" \
  --s3.endpoint "http://minio:9000" \
  --concurrency 4 \
  --log-file /var/log/tidb_restore.log
```

### 步骤 4 - 恢复后验证

```bash
# 行数校验
mysql -h 10.0.4.20 -P 4000 -u root -p -e \
  "SELECT table_schema, table_rows FROM information_schema.tables WHERE table_schema NOT IN ('INFORMATION_SCHEMA','PERFORMANCE_SCHEMA','MYSQL') ORDER BY table_rows DESC LIMIT 20;"

# 业务关键表抽样
mysql -h 10.0.4.20 -P 4000 -u root -p -e "SELECT count(*) FROM your_critical_table;"
```

## 异常处理

| 故障 | 排查 | 处置 |
|------|------|------|
| `br command not found` | 检查 BR 是否安装 | 下载对应版本 BR |
| `connect to PD failed` | 网络/防火墙 | 检查 PD 端口 2379 可达性 |
| S3 上传失败 | rclone 配置/MinIO 状态 | `rclone config show` 确认配置 |
| 校验失败 | 备份不完整/网络中断 | 重新执行备份 |
| 恢复后数据不一致 | 版本不匹配 | 确认 BR 版本与 TiDB 版本一致 |

## 回滚指引

- 备份失败：不影响线上数据，重试即可。
- 恢复失败：目标集群数据已被部分覆盖，需从另一个备份恢复或重建集群。
- **恢复前必须确认**：已完成全量备份且校验通过，记录恢复前的集群状态。

## 与本仓库的关系

| 产物 | 关系 |
|------|------|
| `scripts/tidb_backup.sh` | 本 skill 复用的备份脚本 |
| `configs/rules/` | 含 TiDB 备份告警规则 |
| `docs/07-备份与容灾方案.md` | 备份策略设计文档 |
| `docs/04-数据库运维方案.md` | TiDB 日常运维文档 |
