# SNS 알람 아키텍처 가이드

## 📐 아키텍처 개요

```
┌─────────────────────────────────────────────────────────────────────┐
│                          알람 흐름                                   │
│                                                                     │
│  AMP Alert Rules        AMG Alert Rules                             │
│  (Prometheus-native)    (Grafana-native)                            │
│         │                      │                                    │
│         ▼                      ▼                                    │
│  AMP AlertManager       AMG Alerting                                │
│  (라우팅/그룹화/억제)    (Contact Points)                            │
│         │                      │                                    │
│         └──────────┬───────────┘                                    │
│                    ▼                                                 │
│           Amazon SNS Topics                                         │
│     ┌──────────┬──────────┬──────────┐                             │
│     │  Info    │ Warning  │ Critical │                              │
│     └────┬─────┴────┬─────┴────┬─────┘                             │
│          │           │          │                                    │
│          ▼           ▼          ▼                                    │
│        Email     Email+Slack  Email+Slack+SMS+PagerDuty            │
└─────────────────────────────────────────────────────────────────────┘
```

## 🚀 배포 순서

### Step 1: SNS Topic 생성
```bash
aws cloudformation create-stack \
  --stack-name db-monitoring-alerting \
  --template-body file://alerting/sns-topics-cfn.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=integrated-db-monitoring \
    ParameterKey=AlertEmailEndpoint,ParameterValue=dba-team@example.com \
    ParameterKey=CriticalEmailEndpoint,ParameterValue=oncall@example.com \
    ParameterKey=SlackWebhookUrl,ParameterValue=https://hooks.slack.com/services/xxx \
  --capabilities CAPABILITY_IAM

# 완료 대기
aws cloudformation wait stack-create-complete \
  --stack-name db-monitoring-alerting

# Topic ARN 가져오기
export SNS_INFO_TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name db-monitoring-alerting \
  --query 'Stacks[0].Outputs[?OutputKey==`InfoTopicArn`].OutputValue' --output text)

export SNS_WARNING_TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name db-monitoring-alerting \
  --query 'Stacks[0].Outputs[?OutputKey==`WarningTopicArn`].OutputValue' --output text)

export SNS_CRITICAL_TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name db-monitoring-alerting \
  --query 'Stacks[0].Outputs[?OutputKey==`CriticalTopicArn`].OutputValue' --output text)
```

### Step 2: AMP AlertManager 설정 적용
```bash
# 환경변수 치환
envsubst < alerting/amp-alertmanager-config.yaml > /tmp/alertmanager-resolved.yaml

# AMP에 적용
aws amp put-alert-manager-definition \
  --workspace-id $AMP_WORKSPACE_ID \
  --data fileb:///tmp/alertmanager-resolved.yaml
```

### Step 3: AMP Alert Rules 등록
```bash
aws amp create-rule-groups-namespace \
  --workspace-id $AMP_WORKSPACE_ID \
  --name "db-monitoring-alerts" \
  --data fileb://alerting/amp-alert-rules-complete.yaml
```

### Step 4: AMG Contact Points 설정 (선택사항 — 이중 경로)
```bash
# Grafana API를 통해 Contact Points 설정
envsubst < alerting/grafana-alert-contact-points.json > /tmp/contact-points-resolved.json

curl -X POST \
  -H "Authorization: Bearer $GRAFANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/contact-points-resolved.json \
  "$GRAFANA_URL/api/v1/provisioning/contact-points"
```

### Step 5: 이메일 구독 확인
SNS Topic 생성 후, 등록된 이메일 주소로 확인 메일이 발송됩니다.
**반드시 "Confirm subscription" 링크를 클릭**해야 알림을 받을 수 있습니다.

## 📊 알람 대상 및 임계값

### 인프라 알람
| Alert | 조건 | 심각도 | 설명 |
|-------|------|--------|------|
| ExporterDown | up == 0, 1분 | ⚠️ Warning | Exporter Pod 다운 |
| AllReplicasDown | 모든 replica down, 30초 | 🔴 Critical | 해당 DB 모니터링 완전 중단 |
| MetricGapDetected | 5분 이상 수집 없음 | 🔴 Critical | 데이터 빵꾸 발생 |
| ADOTCollectorDown | ADOT 무응답, 30초 | 🔴 Critical | 전체 메트릭 전달 중단 |

### MySQL 성능 알람
| Alert | 조건 | 심각도 |
|-------|------|--------|
| MySQLConnectionsHigh | > 100, 5분 | ⚠️ Warning |
| MySQLSlowQueriesSpike | > 5/s, 3분 | ⚠️ Warning |
| MySQLReplicationLag | > 30초, 2분 | 🔴 Critical |
| MySQLBufferPoolHitLow | < 95%, 10분 | ⚠️ Warning |
| MySQLThreadsRunningHigh | > 50, 3분 | 🔴 Critical |

