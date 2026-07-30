#!/bin/bash
# ============================================================
# 数据库健康巡检脚本
# 支持 MySQL、PostgreSQL、Redis（TiDB 通过 Prometheus 监控）
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

# ---------- PostgreSQL 巡检 ----------
if command -v psql >/dev/null 2>&1; then
  echo ""
  echo "【PostgreSQL 巡检】"
  PG_HOST="${PG_HOST:-127.0.0.1}"
  PG_PORT="${PG_PORT:-5432}"
  PG_USER="${PG_USER:-monitor}"
  export PGPASSWORD="${PG_PASS:-}"

  if [ -z "${PG_PASS:-}" ]; then
    echo "  [INFO] 未设置 PG_PASS，跳过 PostgreSQL 巡检"
  else
    # 实例存活
    if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Atqc "SELECT 1" >/dev/null 2>&1; then
      echo "  [OK] PostgreSQL 实例存活"
    else
      echo "  [CRIT] PostgreSQL 实例无响应！"
    fi

    # 连接数
    CONN_USED=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Atqc \
      "SELECT count(*) FROM pg_stat_activity" 2>/dev/null)
    MAX_CONN=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Atqc \
      "SELECT setting::int FROM pg_settings WHERE name='max_connections'" 2>/dev/null)
    if [ -n "$CONN_USED" ] && [ -n "$MAX_CONN" ] && [ "$MAX_CONN" -gt 0 ]; then
      PCT=$((CONN_USED * 100 / MAX_CONN))
      if (( PCT > 80 )); then
        echo "  [WARN] 连接数 ${CONN_USED}/${MAX_CONN} (${PCT}%)"
      else
        echo "  [OK] 连接数 ${CONN_USED}/${MAX_CONN} (${PCT}%)"
      fi
    fi

    # idle in transaction（持锁不释放）
    IDLE_TXN=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Atqc \
      "SELECT count(*) FROM pg_stat_activity WHERE state='idle in transaction'" 2>/dev/null)
    if [ -n "$IDLE_TXN" ] && (( IDLE_TXN > 10 )); then
      echo "  [WARN] idle in transaction 会话数: ${IDLE_TXN}（>10，长期持锁风险）"
    else
      echo "  [OK] idle in transaction 会话数: ${IDLE_TXN:-0}"
    fi

    # 流复制状态
    REPL=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Atqc \
      "SELECT client_addr, state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)
       FROM pg_stat_replication" 2>/dev/null)
    if [ -n "$REPL" ]; then
      echo "  [INFO] 流复制备库:"
      echo "$REPL" | while IFS='|' read -r addr state lag; do
        echo "    ${addr:-N/A}  状态=${state:-N/A}  延迟=${lag:-0} 字节"
      done
    else
      echo "  [INFO] 非主节点或无流复制备库连接"
    fi

    # 死锁与回滚统计
    DEADLOCKS=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Atqc \
      "SELECT sum(deadlocks) FROM pg_stat_database" 2>/dev/null)
    ROLLBACKS=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Atqc \
      "SELECT sum(xact_rollback) FROM pg_stat_database" 2>/dev/null)
    echo "  [INFO] 累计死锁数: ${DEADLOCKS:-0}  累计回滚数: ${ROLLBACKS:-0}"

    # 缓冲池命中率
    HIT_RATE=$(psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Atqc \
      "SELECT round(sum(blks_hit)::numeric / nullif(sum(blks_hit)+sum(blks_read),0) * 100, 2)
       FROM pg_stat_database" 2>/dev/null)
    if [ -n "$HIT_RATE" ]; then
      if (( $(echo "$HIT_RATE < 95" | bc -l 2>/dev/null || echo 0) )); then
        echo "  [WARN] 缓冲池命中率: ${HIT_RATE}%（<95%）"
      else
        echo "  [OK] 缓冲池命中率: ${HIT_RATE}%"
      fi
    fi

    # 数据库大小 TOP5
    echo "  [INFO] 数据库大小 TOP5："
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -c \
      "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
       FROM pg_database WHERE datistemplate=false
       ORDER BY pg_database_size(datname) DESC LIMIT 5;" 2>/dev/null | sed 's/^/    /'
  fi
  unset PGPASSWORD
fi

echo ""
echo "============================================================"
echo "============================================================"
echo "  巡检完成：$(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
