# K8s 集群跨云迁移标准 SOP

> **风险等级**：P0 | **预计窗口**：8-24 小时（视应用与 PV 数量） | **停机**：逐服务灰度可免停机

---

## 一、适用场景与前置条件

### 1.1 迁移策略选型

| 策略 | 原理 | 优点 | 缺点 | 适用场景 |
|------|------|------|------|----------|
| **GitOps 重建** | 从 Git 仓库重新部署 | 干净、可审计 | 无状态数据需单独迁移 | 无状态应用、IaC 完善 |
| **Velero 备份恢复** | 备份源集群 -> 恢复到目标 | 含 PV 数据 | 大量 PV 耗时长 | 有状态应用 |
| **逐服务灰度迁移** | 按服务粒度逐个迁移 | 风险可控、可回滚 | 耗时较长 | 生产环境推荐 |

**生产推荐**：GitOps 重建（无状态）+ Velero（有状态 PV）+ 逐服务灰度

### 1.2 迁移架构

```
私有云 K8s                          公有云 K8s
┌─────────────────────┐           ┌─────────────────────┐
│  ┌─────┐ ┌─────┐   │           │   ┌─────┐ ┌─────┐   │
│  │Pod A│ │Pod B│   │  灰度迁移  │   │Pod A│ │Pod B│   │
│  └─────┘ └─────┘   │ ────────> │   └─────┘ └─────┘   │
│  ┌──────────┐      │ Velero    │   ┌──────────┐      │
│  │ PV (NFS) │      │ ────────> │   │ PV (EBS)  │      │
│  └──────────┘      │           │   └──────────┘      │
│  ┌──────────┐      │ DNS 灰度  │   ┌──────────┐      │
│  │ Ingress  │      │ ────────> │   │ Ingress  │      │
│  └──────────┘      │           │   └──────────┘      │
└─────────────────────┘           └─────────────────────┘
        │                                 │
        └───── Git 仓库 (Helm/Kustomize) ─┘
```

### 1.3 前置条件
- [ ] 目标集群已创建（版本与源集群差不超过 1 个小版本）
- [ ] 网络已打通（私有云 <-> 公有云 VPC 互联）
- [ ] 目标集群已安装 Ingress Controller、Cert Manager
- [ ] 镜像仓库可达（或镜像已推送至目标云仓库）
- [ ] Velero 已安装且备份存储可访问
- [ ] StorageClass 已映射（NFS -> EBS/EFS）

---

## 二、角色与职责分工

| 角色 | 职责 |
|------|------|
| 迁移负责人 | 统筹、逐服务迁移顺序规划、审批切换 |
| K8s 运维 | 集群配置、Velero 操作、Ingress 灰度 |
| 应用开发 | 配置适配、镜像推送、业务验证 |
| 复核员 | 逐步复核、监控 |

---

## 三、操作步骤

### 步骤 1：迁移前环境检查

```bash
bash scripts/migration/pre_migration_check.sh \
  --source <私有云master> --target <公有云master> --type k8s
```
- **验证**：源端/目标端节点全部 Ready，Velero 已安装，镜像拉取正常

### 步骤 2：目标集群组件安装

```bash
# 安装 Ingress Controller、Cert Manager、Velero
helm install velero vmware-tanzu/velero \
  --namespace velero --create-namespace \
  --set configuration.backupStorageLocation[0].provider=aws \
  --set configuration.backupStorageLocation[0].bucket=<公有云S3桶>
```
- **验证**：`kubectl get pods -n velero` 全部 Running

### 步骤 3：无状态应用迁移（GitOps 重建）

```bash
# 3.1 从 Git 仓库部署（推荐）
#     若无 GitOps，导出当前运行资源：
kubectl get deployments,svc,configmap,secret,ingress -n app-ns -o yaml > app-ns-backup.yaml

# 3.2 清理集群特定字段
yq eval-all 'del(.items[] | .metadata.clusterIP, .metadata.uid, .metadata.resourceVersion, .status)' app-ns-backup.yaml

# 3.3 在目标集群部署
kubectl --kubeconfig=<公有云kubeconfig> apply -f app-ns-backup.yaml
```
- **验证**：`kubectl --kubeconfig=<公有云> get pods -n app-ns` 全部 Running

### 步骤 4：有状态应用迁移（PV 数据）

```bash
# 方案 A：Velero 备份恢复（推荐）
# 4.1 源集群创建备份
velero backup create app-backup-$(date +%Y%m%d) \
  --include-namespaces app-ns \
  --include-resources pv,pvc,deployments,statefulsets,svc \
  --snapshot-volumes=true

# 4.2 等待备份完成
velero backup describe app-backup-$(date +%Y%m%d) --details

# 4.3 目标集群恢复（StorageClass 映射到公有云存储）
velero restore create app-restore-$(date +%Y%m%d) \
  --from-backup app-backup-$(date +%Y%m%d) \
  --namespace-mappings app-ns:app-ns
```

