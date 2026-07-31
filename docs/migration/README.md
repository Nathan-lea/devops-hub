# 迁移方案与操作手册（专题目录）

> 数据库迁移、K8s 跨云迁移、Web 服务器迁移的独立 SOP 文档集合
> 每种迁移类型独立成文，确保每次操作一致、可追溯、可回滚

## 为什么独立成文

不同类型的迁移**不会同时发生，但会多次发生**。将每种迁移拆为独立 SOP 文档，
操作时只需打开对应文档按步骤执行、打勾、记录，大幅降低遗漏与出错风险。

## 文档导航

| 文档 | 内容 | 适用场景 |
|------|------|----------|
| [00-迁移总则与方法论](00-迁移总则与方法论.md) | 风险等级、六大阶段模型、七大铁律、回滚原则 | **所有迁移必读** |
| [01-MySQL迁移至TiDB-SOP](01-MySQL迁移至TiDB-SOP.md) | DM 全量+增量同步、sync-diff 校验、灰度切换 | MySQL -> TiDB |
| [02-PostgreSQL迁移至TiDB-SOP](02-PostgreSQL迁移至TiDB-SOP.md) | Schema 转换、CSV 导入、序列同步、双写追平 | PostgreSQL -> TiDB |
| [03-数据库跨云迁移-SOP](03-数据库跨云迁移-SOP.md) | 网络打通、DM/CDC 同步、DNS 切换 | 私有云 <-> 公有云 |
| [04-K8s跨云迁移-SOP](04-K8s跨云迁移-SOP.md) | GitOps 重建、Velero 备份恢复、Ingress 灰度 | K8s 集群跨云 |
| [05-Web服务器迁移-SOP](05-Web服务器迁移-SOP.md) | 配置/证书/资源同步、rsync 追平、DNS 灰度 | Nginx/Web 跨主机跨云 |
| [06-迁移通用保障与检查清单](06-迁移通用保障与检查清单.md) | 检查清单、数据校验、灰度模型、回滚模板、监控告警 | 所有迁移通用 |

## 配套脚本

所有迁移脚本统一存放于 `scripts/migration/`：

| 脚本 | 用途 | 用法 |
|------|------|------|
| `pre_migration_check.sh` | 迁移前环境检查（网络/磁盘/备份/连接/端口/复制延迟） | `--source <IP> --target <IP> --type db\|k8s\|web` |
| `migration_data_verify.sh` | 迁移后数据一致性校验（行数/校验和/文件对比） | `--source <IP> --target <IP> --type mysql\|pg\|file` |
| `migration_rollback.sh` | 迁移回滚辅助（DNS 回切/同步停止/状态检查） | `--type dns\|sync\|check --action rollback` |

## SOP 使用方法

```
每次迁移的标准流程：

1. 阅读 00-迁移总则与方法论（确认风险等级与阶段模型）
2. 打开对应迁移类型的 SOP 文档
3. 执行"前置条件检查"，逐项打勾
4. 按"操作步骤"编号逐步执行，每步完成后验证并打勾
5. 填写"操作记录模板"留档
6. 如遇异常，按"异常处理"章节处置
7. 如需回滚，按"回滚步骤"执行
8. 迁移完成 7 天后，执行源端下线确认
```

## 目录结构

```
devops-hub/
├── docs/
│   └── migration/                    # 迁移专题（独立 SOP）
│       ├── README.md                 # 本文件
│       ├── 00-迁移总则与方法论.md
│       ├── 01-MySQL迁移至TiDB-SOP.md
│       ├── 02-PostgreSQL迁移至TiDB-SOP.md
│       ├── 03-数据库跨云迁移-SOP.md
│       ├── 04-K8s跨云迁移-SOP.md
│       ├── 05-Web服务器迁移-SOP.md
│       └── 06-迁移通用保障与检查清单.md
└── scripts/
    └── migration/                    # 迁移脚本（独立目录）
        ├── pre_migration_check.sh
        ├── migration_data_verify.sh
        └── migration_rollback.sh
```
