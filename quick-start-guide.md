# 🚀 AWS 데이터베이스 통합 모니터링 - 빠른 시작 가이드

## 개요

이 가이드는 AWS 데이터베이스(Aurora MySQL, Aurora PostgreSQL, RDS SQL Server, ElastiCache Valkey)의 통합 모니터링 환경을 **원클릭으로 배포**하는 방법을 안내합니다.

### 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│ Amazon VPC                                                       │
│                                                                   │
│  ┌──────────────┐     ┌──────────────────────────────────────┐  │
│  │ Amazon Aurora │     │ Amazon EKS                            │  │
│  │  MySQL (x3)  │────▶│  ├─ MySQL Exporter (x3)              │  │
│  │  PG (x3)     │────▶│  ├─ PostgreSQL Exporter (x3)         │  │
│  └──────────────┘     │  ├─ MS SQL Exporter (x1)             │  │
│  ┌──────────────┐     │  ├─ Redis Exporter (x1)              │  │
│  │ RDS SQL Srvr │────▶│  └─ ADOT Collector ──────────────┐   │  │
│  └──────────────┘     └──────────────────────────────────┼───┘  │
│  ┌──────────────┐                                        │      │
│  │ ElastiCache  │───────────────────────────────────────▶│      │
│  │ (Valkey)     │                                        ▼      │
│  └──────────────┘                          ┌─────────────────┐  │
│                                            │ Amazon Managed   │  │
│                                            │ Prometheus (AMP) │  │
│                                            └────────┬────────┘  │
└─────────────────────────────────────────────────────┼───────────┘
                                                      │
                    ┌──────────────────────────────────┼──────┐
                    │                                  ▼      │
                    │  ┌─────────────────────────────────┐    │
                    │  │ Amazon Managed Grafana (AMG)     │    │
                    │  │   • DB 메트릭 대시보드            │    │
                    │  │   • CloudWatch 연동              │    │
                    │  │   • 알람 설정                    │    │
                    │  └─────────────────────────────────┘    │
                    │  ┌─────────────────────────────────┐    │
                    │  │ Amazon CloudWatch                │    │
                    │  │   • RDS/Aurora 기본 메트릭        │    │
                    │  └─────────────────────────────────┘    │
                    └─────────────────────────────────────────┘
```

---

## 📋 사전 준비 (Prerequisites)

### 1. AWS 계정
- **관리자 권한**이 있는 AWS 계정
- AWS IAM Identity Center (SSO) 설정 완료 (Grafana 접속용)

### 2. 필수 도구 설치

| 도구 | 최소 버전 | macOS 설치 | Linux 설치 |
|------|-----------|-----------|-----------|
| AWS CLI | v2.0+ | `brew install awscli` | [공식 가이드](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html) |
| kubectl | v1.23+ | `brew install kubectl` | [공식 가이드](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) |
| Helm | v3.8+ | `brew install helm` | `curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \| bash` |
| eksctl | v0.123+ | `brew install eksctl` | [공식 가이드](https://eksctl.io/installation/) |
| envsubst | - | `brew install gettext` | `apt install gettext` |

### 3. AWS CLI 설정

```bash
# AWS 자격증명 설정
aws configure
# AWS Access Key ID: [your-key]
# AWS Secret Access Key: [your-secret]
# Default region name: ap-northeast-2
# Default output format: json

# 설정 확인
aws sts get-caller-identity
```

---

## ⚡ 원클릭 배포

### 방법 1: deploy-all.sh (권장)

```bash
# 1. 레포지토리 클론
git clone https://github.com/Deokhyun-Lee/aws-db-monitoring-eks-amp.git
cd aws-db-monitoring-eks-amp

# 2. 실행 권한 부여
chmod +x deploy-all.sh cleanup.sh

# 3. 배포 실행 (이 한 줄이면 끝!)
./deploy-all.sh
```

### 방법 2: Make 사용

```bash
git clone https://github.com/Deokhyun-Lee/aws-db-monitoring-eks-amp.git
cd aws-db-monitoring-eks-amp

# 전체 배포
make deploy

# 상태 확인
make status

# Grafana URL 확인
make dashboard
```

### 배포 옵션

```bash
# 리전 지정
./deploy-all.sh --region us-west-2

# 워크숍 이름 변경
./deploy-all.sh --name my-db-monitoring

