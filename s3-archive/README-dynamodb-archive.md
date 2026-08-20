# DynamoDB 모니터링 + S3 메트릭 아카이브 가이드

## 📋 개요

이 모듈은 두 가지 기능을 제공합니다:

1. **DynamoDB CloudWatch 메트릭 수집** — ADOT Collector의 CloudWatch Receiver로 DynamoDB 서비스 메트릭을 AMP에 통합
2. **S3 Glacier 아카이브** — AMP의 150일 보존 한계를 넘어 장기(5년) 메트릭 보관

## 🏗️ 아키텍처

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  DynamoDB Tables                                                        │
│       ↓                                                                 │
│  CloudWatch (AWS/DynamoDB namespace)                                    │
│       ↓                                                                 │
│  ADOT Collector (CloudWatch Receiver) ← HA: replicas:2                  │
│       ↓                                                                 │
│  AMP (150일 보존)  ──→  Grafana (db: 접두사 Recording Rule 메트릭)      │
│       ↓                                                                 │
│  Lambda (매일 UTC 02:00)                                                │
│       ↓                                                                 │
│  S3 Standard (0~90일) → Glacier IR (90~365일) → Deep Archive (365일+)   │
│       ↓                                                                 │
│  Athena (과거 데이터 쿼리)                                               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

## 📁 파일 구성

### DynamoDB 모니터링
```
dynamodb/
├── dynamodb-cloudwatch-receiver.yaml    # ADOT CloudWatch Receiver 설정
├── amp-recording-rules-dynamodb.yaml    # Recording Rules + Alert
├── grafana-dashboard-dynamodb.json      # Grafana 대시보드
├── discovery-dynamodb-patch.sh          # DynamoDB 자동 디스커버리
└── dynamodb-iam-policy.json             # IAM 권한
```

### S3 아카이브
```
s3-archive/
├── s3-archive-lambda.py                 # Lambda 함수 (AMP → S3 Parquet)
├── s3-archive-cfn.yaml                  # CloudFormation (S3 + Lambda + EventBridge)
├── s3-lifecycle-policy.json             # S3 Lifecycle 정책
├── athena-queries.sql                   # Athena 쿼리 모음
└── README-dynamodb-archive.md           # 이 파일
```

## 🚀 배포 순서

### Part 1: DynamoDB 모니터링

#### Step 1: IAM 정책 추가
```bash
# ADOT Collector의 IAM Role에 DynamoDB/CloudWatch 권한 추가
aws iam put-role-policy \
  --role-name ${WORKSHOP_NAME}-adot-collector-role \
  --policy-name DynamoDBCloudWatchAccess \
  --policy-document file://dynamodb/dynamodb-iam-policy.json
```

#### Step 2: ADOT Collector 설정에 CloudWatch Receiver 추가
```bash
# 기존 ADOT Collector config에 dynamodb-cloudwatch-receiver.yaml 내용 병합
# 또는 ConfigMap으로 주입:
kubectl create configmap adot-dynamodb-config \
  -n observability \
  --from-file=dynamodb/dynamodb-cloudwatch-receiver.yaml

# ADOT Collector 재시작
kubectl rollout restart statefulset/adot-collector -n observability
```

#### Step 3: AMP Recording Rules 등록
```bash
aws amp create-rule-groups-namespace \
  --workspace-id $AMP_WORKSPACE_ID \
  --name "dynamodb-monitoring-rules" \
  --data fileb://dynamodb/amp-recording-rules-dynamodb.yaml
```

#### Step 4: Grafana 대시보드 Import
```bash
# AMG 콘솔에서:
# 1. Dashboards → Import
# 2. grafana-dashboard-dynamodb.json 업로드
# 3. AMP 데이터소스 선택
```

#### Step 5: DynamoDB 자동 디스커버리 (선택)
```bash
# 기존 CronJob에 DynamoDB 디스커버리 추가
# 또는 별도 CronJob으로 실행:
kubectl create configmap dynamodb-discovery-script \
  -n observability \
  --from-file=dynamodb/discovery-dynamodb-patch.sh

# CronJob 적용 (기존 discovery-cronjob.yaml에 추가)
```

### Part 2: S3 아카이브

#### Step 1: CloudFormation 스택 배포
```bash
aws cloudformation create-stack \
  --stack-name ${WORKSHOP_NAME}-metrics-archive \
  --template-body file://s3-archive/s3-archive-cfn.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${WORKSHOP_NAME} \
    ParameterKey=AMPWorkspaceId,ParameterValue=${AMP_WORKSPACE_ID} \
  --capabilities CAPABILITY_NAMED_IAM

# 완료 대기 (~3분)
aws cloudformation wait stack-create-complete \
  --stack-name ${WORKSHOP_NAME}-metrics-archive
```

