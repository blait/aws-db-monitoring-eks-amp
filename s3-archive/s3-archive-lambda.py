"""
=============================================================================
AMP 메트릭 S3 아카이브 Lambda 함수
=============================================================================
AMP(Amazon Managed Prometheus)에서 메트릭을 조회하여 S3에 Parquet 형식으로
저장합니다. EventBridge Rule에 의해 매일 실행됩니다.

아키텍처:
  AMP (150일 Hot) → Lambda (매일) → S3 (Parquet) → Glacier (Lifecycle)

S3 경로 구조:
  s3://{bucket}/metrics/engine={engine}/year={YYYY}/month={MM}/day={DD}/data.parquet

비용:
  - Lambda: ~$0.05/일 (256MB, 5분 실행)
  - S3 Standard: $0.023/GB/월
  - S3 → Glacier: 자동 전환 (Lifecycle Policy)

환경변수:
  - AMP_WORKSPACE_ID: AMP 워크스페이스 ID
  - BUCKET_NAME: 아카이브 S3 버킷 이름
  - AWS_REGION: AWS 리전
  - RETENTION_EXPORT_DAYS: 내보내기 대상 일수 (기본: 1, 전날 데이터)
=============================================================================
"""

import os
import json
import boto3
import logging
from datetime import datetime, timedelta, timezone
from urllib.parse import quote
import io

# AWS SDK SigV4 서명을 위한 import
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials
import urllib.request

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ─────────────────────────────────────────────────────────────────────────────
# 설정
# ─────────────────────────────────────────────────────────────────────────────
AMP_WORKSPACE_ID = os.environ.get('AMP_WORKSPACE_ID')
BUCKET_NAME = os.environ.get('BUCKET_NAME')
AWS_REGION = os.environ.get('AWS_REGION', 'ap-northeast-2')
RETENTION_EXPORT_DAYS = int(os.environ.get('RETENTION_EXPORT_DAYS', '1'))

# 엔진별 수집 대상 메트릭 쿼리
ENGINE_QUERIES = {
    'mysql': [
        # Recording Rule 메트릭 (db: 접두사)
        'db:mysql_connections:by_instance',
        'db:mysql_qps:by_instance',
        'db:mysql_buffer_pool_hit_ratio:by_instance',
        'db:mysql_slow_queries_rate:by_instance',
        'db:mysql_replication_lag:by_instance',
        'db:mysql_threads_running:by_instance',
        # Raw 메트릭 (상세 분석용)
        'mysql_global_status_threads_connected',
        'mysql_global_status_innodb_buffer_pool_pages_total',
        'mysql_global_status_innodb_buffer_pool_pages_free',
    ],
    'postgresql': [
        'db:pg_active_connections:by_instance',
        'db:pg_tps:by_instance',
        'db:pg_cache_hit_ratio:by_instance',
        'db:pg_dead_tuples:by_instance',
        'db:pg_replication_lag_bytes:by_instance',
        'db:pg_wal_rate:by_instance',
        'pg_stat_database_numbackends',
        'pg_stat_database_xact_commit',
    ],
    'mssql': [
        'db:mssql_connections:by_instance',
        'db:mssql_batch_requests_rate:by_instance',
        'db:mssql_buffer_cache_hit_ratio:by_instance',
        'db:mssql_page_life_expectancy:by_instance',
    ],
    'redis': [
        'db:redis_connected_clients:by_instance',
        'db:redis_memory_used_bytes:by_instance',
        'db:redis_hit_ratio:by_instance',
        'db:redis_ops_per_sec:by_instance',
        'db:redis_evicted_keys_rate:by_instance',
    ],
    'dynamodb': [
        'db:dynamodb_consumed_rcu:by_table',
        'db:dynamodb_consumed_wcu:by_table',
        'db:dynamodb_rcu_utilization:by_table',
        'db:dynamodb_wcu_utilization:by_table',
        'db:dynamodb_read_throttle_events:by_table',
        'db:dynamodb_write_throttle_events:by_table',
        'db:dynamodb_latency_avg:by_table',
        'db:dynamodb_latency_p99:by_table',
        'db:dynamodb_system_errors:by_table',
    ],
}