# 네트워킹/DB 건너뛰기 (모니터링만 재배포)
./deploy-all.sh --skip-infra

# DB 스택만 건너뛰기
./deploy-all.sh --skip-db

# 설정만 확인 (실제 배포 안함)
./deploy-all.sh --dry-run
```

---

## ⏱ 예상 배포 시간

| 단계 | 예상 시간 |
|------|-----------|
| 네트워킹 (VPC) | 3~5분 |
| 데이터베이스 (Aurora, RDS, ElastiCache) | 15~20분 |
| EKS 클러스터 | 15~20분 |
| AMP + AMG | 3~5분 |
| Helm 배포 (Exporters) | 3~5분 |
| **총 소요 시간** | **35~50분** |

> 💡 **팁**: DB 스택과 EKS 생성은 스크립트 내에서 가능한 병렬로 진행됩니다.

---

## ✅ 배포 후 확인

### 1. Pod 상태 확인

```bash
kubectl get pods -n observability
```

예상 출력:
```
NAME                                READY   STATUS    RESTARTS   AGE
adot-collector-xxxxx                1/1     Running   0          5m
mysql-exporter-xxxxx                1/1     Running   0          4m
postgres-exporter-xxxxx             1/1     Running   0          4m
redis-exporter-xxxxx                1/1     Running   0          3m
mssql-exporter-xxxxx                1/1     Running   0          3m
```

### 2. 메트릭 수집 확인

```bash
# ADOT Collector 로그 확인
kubectl logs -n observability -l app=adot-collector --tail=20

# 메트릭 엔드포인트 직접 확인
kubectl port-forward -n observability svc/mysql-exporter 9104:9104
curl http://localhost:9104/metrics | head -20
```

### 3. AMP에서 메트릭 조회

```bash
# awscurl 설치 필요: pip install awscurl
export AMP_WS_ID=$(cat .deploy-state.env | grep AMP_WORKSPACE_ID | cut -d= -f2)
export REGION=$(cat .deploy-state.env | grep AWS_REGION | cut -d= -f2)

awscurl --service aps \
  "https://aps-workspaces.${REGION}.amazonaws.com/workspaces/${AMP_WS_ID}/api/v1/query?query=up"
```

---

## 📊 대시보드 접속

### Grafana 접속 방법

1. 배포 완료 후 출력된 **AMG URL**로 접속
2. AWS IAM Identity Center(SSO)로 로그인
3. 미리 구성된 대시보드 확인:
   - **Aurora MySQL Overview** - 커넥션, 쿼리 성능, InnoDB 메트릭
   - **Aurora PostgreSQL Overview** - 트랜잭션, 버퍼 캐시, WAL 메트릭
   - **SQL Server Overview** - 배치 요청, 대기 통계, 메모리
   - **ElastiCache Valkey Overview** - 히트율, 메모리, 커맨드 통계
   - **CloudWatch RDS Metrics** - CPU, 메모리, IOPS, 네트워크

### 대시보드 URL 빠른 확인

```bash
make dashboard
# 또는
cat .deploy-state.env | grep AMG_ENDPOINT
```

---

## 💰 비용 안내

### 예상 시간당 비용 (서울 리전 기준)

| 리소스 | 사양 | 예상 비용/시간 |
|--------|------|---------------|
| EKS 클러스터 | 제어 플레인 | ~$0.10 |
| EKS 노드그룹 | t3.medium × 2 | ~$0.10 |
| Aurora MySQL | db.r6g.large × 3 | ~$0.90 |
| Aurora PostgreSQL | db.r6g.large × 3 | ~$0.90 |
| RDS SQL Server | db.m5.large × 1 | ~$0.50 |
| ElastiCache Valkey | cache.t3.medium × 1 | ~$0.07 |
| AMP | 메트릭 수집량 기준 | ~$0.10 |
| AMG | 워크스페이스 | ~$0.09 |
| **합계** | | **~$2.76/시간** |

> ⚠️ **주의**: 워크숍 종료 후 반드시 `./cleanup.sh`를 실행하여 리소스를 삭제하세요!
> 
> 24시간 방치 시 약 **$66** 과금됩니다.

### 비용 절감 팁
- 워크숍 완료 후 즉시 정리
- DB 인스턴스를 `db.t3.medium`으로 변경하면 ~60% 절감 가능
- 테스트용이라면 Reader 인스턴스 수를 줄여도 됨

---

## 🧹 리소스 정리

### 전체 정리 (원클릭)

```bash
./cleanup.sh
# 또는
make cleanup
```

### 옵션

```bash
# 확인 없이 즉시 삭제
./cleanup.sh --force