#### Step 2: Lambda 함수 코드 업로드
```bash
# Lambda 코드 패키징
cd s3-archive
zip -r lambda-package.zip s3-archive-lambda.py

# Lambda 업데이트
LAMBDA_NAME=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-metrics-archive \
  --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionName`].OutputValue' \
  --output text)

aws lambda update-function-code \
  --function-name $LAMBDA_NAME \
  --zip-file fileb://lambda-package.zip
```

#### Step 3: 수동 테스트 실행
```bash
# Lambda 수동 실행하여 정상 동작 확인
aws lambda invoke \
  --function-name $LAMBDA_NAME \
  --payload '{}' \
  output.json

cat output.json
```

#### Step 4: Athena 테이블 생성
```bash
# Athena 콘솔에서 athena-queries.sql의 CREATE 문 실행
# 또는 AWS CLI:
aws athena start-query-execution \
  --query-string "CREATE DATABASE IF NOT EXISTS db_monitoring" \
  --work-group primary
```

## 💰 비용 분석

### DynamoDB 모니터링 추가 비용

| 항목 | 월 비용 | 비고 |
|------|---------|------|
| CloudWatch GetMetricData API | ~$1.08 | 테이블 10개 × 15메트릭 × 1440회/일 |
| AMP 저장 (DynamoDB 메트릭) | ~$5 | 시계열 150개 추가 |
| ADOT Collector 리소스 증가 | ~$0 | 기존 Pod 내에서 처리 |
| **소계** | **~$6/월** | |

### S3 아카이브 비용

| 항목 | 월 비용 | 비고 |
|------|---------|------|
| Lambda 실행 | ~$1.50 | 512MB × 5분 × 30일 |
| S3 Standard (최근 90일) | ~$0.10 | 약 4.5GB × $0.023/GB |
| S3 Glacier IR (90~365일) | ~$0.05 | 약 13.5GB × $0.004/GB |
| S3 Deep Archive (365일+) | ~$0.02 | 약 18GB × $0.00099/GB |
| **소계** | **~$1.67/월** | |

### 총 추가 비용: **약 $7.67/월**

### vs. 없을 경우의 손실:
- AMP 150일 이후 모든 과거 데이터 유실
- 장기 트렌드 분석 불가
- 인시던트 사후 분석 불가 (150일 이전 데이터)
- SLA 보고서 생성 불가

## ❓ FAQ

### Q: DynamoDB On-Demand 모드에서도 RCU/WCU 메트릭이 수집되나?
**A:** 네. On-Demand 모드에서도 CloudWatch는 ConsumedReadCapacityUnits/ConsumedWriteCapacityUnits를 보고합니다. 다만 ProvisionedCapacity 메트릭은 0으로 나옵니다. Recording Rule의 사용률 계산은 On-Demand일 때 의미가 없으므로, 대시보드에서 Provisioned/On-Demand 구분 패널을 확인하세요.

### Q: CloudWatch API 호출 한도에 걸릴 수 있나?
**A:** ADOT Collector의 CloudWatch Receiver는 GetMetricData API를 배치로 호출합니다. 기본 한도는 50 TPS로, 테이블 100개까지는 문제없습니다. 그 이상이면 poll_interval을 120s로 늘리세요.

### Q: S3 Glacier에 있는 데이터를 바로 Athena로 조회할 수 있나?
**A:** 
- **Glacier Instant Retrieval**: ✅ 즉시 조회 가능 (밀리초 응답)
- **Glacier Deep Archive**: ❌ 복원 필요 (12시간). 먼저 S3 Restore 후 조회.

### Q: Lambda가 실패하면 데이터가 유실되나?
**A:** AMP는 150일간 보존하므로, Lambda가 며칠 실패해도 데이터 유실은 없습니다. CloudWatch Alarm이 실패를 감지하면 수동으로 재실행하세요:
```bash
# 특정 날짜 재실행
aws lambda invoke --function-name $LAMBDA_NAME \
  --payload '{"override_date": "2026-08-15"}' output.json
```

### Q: rate() 메트릭의 아카이브는 어떻게 처리되나?
**A:** Recording Rule의 결과(rate가 이미 계산된 값)를 아카이브합니다. 따라서 S3에서 복원할 때 별도 rate 재계산이 필요 없습니다.
