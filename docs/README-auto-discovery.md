# 통합 DB 자동 디스커버리 시스템

## 개요

이 모듈은 AWS 환경의 **모든 데이터베이스 서비스**를 자동으로 감지하고, 해당 DB에 맞는 Prometheus Exporter를 EKS에 자동 배포하는 시스템입니다.

### 지원 대상

| AWS 서비스 | 엔진 | Exporter | 포트 |
|---|---|---|---|
| Amazon Aurora | MySQL | mysqld_exporter | 9104 |
| Amazon Aurora | PostgreSQL | postgres_exporter | 9187 |
| Amazon RDS | MySQL | mysqld_exporter | 9104 |
| Amazon RDS | PostgreSQL | postgres_exporter | 9187 |
| Amazon RDS | SQL Server | prometheus-mssql-exporter | 4000 |
| Amazon RDS | MariaDB | mysqld_exporter | 9104 |
| Amazon ElastiCache | Redis | redis_exporter | 9121 |
| Amazon ElastiCache | Valkey | redis_exporter | 9121 |

### 동작 방식

```
┌─────────────────────────────────────────────────────────────────────┐
│                    EKS CronJob (5분 주기)                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. discover_aurora()      ─→ aws rds describe-db-clusters          │
│                            ─→ aws rds describe-db-instances          │
│                                                                     │
│  2. discover_rds()         ─→ aws rds describe-db-instances          │
│                               (DBClusterIdentifier == null)          │
│                                                                     │
│  3. discover_elasticache() ─→ aws elasticache describe-repl-groups   │
│                            ─→ aws elasticache describe-cache-clusters│
│                                                                     │
│  4. reconcile()            ─→ 현재 Exporter vs 디스커버리 결과 비교   │
│     ├── 새 DB 감지 → deploy_exporter()                              │
│     └── 삭제된 DB → remove_exporter()                               │
│                                                                     │
│  5. ADOT Collector         ─→ Annotation 기반 자동 scrape            │
│     └── prometheus.io/scrape: "true" Pod 감지                       │
│                                                                     │
│  6. AMP (remote_write)     ─→ 메트릭 저장                           │
│                                                                     │
│  7. AMG Dashboard          ─→ 시각화 + 알림                          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 자동 대응 시나리오

| 이벤트 | 자동 동작 |
|---|---|
| 새 Aurora 클러스터 생성 | 5분 내 Exporter Pod 자동 배포 |
| 기존 클러스터에 Reader 추가 | 5분 내 해당 Reader용 Exporter 추가 |
| 새 RDS 인스턴스 생성 | 엔진 감지 → 적절한 Exporter 배포 |
| ElastiCache 클러스터 생성 | redis_exporter 자동 배포 |
| DB 인스턴스 삭제 | orphaned Exporter 자동 제거 |
| DB 일시 중지 (stopped) | Exporter 유지 (재시작 시 바로 수집) |

---

## 파일 구조

```
auto-discovery/
├── db-discovery-updated.sh          # 메인 디스커버리 스크립트
├── discovery-cronjob.yaml           # CronJob + ConfigMap + Secrets
├── discovery-rbac.yaml              # ServiceAccount + RBAC
├── discovery-iam-policy.json        # AWS IAM 정책
├── adot-collector-config.yaml       # ADOT Collector 전체 설정
├── README-auto-discovery.md         # 이 파일
└── exporter-templates/
    ├── mysql-exporter-template.yaml      # MySQL Exporter 템플릿
    ├── postgresql-exporter-template.yaml # PostgreSQL Exporter 템플릿
    ├── mssql-exporter-template.yaml      # MS SQL Exporter 템플릿
    └── redis-exporter-template.yaml      # Redis Exporter 템플릿
```

---

## 배포 방법

### 사전 준비

1. EKS 클러스터가 동작 중이어야 합니다
2. ADOT Collector가 배포되어 있어야 합니다
3. AMP 워크스페이스가 생성되어 있어야 합니다

### Step 1: IAM 정책 및 역할 생성

```bash
# IAM 정책 생성
aws iam create-policy \
  --policy-name db-discovery-policy \
  --policy-document file://discovery-iam-policy.json

# IRSA용 역할 생성 (OIDC Provider 필요)
export OIDC_PROVIDER=$(aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed -e "s/^https:\/\///")

cat > discovery-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_PROVIDER}:sub": "system:serviceaccount:observability:db-discovery-sa",
        "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name ${WORKSHOP_NAME}-discovery-role \
  --assume-role-policy-document file://discovery-trust-policy.json

aws iam attach-role-policy \
  --role-name ${WORKSHOP_NAME}-discovery-role \
  --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/db-discovery-policy
