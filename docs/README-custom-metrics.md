# 커스텀 메트릭 수집 가이드

## 개요

기본 Exporter가 수집하지 않는 **DB 엔진 내부 심층 지표**를 ConfigMap 기반으로 쉽게 추가할 수 있는 아키텍처입니다.

```
커스텀 쿼리 YAML (ConfigMap)
  ↓ Volume Mount
Exporter Pod (기본 메트릭 + 커스텀 쿼리 자동 실행)
  ↓
ADOT Collector → AMP → Recording Rules → Grafana
```

## 아키텍처

### 각 Exporter의 커스텀 쿼리 메커니즘

| Exporter | 설정 방식 | 옵션 |
|---|---|---|
| **mysqld_exporter** | YAML 파일 (디렉토리) | `--collect.custom_query.hr.directory=<path>` |
| **postgres_exporter** | YAML 파일 | `--extend.query-path=<file>` |
| **sql_exporter** | Collector YAML | `--config.file=<config>` + collector_files |
| **redis_exporter** | Lua 스크립트 + 환경변수 | `--script=<file>`, `--check-keys=<patterns>` |

### 커스텀 메트릭 추가 방법 (3단계)

```bash
# 1. ConfigMap YAML 편집 (해당 엔진의 섹션에 쿼리 추가)
vim custom-metrics-configmap.yaml

# 2. ConfigMap 업데이트
kubectl apply -f custom-metrics-configmap.yaml -n observability

# 3. Exporter Pod 재시작 (ConfigMap 변경 반영)
kubectl rollout restart deployment -l app=mysql-exporter -n observability
```

## 📁 파일 구성

```
custom-metrics/
├── mysql-custom-queries.yaml         # MySQL 커스텀 쿼리 (상세 버전)
├── postgresql-custom-queries.yaml    # PostgreSQL 커스텀 쿼리 (상세 버전)
├── mssql-custom-collectors.yaml      # SQL Server 커스텀 Collector (상세 버전)
├── redis-custom-config.yaml          # Redis 설정 (환경변수 + 옵션)
├── redis-custom-scripts.lua          # Redis Lua 스크립트
├── custom-metrics-configmap.yaml     # ⭐ Kubernetes ConfigMap (배포용)
├── exporter-template-with-custom.yaml # Exporter 템플릿에 적용하는 예시
└── README-custom-metrics.md          # 이 파일
```

## 기본 제공 커스텀 메트릭

### Aurora MySQL / RDS MySQL

| 카테고리 | 메트릭 | 해상도 | 설명 |
|---|---|---|---|
| **Adaptive Hash Index** | innodb_adaptive_hash_searches | HR | AHI 히트 수 |
| | innodb_adaptive_hash_searches_btree | HR | B-tree 폴백 수 |
| **Redo Log** | innodb_log_waits | HR | 로그 버퍼 대기 |
| | innodb_log_write_requests | HR | 로그 쓰기 요청 |
| | innodb_os_log_pending_writes | HR | OS 대기 쓰기 |
| | innodb_log_checkpoint_age | HR | 체크포인트 Age |
| **Lock Wait** | mysql_lock_wait_count | HR | 락 대기 트랜잭션 수 |
| | mysql_lock_wait_max_seconds | HR | 최대 대기 시간 |
| | mysql_lock_type_distribution | HR | 락 유형별 분포 |
| **Buffer Pool** | innodb_buffer_pool_page_distribution | LR | 페이지 유형별 분포 |
| **Mutex** | innodb_rwlock_*_spin_waits | HR | RW-lock 경합 |
| **Undo** | innodb_undo_history_length | MR | Purge 대기 |

### Aurora PostgreSQL / RDS PostgreSQL

| 카테고리 | 메트릭 | 설명 |
|---|---|---|
| **pg_stat_slru** | blks_hit, blks_read, hit_ratio | SLRU 캐시별 적중률 |
| **pg_stat_io** | reads, writes, hits, evictions | 백엔드/오브젝트별 I/O |
| **pg_stat_wal** | wal_records, wal_bytes, sync_time | WAL 생성률 + sync 부하 |
| **Autovacuum** | progress, dead_tuples, phase | 진행 중인 VACUUM 상태 |
| **Autovacuum 대기열** | dead_tuples, dead_to_live_ratio | VACUUM 필요한 테이블 |
| **TOAST 팽창** | toast_size_bytes, toast_to_main_ratio | TOAST 비정상 증가 |
| **Long Query** | count, max_duration_seconds | 5분+ 장시간 쿼리 |
| **Table Bloat** | bloat_pct, dead_tuples | 테이블 팽창 추정 |

