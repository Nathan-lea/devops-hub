# Web 服务器迁移标准 SOP

> **风险等级**：P1 | **预计窗口**：2-4 小时 | **停机**：可灰度免停机
> 适用：Nginx/Apache 跨主机、跨云迁移

---

## 一、适用场景与前置条件

### 1.1 迁移场景

| 场景 | 特点 | 复杂度 |
|------|------|--------|
| Nginx 跨主机迁移 | 配置 + 证书 + 静态资源 | 低 |
| Nginx 跨云迁移 | 上述 + 网络打通 + DNS 切换 | 中 |
| Apache -> Nginx | 配置语法转换 | 中 |
| 物理机 -> 容器化 | 配置容器化 + 镜像制作 | 中高 |

### 1.2 迁移内容盘点

```
Web 服务器迁移清单：
├── ① 配置文件（nginx.conf / conf.d/*.conf / vhost）
├── ② SSL 证书（*.pem / *.key）
├── ③ 静态资源（/var/www / /usr/share/nginx/html）
├── ④ 依赖模块（nginx 编译模块 / PHP-FPM 等）
├── ⑤ 系统调优参数（sysctl / ulimit / 内核网络参数）
└── ⑥ 后端 upstream 连接配置（反代到应用服务器）
```

### 1.3 前置条件
- [ ] 目标 Web 服务器已初始化（OS 基线、Nginx 已安装）
- [ ] 网络已打通（源端 <-> 目标端 SSH 可达）
- [ ] SSL 证书文件可获取（剩余有效期 > 30 天）
- [ ] DNS TTL 已提前 24h 调至 60s
- [ ] 迁移前完整备份已验证

---

## 二、角色与职责分工

| 角色 | 职责 |
|------|------|
| 迁移负责人 | 统筹、审批切换 |
| Web 运维 | 配置同步、证书部署、rsync、nginx -t |
| 复核员 | 逐步复核、监控错误率 |

---

## 三、操作步骤

### 步骤 1：迁移前环境检查

```bash
bash scripts/migration/pre_migration_check.sh \
  --source <源Web服务器> --target <目标Web服务器> --type web
```
- **验证**：端口空闲、SSL 证书有效期 > 30 天、配置文件存在

### 步骤 2：导出源端配置与证书

```bash
# 2.1 导出 Nginx 配置
ssh ops@<源Web服务器> "tar czf /tmp/nginx_config.tar.gz /etc/nginx/"
scp ops@<源Web服务器>:/tmp/nginx_config.tar.gz /tmp/

# 2.2 记录系统调优参数（用于目标端对齐）
ssh ops@<源Web服务器> "
  sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog
  ulimit -n
  nginx -V 2>&1 | tr ' ' '\n' | grep module
"
```
- **验证**：配置包已下载，系统参数已记录

### 步骤 3：目标端配置与数据同步

```bash
# 3.1 同步 Nginx 配置
scp /tmp/nginx_config.tar.gz ops@<目标Web服务器>:/tmp/
ssh ops@<目标Web服务器> "tar xzf /tmp/nginx_config.tar.gz -C /"

# 3.2 同步 SSL 证书
scp -r ops@<源Web服务器>:/etc/nginx/ssl/ ops@<目标Web服务器>:/etc/nginx/ssl/
ssh ops@<目标Web服务器> "chmod 600 /etc/nginx/ssl/*.key"

# 3.3 同步静态资源（rsync 增量）
rsync -avz --progress \
  ops@<源Web服务器>:/var/www/ \
  ops@<目标Web服务器>:/var/www/

# 3.4 修改 upstream 后端地址（跨云时后端 IP 可能变化）
ssh ops@<目标Web服务器> "sed -i 's/10.0.1.20/<新后端IP>/g' /etc/nginx/conf.d/*.conf"

# 3.5 语法检查
ssh ops@<目标Web服务器> "nginx -t"

# 3.6 启动 Nginx（不接外部流量）
ssh ops@<目标Web服务器> "systemctl start nginx"
```
- **验证**：`nginx -t` 通过，Nginx 已启动

### 步骤 4：目标端验证

```bash
# 4.1 本地验证
curl -sI http://<目标Web服务器>/
curl -skI https://<目标Web服务器>/

# 4.2 对比源端与目标端响应
diff <(curl -s http://<源Web服务器>/api/health) \
     <(curl -s http://<目标Web服务器>/api/health)

# 4.3 文件一致性校验
bash scripts/migration/migration_data_verify.sh \
  --source <源Web服务器> --target <目标Web服务器> \
  --type file
```
- **验证**：HTTP 200，响应内容一致，文件数与大小一致

