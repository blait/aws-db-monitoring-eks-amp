# 멀티 어카운트/리전 네트워크 연결 가이드

## 개요

중앙 모니터링 계정의 EKS Pod이 각 워크로드 계정의 DB에 접속하려면 네트워크 연결이 필요합니다.

```
┌─ 중앙 모니터링 계정 ─────────────────┐
│  VPC: 10.0.0.0/16                    │
│  EKS Pod CIDR: 10.0.64.0/18         │
│                                      │
│     Exporter Pod ──────┐             │
└────────────────────────┼─────────────┘
                         │ Transit Gateway / VPC Peering
┌─ 워크로드 계정 ────────┼─────────────┐
│  VPC: 172.16.0.0/16    │             │
│                        ↓             │
│     Aurora MySQL (172.16.10.50:3306) │
└──────────────────────────────────────┘
```

## 옵션 비교

| 방식 | 장점 | 단점 | 비용 | 권장 시나리오 |
|------|------|------|------|---------------|
| **Transit Gateway** ⭐ | 중앙 집중 관리, 확장 용이, 멀티 리전 | 시간당 비용 | $0.05/hr + $0.02/GB | 3개 이상 VPC/계정 |
| **VPC Peering** | 무료(데이터만 과금), 단순 | 1:1 연결, 계정 수만큼 피어링 | $0.01/GB (리전간) | 2~3개 VPC 소규모 |
| **PrivateLink** | 보안 최고, 방화벽 통과 | 서비스별 구성, 복잡 | $0.01/hr + $0.01/GB | 특수 보안 요건 |

---

## 옵션 A: Transit Gateway (권장)

### 구성 순서

#### Step 1: Transit Gateway 생성 (중앙 계정)
```bash
# 중앙 모니터링 계정에서 실행
aws ec2 create-transit-gateway \
  --description "DB Monitoring Hub TGW" \
  --options "AmazonSideAsn=64512,AutoAcceptSharedAttachments=enable,DefaultRouteTableAssociation=enable,DefaultRouteTablePropagation=enable,DnsSupport=enable" \
  --tag-specifications 'ResourceType=transit-gateway,Tags=[{Key=Name,Value=db-monitoring-tgw}]'

# TGW ID 저장
export TGW_ID="tgw-0123456789abcdef0"
```

#### Step 2: Transit Gateway 공유 (RAM)
```bash
# AWS Resource Access Manager로 워크로드 계정에 TGW 공유
aws ram create-resource-share \
  --name "DB-Monitoring-TGW-Share" \
  --resource-arns "arn:aws:ec2:ap-northeast-2:${HUB_ACCOUNT_ID}:transit-gateway/${TGW_ID}" \
  --principals "111111111111" "222222222222" "333333333333" \
  --allow-external-principals

# 또는 Organization 전체에 공유
aws ram create-resource-share \
  --name "DB-Monitoring-TGW-Share" \
  --resource-arns "arn:aws:ec2:ap-northeast-2:${HUB_ACCOUNT_ID}:transit-gateway/${TGW_ID}" \
  --principals "arn:aws:organizations::${ORG_MASTER_ACCOUNT}:organization/${ORG_ID}"
```

#### Step 3: 각 워크로드 계정에서 TGW Attachment
```bash
# 각 워크로드 계정에서 실행
aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id "${TGW_ID}" \
  --vpc-id "vpc-workload-xxxx" \
  --subnet-ids "subnet-private-1" "subnet-private-2" \
  --tag-specifications 'ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=db-monitoring-attachment}]'
```

#### Step 4: 중앙 계정 VPC에서 TGW Attachment
```bash
# 중앙 모니터링 계정에서 실행
aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id "${TGW_ID}" \
  --vpc-id "vpc-monitoring-xxxx" \
  --subnet-ids "subnet-eks-private-1" "subnet-eks-private-2" \
  --tag-specifications 'ResourceType=transit-gateway-attachment,Tags=[{Key=Name,Value=monitoring-hub-attachment}]'
```

#### Step 5: 라우팅 설정
```bash
# 중앙 계정 VPC Route Table: 워크로드 VPC CIDR → TGW
aws ec2 create-route \
  --route-table-id "rtb-eks-private" \
  --destination-cidr-block "172.16.0.0/16" \
  --transit-gateway-id "${TGW_ID}"

# 워크로드 계정 VPC Route Table: 중앙 EKS CIDR → TGW (응답 트래픽용)
aws ec2 create-route \
  --route-table-id "rtb-workload-db" \
  --destination-cidr-block "10.0.0.0/16" \
  --transit-gateway-id "${TGW_ID}"
```

