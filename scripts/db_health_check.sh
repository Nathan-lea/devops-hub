#!/bin/bash
# ============================================================
# 数据库健康巡检脚本
# 支持 MySQL、Redis（TiDB 通过 Prometheus 监控）
# ============================================================

set -euo pipefail

DATE=$(date '+%Y-%m-%d %H:%M:%S')
HOSTNAME=$(hostname)
REPORT="/var/log/db_health/$(date +%Y%m%d)_db_report.txt"
mkdir -p "$(dirname "$REPORT")"

echo "============================================================"
echo "  数据库健康巡检报告"
echo "  主机: $HOSTNAME  时间: $DATE"
echo "============================================================"

# ---------- MySQL 巡检 ----------
if command -v mysql >/dev/null 2>&1; then
  echo ""
  echo "【MySQL 巡检】"
  MYSQL_USER="${MYSQL_USER:-monitor}"
  MYSQL_PASS="${MYSQL_PASS:-}"

  if [ -z "$MYSQL_PASS" ]; then
    echo "  [INFO] 未设置 MYSQL_PASS，跳过 MySQL 巡检"
  else
    # 检查实例是否存活
    if mysqladmin ping -u"$MYSQL_USER" -p"$MYSQL_PASS" 2>/dev/null | grep -q alive; then
      echo "  [OK] MySQL 实例存活"
    else
      echo "  [CRIT] MySQL 实例无响应！"
    fi

    # 连接数
    THREADS=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -BN 2>/dev/null \
      -e "SHOW GLOBAL STATUS LIKE 'Threads_connected'" | awk '{print $2}')
    MAX_CONN=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -BN 2>/dev/null \
      -e "SHOW GLOBAL VARIABLES LIKE 'max_connections'" | awk '{print $2}')
    if [ -n "$THREADS" ] && [ -n "$MAX_CONN" ]; then
      PCT=$((THREADS * 100 / MAX_CONN))
      if (( PCT > 80 )); then
        echo "  [WARN] 连接数 ${THREADS}/${MAX_CONN} (${PCT}%)"
      else
        echo "  [OK] 连接数 ${THREADS}/${MAX_CONN} (${PCT}%)"
      fi
    fi

    # 慢查询数
    SLOW=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -BN 2>/dev/null \
      -e "SHOW GLOBAL STATUS LIKE 'Slow_queries'" | awk '{print $2}')
    echo "  [INFO] 累计慢查询数: ${SLOW:-0}"

    # 主从状态
    REPL_INFO=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW SLAVE STATUS\G" 2>/dev/null)
    if [ -n "$REPL_INFO" ]; then
      IO_RUN=$(echo "$REPL_INFO" | grep "Slave_IO_Running:" | awk '{print $2}')
      SQL_RUN=$(echo "$REPL_INFO" | grep "Slave_SQL_Running:" | awk '{print $2}')
      LAG=$(echo "$REPL_INFO" | grep "Seconds_Behind_Master:" | awk '{print $2}')
      if [ "$IO_RUN" = "Yes" ] && [ "$SQL_RUN" = "Yes" ]; then
        if [ -n "$LAG" ] && (( LAG > 60 )); then
          echo "  [WARN] 主从同步运行中，延迟 ${LAG}s"
        else
          echo "  [OK] 主从同步正常，延迟 ${LAG:-0}s"
        fi
      else
        echo "  [CRIT] 主从同步异常！IO=${IO_RUN} SQL=${SQL_RUN}"
      fi
    else
      echo "  [INFO] 非 from 节点（无主从状态）"
    fi

    # 大表（碎片率 > 30%）
    echo "  [INFO] 碎片率高的表（>30%）："
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e \
      "SELECT TABLE_SCHEMA, TABLE_NAME, DATA_FREE/(DATA_LENGTH+INDEX_LENGTH)*100 AS frag_pct
       FROM information_schema.TABLES
       WHERE TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys')
       AND DATA_LENGTH+INDEX_LENGTH > 0
       AND DATA_FREE/(DATA_LENGTH+INDEX_LENGTH) > 0.3
       ORDER BY frag_pct DESC LIMIT 10;" 2>/dev/null | sed 's/^/    /'
  fi
fi

# ---------- Redis 巡检 ----------
if command -v redis-cli >/dev/null 2>&1; then
  echo ""
  echo "【Redis 巡检】"
  REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
  REDIS_PORT="${REDIS_PORT:-6379}"
  REDIS_PASS="${REDIS_PASS:-}"

  AUTH_ARG=""
  [ -n "$REDIS_PASS" ] && AUTH_ARG="-a $REDIS_PASS"

  # 实例存活
  if redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" $AUTH_ARG ping 2>/dev/null | grep -q PONG; then
    echo "  [OK] Redis 实例存活"
  else
    echo "  [CRIT] Redis 实例无响应！"
  fi

  # 内存
  MEM_USED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" $AUTH_ARG info memory 2>/dev/null | grep used_memory: | cut -d: -f2 | tr -d '\r')
  MAX_MEM=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" $AUTH_ARG config get maxmemory 2>/dev/null | tail -1 | tr -d '\r')
  if [ -n "$MEM_USED" ] && [ -n "$MAX_MEM" ] && [ "$MAX_MEM" -gt 0 ]; then
    MEM_PCT=$((MEM_USED * 100 / MAX_MEM))
    if (( MEM_PCT > 85 )); then
      echo "  [WARN] 内存使用 $((MEM_USED/1024/1024))MB/$((MAX_MEM/1024/1024))MB (${MEM_PCT}%)"
    else
      echo "  [OK] 内存使用 ${MEM_PCT}%"
    fi
  fi

  # 连接数
  CLIENTS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" $AUTH_ARG info clients 2>/dev/null | grep connected_clients: | cut -d: -f2 | tr -d '\r')
  echo "  [INFO] 连接数: ${CLIENTS:-0}"

  # 主从状态
  REPL=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" $AUTH_ARG info replication 2>/dev/null)
  ROLE=$(echo "$REPL" | grep role: | cut -d: -f2 | tr -d '\r')
  echo "  [INFO] 角色: ${ROLE:-unknown}"
  if [ "$ROLE" = "slave" ]; then
    LINK_STATUS=$(echo "$REPL" | grep master_link_status: | cut -d: -f2 | tr -d '\r')
    if [ "$LINK_STATUS" = "up" ]; then
      echo "  [OK] 主从同步正常"
    else
      echo "  [CRIT] 主从同步断开！status=${LINK_STATUS}"
    fi
  fi

  # 持久化状态
  RDB_STATUS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" $AUTH_ARG info persistence 2>/dev/null | grep rdb_last_bgsave_status: | cut -d: -f2 | tr -d '\r')
  echo "  [INFO] RDB 最后备份状态: ${RDB_STATUS:-unknown}"
fi

echo ""
echo "============================================================"
echo "  巡检完成：$(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
