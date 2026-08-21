# AWS 데이터베이스 통합 모니터링 플랫폼 — 배포 가이드

> **GitHub**: https://github.com/Deokhyun-Lee/aws-db-monitoring-eks-amp  
> **예상 소요시간**: 35~50분  
> **예상 비용**: ~$3.5/시간 (EKS + Aurora + RDS + ElastiCache + AMP + AMG)  
> **사전 조건**: AWS 계정 (AdministratorAccess 권한)

---

## 목차

1. [CloudShell 실행](#1-cloudshell-실행)
2. [도구 설치](#2-도구-설치)
3. [레포 클론 및 실행 준비](#3-레포-클론-및-실행-준비)
4. [Dry-Run 설정 확인](#4-dry-run-설정-확인)
5. [전체 배포 실행](#5-전체-배포-실행)
6. [배포 진행 상태 확인](#6-배포-진행-상태-확인)
7. [배포 완료 후 확인](#7-배포-완료-후-확인)
8. [트러블슈팅 가이드](#8-트러블슈팅-가이드)
9. [리소스 정리 (Cleanup)](#9-리소스-정리-cleanup)

---

## 1. CloudShell 실행

### 1-1. AWS Console 접속

1. https://console.aws.amazon.com/ 접속
2. 우측 상단에서 리전을 **Asia Pacific (Seoul) ap-northeast-2**로 선택
3. 로그인 (AdministratorAccess 권한이 있는 IAM 사용자/역할)

### 1-2. CloudShell 열기

1. AWS Console 상단 검색창에 `CloudShell` 입력
2. **CloudShell** 서비스 클릭
3. 또는 상단 바의 **>_** 아이콘 (터미널 모양) 클릭

> 💡 **Tip**: CloudShell은 브라우저 기반 터미널로 AWS CLI, Git, Python이 기본 설치되어 있습니다.  
> 별도 PC 설정이 전혀 불필요합니다.

### 1-3. CloudShell 초기 화면 확인

약 30초~1분 후 터미널이 열리면 아래와 같은 프롬프트가 표시됩니다:

```
~ $
```

상단 탭에 **ap-northeast-2**가 표시되는지 확인하세요 (리전 확인).

---

## 2. 도구 설치

CloudShell에는 AWS CLI와 Git이 기본 설치되어 있지만, EKS 배포에 필요한 도구 3개를 추가 설치해야 합니다:

- **kubectl** — Kubernetes 클러스터 관리 도구
- **eksctl** — EKS 클러스터 생성/관리 도구
- **Helm** — Kubernetes 패키지 매니저

### 설치 명령 (한번에 복사 & 붙여넣기)

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/ && curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" && tar -xzf eksctl_Linux_amd64.tar.gz -C /tmp && sudo mv /tmp/eksctl /usr/local/bin/ && curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash && echo "=== DONE ==="
```

### envsubst 설치

```bash
sudo yum install -y gettext
```

### 설치 확인

```bash
kubectl version --client && eksctl version && helm version --short && envsubst --version | head -1 && echo "=== ALL OK ==="
```

**예상 출력:**
```
Client Version: v1.3x.x
0.2xx.0
v3.2x.x+xxxxx
envsubst (GNU gettext-runtime) 0.21
=== ALL OK ===
```

---

## 3. 레포 클론 및 실행 준비

```bash
git clone https://github.com/Deokhyun-Lee/aws-db-monitoring-eks-amp.git
cd aws-db-monitoring-eks-amp
chmod +x deploy-all.sh cleanup.sh scripts/db-discovery.sh
```

### CRLF 문제 수정 (Windows에서 업로드된 파일)

```bash
sed -i 's/\r$//' deploy-all.sh cleanup.sh scripts/db-discovery.sh
```

> ⚠️ **반드시 실행**: Windows 환경에서 업로드된 Shell 스크립트는 줄바꿈이 CRLF(\\r\\n)로 되어 있어서 Linux에서 실행 시 `cannot execute: required file not found` 에러가 발생합니다.

---

## 4. Dry-Run 설정 확인

실제 배포 전에 설정을 먼저 확인합니다:

```bash
./deploy-all.sh --region ap-northeast-2 --dry-run
```

**예상 출력:**
```
╔══════════════════════════════════════════════════════════════════╗
║   AWS 데이터베이스 통합 모니터링 - 원클릭 배포                  ║
║   EKS + AMP + AMG + ADOT + DB Exporters                        ║
╚══════════════════════════════════════════════════════════════════╝

▶ 사전 조건 확인 중...

  ✔  AWS CLI: v2.xx.xx
  ✔  kubectl: v1.3x.x
  ✔  Helm: v3.xx.x
  ✔  eksctl: 0.2xx.0
  ✔  envsubst: 설치됨

  ✔  AWS 인증 확인: Account XXXXXXXXXXXX

▶ 배포 설정 요약
  ├── 워크숍 이름:    integrated-db-monitoring
  ├── AWS 리전:       ap-northeast-2
  ├── AWS 계정 ID:    XXXXXXXXXXXX
  ├── VPC CIDR:       10.0.0.0/16
  ├── EKS 버전:       1.31
  └── 클러스터 이름:  integrated-db-monitoring-eks

  ⚠  DRY-RUN 모드: 실제 배포를 수행하지 않습니다.
```

모든 항목에 ✔ 표시가 나오면 준비 완료입니다.

---

## 5. 전체 배포 실행

### 5-1. CloudShell 타임아웃 방지

CloudShell은 **20분 무입력 시 세션이 종료**됩니다. 배포는 35~50분 걸리므로 반드시 대비하세요:

**방법 1: 5분마다 CloudShell 창 클릭 또는 Enter**

**방법 2: 별도 탭에서 주기적으로 확인 명령 실행**

> 💡 CloudShell 상단의 `+` 버튼으로 새 탭을 열 수 있습니다. 하나에서 배포 실행, 다른 하나에서 상태 확인하면 편합니다.

### 5-2. 배포 시작

```bash
./deploy-all.sh --region ap-northeast-2
```

**확인 프롬프트:**
```
위 설정으로 배포를 시작합니다. 예상 소요 시간: 35~50분
예상 비용: ~$3.5/시간 (EKS + Aurora + RDS + ElastiCache + AMP + AMG)
계속하시겠습니까? (y/N): y
```

`y` 입력 후 Enter.

### 5-3. 배포 단계 (자동 순차 진행)

| 단계 | 내용 | 소요시간 |
|------|------|----------|
| [1/8] | VPC + 서브넷 + 보안그룹 (CloudFormation) | ~3분 |
| [2/8] | Aurora MySQL/PG + SQL Server + ElastiCache (CloudFormation) | ~15~20분 |
| [3/8] | EKS 클러스터 v1.31 (eksctl) | ~15~20분 |
| [4/8] | Amazon Managed Prometheus (AMP) | ~1분 |
| [5/8] | Amazon Managed Grafana (AMG) | ~2분 |
| [6/8] | ADOT Collector + DB Exporters (Helm) | ~3분 |
| [7/8] | Grafana 대시보드 배포 | ~1분 |
| [8/8] | 최종 확인 및 접속 정보 출력 | 즉시 |

---

## 6. 배포 진행 상태 확인

### 다른 CloudShell 탭에서 확인

```bash
# CloudFormation 스택 상태 확인
aws cloudformation describe-stacks --stack-name integrated-db-monitoring-network --query 'Stacks[0].StackStatus' --output text --region ap-northeast-2

aws cloudformation describe-stacks --stack-name integrated-db-monitoring-db --query 'Stacks[0].StackStatus' --output text --region ap-northeast-2

aws cloudformation describe-stacks --stack-name integrated-db-monitoring-cache --query 'Stacks[0].StackStatus' --output text --region ap-northeast-2
```

```bash
# EKS 클러스터 상태
eksctl get cluster --region ap-northeast-2
```

```bash
# 쿠버네티스 노드 상태
kubectl get nodes
```

**상태값 해석:**
| 상태 | 의미 |
|------|------|
| `CREATE_IN_PROGRESS` | 정상 생성 중 |
| `CREATE_COMPLETE` | 생성 완료 ✅ |
| `ROLLBACK_IN_PROGRESS` | 에러 발생, 롤백 중 |
| `ROLLBACK_COMPLETE` | 에러로 롤백 완료 (트러블슈팅 필요) |

---

## 7. 배포 완료 후 확인

### 7-1. 전체 인프라 확인

```bash
# EKS 노드
kubectl get nodes

# 모니터링 Pod 상태
kubectl get pods -n observability

# AMP 워크스페이스
aws amp list-workspaces --region ap-northeast-2

# Grafana URL
aws grafana list-workspaces --region ap-northeast-2 --query 'workspaces[0].endpoint' --output text
```

### 7-2. Grafana 접속

1. 위 명령의 Grafana URL을 브라우저에 입력
2. AWS IAM Identity Center로 로그인
3. 대시보드에서 DB 모니터링 지표 확인

### 7-3. DB 엔드포인트 확인

```bash
# Aurora MySQL
aws rds describe-db-clusters --db-cluster-identifier integrated-db-monitoring-mysql-cluster --query 'DBClusters[0].Endpoint' --output text --region ap-northeast-2

# Aurora PostgreSQL
aws rds describe-db-clusters --db-cluster-identifier integrated-db-monitoring-postgresql-cluster --query 'DBClusters[0].Endpoint' --output text --region ap-northeast-2

# SQL Server
aws rds describe-db-instances --db-instance-identifier integrated-db-monitoring-sqlserver --query 'DBInstances[0].Endpoint.Address' --output text --region ap-northeast-2

# ElastiCache Valkey
aws elasticache describe-replication-groups --replication-group-id integrated-db-monitoring-valkey --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' --output text --region ap-northeast-2
```

---

## 8. 트러블슈팅 가이드

배포 중 발생할 수 있는 문제와 해결 방법입니다.

### 8-1. `cannot execute: required file not found`

**원인**: Windows CRLF 줄바꿈  
**해결**:
```bash
sed -i 's/\r$//' deploy-all.sh cleanup.sh scripts/db-discovery.sh
```

### 8-2. `envsubst 미설치`

**해결**:
```bash
sudo yum install -y gettext
```

### 8-3. `invalid version, 1.30 is no longer supported`

**원인**: EKS 버전 1.30이 지원 종료됨  
**해결**: `infrastructure/eks-cluster.yaml`의 version을 1.31 이상으로 변경
```bash
sed -i 's/version: "1.30"/version: "1.31"/' infrastructure/eks-cluster.yaml
```

### 8-4. `Character sets beyond ASCII are not supported`

**원인**: CloudFormation 리소스 Description/GroupDescription에 한국어 포함  
**해결**: 해당 필드를 영어로 변경. 주석(`#`)은 괜찮지만 API에 전달되는 Description 값은 ASCII만 허용.
```bash
# 한국어가 포함된 Description 라인 찾기
grep -n "Description.*[가-힣]" infrastructure/*.yaml | grep -v "^#"
```

### 8-5. `Cannot find version X.X for aurora-mysql/aurora-postgresql`

**원인**: 지정한 엔진 버전이 해당 리전에서 사용 불가  
**해결**: 사용 가능한 버전 확인 후 변경
```bash
# Aurora MySQL 사용 가능 버전 확인
aws rds describe-db-engine-versions --engine aurora-mysql \
  --query 'DBEngineVersions[].EngineVersion' --output text --region ap-northeast-2 | tr '\t' '\n' | tail -10

# Aurora PostgreSQL 사용 가능 버전 확인
aws rds describe-db-engine-versions --engine aurora-postgresql \
  --query 'DBEngineVersions[].EngineVersion' --output text --region ap-northeast-2 | tr '\t' '\n' | tail -10
```

**권장 LTS 버전 (2026년 기준):**
- Aurora MySQL: `8.0.mysql_aurora.3.10.5`
- Aurora PostgreSQL: `17.7`

### 8-6. `Unsupported property [VpcSecurityGroupIds]` (SQL Server)

**원인**: `AWS::RDS::DBInstance` (standalone)는 `VPCSecurityGroups` 사용  
**해결**:
```bash
# SQL Server 인스턴스의 속성명 수정
# AWS::RDS::DBCluster → VpcSecurityGroupIds (O)
# AWS::RDS::DBInstance (standalone) → VPCSecurityGroups (O)
sed -i '/SQLServer/,/Tags:/{s/VpcSecurityGroupIds:/VPCSecurityGroups:/}' infrastructure/database-stack.yaml
```

### 8-7. `Invalid type for parameter ParameterValue, value: [...], type: list`

**원인**: AWS CLI가 쉼표를 리스트 구분자로 해석  
**해결**: deploy-all.sh에서 List 타입 파라미터 값의 쉼표를 `\,`로 이스케이프
```bash
# deploy-all.sh 내 파라미터 전달 시
ParameterKey=DatabaseSubnets,ParameterValue="${DATABASE_SUBNETS//,/\\,}"
```

### 8-8. `metadata.name must be set` (EKS)

**원인**: `envsubst`에 전달되는 환경변수가 `export`되지 않음  
**해결**: deploy-all.sh에서 `CLUSTER_NAME`, `AWS_REGION`, `EKS_VERSION`에 `export` 추가
```bash
export CLUSTER_NAME="${WORKSHOP_NAME}-eks"
export AWS_REGION="ap-northeast-2"
export EKS_VERSION="1.31"
```

### 8-9. `sqlserver-ex` + `db.t3.xlarge` 에러

**원인**: SQL Server Express Edition은 db.t3.medium이 최대  
**해결**:
```bash
sed -i 's/DBInstanceClass: db.t3.xlarge/DBInstanceClass: db.t3.medium/' infrastructure/database-stack.yaml
```

### 8-10. `already exists in stack` (리소스 충돌)

**원인**: 이전 실패 스택이 ROLLBACK_FAILED 상태로 리소스를 보유  
**해결**:
```bash
# 1. 잔여 RDS 인스턴스 수동 삭제
aws rds delete-db-instance --db-instance-identifier integrated-db-monitoring-sqlserver --skip-final-snapshot --region ap-northeast-2

# 2. 삭제 완료 대기
aws rds wait db-instance-deleted --db-instance-identifier integrated-db-monitoring-sqlserver --region ap-northeast-2

# 3. 실패한 스택들 삭제
aws cloudformation delete-stack --stack-name integrated-db-monitoring-db --region ap-northeast-2

# 4. 새 이름으로 재생성
aws cloudformation create-stack --stack-name integrated-db-monitoring-db-v2 ...
```

### 8-11. CloudShell 세션 타임아웃

**원인**: 20분 무입력  
**해결**: 
- 5분마다 CloudShell 창 클릭
- 또는 별도 탭에서 상태 확인 명령 주기적 실행
- 끊겼을 때: 다시 CloudShell 열고 `cd ~/aws-db-monitoring-eks-amp`로 이동

---

## 9. 리소스 정리 (Cleanup)

⚠️ **테스트 완료 후 반드시 실행하세요!** 리소스를 그대로 두면 비용이 계속 발생합니다.

```bash
cd ~/aws-db-monitoring-eks-amp
./cleanup.sh --region ap-northeast-2
```

### 수동 정리 (cleanup.sh 실행이 안 될 경우)

역순으로 삭제합니다:

```bash
# 1. Helm 릴리즈 삭제
helm uninstall adot-collector mysql-exporter postgres-exporter redis-exporter mssql-exporter -n observability 2>/dev/null

# 2. EKS 클러스터 삭제 (~10분)
eksctl delete cluster --name integrated-db-monitoring-eks --region ap-northeast-2

# 3. AMP 워크스페이스 삭제
AMP_WS_ID=$(aws amp list-workspaces --alias integrated-db-monitoring-amp --query 'workspaces[0].workspaceId' --output text --region ap-northeast-2)
aws amp delete-workspace --workspace-id $AMP_WS_ID --region ap-northeast-2

# 4. AMG 워크스페이스 삭제
AMG_WS_ID=$(aws grafana list-workspaces --query 'workspaces[?name==`integrated-db-monitoring-grafana`].id' --output text --region ap-northeast-2)
aws grafana delete-workspace --workspace-id $AMG_WS_ID --region ap-northeast-2

# 5. DB 스택 삭제 (~10분)
aws cloudformation delete-stack --stack-name integrated-db-monitoring-db5 --region ap-northeast-2
aws cloudformation wait stack-delete-complete --stack-name integrated-db-monitoring-db5 --region ap-northeast-2

# 6. Cache 스택 삭제
aws cloudformation delete-stack --stack-name integrated-db-monitoring-cache --region ap-northeast-2
aws cloudformation wait stack-delete-complete --stack-name integrated-db-monitoring-cache --region ap-northeast-2

# 7. VPC 스택 삭제 (마지막 — 다른 스택이 먼저 삭제되어야 함)
aws cloudformation delete-stack --stack-name integrated-db-monitoring-network --region ap-northeast-2
aws cloudformation wait stack-delete-complete --stack-name integrated-db-monitoring-network --region ap-northeast-2

# 8. IAM 역할 정리
aws iam detach-role-policy --role-name integrated-db-monitoring-adot-collector-role --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess 2>/dev/null
aws iam delete-role --role-name integrated-db-monitoring-adot-collector-role 2>/dev/null

echo "=== ALL CLEANED UP ==="
```

### 정리 확인

```bash
# CloudFormation 스택 확인 (없어야 정상)
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE --query 'StackSummaries[?contains(StackName, `integrated-db-monitoring`)].StackName' --output text --region ap-northeast-2

# RDS 인스턴스 확인
aws rds describe-db-instances --query 'DBInstances[?contains(DBInstanceIdentifier, `integrated-db-monitoring`)].DBInstanceIdentifier' --output text --region ap-northeast-2

# EKS 클러스터 확인
eksctl get cluster --region ap-northeast-2
```

---

## 아키텍처 요약

```
┌──────────────────────────────────────────────────────────────┐
│  DB Sources                                                   │
│  ┌─────────────┐ ┌──────────────┐ ┌─────────┐ ┌───────────┐ │
│  │Aurora MySQL │ │Aurora PG     │ │SQL Server│ │ElastiCache│ │
│  │Writer+Reader│ │Writer+Reader │ │(Express) │ │(Valkey)   │ │
│  └──────┬──────┘ └──────┬───────┘ └────┬────┘ └─────┬─────┘ │
└─────────┼───────────────┼──────────────┼────────────┼────────┘
          │               │              │            │
          ▼               ▼              ▼            ▼
┌──────────────────────────────────────────────────────────────┐
│  EKS Cluster (v1.31, 3 nodes)                                │
│  ┌────────────┐ ┌──────────────┐ ┌──────────┐ ┌───────────┐ │
│  │mysqld_exp  │ │postgres_exp  │ │mssql_exp │ │redis_exp  │ │
│  └──────┬─────┘ └──────┬───────┘ └────┬─────┘ └─────┬─────┘ │
│         └───────────────┴──────────────┴─────────────┘       │
│                              │                                │
│                    ┌─────────▼─────────┐                     │
│                    │  ADOT Collector    │                     │
│                    │  (Remote Write)    │                     │
│                    └─────────┬─────────┘                     │
└──────────────────────────────┼───────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────┐
│  Amazon Managed Prometheus (AMP)                              │
│  → Recording Rules (HA Dedup)                                │
│  → AlertManager → SNS (Email/Slack/SMS)                      │
└──────────────────────────────┬───────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────┐
│  Amazon Managed Grafana (AMG)                                 │
│  → 대시보드 (MySQL / PG / MSSQL / Redis / DynamoDB)           │
└──────────────────────────────────────────────────────────────┘
```

---

## 옵션 사용법

```bash
# 기본 배포 (서울 리전)
./deploy-all.sh --region ap-northeast-2

# 설정만 확인 (실제 배포 안 함)
./deploy-all.sh --region ap-northeast-2 --dry-run

# VPC/DB 생성 건너뛰기 (이미 존재할 때)
./deploy-all.sh --region ap-northeast-2 --skip-infra

# DB 생성만 건너뛰기
./deploy-all.sh --region ap-northeast-2 --skip-db

# 워크숍 이름 변경
./deploy-all.sh --region ap-northeast-2 --name my-monitoring

# 도움말
./deploy-all.sh --help
```

---

## 참고 사항

- **CloudShell 스토리지**: CloudShell의 `/home/cloudshell-user/` 디렉토리는 세션 간 유지됩니다. git clone한 레포는 다음 접속 시에도 남아있습니다.
- **비용 최적화**: NAT Gateway는 단일(비용 절감), EKS 노드는 m5.large 3대입니다.
- **보안**: 모든 DB는 Private 서브넷에 배치되며, Public 접근 불가합니다. EKS에서만 접근 가능합니다.
- **Aurora LTS 버전**: MySQL 3.10.5, PostgreSQL 17.7을 사용합니다 (장기 지원 보장).

---

*최종 업데이트: 2026-08-21*