```bash
# 方案 B：rsync 手动迁移 PV 数据（NFS/CephFS 场景）
# 4.1 源集群缩容 StatefulSet（停止写入）
kubectl scale statefulset app-sts -n app-ns --replicas=0
# 4.2 rsync 同步数据
rsync -avz --progress ops@<私有云NFS>:/data/app-pv/ ops@<公有云EFS>:/data/app-pv/
# 4.3 目标集群创建 PVC 并挂载，扩容 StatefulSet
```
- **验证**：`kubectl --kubeconfig=<公有云> get pvc -n app-ns` 全部 Bound

### 步骤 5：流量灰度切换

```bash
# 5.1 DNS 加权（10% -> 50% -> 100%）
#     私有云 LB 权重 90, 公有云 LB 权重 10

# 5.2 Ingress Canary（Nginx Ingress）
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app-canary
  annotations:
    nginx.ingress.kubernetes.io/canary: "true"
    nginx.ingress.kubernetes.io/canary-weight: "10"   # 10% 灰度
spec:
  rules:
  - host: app.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: app-svc
            port:
              number: 8080
```
- **验证**：`curl -sI https://app.example.com/health` 返回 200

### 步骤 6：逐服务迁移（重复步骤 3-5）

按服务依赖顺序逐个迁移：基础设施 -> 无状态服务 -> 有状态服务 -> 入口层

### 步骤 7：观察与源集群下线
- 全部服务切换后观察 7 天
- **不要删除源集群资源**，直到目标集群稳定 7 天

---

## 四、检查清单

### 4.1 迁移前
- [ ] 目标集群版本与源集群兼容
- [ ] 网络已打通（私有云 <-> 公有云）
- [ ] Ingress Controller、Cert Manager、Velero 已安装
- [ ] 镜像仓库可达
- [ ] StorageClass 已映射（NFS -> EBS/EFS）
- [ ] NetworkPolicy 已适配目标集群网络模型
- [ ] `pre_migration_check.sh` 全绿
- [ ] 逐服务迁移顺序已规划

### 4.2 切换前
- [ ] 无状态应用已部署且 Pod Running
- [ ] 有状态应用 PV 数据已恢复，PVC Bound
- [ ] Ingress/DNS 灰度配置就绪

### 4.3 切换后
- [ ] 全部服务 100% 流量运行 2 小时无异常
- [ ] 源集群资源保留 7 天

---

## 五、回滚步骤

| 阶段 | 回滚操作 | 恢复时间 |
|------|----------|----------|
| 预迁移 | 停止目标集群 Pod，源集群不受影响 | 0min |
| 灰度中 | DNS 权重回切源集群 | <5min（TTL 60s） |
| 全量后 | DNS 回切 + 源集群恢复 StatefulSet | <10min |

> **关键**：迁移期间**不要删除源集群资源**，直到目标集群稳定 7 天。
> **辅助脚本**：`bash scripts/migration/migration_rollback.sh --type dns --action rollback`

---

## 六、异常处理

| 异常现象 | 可能原因 | 处置方法 |
|----------|----------|----------|
| Pod 镜像拉取失败 | 镜像仓库不可达 | 推送镜像至目标云仓库；检查镜像拉取凭证 |
| PVC Pending | StorageClass 不存在 | 创建对应 StorageClass；检查 PV 映射 |
| Velero 恢复失败 | 备份存储不可访问、快照不可用 | 检查 S3 连通性；改用 rsync 手动迁移 |
| Ingress 灰度不生效 | Ingress Controller 版本差异 | 检查注解语法；确认 Nginx Ingress 版本 |
| NetworkPolicy 阻断 | 目标集群网络模型不同 | 调整 NetworkPolicy 放行目标集群网段 |

---

## 七、操作记录模板

```
迁移项目：K8s 跨云迁移（____ -> ____）
日期：____-__-__  操作人：______  复核人：______

服务迁移顺序：
1. ____________  □完成  2. ____________  □完成  3. ____________  □完成

┌────────────────────┬────────┬──────────┬─────────────┐
│ 步骤               │ 开始   │ 完成     │ 结果        │
├────────────────────┼────────┼──────────┼─────────────┤
│ 1. 前置检查        │ __:__  │ __:__    │ □通过 □失败 │
│ 2. 组件安装        │ __:__  │ __:__    │ □通过 □失败 │
│ 3. 无状态迁移      │ __:__  │ __:__    │ □通过 □失败 │
│ 4. 有状态PV迁移    │ __:__  │ __:__    │ □通过 □失败 │
│ 5. 流量灰度切换    │ __:__  │ __:__    │ □通过 □失败 │
│ 6. 逐服务迁移      │ __:__  │ __:__    │ □通过 □失败 │
│ 7. 源集群下线      │ __:__  │ __:__    │ □通过 □失败 │
└────────────────────┴────────┴──────────┴─────────────┘

异常记录：___________________________________________________________________
```
