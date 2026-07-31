# PostgreSQL 迁移至 TiDB 标准 SOP

> **风险等级**：P0/P1 | **预计窗口**：6-12 小时 | **停机**：推荐双写方案可灰度免停机
> **注意**：PG 与 TiDB（MySQL 协议）差异大，是所有迁移中复杂度最高的场景

---

## 一、适用场景与前置条件

### 1.1 适用场景
- PostgreSQL 迁移至 TiDB（统一技术栈、水平扩展）
- PG 数据量增长快，需分布式能力
- 团队向 MySQL 生态统一

### 1.2 兼容性差异评估

| 维度 | PostgreSQL | TiDB | 兼容性 | 处理策略 |
|------|------------|------|--------|----------|
| SQL 方言 | PG 方言 | MySQL 方言 | ⭐ | 需大量改写 |
| 数据类型 | rich type | MySQL type | ⭐⭐ | 需逐列映射 |
| 序列 | SEQUENCE | AUTO_INCREMENT | ⭐⭐ | 转换为自增列 |
| 存储过程 | PL/pgSQL | 不兼容 | ⭐ | 重写为应用逻辑 |
| JSONB | JSONB（二进制） | JSON（文本） | ⭐⭐⭐ | 可迁移，操作符不同 |
| 数组类型 | ARRAY | 不支持 | ⭐ | 拆为关联表或 JSON |

### 1.3 数据类型映射表

| PostgreSQL 类型 | TiDB 类型 | 注意事项 |
|-----------------|-----------|----------|
| `serial` / `bigserial` | `INT AUTO_INCREMENT` | 序列值需手动同步 |
| `boolean` | `TINYINT(1)` | true->1, false->0 |
| `text` / `varchar` | `TEXT` / `VARCHAR` | 长度语义一致 |
| `timestamp with time zone` | `TIMESTAMP` | 时区由应用层处理 |
| `numeric` / `decimal` | `DECIMAL` | 精度保持一致 |
| `jsonb` | `JSON` | `->>` 改 `JSON_EXTRACT` |
| `uuid` | `VARCHAR(36)` | 改为应用生成 UUID |
| `array` | 拆为子表或 `JSON` | 需重建数据模型 |
| `bytea` | `BLOB` | 二进制直接映射 |

### 1.4 迁移路径（四步法）

```
┌────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ ① PG 导出  │──>│ ② Schema 转换 │──>│ ③ 数据导入   │──>│ ④ 增量同步   │
│ pg_dump    │   │ 类型/语法改写 │   │ Lightning    │   │ 双写/CDC     │
└────────────┘   └──────────────┘   └──────────────┘   └──────────────┘
```

### 1.5 前置条件
- [ ] TiDB 集群已部署且健康
- [ ] Schema 转换方案已评审（类型映射、存储过程改写方案确认）
- [ ] 网络已打通（PG 源端 <-> 导出机 <-> TiDB 目标端）
- [ ] 迁移前完整备份已验证可恢复
- [ ] 应用层双写方案已开发并测试通过（推荐增量同步方式）

---

## 二、角色与职责分工

| 角色 | 职责 | 人数 |
|------|------|------|
| 迁移负责人 | 统筹全流程、审批切换 | 1 |
| DBA 操作员 | Schema 转换、数据导出导入、序列同步 | 1 |
| 应用开发 | 双写代码开发与上线 | 1 |
| 复核员 | 逐步复核、监控告警 | 1 |

---

## 三、操作步骤

### 步骤 1：迁移前环境检查

```bash
bash scripts/migration/pre_migration_check.sh \
  --source 10.0.3.10 --target 10.0.4.10 --type db
```
- **验证**：脚本输出 `✅ 前置检查全部通过`

### 步骤 2：Schema 转换

