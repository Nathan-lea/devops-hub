#!/bin/bash
# ============================================================
# Kubernetes 集群健康巡检脚本
# 检查：节点状态、异常Pod、资源使用、事件、证书
# 依赖：kubectl 已配置 kubeconfig
# ============================================================

set -euo pipefail

DATE=$(date '+%Y-%m-%d %H:%M:%S')
REPORT="/var/log/k8s_health/$(date +%Y%m%d)_k8s_report.txt"
mkdir -p "$(dirname "$REPORT")"

echo "============================================================"
echo "  Kubernetes 集群健康巡检报告"
echo "  时间: $DATE"
echo "============================================================"

# ---------- 1. 集群基本信息 ----------
echo ""
echo "【1. 集群信息】"
kubectl cluster-info 2>/dev/null | head -5 | sed 's/^/  /'
echo ""

# ---------- 2. 节点状态 ----------
echo "【2. 节点状态】"
kubectl get nodes -o wide 2>/dev/null | sed 's/^/  /'
echo ""

# 检查 NotReady 节点
NOT_READY=$(kubectl get nodes -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready")].status!="True")]}' 2>/dev/null | jq -r '.metadata.name' 2>/dev/null || true)
if [ -n "$NOT_READY" ]; then
  echo "  [CRIT] NotReady 节点: $NOT_READY"
else
  echo "  [OK] 所有节点 Ready"
fi
echo ""

# ---------- 3. 异常 Pod ----------
echo "【3. 异常 Pod】"
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | sed 's/^/  /'
echo ""

# CrashLoopBackOff
CRASH_PODS=$(kubectl get pods -A -o jsonpath='{range .items[?(@.status.containerStatuses[0].state.waiting.reason=="CrashLoopBackOff")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [ -n "$CRASH_PODS" ]; then
  echo "  [WARN] CrashLoopBackOff:"
  echo "$CRASH_PODS" | sed 's/^/    /'
else
  echo "  [OK] 无 CrashLoopBackOff"
fi
echo ""

# Pending
PENDING_PODS=$(kubectl get pods -A --field-selector=status.phase=Pending -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
if [ -n "$PENDING_PODS" ]; then
  echo "  [WARN] Pending Pods:"
  echo "$PENDING_PODS" | head -10 | sed 's/^/    /'
else
  echo "  [OK] 无 Pending Pods"
fi
echo ""

# ---------- 4. 资源使用 ----------
echo "【4. 节点资源使用】"
if kubectl top nodes >/dev/null 2>&1; then
  kubectl top nodes 2>/dev/null | sed 's/^/  /'
else
  echo "  [INFO] metrics-server 未安装，无法获取资源使用"
fi
echo ""

# ---------- 5. 关键 Deployment ----------
echo "【5. Deployment 副本状态】"
kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: ready={.status.readyReplicas}/{.status.replicas}{"\n"}{end}' 2>/dev/null \
  | awk -F'=' '{split($2,a,"/"); if(a[1]!=a[2]) print "  [WARN] "$0; else print "  [OK] "$0}' || true
echo ""

# ---------- 6. Warning 事件（最近1小时） ----------
echo "【6. 最近 Warning 事件】"
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -20 | sed 's/^/  /' || true
echo ""

# ---------- 7. etcd 健康检查 ----------
echo "【7. etcd 状态】"
# 需要在 master 节点执行
if [ -f /etc/kubernetes/pki/etcd/ca.crt ]; then
  ETCD_STATUS=$(ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
    endpoint health 2>&1) || true
  echo "  $ETCD_STATUS" | sed 's/^/  /'
else
  echo "  [INFO] 非 master 节点，跳过 etcd 检查"
fi
echo ""

# ---------- 8. 证书有效期检查 ----------
echo "【8. K8s 证书有效期】"
if [ -d /etc/kubernetes/pki ]; then
  find /etc/kubernetes/pki -name "*.crt" | while read -r cert; do
    EXPIRY=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$EXPIRY" ]; then
      EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null || true)
      NOW_EPOCH=$(date +%s)
      if [ -n "$EXPIRY_EPOCH" ]; then
        DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
        if (( DAYS_LEFT < 30 )); then
          echo "  [WARN] ${cert} 将在 ${DAYS_LEFT} 天后过期"
        else
          echo "  [OK] ${cert} 剩余 ${DAYS_LEFT} 天"
        fi
      fi
    fi
  done
else
  echo "  [INFO] 非 master 节点"
fi
echo ""

# ---------- 9. PVC 使用 ----------
echo "【9. PVC 状态】"
kubectl get pvc -A 2>/dev/null | sed 's/^/  /' || true
echo ""

echo "============================================================"
echo "  巡检完成：$(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