```

### Step 2: RBAC 및 ServiceAccount 배포

```bash
# discovery-rbac.yaml 내의 ACCOUNT_ID를 실제 값으로 치환
sed -i "s/ACCOUNT_ID/${ACCOUNT_ID}/g" discovery-rbac.yaml
kubectl apply -f discovery-rbac.yaml
```

### Step 3: DB 접속 시크릿 설정

```bash
# MySQL 모니터링 계정 (DB에서 먼저 생성 필요)
# CREATE USER 'monitoring'@'%' IDENTIFIED BY 'MonitoringPass123!';
# GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO 'monitoring'@'%';

# PostgreSQL 모니터링 계정
# CREATE USER monitoring WITH PASSWORD 'MonitoringPass123!';
# GRANT pg_monitor TO monitoring;

kubectl apply -f discovery-cronjob.yaml  # Secrets 포함
```

### Step 4: Exporter 템플릿 등록

```bash
kubectl create configmap db-exporter-templates \
  --from-file=mysql-exporter-template.yaml=exporter-templates/mysql-exporter-template.yaml \
  --from-file=postgresql-exporter-template.yaml=exporter-templates/postgresql-exporter-template.yaml \
  --from-file=mssql-exporter-template.yaml=exporter-templates/mssql-exporter-template.yaml \
  --from-file=redis-exporter-template.yaml=exporter-templates/redis-exporter-template.yaml \
  -n observability
```

### Step 5: 디스커버리 스크립트 등록 및 CronJob 배포

```bash
kubectl create configmap db-discovery-script \
  --from-file=db-discovery-updated.sh=db-discovery-updated.sh \
  -n observability

kubectl apply -f discovery-cronjob.yaml
```

### Step 6: 수동 테스트 실행

```bash
# 즉시 한 번 실행하여 동작 확인
kubectl create job --from=cronjob/db-auto-discovery manual-test -n observability

# 로그 확인
kubectl logs job/manual-test -n observability -f
```

---

## 설정 옵션

### 태그 기반 필터링

특정 태그가 있는 DB만 모니터링하고 싶은 경우:

```yaml
# discovery-cronjob.yaml 의 ConfigMap에서:
TAG_FILTER_ENABLED: "true"
TAG_FILTER_KEY: "monitoring"
TAG_FILTER_VALUE: "enabled"
```

그 후 모니터링할 DB에 태그를 추가:
```bash
aws rds add-tags-to-resource \
  --resource-name arn:aws:rds:ap-northeast-2:123456789:db:my-instance \
  --tags Key=monitoring,Value=enabled
```

### VPC 필터링

EKS와 같은 VPC 내의 DB만 모니터링:

```yaml
VPC_FILTER_ENABLED: "true"
TARGET_VPC_ID: "vpc-0abc123def456"
```

### 디스커버리 주기 변경

```yaml
# discovery-cronjob.yaml
spec:
  schedule: "*/1 * * * *"   # 1분 (빠른 감지, API 비용 증가)
  schedule: "*/5 * * * *"   # 5분 (기본값, 권장)
  schedule: "*/15 * * * *"  # 15분 (안정적, API 비용 절감)
  schedule: "0 * * * *"     # 매시간 (기존 방식)
```

---

## 트러블슈팅

### Exporter가 생성되지 않음
```bash
# CronJob 로그 확인
kubectl logs -l app=db-discovery -n observability --tail=100

# 현재 디스커버리 상태 확인
kubectl get configmap db-discovery-state -n observability -o yaml

# DRY-RUN 모드로 실행하여 동작 확인
kubectl set env cronjob/db-auto-discovery DRY_RUN=true -n observability
kubectl create job --from=cronjob/db-auto-discovery dry-run-test -n observability
```

### ADOT가 Exporter를 scrape하지 않음
```bash
# Exporter Pod의 annotation 확인
kubectl get pods -n observability -l db-discovery/managed-by=auto-discovery \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.annotations}{"\n"}{end}'

# ADOT Collector 타깃 확인
kubectl port-forward svc/adot-collector 8888:8888 -n observability
curl http://localhost:8888/metrics | grep "up{"
```

### IAM 권한 오류
```bash
# ServiceAccount의 IAM 역할 확인
kubectl get sa db-discovery-sa -n observability -o yaml | grep eks.amazonaws.com

# AWS API 직접 테스트
kubectl run --rm -it aws-test --image=amazon/aws-cli:2.15.0 \
  --serviceaccount=db-discovery-sa -n observability -- \
  aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
```

---

## 향후 개선 방향

1. **EventBridge 기반 실시간 디스커버리**: CronJob 대신 EventBridge → Lambda → K8s API로 즉시 반응
2. **Helm Operator 방식**: CronJob 대신 Kubernetes Operator 패턴으로 전환
3. **DocumentDB, Neptune 지원**: 추가 AWS DB 서비스로 확장
4. **자동 대시보드 생성**: 새 DB 감지 시 Grafana 대시보드도 자동 생성
