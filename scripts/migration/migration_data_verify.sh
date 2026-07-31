#!/bin/bash
# ============================================================
# 迁移数据一致性校验脚本
# 用途：迁移后对比源端与目标端数据，确认一致性
# 支持：MySQL 行数/校验和对比、PG 行数对比、文件级 rsync 校验
# 用法：bash migration_data_verify.sh --source <ip> --target <ip> \
#        --type mysql|pg|file --db <dbname> [--table <table>]
# ============================================================

set -euo pipefail

# ---------- 参数解析 ----------
SOURCE_IP=""
TARGET_IP=""
VERIFY_TYPE="mysql"
DB_NAME=""
TABLE_NAME=""
SOURCE_PORT="${SOURCE_PORT:-3306}"
TARGET_PORT="${TARGET_PORT:-3306}"
REPORT_FILE="/var/log/migration/data_verify_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$REPORT_FILE")"
VERIFY_PASSED=0
VERIFY_FAILED=0
VERIFY_WARNED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE_IP="$2"; shift 2;;
    --target) TARGET_IP="$2"; shift 2;;
    --type)   VERIFY_TYPE="$2"; shift 2;;
    --db)     DB_NAME="$2"; shift 2;;
    --table)  TABLE_NAME="$2"; shift 2;;
    *) echo "未知参数: $1"; exit 1;;
  esac
done

if [ -z "$SOURCE_IP" ] || [ -z "$TARGET_IP" ]; then
  echo "用法: $0 --source <源IP> --target <目标IP> --type mysql|pg|file [--db <库名>]"
  exit 1
fi

# ---------- 工具函数 ----------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$REPORT_FILE"; }
pass() { echo "  [✓ PASS] $1" | tee -a "$REPORT_FILE"; ((VERIFY_PASSED++)); }
fail() { echo "  [✗ FAIL] $1" | tee -a "$REPORT_FILE"; ((VERIFY_FAILED++)); }
warn() { echo "  [! WARN] $1" | tee -a "$REPORT_FILE"; ((VERIFY_WARNED++)); }

# ---------- 报告头 ----------
log "============================================================"
log "  迁移数据一致性校验报告"
log "  源端: $SOURCE_IP    目标端: $TARGET_IP"
log "  校验类型: $VERIFY_TYPE    数据库: ${DB_NAME:-N/A}"
log "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
log "============================================================"

# ============================================================
# MySQL 行数与校验和对比
# ============================================================
if [ "$VERIFY_TYPE" = "mysql" ]; then
  [ -z "$DB_NAME" ] && { log "ERROR: MySQL 校验需指定 --db"; exit 1; }

  log ""
  log "【MySQL 数据校验 - 库: $DB_NAME】"

  MYSQL_USER="${MYSQL_USER:-monitor}"

  # 获取源端表列表
  log "获取源端表列表..."
  TABLES=$(mysql -h"$SOURCE_IP" -P"$SOURCE_PORT" -u"$MYSQL_USER" -p"${MYSQL_PASS:-}" \
    -BN -e "SHOW TABLES FROM \`$DB_NAME\`" 2>/dev/null) || {
    fail "无法连接源端 MySQL 或库不存在"
    exit 1
  }

  TABLE_COUNT=$(echo "$TABLES" | wc -l)
  log "源端表数量: $TABLE_COUNT"

  # 逐表对比行数
  log ""
  log "--- 逐表行数对比 ---"
  MISMATCH_COUNT=0
  for TBL in $TABLES; do
    SRC_ROWS=$(mysql -h"$SOURCE_IP" -P"$SOURCE_PORT" -u"$MYSQL_USER" -p"${MYSQL_PASS:-}" \
      -BN -e "SELECT count(*) FROM \`$DB_NAME\`.\`$TBL\`" 2>/dev/null || echo -1)
    DST_ROWS=$(mysql -h"$TARGET_IP" -P"$TARGET_PORT" -u"$MYSQL_USER" -p"${MYSQL_PASS:-}" \
      -BN -e "SELECT count(*) FROM \`$DB_NAME\`.\`$TBL\`" 2>/dev/null || echo -1)

    if [ "$SRC_ROWS" = "$DST_ROWS" ]; then
      printf "  [✓] %-40s 源=%-12s 目标=%-12s\n" "$TBL" "$SRC_ROWS" "$DST_ROWS" | tee -a "$REPORT_FILE"
    else
      printf "  [✗] %-40s 源=%-12s 目标=%-12s  ← 不一致!\n" "$TBL" "$SRC_ROWS" "$DST_ROWS" | tee -a "$REPORT_FILE"
      ((MISMATCH_COUNT++))
    fi
  done

  if [ "$MISMATCH_COUNT" -eq 0 ]; then
    pass "全部 ${TABLE_COUNT} 张表行数一致"
  else
    fail "${MISMATCH_COUNT}/${TABLE_COUNT} 张表行数不一致"
  fi

  # 校验和对比（对指定表或小表抽样）
  log ""
  log "--- 校验和对比（CRC32，抽样大表以外）---"
  if [ -n "$TABLE_NAME" ]; then
    SRC_CRC=$(mysql -h"$SOURCE_IP" -P"$SOURCE_PORT" -u"$MYSQL_USER" -p"${MYSQL_PASS:-}" \
      -BN -e "SELECT COALESCE(SUM(CRC32(CONCAT_WS('#', *))),0) FROM \`$DB_NAME\`.\`$TABLE_NAME\`" 2>/dev/null || echo 0)
    DST_CRC=$(mysql -h"$TARGET_IP" -P"$TARGET_PORT" -u"$MYSQL_USER" -p"${MYSQL_PASS:-}" \
      -BN -e "SELECT COALESCE(SUM(CRC32(CONCAT_WS('#', *))),0) FROM \`$DB_NAME\`.\`$TABLE_NAME\`" 2>/dev/null || echo 0)
    if [ "$SRC_CRC" = "$DST_CRC" ]; then
      pass "表 $TABLE_NAME 校验和一致: $SRC_CRC"
    else
      fail "表 $TABLE_NAME 校验和不一致: 源=$SRC_CRC 目标=$DST_CRC"
    fi
  else
    warn "未指定 --table，跳过校验和对比（大表 CRC32 计算耗时长）"
  fi