#### Step 6: Security Group 설정
```bash
# 워크로드 계정: DB Security Group에 중앙 EKS Pod CIDR 허용
aws ec2 authorize-security-group-ingress \
  --group-id "sg-workload-db" \
  --protocol tcp \
  --port 3306 \
  --cidr "10.0.64.0/18"    # EKS Pod CIDR

# 포트별 허용 (각 DB 엔진)
# MySQL: 3306, PostgreSQL: 5432, SQL Server: 1433, Redis: 6379
```

---

### 멀티 리전 Transit Gateway Peering

서로 다른 리전의 DB를 모니터링할 때:

```bash
# 리전 A (ap-northeast-2)에 TGW가 이미 있다면,
# 리전 B (us-east-1)에도 TGW 생성 후 Peering

# 리전 B에 TGW 생성
aws ec2 create-transit-gateway \
  --region us-east-1 \
  --description "DB Monitoring TGW (us-east-1)"

# TGW Peering 연결
aws ec2 create-transit-gateway-peering-attachment \
  --transit-gateway-id "${TGW_ID_REGION_A}" \
  --peer-transit-gateway-id "${TGW_ID_REGION_B}" \
  --peer-region "us-east-1" \
  --peer-account-id "${HUB_ACCOUNT_ID}"

# Peering 수락 (us-east-1에서)
aws ec2 accept-transit-gateway-peering-attachment \
  --region us-east-1 \
  --transit-gateway-attachment-id "tgw-attach-xxxxx"
```

---

## DNS 해석 설정

### Route 53 Resolver (권장)

EKS Pod이 다른 계정/VPC의 DB 엔드포인트(예: `mydb.cluster-xxxxx.ap-northeast-2.rds.amazonaws.com`)를 해석해야 합니다.

```bash
# 중앙 계정에 Route 53 Resolver Inbound Endpoint 생성
aws route53resolver create-resolver-endpoint \
  --creator-request-id "db-monitoring-inbound" \
  --security-group-ids "sg-resolver" \
  --direction INBOUND \
  --ip-addresses "SubnetId=subnet-eks-1,Ip=10.0.10.100" "SubnetId=subnet-eks-2,Ip=10.0.11.100"

# 각 워크로드 계정에 Resolver Rule 생성 (RDS DNS → 중앙 Resolver로 포워딩)
# 또는 VPC DNS Resolution 활성화 (VPC Peering/TGW에서)
```

**TGW를 사용하는 경우**: DNS 해석은 일반적으로 자동으로 동작합니다.
RDS 엔드포인트는 Public DNS이지만 Private IP로 해석되며, TGW 라우팅으로 접근 가능합니다.

---

## 옵션 B: VPC Peering (소규모용)

```bash
# 중앙 계정에서 피어링 요청
aws ec2 create-vpc-peering-connection \
  --vpc-id "vpc-monitoring" \
  --peer-vpc-id "vpc-workload" \
  --peer-owner-id "111111111111" \
  --peer-region "ap-northeast-2"

# 워크로드 계정에서 수락
aws ec2 accept-vpc-peering-connection \
  --vpc-peering-connection-id "pcx-xxxxx"

# 양방향 라우트 추가
aws ec2 create-route \
  --route-table-id "rtb-monitoring" \
  --destination-cidr-block "172.16.0.0/16" \
  --vpc-peering-connection-id "pcx-xxxxx"
```

---

## CIDR 설계 권장사항

| 계정/VPC | CIDR | 용도 |
|----------|------|------|
| 중앙 모니터링 | 10.0.0.0/16 | EKS, AMP, AMG |
| Production A | 172.16.0.0/16 | Aurora, RDS |
| Production B | 172.17.0.0/16 | ElastiCache, DynamoDB |
| Staging | 172.18.0.0/16 | Dev/Test DB |
| EU 서비스 | 172.19.0.0/16 | 유럽 리전 DB |

> ⚠️ CIDR이 겹치면 라우팅이 불가합니다. 계정/VPC 설계 시 CIDR 충돌을 반드시 피하세요.

---

## 비용 예상

| 구성 요소 | 월 비용 (10 VPC, ap-northeast-2) |
|-----------|------|
| Transit Gateway (시간당) | ~$36/월 |
| TGW 데이터 전송 | ~$5~15/월 (메트릭 수집 트래픽 소량) |
| Route 53 Resolver | ~$10/월 |
| **총 네트워크 추가 비용** | **~$50~60/월** |

VPC Peering은 데이터 전송 비용만 ($0.01/GB), 소규모 시 $5 미만.

---

## 체크리스트

- [ ] CIDR 충돌 없음 확인
- [ ] Transit Gateway 생성 및 공유 (RAM)
- [ ] 각 계정에서 TGW Attachment
- [ ] Route Table 업데이트 (양방향)
- [ ] Security Group: DB 포트 개방 (3306, 5432, 1433, 6379)
- [ ] DNS 해석 확인 (EKS Pod에서 `nslookup <db-endpoint>`)
- [ ] 연결 테스트 (EKS Pod에서 `telnet <db-endpoint> <port>`)
