# 客户运维 Profile 目录

> 每个客户一个 Profile 文件，定义该客户的全部运维差异化配置。

## 使用方法

```bash
# 1. 从模板创建新客户 Profile
cp EXAMPLE-customer.yml <customer-id>.yml

# 2. 编辑填写客户实际要求
vi <customer-id>.yml

# 3. 在 inventory 中创建对应客户主机组
#    [customer_<customer-id>:children]
#    customer_<customer-id>_mysql
#    customer_<customer-id>_web

# 4. 创建 group_vars 目录
mkdir -p playbooks/group_vars/customer_<customer-id>/
cp <customer-id>.yml playbooks/group_vars/customer_<customer-id>/vars.yml

# 5. 在 prometheus targets 中为该客户主机添加 customer 标签
# 6. 在 alertmanager 中添加该客户的路由规则
```

## Profile 驱动的配置矩阵

```
                Customer Profile (<customer-id>.yml)
                           │
         ┌────────┬────────┼────────┬────────┬────────┐
         ▼        ▼        ▼        ▼        ▼        ▼
    ┌────────┐┌──────┐┌──────┐┌──────┐┌──────┐┌──────┐
    │Inventory││group ││Monitor││Alert ││Backup││Security│
    │分组     ││_vars ││阈值   ││路由  ││策略  ││基线   │
    └────────┘└──────┘└──────┘└──────┘└──────┘└──────┘
```

## SLA 等级与默认配置对照

| 配置项 | premium | standard | basic |
|--------|---------|----------|-------|
| 采集间隔 | 10s | 15s | 30s |
| 备份保留(日) | 30 天 | 14 天 | 7 天 |
| 异地备份 | ✅ | 可选 | ❌ |
| 电话通知 | ✅ Critical | ❌ | ❌ |
| 安全基线 | CIS L2 | CIS L1 | CIS L1 |
| 日志保留 | 365 天 | 180 天 | 90 天 |
| 变更窗口 | 周六 00-04 | 周三 22-24 | 灵活 |

## 文件清单

| 文件 | 说明 |
|------|------|
| `EXAMPLE-customer.yml` | 模板文件，新客户从此复制 |
| `<customer-id>.yml` | 各客户实际 Profile（按需创建） |