# ============================================================
# PostgreSQL 行数对比
# ============================================================
elif [ "$VERIFY_TYPE" = "pg" ]; then
  [ -z "$DB_NAME" ] && { log "ERROR: PG 校验需指定 --db"; exit 1; }

  log ""
  log "【PostgreSQL 数据校验 - 库: $DB_NAME】"

  PG_USER="${PG_USER:-monitor}"
  export PGPASSWORD="${PG_PASS:-}"
  PG_SOURCE_PORT="${PG_SOURCE_PORT:-5432}"
  PG_TARGET_PORT="${PG_TARGET_PORT:-5432}"

  # 获取表列表
  log "获取源端表列表..."
  TABLES=$(psql -h"$SOURCE_IP" -p"$PG_SOURCE_PORT" -U"$PG_USER" -d"$DB_NAME" -Atqc \
    "SELECT tablename FROM pg_tables WHERE schemaname='public'" 2>/dev/null) || {
    fail "无法连接源端 PG 或库不存在"
    unset PGPASSWORD
    exit 1
  }

  TABLE_COUNT=$(echo "$TABLES" | wc -l)
  log "源端表数量: $TABLE_COUNT"

  # 逐表对比行数
  log ""
  log "--- 逐表行数对比 ---"
  MISMATCH_COUNT=0
  for TBL in $TABLES; do
    SRC_ROWS=$(psql -h"$SOURCE_IP" -p"$PG_SOURCE_PORT" -U"$PG_USER" -d"$DB_NAME" -Atqc \
      "SELECT count(*) FROM public.\"$TBL\"" 2>/dev/null || echo -1)
    DST_ROWS=$(psql -h"$TARGET_IP" -p"$PG_TARGET_PORT" -U"$PG_USER" -d"$DB_NAME" -Atqc \
      "SELECT count(*) FROM public.\"$TBL\"" 2>/dev/null || echo -1)

    if [ "$SRC_ROWS" = "$DST_ROWS" ]; then
      printf "  [✓] %-40s 源=%-12s 目标=%-12s\n" "$TBL" "$SRC_ROWS" "$DST_ROWS" | tee -a "$REPORT_FILE"
    else
      printf "  [✗] %-40s 源=%-12s 目标=%-12s  ← 不一致!\n" "$TBL" "$SRC_ROWS" "$DST_ROWS" | tee -a "$REPORT_FILE"
      ((MISMATCH_COUNT++))
    fi
  done

  if [ "$MISMATCH_COUNT" -eq 0 ]; then
    pass "全部 ${TABLE_COUNT} 张表行数一致"
  else
    fail "${MISMATCH_COUNT}/${TABLE_COUNT} 张表行数不一致"
  fi

  # 序列最大值对比（防止迁移后序列溢出）
  log ""
  log "--- 序列最大值检查 ---"
  SEQS=$(psql -h"$SOURCE_IP" -p"$PG_SOURCE_PORT" -U"$PG_USER" -d"$DB_NAME" -Atqc \
    "SELECT sequence_name FROM information_schema.sequences WHERE sequence_schema='public'" 2>/dev/null || echo "")
  for SEQ in $SEQS; do
    SRC_LAST=$(psql -h"$SOURCE_IP" -p"$PG_SOURCE_PORT" -U"$PG_USER" -d"$DB_NAME" -Atqc \
      "SELECT last_value FROM public.\"$SEQ\"" 2>/dev/null || echo 0)
    DST_LAST=$(psql -h"$TARGET_IP" -p"$PG_TARGET_PORT" -U"$PG_USER" -d"$DB_NAME" -Atqc \
      "SELECT last_value FROM public.\"$SEQ\"" 2>/dev/null || echo 0)
    if [ "$SRC_LAST" -le "$DST_LAST" ]; then
      printf "  [✓] %-40s 源=%-12s 目标=%-12s\n" "$SEQ" "$SRC_LAST" "$DST_LAST" | tee -a "$REPORT_FILE"
    else
      printf "  [!] %-40s 源=%-12s 目标=%-12s  ← 目标序列偏小!\n" "$SEQ" "$SRC_LAST" "$DST_LAST" | tee -a "$REPORT_FILE"
      warn "序列 $SEQ 目标端值偏小，需 setval 修正"
    fi
  done
  unset PGPASSWORD