### 步骤 5：持续 rsync 增量追平

```bash
# 设置定时任务每 5 分钟同步静态资源（直到切换）
echo "*/5 * * * * rsync -az --delete ops@<源Web服务器>:/var/www/ /var/www/" | crontab -
```
- **验证**：切换前最后一次 rsync 无差异

### 步骤 6：DNS 加权灰度切换

```
步骤 6a（10%）：DNS 加权 源90/目10，观察 30 分钟
步骤 6b（50%）：DNS 加权 源50/目50，观察 30 分钟
步骤 6c（100%）：DNS 加权 源0/目100，观察 2 小时
```
- **验证**：错误率 = 0，响应时间正常

### 步骤 7：切换后验证与清理

```bash
# 7.1 外部可达性
curl -sI https://app.example.com/
# 7.2 SSL 证书有效性
echo | openssl s_client -connect app.example.com:443 2>/dev/null | openssl x509 -noout -dates
# 7.3 日志检查（无 5xx 错误）
ssh ops@<目标Web服务器> "tail -100 /var/log/nginx/error.log | grep -c ' 5[0-9][0-9] '"
# 7.4 停止源端 Nginx（观察 2h 后）
# 7.5 删除 crontab rsync 任务
```
- **验证**：外部访问正常，无 5xx 错误

---

## 四、检查清单

### 4.1 迁移前
- [ ] Nginx 配置已通过 `nginx -t` 语法检查
- [ ] SSL 证书已同步且剩余有效期 > 30 天
- [ ] 静态资源 rsync 增量同步已追平
- [ ] upstream 后端地址已更新（跨云时）
- [ ] 系统调优参数已对齐（ulimit / sysctl）
- [ ] `pre_migration_check.sh` 全绿
- [ ] DNS TTL 已调至 60s（24h 前）

### 4.2 切换前
- [ ] 目标端 `nginx -t` 通过
- [ ] 目标端 HTTP/HTTPS 响应正常
- [ ] 文件一致性校验通过
- [ ] rsync 增量无差异

### 4.3 切换后
- [ ] 100% 流量运行 2 小时无异常
- [ ] 无 5xx 错误
- [ ] 源端 Nginx 保留 7 天后下线

---

## 五、回滚步骤

| 阶段 | 回滚操作 | 恢复时间 |
|------|----------|----------|
| 预迁移 | 停目标端 Nginx，源端不受影响 | 0min |
| DNS 灰度中 | DNS 权重回切源端 | <5min（TTL 60s） |
| 全量后 | DNS 回切源端，源端 Nginx 保持运行 | <5min |

> Web 迁移无状态，回滚代价最低。关键在于 SSL 证书和配置的完整性。
> **辅助脚本**：`bash scripts/migration/migration_rollback.sh --type dns --action rollback`

---

## 六、异常处理

| 异常现象 | 可能原因 | 处置方法 |
|----------|----------|----------|
| nginx -t 失败 | 配置语法错误、模块缺失 | 逐个排查配置文件；安装缺失模块 |
| SSL 证书报错 | 证书过期、路径错误 | 续期证书；检查 ssl_certificate 路径 |
| 502 Bad Gateway | upstream 后端不可达 | 检查后端地址、安全组放行 |
| 静态资源 404 | rsync 未同步完整 | 重新 rsync；检查文件权限 |
| 响应内容不一致 | 配置差异、缓存 | 对比配置 diff；清理缓存 |

---

## 七、操作记录模板

```
迁移项目：Web 服务器迁移（____ -> ____）
日期：____-__-__  操作人：______  复核人：______

┌──────────────────┬────────┬──────────┬─────────────┐
│ 步骤             │ 开始   │ 完成     │ 结果        │
├──────────────────┼────────┼──────────┼─────────────┤
│ 1. 前置检查      │ __:__  │ __:__    │ □通过 □失败 │
│ 2. 导出配置      │ __:__  │ __:__    │ □通过 □失败 │
│ 3. 配置数据同步  │ __:__  │ __:__    │ □通过 □失败 │
│ 4. 目标端验证    │ __:__  │ __:__    │ □通过 □失败 │
│ 5. rsync 追平    │ __:__  │ __:__    │ □通过 □失败 │
│ 6. DNS 灰度切换  │ __:__  │ __:__    │ □通过 □失败 │
│ 7. 切换后验证    │ __:__  │ __:__    │ □通过 □失败 │
└──────────────────┴────────┴──────────┴─────────────┘

异常记录：___________________________________________________________________
```