### RDS SQL Server

| 카테고리 | 메트릭 | 설명 |
|---|---|---|
| **Wait Stats** | wait_time_ms, signal_wait_ms | Wait Type별 대기 시간 |
| | wait_category | 카테고리별 분류 (Lock/IO/Latch/Network/CPU) |
| **TempDB** | space_usage_kb (user/internal/version_store) | TempDB 공간 사용량 |
| | contention_count, max_wait_ms | 페이지 래치 경합 |
| **Query Store** | top_duration_us, top_cpu_us | Top 쿼리 실행 시간 |
| | top_logical_reads, execution_count | Top 쿼리 I/O + 실행 횟수 |
| **Memory** | memory_clerks_kb | Memory Clerk별 사용량 |

### ElastiCache Redis / Valkey

| 카테고리 | 메트릭 | 설명 |
|---|---|---|
| **Slow Log** | slowlog_length, max_duration_us | Slow 명령 분석 |
| | slowlog_commands (by command) | 명령어별 Slow 빈도 |
| **Key Pattern** | key_count_by_pattern | 패턴별 키 수 |
| **TTL 분석** | keyspace_expires_ratio | TTL 설정 비율 |
| **Client** | clients_idle_long, clients_blocked | 유휴/블로킹 클라이언트 |
| **Memory** | memory_fragmentation_ratio | 메모리 단편화 |
| | allocator_frag_ratio | Allocator 단편화 |

## ⚠️ 주의사항

### DB 부하 영향

| 쿼리 | 부하 수준 | 권장 |
|---|---|---|
| information_schema.innodb_metrics | 낮음 | HR (30초) |
| information_schema.innodb_buffer_page | **높음** | LR (1시간), Reader에서만 |
| performance_schema.data_locks | 중간 | HR, 락 상황에 따라 |
| pg_stat_slru / pg_stat_wal | 낮음 | HR (30초) |
| pg_stat_progress_vacuum | 낮음 | HR (30초) |
| sys.dm_os_wait_stats | 낮음 | HR (30초) |
| sys.query_store_* | 중간 | MR (10분) |
| SLOWLOG GET | 낮음 | HR (30초) |
| SCAN (key pattern) | **중간~높음** | max_iterations 제한 필수 |

### DB 권한 설정

```sql
-- MySQL: 모니터링 전용 유저에 필요한 권한
GRANT SELECT ON information_schema.* TO 'monitoring'@'%';
GRANT SELECT ON performance_schema.* TO 'monitoring'@'%';
GRANT PROCESS ON *.* TO 'monitoring'@'%';

-- PostgreSQL: 모니터링 전용 유저에 필요한 권한
GRANT pg_monitor TO monitoring;
GRANT SELECT ON ALL TABLES IN SCHEMA pg_catalog TO monitoring;

-- SQL Server: 모니터링 전용 유저에 필요한 권한
GRANT VIEW SERVER STATE TO [monitoring];
GRANT VIEW DATABASE STATE TO [monitoring];
```

### 커스텀 쿼리 작성 규칙

1. **타임아웃**: 각 쿼리는 5초 이내에 완료되어야 함
2. **결과 수 제한**: `LIMIT` 사용 (무제한 결과 금지)
3. **라벨 카디널리티**: 라벨 값의 종류가 100개를 넘지 않도록 (AMP 비용)
4. **트랜잭션 격리**: 읽기 전용, 짧은 트랜잭션으로 실행
5. **테스트**: 실제 환경 적용 전에 수동으로 쿼리 실행 시간 확인

## 커스텀 메트릭 추가 예시

### 새로운 MySQL 메트릭 추가

```yaml
# custom-metrics-configmap.yaml의 mysql-custom-queries ConfigMap에 추가

  # 예: 커넥션 풀 상태 모니터링
  my_new_metric.yaml: |
    mysql_connection_pool_status:
      query: "SELECT variable_name, variable_value FROM performance_schema.global_status WHERE variable_name LIKE 'Threads%'"
      metrics:
        - variable_name:
            usage: "LABEL"
            description: "변수명"
        - variable_value:
            usage: "GAUGE"
            description: "값"
```

### 적용
```bash
kubectl apply -f custom-metrics-configmap.yaml -n observability
kubectl rollout restart deployment -l app=mysql-exporter -n observability
```

30초 후 새 메트릭이 수집되기 시작합니다.
