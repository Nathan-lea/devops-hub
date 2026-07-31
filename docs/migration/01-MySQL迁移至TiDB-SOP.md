# MySQL 迁移至 TiDB 标准 SOP

> **风险等级**：P0（核心业务库） | **预计窗口**：4-8 小时 | **停机**：可灰度免停机

---

## 一、适用场景与前置条件

### 1.1 适用场景
- MySQL 5.7/8.0 迁移至 TiDB（降低分库分表复杂度、水平扩展）
- 单库数据量 > 500GB，分库分表维护成本高
- 需要 HTAP（混合事务/分析）能力

### 1.2 兼容性速查

| 维度 | MySQL | TiDB | 兼容性 | 处理策略 |
|------|-------|------|--------|----------|
| SQL 语法 | 5.7/8.0 | 高度兼容 5.7 | ⭐⭐⭐⭐ | 99% 无需修改 |
| 存储引擎 | InnoDB/MyISAM | TiKV | ⭐⭐⭐⭐ | MyISAM 需改 InnoDB |
| 存储过程/触发器 | 支持 | 部分支持 | ⭐⭐ | 需人工排查 |
| 自增列 | AUTO_INCREMENT | AUTO_RANDOM | ⭐⭐ | 建议改 AUTO_RANDOM 防热点 |
| 外键 | 支持 | v6.6+ 支持 | ⭐⭐⭐ | 建议应用层保证 |
| 事务隔离 | RR | SI(快照隔离) | ⭐⭐⭐ | SELECT FOR UPDATE 行为不同 |

### 1.3 前置条件
- [ ] TiDB 集群已部署且健康（PD/TiKV/TiDB Server 均 Up）
- [ ] 源端 MySQL 已开启 binlog，格式为 ROW，`binlog_row_image=FULL`
- [ ] 网络已打通（DM-Worker 可同时访问 MySQL 与 TiDB）
- [ ] 完成兼容性评估（触发器/存储过程/外键/自定义函数排查）
- [ ] 迁移前完整备份已验证可恢复

---

## 二、角色与职责分工

| 角色 | 职责 | 人数 |
|------|------|------|
| 迁移负责人 | 统筹全流程、审批切换决策、协调各方 | 1 |
| DBA 操作员 | 执行 DM 部署/同步/校验/切换操作 | 1 |
| 复核员 | 逐步复核操作正确性、监控告警 | 1 |
| 业务方代表 | 灰度期间业务验证、异常上报 | 1 |

---

## 三、操作步骤

### 步骤 1：迁移前环境检查

```bash
bash scripts/migration/pre_migration_check.sh \
  --source 10.0.2.10 --target 10.0.4.10 --type db
```

- **验证**：脚本输出 `✅ 前置检查全部通过`，退出码 0
- **通过条件**：无 FAIL 项；WARN 项已人工确认

### 步骤 2：部署 DM 集群

```bash
# 2.1 安装 DM
tiup install dm
tiup dm deploy dm-prod 7.0 ./dm-topology.yaml --user ops

# 2.2 确认源端 binlog 配置
#    my.cnf 必须包含：
#    server_id=100
#    log_bin=mysql-bin
#    binlog_format=ROW
#    binlog_row_image=FULL
```

- **验证**：`tiup dm --prefix dm-prod display` 显示 DM 各组件正常

### 步骤 3：配置源端 MySQL

```yaml
# source-mysql.yaml
source-id: "mysql-source-01"
enable-gtid: true
from:
  host: "10.0.2.10"           # 占位 IP
  port: 3306
  user: "repl"
  password: "${vault_mysql_repl_pass}"
```

```bash
tiup dm --prefix dm-prod source create ./source-mysql.yaml
```

- **验证**：`tiup dm --prefix dm-prod source list` 显示 mysql-source-01 状态为 online

### 步骤 4：创建迁移任务（全量+增量）

```yaml
# task-mysql-to-tidb.yaml
name: "mysql-to-tidb-01"
task-mode: "all"            # all = full + incremental
meta-schema: "dm_meta"
timezone: "Asia/Shanghai"

target-database:
  host: "10.0.4.10"         # 占位 IP
  port: 4000
  user: "root"
  password: "${vault_tidb_root_pass}"

mysql-instances:
  - source-id: "mysql-source-01"
    block-allow-list: "bw-list-01"
    mydumper-config-name: "global"
    loader-config-name: "global"
    syncer-config-name: "global"

block-allow-list:
  bw-list-01:
    do-dbs: ["app_db", "user_db"]
    ignore-dbs: ["mysql", "sys"]

mydumper:
  global:
    threads: 4
    chunk-filesize: 64

syncer:
  global:
    worker-count: 16
    batch: 100
```

```bash
tiup dm --prefix dm-prod task create ./task-mysql-to-tidb.yaml
```

- **验证**：`tiup dm --prefix dm-prod task query mysql-to-tidb-01` 显示任务 Running

### 步骤 5：等待全量完成 + 增量追平

```bash
# 持续查询任务状态
watch -n 30 'tiup dm --prefix dm-prod task query mysql-to-tidb-01'
```

- **验证**：全量阶段 `stage` 变为 `Finished`，增量阶段 `binlog lag` = 0
- **通过条件**：增量同步延迟 < 1s，持续观察 10 分钟稳定

### 步骤 6：数据一致性校验

```bash
# 使用 sync-diff-inspector 校验
./sync-diff-inspector --config=./diff-config.toml
```

```toml
# diff-config.toml
[data-sources.mysql]
    host = "10.0.2.10"
    port = 3306
    user = "root"
    password = "${vault_mysql_root}"

[data-sources.tidb]
    host = "10.0.4.10"
    port = 4000
    user = "root"
    password = "${vault_tidb_root}"

[task]
    output-dir = "./output"
    source-instances = ["mysql"]
    target-instance = ["tidb"]
    target-check-tables = ["app_db.*"]
```