# ============================================================
# 文件级 rsync 校验（Web 静态资源等）
# ============================================================
elif [ "$VERIFY_TYPE" = "file" ]; then
  FILE_PATH="${FILE_PATH:-/var/www}"
  log ""
  log "【文件级一致性校验 - 路径: $FILE_PATH】"

  # 源端文件数与总大小
  log "统计源端文件..."
  SRC_SUMMARY=$(ssh -o StrictHostKeyChecking=no "ops@$SOURCE_IP" \
    "find '$FILE_PATH' -type f | wc -l; du -sb '$FILE_PATH' | cut -f1" 2>/dev/null || echo "0 0")
  SRC_FILES=$(echo "$SRC_SUMMARY" | head -1)
  SRC_SIZE=$(echo "$SRC_SUMMARY" | tail -1)

  # 目标端文件数与总大小
  log "统计目标端文件..."
  DST_SUMMARY=$(ssh -o StrictHostKeyChecking=no "ops@$TARGET_IP" \
    "find '$FILE_PATH' -type f | wc -l; du -sb '$FILE_PATH' | cut -f1" 2>/dev/null || echo "0 0")
  DST_FILES=$(echo "$DST_SUMMARY" | head -1)
  DST_SIZE=$(echo "$DST_SUMMARY" | tail -1)

  log "源端: ${SRC_FILES} 文件, $(numfmt --to=iec "$SRC_SIZE" 2>/dev/null || echo "$SRC_SIZE")"
  log "目标: ${DST_FILES} 文件, $(numfmt --to=iec "$DST_SIZE" 2>/dev/null || echo "$DST_SIZE")"

  if [ "$SRC_FILES" = "$DST_FILES" ]; then
    pass "文件数量一致: ${SRC_FILES}"
  else
    fail "文件数量不一致: 源=${SRC_FILES} 目标=${DST_FILES}"
  fi

  if [ "$SRC_SIZE" = "$DST_SIZE" ]; then
    pass "总大小一致: $(numfmt --to=iec "$SRC_SIZE" 2>/dev/null || echo "$SRC_SIZE")"
  else
    warn "总大小有差异: 源=$(numfmt --to=iec "$SRC_SIZE" 2>/dev/null || echo "$SRC_SIZE") 目标=$(numfmt --to=iec "$DST_SIZE" 2>/dev/null || echo "$DST_SIZE")"
  fi

  # rsync dry-run 差异检查
  log ""
  log "--- rsync dry-run 差异检查 ---"
  DIFF_COUNT=$(rsync -an --stats "ops@$SOURCE_IP:$FILE_PATH/" "ops@$TARGET_IP:$FILE_PATH/" 2>/dev/null \
    | grep -c '^[^ ]' || echo 0)
  if [ "$DIFF_COUNT" -le 2 ]; then
    pass "rsync 无差异文件"
  else
    warn "rsync 发现 ${DIFF_COUNT} 个差异项，请检查"
  fi

else
  log "ERROR: 不支持的校验类型 $VERIFY_TYPE（支持 mysql/pg/file）"
  exit 1
fi

# ============================================================
# 汇总
# ============================================================
log ""
log "============================================================"
log "  校验汇总: ${VERIFY_PASSED} 通过, ${VERIFY_WARNED} 警告, ${VERIFY_FAILED} 失败"
if [ "$VERIFY_FAILED" -gt 0 ]; then
  log "  结论: ❌ 存在不一致项，禁止切换流量"
  log "============================================================"
  exit 1
elif [ "$VERIFY_WARNED" -gt 0 ]; then
  log "  结论: ⚠️ 存在警告项，请人工确认后再切换"
  log "============================================================"
  exit 0
else
  log "  结论: ✅ 数据一致性校验通过，可以切换流量"
  log "============================================================"
  exit 0
fi