# ─────────────────────────────────────────────────────────────────────────────
# AMP Query API 호출 (SigV4 서명)
# ─────────────────────────────────────────────────────────────────────────────
def query_amp_range(query: str, start_time: datetime, end_time: datetime, step: str = '60s') -> dict:
    """
    AMP의 query_range API를 호출하여 시계열 데이터를 가져옵니다.
    
    Args:
        query: PromQL 쿼리
        start_time: 시작 시간 (UTC)
        end_time: 종료 시간 (UTC)
        step: 데이터 포인트 간격 (기본: 60초)
    
    Returns:
        Prometheus API 응답 (dict)
    """
    endpoint = f"https://aps-workspaces.{AWS_REGION}.amazonaws.com"
    path = f"/workspaces/{AMP_WORKSPACE_ID}/api/v1/query_range"
    
    params = {
        'query': query,
        'start': start_time.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'end': end_time.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'step': step,
    }
    
    # URL 구성
    query_string = '&'.join(f"{k}={quote(str(v))}" for k, v in params.items())
    url = f"{endpoint}{path}?{query_string}"
    
    # SigV4 서명
    session = boto3.Session()
    credentials = session.get_credentials().get_frozen_credentials()
    
    request = AWSRequest(method='GET', url=url)
    SigV4Auth(credentials, 'aps', AWS_REGION).add_auth(request)
    
    # HTTP 요청
    req = urllib.request.Request(
        url=url,
        headers=dict(request.headers),
        method='GET'
    )
    
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.loads(response.read().decode('utf-8'))
    except Exception as e:
        logger.error(f"AMP 쿼리 실패: {query} - {e}")
        return {'status': 'error', 'data': {'result': []}}


# ─────────────────────────────────────────────────────────────────────────────
# 메트릭 데이터를 Parquet 형식으로 변환
# ─────────────────────────────────────────────────────────────────────────────
def convert_to_parquet(results: list, engine: str, date_str: str) -> bytes:
    """
    Prometheus 쿼리 결과를 Parquet 바이트로 변환합니다.
    
    Parquet 스키마:
      - timestamp (int64): Unix timestamp
      - metric_name (string): 메트릭 이름
      - value (float64): 메트릭 값
      - labels (string): JSON 형식의 라벨
      - db_instance (string): DB 인스턴스/테이블 이름
      - engine (string): DB 엔진 유형
    """
    import pyarrow as pa
    import pyarrow.parquet as pq
    
    timestamps = []
    metric_names = []
    values = []
    labels_list = []
    db_instances = []
    engines = []
    
    for result in results:
        metric_name = result.get('metric_name', 'unknown')
        metric_labels = result.get('metric', {})
        db_instance = (
            metric_labels.get('db_instance', '') or 
            metric_labels.get('TableName', '') or 
            'unknown'
        )
        
        for timestamp, value in result.get('values', []):
            timestamps.append(int(float(timestamp)))
            metric_names.append(metric_name)
            try:
                values.append(float(value))
            except (ValueError, TypeError):
                values.append(0.0)
            labels_list.append(json.dumps(metric_labels, ensure_ascii=False))
            db_instances.append(db_instance)
            engines.append(engine)
    
    if not timestamps:
        return None
    
    # PyArrow Table 생성
    table = pa.table({
        'timestamp': pa.array(timestamps, type=pa.int64()),
        'metric_name': pa.array(metric_names, type=pa.string()),
        'value': pa.array(values, type=pa.float64()),
        'labels': pa.array(labels_list, type=pa.string()),
        'db_instance': pa.array(db_instances, type=pa.string()),
        'engine': pa.array(engines, type=pa.string()),
    })
    
    # Parquet으로 직렬화
    buffer = io.BytesIO()
    pq.write_table(table, buffer, compression='snappy')
    return buffer.getvalue()