- **验证**：校验报告显示所有表 `result: pass`
- **通过条件**：行数一致 + 抽样校验和一致

### 步骤 7：灰度切换（10% -> 50% -> 100%）

```
步骤 7a（10% 灰度）：
  - 应用配置中心将 10% 数据源连接指向 TiDB（4000 端口）
  - DM 增量同步保持运行（双向保障）
  - 观察 30 分钟：错误率、延迟、慢查询

步骤 7b（50% 灰度）：
  - 50% 流量切至 TiDB
  - 观察 1 小时

步骤 7c（100% 切换）：
  - 全量流量切至 TiDB
  - 停止 DM 增量同步
  - 观察 2 小时
```

```bash
# 切换后停止 DM 同步
tiup dm --prefix dm-prod task stop mysql-to-tidb-01

# 最终数据校验
bash scripts/migration/migration_data_verify.sh \
  --source 10.0.2.10 --target 10.0.4.10 \
  --type mysql --db app_db
```

- **验证**：应用日志无数据库错误；监控大盘 TiDB QPS/延迟正常
- **通过条件**：100% 流量运行 2 小时无异常

### 步骤 8：观察期与源端下线

- 切换后观察 **7 天**，确认无异常
- 第 8 天下线源端 MySQL（保留备份 30 天）

---

## 四、检查清单

### 4.1 迁移前
- [ ] 兼容性评估报告通过评审（触发器/存储过程/外键/视图已排查）
- [ ] 源端 MySQL binlog 已开启（ROW 格式 + binlog_row_image=FULL）
- [ ] TiDB 集群健康，容量充足
- [ ] DM 集群已部署，源端连通
- [ ] `pre_migration_check.sh` 全绿
- [ ] 完整备份已验证可恢复
- [ ] 回滚预案已编写并评审
- [ ] 迁移窗口已申请，双人就位

### 4.2 切换前
- [ ] 全量同步完成
- [ ] 增量同步延迟 < 1s，持续 10 分钟稳定
- [ ] sync-diff-inspector 校验全部通过
- [ ] 应用已支持数据源配置热切换

### 4.3 切换后
- [ ] 100% 流量运行 2 小时无异常
- [ ] `migration_data_verify.sh` 校验通过
- [ ] DM 同步已停止
- [ ] 观察 7 天无异常后下线源端

---

## 五、回滚步骤

### 5.1 切换前回滚（全量/增量同步阶段）
```
1. 停止 DM 任务：tiup dm --prefix dm-prod task stop mysql-to-tidb-01
2. 应用继续使用 MySQL（零影响）
3. 排查同步问题，修复后重新启动
```
- **恢复时间**：< 1 分钟

### 5.2 切换中回滚（灰度阶段）
```
1. 配置中心回切：将数据源连接指回 MySQL
2. 重启 DM 增量同步：tiup dm --prefix dm-prod task start mysql-to-tidb-01
3. 确认应用全部回到 MySQL
```
- **恢复时间**：< 5 分钟

### 5.3 切换后回滚（全量切换后）
```
1. 评估 TiDB 新增数据量，决定是否值得回滚
2. 若 DM 仍在运行（未 stop）：配置中心回切 MySQL，<5min 恢复
3. 若 DM 已停止：需手动导出 TiDB 增量数据导入 MySQL（耗时，谨慎决策）
```
- **恢复时间**：5 分钟 ~ 数小时（取决于是否已 stop DM）

> **辅助脚本**：`bash scripts/migration/migration_rollback.sh --type sync --action rollback`

---

## 六、异常处理

| 异常现象 | 可能原因 | 处置方法 |
|----------|----------|----------|
| DM 全量同步卡住 | 大表无主键、网络中断 | 检查大表是否有主键；`tiup dm task pause` 后 `resume` |
| 增量同步延迟不降 | 源端写入过快、TiDB 写入瓶颈 | 调大 `worker-count`；检查 TiDB 热点 |
| sync-diff 报不一致 | 全量与增量间有写入窗口 | 重新全量同步或低峰期重新校验 |
| 灰度后应用报错 | SQL 不兼容、字符集差异 | 检查错误 SQL，修复后重试灰度 |
| TiDB 慢查询 | 执行计划差异、统计信息过期 | `ANALYZE TABLE`；检查执行计划 |

---

## 七、操作记录模板

```
迁移项目：MySQL -> TiDB（app_db）
日期：____-__-__  操作人：______  复核人：______

┌──────────────┬────────┬──────────┬─────────────┐
│ 步骤         │ 开始   │ 完成     │ 结果        │
├──────────────┼────────┼──────────┼─────────────┤
│ 1. 前置检查  │ __:__  │ __:__    │ □通过 □失败 │
│ 2. DM 部署   │ __:__  │ __:__    │ □通过 □失败 │
│ 3. 配置源端  │ __:__  │ __:__    │ □通过 □失败 │
│ 4. 创建任务  │ __:__  │ __:__    │ □通过 □失败 │
│ 5. 同步追平  │ __:__  │ __:__    │ □通过 □失败 │
│ 6. 数据校验  │ __:__  │ __:__    │ □通过 □失败 │
│ 7a. 10%灰度  │ __:__  │ __:__    │ □通过 □失败 │
│ 7b. 50%灰度  │ __:__  │ __:__    │ □通过 □失败 │
│ 7c. 100%切换 │ __:__  │ __:__    │ □通过 □失败 │
│ 8. 源端下线  │ __:__  │ __:__    │ □通过 □失败 │
└──────────────┴────────┴──────────┴─────────────┘

异常记录：
___________________________________________________________________

回滚记录（如有）：
___________________________________________________________________
```
