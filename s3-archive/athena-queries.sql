-- =============================================================================
-- Athena 쿼리 모음 — S3에 아카이브된 AMP 메트릭 조회
-- =============================================================================
-- 
-- S3에 Parquet 형식으로 저장된 과거 메트릭 데이터를 Athena로 조회합니다.
-- AMP의 150일 보존 기간이 지난 데이터도 Athena로 분석 가능합니다.
--
-- 사전 조건:
--   1. Glue Database 생성
--   2. Glue Table 생성 (아래 DDL 참조)
--   3. S3 버킷에 데이터 존재
--
-- 💰 비용:
--   - Athena 쿼리: $5/TB 스캔
--   - Parquet + 파티션 활용 시 스캔량 최소화 (보통 수 MB → $0.01 미만)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Glue Database 생성
-- ─────────────────────────────────────────────────────────────────────────────
CREATE DATABASE IF NOT EXISTS db_monitoring
COMMENT 'AWS DB 통합 모니터링 메트릭 아카이브';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Glue Table 생성 (Parquet, 파티션: engine/year/month/day)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE EXTERNAL TABLE IF NOT EXISTS db_monitoring.metrics_archive (
    timestamp      BIGINT       COMMENT 'Unix timestamp (초)',
    metric_name    STRING       COMMENT '메트릭 이름 (예: db:mysql_qps:by_instance)',
    value          DOUBLE       COMMENT '메트릭 값',
    labels         STRING       COMMENT 'JSON 형식의 전체 라벨',
    db_instance    STRING       COMMENT 'DB 인스턴스 또는 테이블 이름',
    engine         STRING       COMMENT 'DB 엔진 (mysql, postgresql, mssql, redis, dynamodb)'
)
PARTITIONED BY (
    `engine_partition` STRING,
    `year`             STRING,
    `month`            STRING,
    `day`              STRING
)
STORED AS PARQUET
LOCATION 's3://${BUCKET_NAME}/metrics/'
TBLPROPERTIES (
    'parquet.compression' = 'SNAPPY',
    'projection.enabled' = 'true',
    'projection.engine_partition.type' = 'enum',
    'projection.engine_partition.values' = 'mysql,postgresql,mssql,redis,dynamodb',
    'projection.year.type' = 'integer',
    'projection.year.range' = '2024,2030',
    'projection.month.type' = 'integer',
    'projection.month.range' = '1,12',
    'projection.month.digits' = '2',
    'projection.day.type' = 'integer',
    'projection.day.range' = '1,31',
    'projection.day.digits' = '2',
    'storage.location.template' = 's3://${BUCKET_NAME}/metrics/engine=${engine_partition}/year=${year}/month=${month}/day=${day}/'
);

-- 파티션 자동 인식 (Projection 사용 시 불필요, 수동 복구용)
-- MSCK REPAIR TABLE db_monitoring.metrics_archive;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. 기본 조회 쿼리
-- ─────────────────────────────────────────────────────────────────────────────

-- 특정 DB 인스턴스의 최근 7일 QPS 추이
SELECT 
    from_unixtime(timestamp) AS time_kst,
    metric_name,
    value,
    db_instance
FROM db_monitoring.metrics_archive
WHERE engine_partition = 'mysql'
  AND year = '2026'
  AND month = '08'
  AND day BETWEEN '13' AND '20'
  AND db_instance = 'my-aurora-writer'
  AND metric_name = 'db:mysql_qps:by_instance'
ORDER BY timestamp;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 일별 평균/최대값 요약 (월간 리포트용)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 
    engine_partition AS engine,
    db_instance,
    metric_name,
    year || '-' || month || '-' || day AS date,
    AVG(value) AS avg_value,
    MAX(value) AS max_value,
    MIN(value) AS min_value,
    COUNT(*) AS data_points
FROM db_monitoring.metrics_archive
WHERE year = '2026'
  AND month = '08'
GROUP BY engine_partition, db_instance, metric_name, year, month, day
ORDER BY date, engine, db_instance, metric_name;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. DynamoDB 스로틀 이벤트 분석
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 
    from_unixtime(timestamp) AS time,
    db_instance AS table_name,
    metric_name,
    value AS throttle_count
FROM db_monitoring.metrics_archive
WHERE engine_partition = 'dynamodb'
  AND metric_name IN (
      'db:dynamodb_read_throttle_events:by_table',
      'db:dynamodb_write_throttle_events:by_table'
  )
  AND value > 0
  AND year = '2026'
  AND month = '08'
ORDER BY timestamp DESC
LIMIT 100;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. 특정 장애 시점 전후 메트릭 조회 (인시던트 분석)
-- ─────────────────────────────────────────────────────────────────────────────
-- 예: 2026-08-15 14:00~16:00 (KST) 장애 시점
SELECT 
    from_unixtime(timestamp) AS time,
    engine,
    db_instance,
    metric_name,
    value
FROM db_monitoring.metrics_archive
WHERE year = '2026' AND month = '08' AND day = '15'
  AND timestamp BETWEEN 1723690800 AND 1723698000  -- UTC 05:00~07:00
  AND db_instance = 'my-aurora-writer'
ORDER BY timestamp, metric_name;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. 엔진별 월간 데이터 저장량 확인 (비용 모니터링)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 
    engine_partition AS engine,
    year || '-' || month AS month,
    COUNT(*) AS total_data_points,
    COUNT(DISTINCT db_instance) AS unique_instances,
    COUNT(DISTINCT metric_name) AS unique_metrics
FROM db_monitoring.metrics_archive
WHERE year = '2026'
GROUP BY engine_partition, year, month
ORDER BY month, engine;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. 장기 트렌드 분석 (주간 평균 비교)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 
    db_instance,
    metric_name,
    date_trunc('week', from_unixtime(timestamp)) AS week_start,
    AVG(value) AS weekly_avg,
    MAX(value) AS weekly_max,
    APPROX_PERCENTILE(value, 0.95) AS weekly_p95
FROM db_monitoring.metrics_archive
WHERE engine_partition = 'postgresql'
  AND metric_name = 'db:pg_tps:by_instance'
  AND year = '2026'
GROUP BY db_instance, metric_name, date_trunc('week', from_unixtime(timestamp))
ORDER BY week_start;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. Replication Lag 이력 (SLA 보고서용)
-- ─────────────────────────────────────────────────────────────────────────────
SELECT 
    db_instance,
    year || '-' || month AS month,
    -- SLA: Replication Lag > 30초인 비율
    COUNT(CASE WHEN value > 30 THEN 1 END) * 100.0 / COUNT(*) AS pct_above_30s,
    COUNT(CASE WHEN value > 60 THEN 1 END) * 100.0 / COUNT(*) AS pct_above_60s,
    MAX(value) AS max_lag_seconds,
    AVG(value) AS avg_lag_seconds
FROM db_monitoring.metrics_archive
WHERE metric_name = 'db:mysql_replication_lag:by_instance'
  AND year = '2026'
GROUP BY db_instance, year, month
ORDER BY month, db_instance;
