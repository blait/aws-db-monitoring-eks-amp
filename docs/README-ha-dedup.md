# Exporter HA Active-Active + AMP Recording Rules 중복 제거

## 🎯 목표

| 요구사항 | 해결 방법 |
|---|---|
| Exporter Pod HA (빵꾸 없음) | replicas: 2, 둘 다 동시에 수집 |
| Grafana에서 이중 차트 없음 | AMP Recording Rules에서 `max without(pod)` |
| 전환 시 이상 수치 없음 | rate()를 Pod별로 먼저 계산 → max |
| AMP/Grafana 비용 최소화 | 불필요한 메트릭 drop + pre-aggregation |

## 📐 아키텍처

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        DB 서버 (Aurora MySQL 등)                         │
└──────────────────────┬────────────────────────┬─────────────────────────┘
                       │                        │
              ┌────────▼────────┐      ┌────────▼────────┐
              │ Exporter Pod A  │      │ Exporter Pod B  │
              │ (Node 1 / AZ-a)│      │ (Node 2 / AZ-c)│
              │ 동시 수집 중     │      │ 동시 수집 중     │
              └────────┬────────┘      └────────┬────────┘
                       │                        │
              ┌────────▼────────────────────────▼────────┐
              │          ADOT Collector (HA: 2개)          │
              │  Target Allocator: consistent-hashing    │
              │                                          │
              │  metric_relabel_configs:                  │
              │    - drop: go_*, process_*, promhttp_*   │
              │    - labeldrop: instance, job            │
              │    - 유지: pod, db_instance, db_engine   │
              └──────────────────┬───────────────────────┘
                                 │
              ┌──────────────────▼───────────────────────┐
              │      Amazon Managed Prometheus (AMP)       │
              │                                           │
              │  저장: Raw 메트릭 (Pod A + Pod B 각각)     │
              │  ┌─────────────────────────────────────┐  │
              │  │  Recording Rules (30초 간격 실행)     │  │
              │  │                                     │  │
              │  │  Gauge:                             │  │
              │  │    db:mysql_threads_connected =     │  │
              │  │    max without(pod) (원본)          │  │
              │  │                                     │  │
              │  │  Rate/Counter:                      │  │
              │  │    db:mysql_qps =                   │  │
              │  │    max without(pod) (rate(...[5m])) │  │
              │  └─────────────────────────────────────┘  │
              └──────────────────┬───────────────────────┘
                                 │
              ┌──────────────────▼───────────────────────┐
              │      Amazon Managed Grafana (AMG)          │
              │                                           │
              │  대시보드: db: 접두사 메트릭만 사용         │
              │  → 항상 DB 인스턴스당 1개 라인            │
              │  → Pod A/B 구분 없음                      │
              │  → 빵꾸 없음 (하나라도 살아있으면 값 존재) │
              └───────────────────────────────────────────┘
```

## 💰 비용 분석

### Before (replicas:1, 비용 최적화 없음)

| 항목 | 시계열 수 (DB 10개 기준) | 월 비용 |
|---|---|---|
| Raw 메트릭 | ~3,000 (go_, process_ 포함) | $45 |
| Grafana 쿼리 | 직접 raw 쿼리 | 쿼리 비용 높음 |
| **합계** | | **~$50/월** |

### After (replicas:2, 비용 최적화 적용)

| 항목 | 시계열 수 (DB 10개 기준) | 월 비용 |
|---|---|---|
| Raw 메트릭 (drop 후) | ~2,400 (×2 Pod = 4,800, 하지만 go/process drop) | $36 |
| Recording Rule 결과 | ~600 (db: 접두사) | $9 |
| Grafana 쿼리 | pre-aggregated 메트릭만 → 쿼리 비용 낮음 | 절약 |
| **합계** | | **~$48/월** |

### 비용 차이

```
HA 추가 비용: +$48 - $50 = 거의 동일! (-$2)

이유:
- Exporter 2배 → Raw 시계열 2배... 이지만
- go_*, process_*, promhttp_* drop → 원본 대비 40% 시계열 감소
- 결과: 2배 × 0.6 = 1.2배 수준
- EKS Pod 추가 비용: ~$5/월 (50m CPU × 10 DB × 2 replica)
```

**결론: HA 구성해도 AMP 비용 거의 증가 없음 (불필요 메트릭 drop 효과)**

## 📁 파일 구성

```
ha-config/
├── exporter-ha-deployment-template.yaml   # Exporter HA Deployment 템플릿
├── adot-collector-ha-dedup.yaml           # ADOT Collector (비용 최적화 relabel)
├── amp-recording-rules-ha.yaml            # AMP Recording Rules (dedup + alert)
├── grafana-dashboard-ha.json              # Grafana 대시보드 (db: 메트릭 사용)
├── db-discovery-ha-patch.sh               # Discovery 스크립트 HA 패치
└── README-ha-dedup.md                     # 이 파일
```

## 🚀 배포 순서

### Step 1: ADOT Collector 배포 (비용 최적화 + HA)
```bash
# 기존 ADOT Collector 제거
kubectl delete -n observability opentelemetrycollector adot-collector