# ─────────────────────────────────────────────────────────────────────────────
# S3 업로드
# ─────────────────────────────────────────────────────────────────────────────
def upload_to_s3(data: bytes, engine: str, date: datetime):
    """
    Parquet 데이터를 S3에 업로드합니다.
    
    경로: s3://{bucket}/metrics/engine={engine}/year={YYYY}/month={MM}/day={DD}/data.parquet
    """
    s3 = boto3.client('s3', region_name=AWS_REGION)
    
    key = (
        f"metrics/"
        f"engine={engine}/"
        f"year={date.strftime('%Y')}/"
        f"month={date.strftime('%m')}/"
        f"day={date.strftime('%d')}/"
        f"data.parquet"
    )
    
    s3.put_object(
        Bucket=BUCKET_NAME,
        Key=key,
        Body=data,
        ContentType='application/x-parquet',
        Metadata={
            'engine': engine,
            'date': date.strftime('%Y-%m-%d'),
            'exported_at': datetime.now(timezone.utc).isoformat(),
        }
    )
    
    logger.info(f"✅ S3 업로드 완료: s3://{BUCKET_NAME}/{key} ({len(data)} bytes)")
    return key


# ─────────────────────────────────────────────────────────────────────────────
# Lambda 핸들러
# ─────────────────────────────────────────────────────────────────────────────
def lambda_handler(event, context):
    """
    EventBridge에 의해 매일 실행됩니다.
    전날 24시간의 메트릭을 엔진별로 S3에 아카이브합니다.
    """
    logger.info("=" * 60)
    logger.info("AMP 메트릭 S3 아카이브 시작")
    logger.info(f"  Workspace: {AMP_WORKSPACE_ID}")
    logger.info(f"  Bucket: {BUCKET_NAME}")
    logger.info(f"  Region: {AWS_REGION}")
    logger.info("=" * 60)
    
    # 대상 날짜 계산 (전날)
    now = datetime.now(timezone.utc)
    target_date = now - timedelta(days=RETENTION_EXPORT_DAYS)
    start_time = target_date.replace(hour=0, minute=0, second=0, microsecond=0)
    end_time = start_time + timedelta(days=1)
    
    logger.info(f"대상 기간: {start_time.isoformat()} ~ {end_time.isoformat()}")
    
    results_summary = {}
    
    for engine, queries in ENGINE_QUERIES.items():
        logger.info(f"\n{'─' * 40}")
        logger.info(f"엔진: {engine} ({len(queries)}개 메트릭)")
        logger.info(f"{'─' * 40}")
        
        all_results = []
        
        for query in queries:
            logger.info(f"  쿼리: {query}")
            
            response = query_amp_range(
                query=query,
                start_time=start_time,
                end_time=end_time,
                step='60s'  # 1분 간격
            )
            
            if response.get('status') == 'success':
                result_data = response.get('data', {}).get('result', [])
                for series in result_data:
                    all_results.append({
                        'metric_name': query,
                        'metric': series.get('metric', {}),
                        'values': series.get('values', []),
                    })
                logger.info(f"    → {len(result_data)}개 시계열, "
                          f"{sum(len(s.get('values', [])) for s in result_data)}개 데이터포인트")
            else:
                logger.warning(f"    → 쿼리 실패: {response.get('error', 'unknown')}")
        
        # Parquet 변환 및 S3 업로드
        if all_results:
            total_points = sum(len(r.get('values', [])) for r in all_results)
            logger.info(f"\n  총 {len(all_results)}개 시계열, {total_points}개 데이터포인트")
            
            parquet_data = convert_to_parquet(all_results, engine, target_date.strftime('%Y-%m-%d'))
            
            if parquet_data:
                s3_key = upload_to_s3(parquet_data, engine, target_date)
                results_summary[engine] = {
                    'series_count': len(all_results),
                    'data_points': total_points,
                    'parquet_size_bytes': len(parquet_data),
                    's3_key': s3_key,
                }
            else:
                logger.warning(f"  {engine}: 데이터 없음, S3 업로드 스킵")
                results_summary[engine] = {'series_count': 0, 'data_points': 0}
        else:
            logger.warning(f"  {engine}: 쿼리 결과 없음")
            results_summary[engine] = {'series_count': 0, 'data_points': 0}
    
    # 결과 요약
    logger.info("\n" + "=" * 60)
    logger.info("아카이브 완료 요약")
    logger.info("=" * 60)
    for engine, summary in results_summary.items():
        logger.info(f"  {engine}: {summary.get('data_points', 0)} 포인트, "
                   f"{summary.get('parquet_size_bytes', 0)} bytes")
    
    return {
        'statusCode': 200,
        'body': {
            'message': 'AMP 메트릭 아카이브 완료',
            'target_date': target_date.strftime('%Y-%m-%d'),
            'engines': results_summary,
        }
    }