# VPC만 유지하고 나머지 삭제
./cleanup.sh --keep-vpc
```

### 수동 정리 (스크립트 실패 시)

```bash
# 1. Helm 릴리스 삭제
helm uninstall mssql-exporter redis-exporter postgres-exporter mysql-exporter adot-collector -n observability

# 2. EKS 클러스터 삭제
eksctl delete cluster --name integrated-db-monitoring-eks --region ap-northeast-2

# 3. AMP 워크스페이스 삭제
aws amp delete-workspace --workspace-id <WORKSPACE_ID>

# 4. AMG 워크스페이스 삭제
aws grafana delete-workspace --workspace-id <WORKSPACE_ID>

# 5. CloudFormation 스택 삭제 (역순)
aws cloudformation delete-stack --stack-name integrated-db-monitoring-cache
aws cloudformation delete-stack --stack-name integrated-db-monitoring-db
aws cloudformation delete-stack --stack-name integrated-db-monitoring-network

# 6. IAM 역할 삭제
aws iam detach-role-policy --role-name integrated-db-monitoring-adot-collector-role --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess
aws iam delete-role --role-name integrated-db-monitoring-adot-collector-role
aws iam delete-role --role-name integrated-db-monitoring-amg-role
```

---

## 🔧 트러블슈팅

### 자주 발생하는 문제

| 문제 | 원인 | 해결 |
|------|------|------|
| `eksctl create cluster` 실패 | VPC 서브넷 부족 | `--skip-infra`로 재시작 또는 CIDR 변경 |
| Pod `CrashLoopBackOff` | DB 연결 실패 | Security Group에서 EKS 노드 CIDR 허용 확인 |
| ADOT → AMP 전송 실패 | IRSA 설정 오류 | Service Account annotation 확인 |
| AMG 로그인 불가 | SSO 미설정 | IAM Identity Center에서 사용자 추가 |
| Helm timeout | 이미지 풀 실패 | ECR Public 접근 가능한지 확인 |

### 로그 확인

```bash
# ADOT Collector 로그
kubectl logs -n observability -l app.kubernetes.io/name=opentelemetry-collector -f

# 특정 Exporter 로그
kubectl logs -n observability -l app=mysql-exporter -f
kubectl logs -n observability -l app=redis-exporter -f
kubectl logs -n observability -l app=mssql-exporter -f

# 이벤트 확인
kubectl get events -n observability --sort-by='.lastTimestamp'
```

---

## 📁 프로젝트 구조

```
aws-db-monitoring-eks-amp/
├── deploy-all.sh              # 원클릭 배포 스크립트
├── cleanup.sh                 # 리소스 정리 스크립트
├── Makefile                   # Make 명령어
├── quick-start-guide.md       # 이 문서
├── networking-stack.yaml      # VPC/서브넷 CloudFormation
├── database-stack.yaml        # DB 인프라 CloudFormation
├── cache-stack.yaml           # ElastiCache CloudFormation
├── eks-cluster.yaml           # EKS 클러스터 설정
├── helm-charts/
│   ├── adot-collector/        # ADOT Collector Helm values
│   │   └── values.yaml
│   ├── mysql-exporter/        # MySQL Exporter Helm values
│   │   └── values.yaml
│   ├── postgres-exporter/     # PostgreSQL Exporter Helm values
│   │   └── values.yaml
│   ├── redis-exporter/        # Redis/Valkey Exporter Helm values
│   │   └── values.yaml
│   └── mssql-exporter/        # MS SQL Exporter Helm chart
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
├── dashboards/
│   ├── aurora-mysql.json      # MySQL 대시보드
│   ├── aurora-postgresql.json # PostgreSQL 대시보드
│   ├── sqlserver.json         # SQL Server 대시보드
│   ├── elasticache.json       # ElastiCache 대시보드
│   └── cloudwatch-rds.json    # CloudWatch RDS 대시보드
└── scripts/
    └── db-discovery.sh        # DB 자동 디스커버리 스크립트
```

---

## 📞 문의

- **GitHub Issues**: https://github.com/Deokhyun-Lee/aws-db-monitoring-eks-amp/issues
- **담당자**: Lee, Deokhyun (Database Specialist SA)
