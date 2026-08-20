# 멀티 어카운트/리전 DB 통합 모니터링 가이드

## 개요

이 모듈은 **여러 AWS 계정과 리전에 분산된 DB를 하나의 중앙 모니터링 플랫폼**에서 통합 관리할 수 있도록 합니다.

```
┌─ 중앙 모니터링 계정 (Hub) ─────────────────────────────────────────┐
│  EKS: Exporter Pods + ADOT Collector                               │
│  AMP: 통합 메트릭 저장소                                            │
│  AMG: 통합 대시보드 (계정/리전별 필터)                               │
│  CronJob: 멀티 어카운트 자동 디스커버리                              │
└────────────────────────────────────────────────────────────────────┘
        ↕ Cross-Account AssumeRole      ↕ Transit Gateway
┌─ Prod 계정 (서울) ─┐  ┌─ Prod 계정 (버지니아) ─┐  ┌─ Dev 계정 ─┐
│  Aurora MySQL      │  │  Aurora PostgreSQL     │  │  RDS MySQL │
│  ElastiCache       │  │  DynamoDB              │  │  Redis     │
└────────────────────┘  └────────────────────────┘  └────────────┘
```

## 파일 구성

| 파일 | 용도 | 배포 위치 |
|------|------|-----------|
| `multi-account-config.yaml` | 대상 계정/리전 설정 ConfigMap | 중앙 계정 EKS |
| `cross-account-role-cfn.yaml` | 모니터링 대상 역할 (워크로드 계정용) | 각 워크로드 계정 |
| `hub-account-role-cfn.yaml` | Discovery/Exporter IAM 역할 (중앙 계정용) | 중앙 계정 |
| `db-discovery-multi-account.sh` | 멀티 어카운트 디스커버리 스크립트 | 중앙 계정 EKS CronJob |
| `exporter-template-multi-account.yaml` | Exporter 템플릿 (계정/리전 라벨 포함) | 중앙 계정 EKS |
| `network-connectivity-guide.md` | 네트워크 연결 가이드 | 참조 문서 |
| `grafana-dashboard-multi-account.json` | 멀티 어카운트 Grafana 대시보드 | AMG |

## 초기 설정 순서

### Phase 1: 중앙 모니터링 계정 준비 (30분)

```bash
# 1. Hub IAM Role 생성
aws cloudformation deploy \
  --template-file hub-account-role-cfn.yaml \
  --stack-name db-monitoring-hub-role \
  --parameter-overrides \
    ClusterName="${CLUSTER_NAME}" \
    OidcProvider="${OIDC_PROVIDER}" \
    TargetAccountIds="111111111111,222222222222,333333333333" \
  --capabilities CAPABILITY_NAMED_IAM

# 2. ConfigMap 배포
kubectl apply -f multi-account-config.yaml

# 3. Exporter 템플릿 ConfigMap
kubectl create configmap exporter-templates \
  -n observability \
  --from-file=mysql-exporter-template.yaml=exporter-template-multi-account.yaml
```

### Phase 2: 워크로드 계정 역할 생성 (계정당 5분)

```bash
# 개별 계정에 배포
aws cloudformation deploy \
  --template-file cross-account-role-cfn.yaml \
  --stack-name db-monitoring-target-role \
  --parameter-overrides \
    HubAccountId="${HUB_ACCOUNT_ID}" \
    HubEksRoleName="${CLUSTER_NAME}-discovery-role" \
  --capabilities CAPABILITY_NAMED_IAM

# 또는 StackSet으로 여러 계정에 한번에 (Organizations 사용 시)
aws cloudformation create-stack-set \
  --stack-set-name DBMonitoringTargetRole \
  --template-body file://cross-account-role-cfn.yaml \
  --parameters ParameterKey=HubAccountId,ParameterValue=${HUB_ACCOUNT_ID} \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false

aws cloudformation create-stack-instances \
  --stack-set-name DBMonitoringTargetRole \
  --deployment-targets OrganizationalUnitIds=ou-xxxx-yyyyyyyy \
  --regions ap-northeast-2 us-east-1 eu-west-1
```

### Phase 3: 네트워크 연결 (30~60분)

`network-connectivity-guide.md` 참조.

핵심 단계:
1. Transit Gateway 생성 (또는 VPC Peering)
2. 각 워크로드 VPC에서 TGW Attachment
3. Route Table 업데이트
4. Security Group: DB 포트 개방

### Phase 4: Discovery 배포 및 테스트