```bash
# 2.1 导出 PG schema
pg_dump -h 10.0.3.10 -U backup -d app_db --schema-only --no-owner > pg_schema.sql

# 2.2 转换 schema（人工或脚本）
#    关键转换规则：
#      SERIAL -> INT AUTO_INCREMENT
#      BOOLEAN -> TINYINT(1)
#      JSONB -> JSON
#      TIMESTAMP WITH TIME ZONE -> TIMESTAMP
#      移除 SEQUENCE，改用 AUTO_INCREMENT
#      移除 PG 特有语法（RETURNING / ON CONFLICT 等）

# 2.3 在 TiDB 创建转换后的 schema
mysql -h 10.0.4.10 -P 4000 -u root -p < tidb_schema.sql
```
- **验证**：`mysql -h 10.0.4.10 -P 4000 -e "SHOW TABLES FROM app_db"` 表数量与 PG 一致

### 步骤 3：全量数据导出与导入

```bash
# 3.1 PG 数据导出为 CSV（逐表）
export PGPASSWORD="${vault_pg_backup_pass}"
psql -h 10.0.3.10 -U backup -d app_db -Atqc \
  "SELECT tablename FROM pg_tables WHERE schemaname='public'" | \
while read TBL; do
  psql -h 10.0.3.10 -U backup -d app_db -c \
    "COPY public.\"$TBL\" TO '/tmp/${TBL}.csv' WITH CSV HEADER"
done

# 3.2 TiDB Lightning 导入 CSV
tiup tidb-lightning -config ./lightning-pg-to-tidb.toml
```

```toml
# lightning-pg-to-tidb.toml
[lightning]
level = "info"
[tikv-importer]
backend = "local"           # 物理导入，速度最快
[mydumper]
data-source-dir = "/tmp/pg_csv/"
[mydumper.csv]
header = true
delimiter = ","
[task]
target-database.host = "10.0.4.10"
target-database.port = 4000
target-database.user = "root"
target-database.password = "${vault_tidb_root}"
```
- **验证**：Lightning 日志显示 `import success`，无报错

### 步骤 4：序列/自增列同步

```bash
# 4.1 查询 PG 每张表序列最大值
psql -h 10.0.3.10 -U backup -d app_db -Atqc "
  SELECT tablename, pg_get_serial_sequence(tablename, 'id')
  FROM pg_tables WHERE schemaname='public';"

# 4.2 在 TiDB 设置 AUTO_INCREMENT 起始值（源端最大 ID + 1000 安全余量）
mysql -h 10.0.4.10 -P 4000 -u root -p -e "
  ALTER TABLE app_db.users AUTO_INCREMENT = <源端最大ID+1000>;"
```
- **验证**：TiDB 各表 `AUTO_INCREMENT` 值 >= PG 对应序列 `last_value`

### 步骤 5：增量同步（应用层双写，推荐）

```
方案 A（推荐）：应用层双写
  1. 应用代码增加双写逻辑（写 PG + 异步写 TiDB）
  2. 全量迁移后，双写追平增量
  3. 校验一致后切换读流量到 TiDB
  4. 最后停止 PG 写入，下线双写代码

方案 B：PG 逻辑解码 CDC
  wal2json + Debezium -> Kafka -> TiDB（复杂度高，不推荐）

方案 C：低峰期停机一次性切换（数据量小、可容忍停机时）
```
- **验证**：双写运行后，`migration_data_verify.sh` 行数对比一致

### 步骤 6：数据一致性校验

```bash
# PG 端行数
psql -h 10.0.3.10 -U monitor -d app_db -Atqc \
  "SELECT tablename, (SELECT count(*) FROM public.tablename) FROM pg_tables WHERE schemaname='public'"

# TiDB 端行数
mysql -h 10.0.4.10 -P 4000 -u monitor -e \
  "SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema='app_db'"
```
- **验证**：各表行数一致
- **通过条件**：行数差 = 0（或仅双写延迟导致的微小差异已追平）

### 步骤 7：灰度切换（10% -> 50% -> 100%）

```
步骤 7a（10%）：应用 10% 读流量指向 TiDB，观察 30 分钟
步骤 7b（50%）：50% 读流量，观察 1 小时
步骤 7c（100%）：全量读+写切至 TiDB，停止 PG 写入，观察 2 小时
```
- **验证**：应用无报错，监控正常
- **通过条件**：100% 运行 2 小时无异常