### PostgreSQL 성능 알람
| Alert | 조건 | 심각도 |
|-------|------|--------|
| PGConnectionsHigh | > 100, 5분 | ⚠️ Warning |
| PGDeadTuplesHigh | > 100K, 15분 | ⚠️ Warning |
| PGReplicationLag | > 100MB, 2분 | 🔴 Critical |
| PGCacheHitLow | < 95%, 10분 | ⚠️ Warning |

### Redis 성능 알람
| Alert | 조건 | 심각도 |
|-------|------|--------|
| RedisMemoryHigh | > 80%, 5분 | ⚠️ Warning |
| RedisEvictedKeysSpike | > 100/s, 3분 | 🔴 Critical |
| RedisHitRatioLow | < 90%, 10분 | ⚠️ Warning |

### DynamoDB 성능 알람
| Alert | 조건 | 심각도 |
|-------|------|--------|
| DynamoDBThrottleEvents | > 0, 2분 | ⚠️ Warning |
| DynamoDBLatencyHigh | P99 > 100ms, 5분 | ⚠️ Warning |
| DynamoDBSystemErrors | > 0, 1분 | 🔴 Critical |
| DynamoDBCapacityUtilizationHigh | > 80%, 10분 | ⚠️ Warning |

## 🔧 알람 튜닝 가이드

### 임계값 조정
Alert Rules 파일에서 각 알림의 `expr`과 `for` 값을 환경에 맞게 조정:
```yaml
# 예: MySQL 연결 수 임계값을 200으로 변경
- alert: MySQLConnectionsHigh
  expr: db:mysql_connections:by_instance > 200  # 100 → 200
  for: 5m
```

### 알림 피로 방지
1. **그룹화**: `group_by`로 동일 DB의 알림 묶기
2. **억제**: critical 발생 시 같은 인스턴스 warning 억제
3. **반복 간격**: warning 4시간, info 12시간
4. **점검 시간**: `mute_timings`로 정기 점검 시간대 음소거

### Silence (임시 음소거)
특정 인스턴스 점검 시:
```bash
# AMG UI에서: Alerting → Silences → New Silence
# 또는 API:
curl -X POST "$GRAFANA_URL/api/alertmanager/grafana/api/v2/silences" \
  -H "Authorization: Bearer $GRAFANA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "matchers": [{"name": "db_instance", "value": "aurora-mysql-1", "isRegex": false}],
    "startsAt": "2026-08-20T18:00:00Z",
    "endsAt": "2026-08-20T22:00:00Z",
    "createdBy": "dba-team",
    "comment": "정기 점검"
  }'
```

## 🌐 멀티 어카운트 환경 알람

### 옵션 A: 중앙 SNS Topic (권장)
- 모든 계정의 알림이 중앙 모니터링 계정의 SNS Topic으로 집중
- Alert 메시지에 `account_id`, `region` 포함으로 구분
- 장점: 관리 간단, 한곳에서 모든 알림 확인

### 옵션 B: 계정별 SNS Topic
- 각 워크로드 계정에 SNS Topic 생성
- AMP AlertManager에서 `account_id` 라벨 기반 라우팅
- 장점: 계정별 독립 관리, 비용 분리

## 🧪 테스트 방법

### Alert Rule 수동 트리거 (테스트용)
```bash
# AMP Query로 현재 Alert 상태 확인
awscurl --service aps \
  "https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/api/v1/alerts"

# SNS 직접 테스트 발송
aws sns publish \
  --topic-arn $SNS_WARNING_TOPIC_ARN \
  --subject "[TEST] DB 모니터링 알림 테스트" \
  --message '{"alerts":[{"labels":{"alertname":"TestAlert","db_instance":"test-db","severity":"warning"},"annotations":{"summary":"테스트 알림입니다"}}]}'
```

## 📁 파일 목록

| 파일 | 용도 |
|------|------|
| `sns-topics-cfn.yaml` | SNS Topic 3개 + Lambda + KMS (CloudFormation) |
| `amp-alertmanager-config.yaml` | AMP AlertManager 설정 (라우팅/억제/템플릿) |
| `amp-alert-rules-complete.yaml` | 전체 Alert Rules (인프라 + 5개 엔진 성능) |
| `grafana-alert-contact-points.json` | AMG Contact Point + Notification Policy |
| `alerting-iam-policy.json` | AMP/AMG → SNS Publish 권한 |
| `README-alerting.md` | 이 가이드 |