```bash
# DRY-RUN으로 먼저 테스트
kubectl create job --from=cronjob/db-discovery db-discovery-test -n observability
kubectl logs -f job/db-discovery-test -n observability

# 정상 확인 후 CronJob 활성화
kubectl apply -f discovery-cronjob-multi-account.yaml
```

---

## 새 계정 추가 방법 (3단계)

### Step 1: 워크로드 계정에 역할 생성
```bash
aws cloudformation deploy \
  --template-file cross-account-role-cfn.yaml \
  --stack-name db-monitoring-target-role \
  --parameter-overrides HubAccountId=${HUB_ACCOUNT_ID}
```

### Step 2: multi-account-config.yaml 업데이트
```yaml
target_accounts:
  # ... 기존 항목 ...
  - id: "555555555555"           # ← 새 계정 추가
    name: "new-service"
    role_arn: "arn:aws:iam::555555555555:role/DBMonitoringTargetRole"
    regions: ["ap-northeast-2"]
    tag_filter:
      key: "monitoring"
      value: "enabled"
```
```bash
kubectl apply -f multi-account-config.yaml
```

### Step 3: 네트워크 연결
```bash
# 새 계정 VPC에서 Transit Gateway Attachment
aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id "${TGW_ID}" \
  --vpc-id "vpc-new-xxxx" \
  --subnet-ids "subnet-1" "subnet-2"

# Route Table + Security Group 업데이트
```

완료! 다음 Discovery CronJob 실행 시 (5분 이내) 자동으로 새 계정의 DB가 발견되고 Exporter가 배포됩니다.

---

## 비용 영향 분석

### 추가 비용 (10개 워크로드 계정, 총 50개 DB 기준)

| 항목 | 월 비용 | 설명 |
|------|---------|------|
| Transit Gateway | $36 | 시간당 $0.05 |
| TGW 데이터 전송 | $10~20 | 메트릭 수집 트래픽 (소량) |
| 추가 EKS Pod (HA 2x) | $25 | 50 DB × 2 Pod × 소량 리소스 |
| AMP 추가 시계열 | $15 | account_id/region 라벨로 카디널리티 증가 |
| **총 추가 비용** | **~$85~95/월** |

### 비용 절약 vs 별도 구축

| 방식 | 월 비용 |
|------|---------|
| 계정별 개별 모니터링 스택 (10개) | ~$1,500/월 (AMP+AMG ×10) |
| **중앙 통합 (이 구성)** | **~$250/월** (기본 스택 + $95 추가) |
| **절약** | **~$1,250/월 (83% 절약)** |

---

## 트러블슈팅

### AssumeRole 실패
```bash
# 확인: Trust Policy에 중앙 계정 Role이 포함되어 있는지
aws iam get-role --role-name DBMonitoringTargetRole \
  --query 'Role.AssumeRolePolicyDocument'

# 확인: External ID가 일치하는지
```

### DB 연결 실패 (Exporter → DB)
```bash
# Pod에서 직접 연결 테스트
kubectl exec -it <exporter-pod> -n observability -- \
  sh -c "nc -zv <db-endpoint> <port>"

# DNS 해석 확인
kubectl exec -it <exporter-pod> -n observability -- \
  nslookup <db-endpoint>
```

### 메트릭이 Grafana에 안 보임
```bash
# AMP에서 직접 쿼리
awscurl --service aps \
  "https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/api/v1/query?query=up{account_id='111111111111'}"
```

### 특정 계정만 Discovery 실패
```bash
# 해당 계정의 Role 테스트
aws sts assume-role \
  --role-arn "arn:aws:iam::111111111111:role/DBMonitoringTargetRole" \
  --role-session-name "test" \
  --external-id "db-monitoring-cross-account"
```

---

## FAQ

**Q: 계정이 100개 이상이면?**
A: Discovery CronJob의 `concurrency` 설정으로 병렬 처리. 100개 계정 × 3개 리전 = 300개 조합을 5분 내 처리 가능 (API 호출은 경량).

**Q: CIDR이 겹치는 VPC가 있으면?**
A: Transit Gateway에서는 CIDR 충돌 시 라우팅 불가. 해당 VPC는 PrivateLink 방식으로 개별 연결하거나, VPC CIDR 변경 필요.

**Q: 멀티 리전 지연 시간은?**
A: 메트릭 scrape는 30초 간격이므로 리전간 지연(50~200ms)은 무시 가능. DB 접속은 TCP이므로 지연이 있으나 메트릭 수집에는 영향 미미.

**Q: DynamoDB는 네트워크 연결이 필요한가?**
A: 아닙니다. DynamoDB는 CloudWatch 메트릭으로 수집하므로 IAM AssumeRole만 있으면 됩니다 (네트워크 연결 불필요).