### 步骤 8：观察期与源端下线
- 切换后观察 7 天，确认无异常
- 下线双写代码，下线 PG（保留备份 30 天）

---

## 四、检查清单

### 4.1 迁移前
- [ ] Schema 转换方案评审通过（类型映射、存储过程改写确认）
- [ ] PG 端无长事务、无大 DDL 执行中
- [ ] TiDB 集群健康，容量充足
- [ ] 应用双写代码已开发并通过测试
- [ ] `pre_migration_check.sh` 全绿
- [ ] 完整备份已验证可恢复
- [ ] 回滚预案已编写并评审

### 4.2 切换前
- [ ] 全量数据导入完成
- [ ] 序列/自增列已同步
- [ ] 双写增量追平，行数一致
- [ ] 应用已支持数据源热切换

### 4.3 切换后
- [ ] 100% 流量运行 2 小时无异常
- [ ] 双写代码已下线
- [ ] 观察 7 天后下线 PG

---

## 五、回滚步骤

### 5.1 双写期间回滚
```
1. 停止应用双写代码（恢复仅写 PG）
2. 应用读流量切回 PG
3. 排查 TiDB 问题
```
- **恢复时间**：< 5 分钟

### 5.2 切换后回滚
```
1. 评估 TiDB 新增数据量
2. 应用读+写切回 PG
3. 若需同步增量：从 TiDB 导出增量数据导入 PG（耗时，谨慎）
```
- **恢复时间**：5 分钟 ~ 数小时
- **注意**：PG->TiDB 回滚代价高（SQL 方言差异），**切换前务必充分验证**

> **辅助脚本**：`bash scripts/migration/migration_rollback.sh --type sync --action rollback`

---

## 六、异常处理

| 异常现象 | 可能原因 | 处置方法 |
|----------|----------|----------|
| Lightning 导入报错 | CSV 格式不匹配、类型转换错误 | 检查 CSV 分隔符/引号；修正类型映射 |
| 序列值冲突 | AUTO_INCREMENT 起始值设置过低 | 重新查询 PG 最大 ID，设置 +1000 余量 |
| 双写 TiDB 报错 | SQL 不兼容、字段类型不匹配 | 修复应用 SQL；检查类型映射 |
| JSON 查询结果不一致 | JSONB vs JSON 操作符差异 | 改写查询使用 `JSON_EXTRACT` |
| 数组类型数据丢失 | PG ARRAY 无法直接映射 | 拆为关联表或 JSON 存储 |

---

## 七、操作记录模板

```
迁移项目：PostgreSQL -> TiDB（app_db）
日期：____-__-__  操作人：______  复核人：______  应用开发：______

┌────────────────┬────────┬──────────┬─────────────┐
│ 步骤           │ 开始   │ 完成     │ 结果        │
├────────────────┼────────┼──────────┼─────────────┤
│ 1. 前置检查    │ __:__  │ __:__    │ □通过 □失败 │
│ 2. Schema 转换 │ __:__  │ __:__    │ □通过 □失败 │
│ 3. 全量导入    │ __:__  │ __:__    │ □通过 □失败 │
│ 4. 序列同步    │ __:__  │ __:__    │ □通过 □失败 │
│ 5. 双写追平    │ __:__  │ __:__    │ □通过 □失败 │
│ 6. 数据校验    │ __:__  │ __:__    │ □通过 □失败 │
│ 7a. 10%灰度    │ __:__  │ __:__    │ □通过 □失败 │
│ 7b. 50%灰度    │ __:__  │ __:__    │ □通过 □失败 │
│ 7c. 100%切换   │ __:__  │ __:__    │ □通过 □失败 │
│ 8. 源端下线    │ __:__  │ __:__    │ □通过 □失败 │
└────────────────┴────────┴──────────┴─────────────┘

异常记录：___________________________________________________________________
回滚记录（如有）：___________________________________________________________
```