# HA + 비용 최적화 버전 배포
kubectl apply -f ha-config/adot-collector-ha-dedup.yaml
```

### Step 2: AMP Recording Rules 등록
```bash
aws amp create-rule-groups-namespace \
  --workspace-id $AMP_WORKSPACE_ID \
  --name "db-monitoring-ha-rules" \
  --data fileb://ha-config/amp-recording-rules-ha.yaml
```

### Step 3: Discovery 스크립트 HA 패치 적용
```bash
# 기존 deploy_exporter 함수를 HA 버전으로 교체
# db-discovery-updated.sh에서:
source ./ha-config/db-discovery-ha-patch.sh
# 이후 deploy_exporter_ha() 사용
```

### Step 4: 기존 Exporter를 HA로 재배포
```bash
# Discovery를 수동 실행하면 기존 exporter가 replicas:2로 업데이트됨
kubectl create job --from=cronjob/db-discovery db-discovery-ha-upgrade -n observability
```

### Step 5: Grafana 대시보드 Import
```bash
# AMG API를 통해 대시보드 import
curl -X POST \
  -H "Authorization: Bearer $GRAFANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d @ha-config/grafana-dashboard-ha.json \
  "${GRAFANA_URL}/api/dashboards/db"
```

## ❓ FAQ

### Q: 두 Pod의 수집 시점이 미묘하게 다르면 max 값이 이상하지 않나?

**A:** 실질적으로 문제 없습니다.

- ADOT Collector가 30초 간격으로 scrape
- 2개 Pod에 대한 scrape 시점 차이: 수 밀리초~수 초
- Gauge 메트릭 (connections 등): 순간값이므로 max 차이 미미
- Rate 메트릭: 5분 window에 대한 평균이므로 수 초 차이 무시 가능
- `max without(pod)`: 같은 timestamp에 2개 값이 있으면 큰 쪽 선택, 실질적으로 거의 동일한 값

### Q: rate() 전환 시 스파이크가 발생하지 않나?

**A:** 발생하지 않습니다.

```
Pod A가 죽는 시나리오:

시점 T=0: Pod A rate=100 QPS, Pod B rate=100 QPS → max=100
시점 T=30: Pod A scrape 실패 (rate=NaN), Pod B rate=102 QPS → max=102
시점 T=60: Pod A 아직 다운 (NaN), Pod B rate=98 QPS → max=98

→ Grafana 차트: 100 → 102 → 98 (자연스러운 변동, 스파이크 없음)
```

Pod A가 복구될 때:
```
시점 T=150: Pod A rate=NaN (counter 리셋, 아직 5m window 미충족)
            Pod B rate=105 QPS → max=105
시점 T=300: Pod A rate=103 QPS (정상화), Pod B rate=104 QPS → max=104

→ Grafana 차트: 연속적으로 정상값만 표시 (복구 시에도 스파이크 없음)
```

### Q: AMP 저장 비용이 2배 되지 않나?

**A:** 아닙니다. 실제로는 약 1.2배 수준입니다.

- Raw 메트릭 2배 수집이지만:
  - `go_*` 제거: 약 50개 시계열/Pod 절약
  - `process_*` 제거: 약 10개 시계열/Pod 절약
  - `promhttp_*` 제거: 약 5개 시계열/Pod 절약
  - `instance`, `job` 라벨 제거: 카디널리티 감소
- 결과: 원본 100개 시계열 → drop 후 60개 × 2 Pod = 120개
- **추가분: 기존 대비 +20%** (2배가 아님!)

### Q: Recording Rule 결과가 나올 때까지 시간이 걸리지 않나?

**A:** Recording Rules는 30초 간격으로 평가됩니다.

- 첫 배포 후 약 30~60초 내에 `db:` 접두사 메트릭이 생성됨
- Grafana에서 `db:mysql_qps`를 조회하면 즉시 결과가 반환됨
- 이전 데이터는 없지만, 그건 어떤 방식이든 마찬가지

### Q: 모니터링 대상 DB가 100개가 되면 비용은?

**A:** 

| DB 수 | Exporter Pod | AMP 시계열 (drop 후) | 예상 월 비용 |
|---|---|---|---|
| 10 | 20 Pod | ~4,800 | ~$48 |
| 50 | 100 Pod | ~24,000 | ~$150 |
| 100 | 200 Pod | ~48,000 | ~$280 |

EKS 노드 추가 비용: DB 50개 기준 t3.medium 1~2개 추가 ≈ $60~120/월
