#!/bin/bash
###############################################################################
# AWS 데이터베이스 통합 모니터링 원클릭 배포 스크립트
# GitHub: https://github.com/Deokhyun-Lee/aws-db-monitoring-eks-amp
#
# 이 스크립트는 다음을 자동으로 배포합니다:
#   1. VPC + 네트워킹 인프라
#   2. Aurora MySQL (Writer + Reader×2), Aurora PostgreSQL (Writer + Reader×2)
#   3. RDS SQL Server, ElastiCache Valkey
#   4. EKS 클러스터 (v1.30)
#   5. Amazon Managed Prometheus (AMP)
#   6. Amazon Managed Grafana (AMG)
#   7. ADOT Collector + DB Exporters (MySQL, PostgreSQL, MSSQL, Redis)
#   8. Grafana 대시보드 자동 구성
#
# 사용법: ./deploy-all.sh [--region ap-northeast-2] [--skip-db] [--dry-run]
###############################################################################

set -euo pipefail

#==============================================================================
# 색상 및 포맷팅
#==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# 진행 상태 카운터
TOTAL_STEPS=8
CURRENT_STEP=0

#==============================================================================
# 유틸리티 함수
#==============================================================================
print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║   AWS 데이터베이스 통합 모니터링 - 원클릭 배포                  ║"
    echo "║   EKS + AMP + AMG + ADOT + DB Exporters                        ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${GREEN}[${CURRENT_STEP}/${TOTAL_STEPS}]${NC} ${WHITE}$1${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

log_info() {
    echo -e "  ${CYAN}ℹ${NC}  $1"
}

log_success() {
    echo -e "  ${GREEN}✔${NC}  $1"
}

log_warning() {
    echo -e "  ${YELLOW}⚠${NC}  $1"
}

log_error() {
    echo -e "  ${RED}✘${NC}  $1"
}

log_wait() {
    echo -e "  ${PURPLE}⏳${NC} $1"
}

# 스피너 (장시간 작업 시 사용)
spinner() {
    local pid=$1
    local delay=0.5
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf "  ${PURPLE}%c${NC} %s\r" "$spinstr" "$2"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "  ${GREEN}✔${NC} %s\n" "$2"
}

# 경과 시간 표시
show_elapsed() {
    local start=$1
    local end=$(date +%s)
    local elapsed=$((end - start))
    local min=$((elapsed / 60))
    local sec=$((elapsed % 60))
    echo -e "  ${CYAN}⏱${NC}  소요 시간: ${min}분 ${sec}초"
}

# 에러 핸들링
handle_error() {
    local line=$1
    local exit_code=$2
    echo ""
    log_error "스크립트 실행 중 오류 발생 (라인: ${line}, 종료코드: ${exit_code})"
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  롤백 안내                                                       ║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║  다음 명령으로 생성된 리소스를 정리할 수 있습니다:                ║${NC}"
    echo -e "${YELLOW}║    ./cleanup.sh                                                  ║${NC}"
    echo -e "${YELLOW}║                                                                  ║${NC}"
    echo -e "${YELLOW}║  또는 특정 단계부터 재시작:                                      ║${NC}"
    echo -e "${YELLOW}║    ./deploy-all.sh --skip-infra  (인프라 건너뛰기)               ║${NC}"
    echo -e "${YELLOW}║    ./deploy-all.sh --skip-db     (DB 생성 건너뛰기)              ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
    exit $exit_code
}

trap 'handle_error ${LINENO} $?' ERR

#==============================================================================
# 설정 변수
#==============================================================================
WORKSHOP_NAME="${WORKSHOP_NAME:-integrated-db-monitoring}"
AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo 'ap-northeast-2')}"
VPC_CIDR="${VPC_CIDR:-10.0.0.0/16}"
EKS_VERSION="1.30"
SKIP_INFRA=false
SKIP_DB=false
DRY_RUN=false

# 명령줄 인자 파싱
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            AWS_REGION="$2"
            shift 2
            ;;
        --name)
            WORKSHOP_NAME="$2"
            shift 2
            ;;
        --skip-infra)
            SKIP_INFRA=true
            shift
            ;;
        --skip-db)
            SKIP_DB=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "사용법: $0 [옵션]"
            echo ""
            echo "옵션:"
            echo "  --region REGION    AWS 리전 (기본: ap-northeast-2)"
            echo "  --name NAME        워크숍 이름 (기본: integrated-db-monitoring)"
            echo "  --skip-infra       네트워킹/DB 인프라 건너뛰기"
            echo "  --skip-db          DB 스택 생성 건너뛰기"
            echo "  --dry-run          실제 배포 없이 설정만 확인"
            echo "  --help, -h         이 도움말 표시"
            exit 0
            ;;
        *)
            log_error "알 수 없는 옵션: $1"
            exit 1
            ;;
    esac
done

# 파생 변수
CLUSTER_NAME="${WORKSHOP_NAME}-eks"
ACCOUNT_ID=""
OIDC_PROVIDER=""

#==============================================================================
# Step 0: 사전 조건 확인
#==============================================================================
print_banner

echo -e "${WHITE}${BOLD}▶ 사전 조건 확인 중...${NC}"
echo ""

check_command() {
    local cmd=$1
    local min_version=$2
    local install_hint=$3
    
    if command -v "$cmd" &> /dev/null; then
        local version=$($cmd version --short 2>/dev/null || $cmd version --client -o yaml 2>/dev/null | grep gitVersion | awk '{print $2}' || $cmd --version 2>/dev/null | head -1 || echo "unknown")
        log_success "$cmd 설치됨: $version"
        return 0
    else
        log_error "$cmd 미설치. 설치 방법: $install_hint"
        return 1
    fi
}

PREREQ_OK=true

# AWS CLI
if command -v aws &> /dev/null; then
    AWS_VERSION=$(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2)
    log_success "AWS CLI: v${AWS_VERSION}"
else
    log_error "AWS CLI 미설치. 설치: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html"
    PREREQ_OK=false
fi

# kubectl
if command -v kubectl &> /dev/null; then
    KUBECTL_VERSION=$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion": "[^"]*"' | cut -d'"' -f4 || echo "설치됨")
    log_success "kubectl: ${KUBECTL_VERSION}"
else
    log_error "kubectl 미설치. 설치: https://kubernetes.io/docs/tasks/tools/"
    PREREQ_OK=false
fi

# Helm
if command -v helm &> /dev/null; then
    HELM_VERSION=$(helm version --short 2>/dev/null || echo "설치됨")
    log_success "Helm: ${HELM_VERSION}"
else
    log_error "Helm 미설치. 설치: brew install helm 또는 https://helm.sh/docs/intro/install/"
    PREREQ_OK=false
fi

# eksctl
if command -v eksctl &> /dev/null; then
    EKSCTL_VERSION=$(eksctl version 2>/dev/null || echo "설치됨")
    log_success "eksctl: ${EKSCTL_VERSION}"
else
    log_error "eksctl 미설치. 설치: brew install eksctl 또는 https://eksctl.io/installation/"
    PREREQ_OK=false
fi

# envsubst
if command -v envsubst &> /dev/null; then
    log_success "envsubst: 설치됨"
else
    log_error "envsubst 미설치. 설치: brew install gettext (macOS) 또는 apt install gettext (Linux)"
    PREREQ_OK=false
fi

# AWS 자격증명 확인
echo ""
if aws sts get-caller-identity &> /dev/null; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    log_success "AWS 인증 확인: Account ${ACCOUNT_ID}"
else
    log_error "AWS 자격증명 미설정. 'aws configure' 를 먼저 실행하세요."
    PREREQ_OK=false
fi

if [ "$PREREQ_OK" = false ]; then
    echo ""
    log_error "사전 조건을 충족하지 못했습니다. 위 안내에 따라 설치 후 다시 실행하세요."
    exit 1
fi

#==============================================================================
# 설정 요약 출력
#==============================================================================
echo ""
echo -e "${WHITE}${BOLD}▶ 배포 설정 요약${NC}"
echo -e "  ├── 워크숍 이름:    ${CYAN}${WORKSHOP_NAME}${NC}"
echo -e "  ├── AWS 리전:       ${CYAN}${AWS_REGION}${NC}"
echo -e "  ├── AWS 계정 ID:    ${CYAN}${ACCOUNT_ID}${NC}"
echo -e "  ├── VPC CIDR:       ${CYAN}${VPC_CIDR}${NC}"
echo -e "  ├── EKS 버전:       ${CYAN}${EKS_VERSION}${NC}"
echo -e "  └── 클러스터 이름:  ${CYAN}${CLUSTER_NAME}${NC}"
echo ""

if [ "$DRY_RUN" = true ]; then
    log_warning "DRY-RUN 모드: 실제 배포를 수행하지 않습니다."
    exit 0
fi

# 확인
echo -e "${YELLOW}위 설정으로 배포를 시작합니다. 예상 소요 시간: 35~50분${NC}"
echo -e "${YELLOW}예상 비용: ~\$3.5/시간 (EKS + Aurora + RDS + ElastiCache + AMP + AMG)${NC}"
read -p "계속하시겠습니까? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "배포를 취소합니다."
    exit 0
fi

DEPLOY_START=$(date +%s)

#==============================================================================
# Step 1: 네트워킹 인프라 배포
#==============================================================================
if [ "$SKIP_INFRA" = false ]; then
    log_step "네트워킹 인프라 배포 (VPC, 서브넷, 보안 그룹)"
    STEP_START=$(date +%s)

    log_info "CloudFormation 스택 생성: ${WORKSHOP_NAME}-network"
    aws cloudformation create-stack \
        --stack-name ${WORKSHOP_NAME}-network \
        --template-body file://infrastructure/networking-stack.yaml \
        --parameters \
            ParameterKey=EnvironmentName,ParameterValue=${WORKSHOP_NAME} \
            ParameterKey=VpcCidr,ParameterValue=${VPC_CIDR} \
        --capabilities CAPABILITY_IAM \
        --region ${AWS_REGION}

    log_wait "네트워킹 스택 생성 대기 중... (약 3~5분)"
    aws cloudformation wait stack-create-complete \
        --stack-name ${WORKSHOP_NAME}-network \
        --region ${AWS_REGION}

    log_success "네트워킹 스택 생성 완료"
    show_elapsed $STEP_START

    # 네트워킹 출력값 저장
    export VPC_ID=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-network \
        --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
        --output text --region ${AWS_REGION})

    export PUBLIC_SUBNETS=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-network \
        --query 'Stacks[0].Outputs[?OutputKey==`PublicSubnets`].OutputValue' \
        --output text --region ${AWS_REGION})

    export PRIVATE_SUBNETS=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-network \
        --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnets`].OutputValue' \
        --output text --region ${AWS_REGION})

    export DATABASE_SUBNETS=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-network \
        --query 'Stacks[0].Outputs[?OutputKey==`DatabaseSubnets`].OutputValue' \
        --output text --region ${AWS_REGION})

    export PRIVATE_SUBNET_CIDRS=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-network \
        --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnetCidrs`].OutputValue' \
        --output text --region ${AWS_REGION})

    log_success "VPC ID: ${VPC_ID}"
else
    log_step "네트워킹 인프라 (SKIP)"
    log_warning "기존 네트워킹 인프라 사용"
    
    # 기존 스택에서 값 가져오기
    export VPC_ID=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-network \
        --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
        --output text --region ${AWS_REGION})
    export PUBLIC_SUBNETS=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-network \
        --query 'Stacks[0].Outputs[?OutputKey==`PublicSubnets`].OutputValue' \
        --output text --region ${AWS_REGION})
    export PRIVATE_SUBNETS=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-network \
        --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnets`].OutputValue' \
        --output text --region ${AWS_REGION})
    export DATABASE_SUBNETS=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-network \
        --query 'Stacks[0].Outputs[?OutputKey==`DatabaseSubnets`].OutputValue' \
        --output text --region ${AWS_REGION})
    export PRIVATE_SUBNET_CIDRS=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-network \
        --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnetCidrs`].OutputValue' \
        --output text --region ${AWS_REGION})
fi

#==============================================================================
# Step 2: 데이터베이스 인프라 배포
#==============================================================================
if [ "$SKIP_DB" = false ] && [ "$SKIP_INFRA" = false ]; then
    log_step "데이터베이스 인프라 배포 (Aurora MySQL/PG, SQL Server, ElastiCache)"
    STEP_START=$(date +%s)

    # 2-1: 데이터베이스 스택 (Aurora MySQL 3개, Aurora PostgreSQL 3개, SQL Server 1개)
    log_info "데이터베이스 스택 생성 중... (Aurora MySQL, Aurora PostgreSQL, SQL Server)"
    aws cloudformation create-stack \
        --stack-name ${WORKSHOP_NAME}-db \
        --template-body file://infrastructure/database-stack.yaml \
        --parameters \
            ParameterKey=EnvironmentName,ParameterValue=${WORKSHOP_NAME} \
            ParameterKey=VpcId,ParameterValue=${VPC_ID} \
            ParameterKey=DatabaseSubnets,ParameterValue=\"${DATABASE_SUBNETS}\" \
            ParameterKey=PrivateSubnetCidrs,ParameterValue=\"${PRIVATE_SUBNET_CIDRS}\" \
            ParameterKey=PublicSubnets,ParameterValue=\"${PUBLIC_SUBNETS}\" \
            ParameterKey=SQLServerMasterUsername,ParameterValue=admin \
            ParameterKey=SQLServerMasterPassword,ParameterValue=AdminAdmin123! \
        --capabilities CAPABILITY_IAM \
        --region ${AWS_REGION}

    # 2-2: 캐시 스택 (ElastiCache Valkey)
    log_info "캐시 스택 생성 중... (ElastiCache Valkey)"
    aws cloudformation create-stack \
        --stack-name ${WORKSHOP_NAME}-cache \
        --template-body file://infrastructure/cache-stack.yaml \
        --parameters \
            ParameterKey=EnvironmentName,ParameterValue=${WORKSHOP_NAME} \
            ParameterKey=VpcId,ParameterValue=${VPC_ID} \
            ParameterKey=DatabaseSubnets,ParameterValue=\"${DATABASE_SUBNETS}\" \
            ParameterKey=PrivateSubnetCidrs,ParameterValue=\"${PRIVATE_SUBNET_CIDRS}\" \
        --capabilities CAPABILITY_IAM \
        --region ${AWS_REGION}

    # 두 스택 병렬 대기
    log_wait "데이터베이스 스택 생성 대기 중... (약 15~20분)"
    aws cloudformation wait stack-create-complete \
        --stack-name ${WORKSHOP_NAME}-db \
        --region ${AWS_REGION}
    log_success "데이터베이스 스택 완료"

    log_wait "캐시 스택 생성 대기 중..."
    aws cloudformation wait stack-create-complete \
        --stack-name ${WORKSHOP_NAME}-cache \
        --region ${AWS_REGION}
    log_success "캐시 스택 완료"

    show_elapsed $STEP_START

    # 엔드포인트 저장
    export MYSQL_ENDPOINT1=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-db \
        --query 'Stacks[0].Outputs[?OutputKey==`MySQLInstance1Endpoint`].OutputValue' \
        --output text --region ${AWS_REGION})
    export MYSQL_ENDPOINT2=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-db \
        --query 'Stacks[0].Outputs[?OutputKey==`MySQLInstance2Endpoint`].OutputValue' \
        --output text --region ${AWS_REGION})
    export MYSQL_ENDPOINT3=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-db \
        --query 'Stacks[0].Outputs[?OutputKey==`MySQLInstance3Endpoint`].OutputValue' \
        --output text --region ${AWS_REGION})
    export POSTGRESQL_ENDPOINT1=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-db \
        --query 'Stacks[0].Outputs[?OutputKey==`PostgreSQLInstance1Endpoint`].OutputValue' \
        --output text --region ${AWS_REGION})
    export POSTGRESQL_ENDPOINT2=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-db \
        --query 'Stacks[0].Outputs[?OutputKey==`PostgreSQLInstance2Endpoint`].OutputValue' \
        --output text --region ${AWS_REGION})
    export POSTGRESQL_ENDPOINT3=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-db \
        --query 'Stacks[0].Outputs[?OutputKey==`PostgreSQLInstance3Endpoint`].OutputValue' \
        --output text --region ${AWS_REGION})
    export SQLSERVER_ENDPOINT=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-db \
        --query 'Stacks[0].Outputs[?OutputKey==`SQLServerInstanceEndpoint`].OutputValue' \
        --output text --region ${AWS_REGION})
    export ELASTICACHE_VALKEY_ENDPOINT=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-cache \
        --query 'Stacks[0].Outputs[?OutputKey==`ElastiCacheRedisEndpoint`].OutputValue' \
        --output text --region ${AWS_REGION})
    export ELASTICACHE_VALKEY_PORT=$(aws cloudformation describe-stacks \
        --stack-name ${WORKSHOP_NAME}-cache \
        --query 'Stacks[0].Outputs[?OutputKey==`ElastiCacheRedisPort`].OutputValue' \
        --output text --region ${AWS_REGION})

    log_info "MySQL 엔드포인트: ${MYSQL_ENDPOINT1}, ${MYSQL_ENDPOINT2}, ${MYSQL_ENDPOINT3}"
    log_info "PostgreSQL 엔드포인트: ${POSTGRESQL_ENDPOINT1}, ${POSTGRESQL_ENDPOINT2}, ${POSTGRESQL_ENDPOINT3}"
    log_info "SQL Server 엔드포인트: ${SQLSERVER_ENDPOINT}"
    log_info "ElastiCache Valkey: ${ELASTICACHE_VALKEY_ENDPOINT}:${ELASTICACHE_VALKEY_PORT}"
else
    log_step "데이터베이스 인프라 (SKIP)"
    log_warning "기존 데이터베이스 인프라 사용"
    
    # 기존 스택에서 엔드포인트 가져오기
    export MYSQL_ENDPOINT1=$(aws cloudformation describe-stacks --stack-name ${WORKSHOP_NAME}-db \
        --query 'Stacks[0].Outputs[?OutputKey==`MySQLInstance1Endpoint`].OutputValue' --output text --region ${AWS_REGION} 2>/dev/null || echo "")
    export SQLSERVER_ENDPOINT=$(aws cloudformation describe-stacks --stack-name ${WORKSHOP_NAME}-db \
        --query 'Stacks[0].Outputs[?OutputKey==`SQLServerInstanceEndpoint`].OutputValue' --output text --region ${AWS_REGION} 2>/dev/null || echo "")
    export ELASTICACHE_VALKEY_ENDPOINT=$(aws cloudformation describe-stacks --stack-name ${WORKSHOP_NAME}-cache \
        --query 'Stacks[0].Outputs[?OutputKey==`ElastiCacheRedisEndpoint`].OutputValue' --output text --region ${AWS_REGION} 2>/dev/null || echo "")
    export ELASTICACHE_VALKEY_PORT=$(aws cloudformation describe-stacks --stack-name ${WORKSHOP_NAME}-cache \
        --query 'Stacks[0].Outputs[?OutputKey==`ElastiCacheRedisPort`].OutputValue' --output text --region ${AWS_REGION} 2>/dev/null || echo "6379")
fi

#==============================================================================
# Step 3: EKS 클러스터 생성
#==============================================================================
log_step "EKS 클러스터 생성 (v${EKS_VERSION})"
STEP_START=$(date +%s)

export PRIVATE_SUBNET_1=$(echo $PRIVATE_SUBNETS | cut -d',' -f1)
export PRIVATE_SUBNET_2=$(echo $PRIVATE_SUBNETS | cut -d',' -f2)
export PRIVATE_SUBNET_3=$(echo $PRIVATE_SUBNETS | cut -d',' -f3)

# EKS 클러스터 설정 파일 생성 (envsubst)
log_info "EKS 클러스터 설정 파일 생성 중..."
envsubst < infrastructure/eks-cluster.yaml > eks-cluster-resolved.yaml

# 클러스터 생성
log_wait "EKS 클러스터 생성 중... (약 15~20분)"
eksctl create cluster -f eks-cluster-resolved.yaml

# OIDC Provider 활성화
log_info "OIDC Provider 활성화..."
eksctl utils associate-iam-oidc-provider \
    --region ${AWS_REGION} \
    --cluster ${CLUSTER_NAME} \
    --approve

export OIDC_PROVIDER=$(aws eks describe-cluster \
    --name ${CLUSTER_NAME} \
    --query "cluster.identity.oidc.issuer" \
    --output text --region ${AWS_REGION} | sed -e "s/^https:\/\///")

# 클러스터 확인
log_info "클러스터 노드 확인:"
kubectl get nodes

log_success "EKS 클러스터 생성 완료: ${CLUSTER_NAME}"
show_elapsed $STEP_START

#==============================================================================
# Step 4: Amazon Managed Prometheus (AMP) 설정
#==============================================================================
log_step "Amazon Managed Prometheus (AMP) 설정"
STEP_START=$(date +%s)

# AMP 워크스페이스 생성
log_info "AMP 워크스페이스 생성..."
aws amp create-workspace \
    --alias ${WORKSHOP_NAME}-amp \
    --tags Name=${WORKSHOP_NAME}-amp \
    --region ${AWS_REGION}

# 워크스페이스 ID 대기 (생성까지 약간의 시간 필요)
sleep 5

export AMP_WORKSPACE_ID=$(aws amp list-workspaces \
    --alias ${WORKSHOP_NAME}-amp \
    --query 'workspaces[0].workspaceId' \
    --output text --region ${AWS_REGION})

export AMP_ENDPOINT="https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/api/v1/remote_write"
export AMP_QUERY_ENDPOINT="https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}"

log_success "AMP 워크스페이스 ID: ${AMP_WORKSPACE_ID}"
log_info "AMP Remote Write: ${AMP_ENDPOINT}"

# ADOT Collector IAM 역할 생성
log_info "ADOT Collector IAM 역할 생성..."
cat > /tmp/adot-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:observability:adot-collector",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
    --role-name ${WORKSHOP_NAME}-adot-collector-role \
    --assume-role-policy-document file:///tmp/adot-trust-policy.json 2>/dev/null || \
    log_warning "IAM 역할이 이미 존재합니다. 기존 역할을 사용합니다."

aws iam attach-role-policy \
    --role-name ${WORKSHOP_NAME}-adot-collector-role \
    --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess 2>/dev/null || true

export ADOT_ROLE_ARN=$(aws iam get-role \
    --role-name ${WORKSHOP_NAME}-adot-collector-role \
    --query 'Role.Arn' \
    --output text)

log_success "ADOT IAM Role ARN: ${ADOT_ROLE_ARN}"
show_elapsed $STEP_START

#==============================================================================
# Step 5: Amazon Managed Grafana (AMG) 설정
#==============================================================================
log_step "Amazon Managed Grafana (AMG) 설정"
STEP_START=$(date +%s)

# AMG 워크스페이스 생성 (CLI)
log_info "AMG 워크스페이스 생성..."

# AMG 서비스 역할 생성
cat > /tmp/amg-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "grafana.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "${ACCOUNT_ID}"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
    --role-name ${WORKSHOP_NAME}-amg-role \
    --assume-role-policy-document file:///tmp/amg-trust-policy.json 2>/dev/null || \
    log_warning "AMG IAM 역할이 이미 존재합니다."

# AMG에 AMP 및 CloudWatch 접근 권한 부여
aws iam attach-role-policy \
    --role-name ${WORKSHOP_NAME}-amg-role \
    --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess 2>/dev/null || true

aws iam attach-role-policy \
    --role-name ${WORKSHOP_NAME}-amg-role \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess 2>/dev/null || true

AMG_ROLE_ARN=$(aws iam get-role \
    --role-name ${WORKSHOP_NAME}-amg-role \
    --query 'Role.Arn' --output text)

# AMG 워크스페이스 생성
AMG_WS_ID=$(aws grafana create-workspace \
    --workspace-name "${WORKSHOP_NAME}-grafana" \
    --account-access-type CURRENT_ACCOUNT \
    --authentication-providers AWS_SSO \
    --permission-type SERVICE_MANAGED \
    --workspace-role-arn "${AMG_ROLE_ARN}" \
    --workspace-data-sources PROMETHEUS CLOUDWATCH \
    --region ${AWS_REGION} \
    --query 'workspace.id' \
    --output text 2>/dev/null || echo "")

if [ -z "$AMG_WS_ID" ]; then
    # 이미 존재하는 경우 조회
    AMG_WS_ID=$(aws grafana list-workspaces \
        --region ${AWS_REGION} \
        --query "workspaces[?name=='${WORKSHOP_NAME}-grafana'].id" \
        --output text)
    log_warning "AMG 워크스페이스가 이미 존재합니다: ${AMG_WS_ID}"
fi

# AMG 워크스페이스가 ACTIVE 될 때까지 대기
log_wait "AMG 워크스페이스 활성화 대기..."
for i in $(seq 1 30); do
    AMG_STATUS=$(aws grafana describe-workspace \
        --workspace-id ${AMG_WS_ID} \
        --region ${AWS_REGION} \
        --query 'workspace.status' \
        --output text 2>/dev/null || echo "CREATING")
    if [ "$AMG_STATUS" = "ACTIVE" ]; then
        break
    fi
    sleep 10
done

AMG_ENDPOINT=$(aws grafana describe-workspace \
    --workspace-id ${AMG_WS_ID} \
    --region ${AWS_REGION} \
    --query 'workspace.endpoint' \
    --output text)

log_success "AMG 워크스페이스: https://${AMG_ENDPOINT}"

# AMG에 AMP 데이터소스 등록 (Grafana API key 필요)
log_info "AMG 데이터소스 구성을 위해 API Key 생성..."
AMG_API_KEY=$(aws grafana create-workspace-api-key \
    --workspace-id ${AMG_WS_ID} \
    --key-name "deploy-automation" \
    --key-role ADMIN \
    --seconds-to-live 3600 \
    --region ${AWS_REGION} \
    --query 'key' \
    --output text 2>/dev/null || echo "")

if [ -n "$AMG_API_KEY" ]; then
    # Prometheus 데이터소스 추가
    log_info "AMP 데이터소스 등록..."
    curl -s -X POST "https://${AMG_ENDPOINT}/api/datasources" \
        -H "Authorization: Bearer ${AMG_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"Amazon Managed Prometheus\",
            \"type\": \"prometheus\",
            \"url\": \"${AMP_QUERY_ENDPOINT}\",
            \"access\": \"proxy\",
            \"isDefault\": true,
            \"jsonData\": {
                \"httpMethod\": \"POST\",
                \"sigV4Auth\": true,
                \"sigV4AuthType\": \"default\",
                \"sigV4Region\": \"${AWS_REGION}\"
            }
        }" > /dev/null && log_success "AMP 데이터소스 등록 완료" || log_warning "데이터소스 등록 실패 - 수동 등록 필요"

    # CloudWatch 데이터소스 추가
    log_info "CloudWatch 데이터소스 등록..."
    curl -s -X POST "https://${AMG_ENDPOINT}/api/datasources" \
        -H "Authorization: Bearer ${AMG_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"Amazon CloudWatch\",
            \"type\": \"cloudwatch\",
            \"access\": \"proxy\",
            \"jsonData\": {
                \"authType\": \"default\",
                \"defaultRegion\": \"${AWS_REGION}\"
            }
        }" > /dev/null && log_success "CloudWatch 데이터소스 등록 완료" || log_warning "CloudWatch 데이터소스 등록 실패"
else
    log_warning "AMG API Key 생성 실패. 데이터소스를 수동으로 등록해야 합니다."
    log_info "AMG 콘솔: https://${AMG_ENDPOINT}"
fi

show_elapsed $STEP_START

#==============================================================================
# Step 6: 모니터링 스택 배포 (Helm)
#==============================================================================
log_step "모니터링 스택 배포 (ADOT + Exporters)"
STEP_START=$(date +%s)

# observability 네임스페이스 생성
log_info "Kubernetes 네임스페이스 생성..."
kubectl create namespace observability 2>/dev/null || true

# Helm repos 추가
log_info "Helm 레포지토리 추가..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update

# DB Discovery 실행 (Aurora + RDS 인스턴스 자동 탐색)
log_info "DB 인스턴스 디스커버리 실행..."
if [ -f "./scripts/db-discovery.sh" ]; then
    chmod +x ./scripts/db-discovery.sh
    ./scripts/db-discovery.sh
fi

# 6-1: ADOT Collector 배포
log_info "ADOT Collector 배포..."
helm upgrade --install adot-collector open-telemetry/opentelemetry-collector \
    --namespace observability \
    --values helm-charts/adot-collector/values.yaml \
    --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${ADOT_ROLE_ARN}" \
    --set config.exporters.prometheusremotewrite.endpoint="${AMP_ENDPOINT}" \
    --wait --timeout 5m

log_success "ADOT Collector 배포 완료"

# 6-2: MySQL Exporter 배포
log_info "MySQL Exporter 배포..."
helm upgrade --install mysql-exporter prometheus-community/prometheus-mysql-exporter \
    --namespace observability \
    --values helm-charts/mysql-exporter/values.yaml \
    --wait --timeout 3m

log_success "MySQL Exporter 배포 완료"

# 6-3: PostgreSQL Exporter 배포
log_info "PostgreSQL Exporter 배포..."
helm upgrade --install postgres-exporter prometheus-community/prometheus-postgres-exporter \
    --namespace observability \
    --values helm-charts/postgres-exporter/values.yaml \
    --wait --timeout 3m

log_success "PostgreSQL Exporter 배포 완료"

# 6-4: Redis (Valkey) Exporter 배포
log_info "Redis/Valkey Exporter 배포..."
helm upgrade --install redis-exporter prometheus-community/prometheus-redis-exporter \
    --namespace observability \
    --values helm-charts/redis-exporter/values.yaml \
    --set "redisAddress=redis://${ELASTICACHE_VALKEY_ENDPOINT}:${ELASTICACHE_VALKEY_PORT}" \
    --wait --timeout 3m

log_success "Redis Exporter 배포 완료"

# 6-5: MS SQL Exporter 배포
log_info "MS SQL Exporter 배포..."
helm upgrade --install mssql-exporter ./helm-charts/mssql-exporter \
    --namespace observability \
    --set "mssql.host=${SQLSERVER_ENDPOINT}" \
    --set "mssql.port=1433" \
    --set "mssql.username=admin" \
    --set "mssql.password=AdminAdmin123!" \
    --wait --timeout 3m

log_success "MS SQL Exporter 배포 완료"

# Pod 상태 확인
echo ""
log_info "모니터링 Pod 상태 확인:"
kubectl get pods -n observability -o wide
echo ""

show_elapsed $STEP_START

#==============================================================================
# Step 7: Grafana 대시보드 배포
#==============================================================================
log_step "Grafana 대시보드 배포"
STEP_START=$(date +%s)

if [ -n "$AMG_API_KEY" ]; then
    # 대시보드 JSON 파일 배포
    for dashboard_file in dashboards/*.json; do
        if [ -f "$dashboard_file" ]; then
            DASHBOARD_NAME=$(basename "$dashboard_file" .json)
            log_info "대시보드 배포: ${DASHBOARD_NAME}"
            
            DASHBOARD_JSON=$(cat "$dashboard_file")
            curl -s -X POST "https://${AMG_ENDPOINT}/api/dashboards/db" \
                -H "Authorization: Bearer ${AMG_API_KEY}" \
                -H "Content-Type: application/json" \
                -d "{
                    \"dashboard\": ${DASHBOARD_JSON},
                    \"overwrite\": true,
                    \"message\": \"Auto-deployed by deploy-all.sh\"
                }" > /dev/null && log_success "${DASHBOARD_NAME} 배포 완료" || \
                log_warning "${DASHBOARD_NAME} 배포 실패"
        fi
    done
else
    log_warning "AMG API Key가 없어 대시보드를 수동으로 import해야 합니다."
    log_info "대시보드 파일: dashboards/ 디렉토리"
fi

show_elapsed $STEP_START

#==============================================================================
# Step 8: 최종 확인 및 접속 정보 출력
#==============================================================================
log_step "배포 완료 및 접속 정보"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  🎉 배포가 성공적으로 완료되었습니다!                            ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${WHITE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${WHITE}${BOLD} 접속 정보${NC}"
echo -e "${WHITE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${CYAN}Amazon Managed Grafana:${NC}"
echo -e "    URL: ${GREEN}https://${AMG_ENDPOINT}${NC}"
echo ""
echo -e "  ${CYAN}Amazon Managed Prometheus:${NC}"
echo -e "    Workspace ID: ${GREEN}${AMP_WORKSPACE_ID}${NC}"
echo -e "    Query URL:    ${GREEN}${AMP_QUERY_ENDPOINT}${NC}"
echo ""
echo -e "  ${CYAN}EKS 클러스터:${NC}"
echo -e "    이름: ${GREEN}${CLUSTER_NAME}${NC}"
echo -e "    리전: ${GREEN}${AWS_REGION}${NC}"
echo ""
echo -e "  ${CYAN}데이터베이스 엔드포인트:${NC}"
echo -e "    Aurora MySQL:      ${GREEN}${MYSQL_ENDPOINT1:-N/A}${NC}"
echo -e "    Aurora PostgreSQL:  ${GREEN}${POSTGRESQL_ENDPOINT1:-N/A}${NC}"
echo -e "    SQL Server:         ${GREEN}${SQLSERVER_ENDPOINT:-N/A}${NC}"
echo -e "    ElastiCache Valkey: ${GREEN}${ELASTICACHE_VALKEY_ENDPOINT:-N/A}:${ELASTICACHE_VALKEY_PORT:-6379}${NC}"
echo ""
echo -e "${WHITE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${WHITE}${BOLD} 모니터링 Pod 상태${NC}"
echo -e "${WHITE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
kubectl get pods -n observability --no-headers | while read line; do
    echo -e "    ${line}"
done
echo ""

# 총 소요 시간
DEPLOY_END=$(date +%s)
TOTAL_ELAPSED=$((DEPLOY_END - DEPLOY_START))
TOTAL_MIN=$((TOTAL_ELAPSED / 60))
TOTAL_SEC=$((TOTAL_ELAPSED % 60))
echo -e "  ${CYAN}⏱ 총 배포 소요 시간: ${BOLD}${TOTAL_MIN}분 ${TOTAL_SEC}초${NC}"
echo ""
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW} 💡 다음 단계:${NC}"
echo -e "${YELLOW}   1. AMG 콘솔에서 IAM Identity Center 사용자 할당${NC}"
echo -e "${YELLOW}   2. Grafana 로그인 후 대시보드 확인${NC}"
echo -e "${YELLOW}   3. 정리: ./cleanup.sh${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# 설정값 파일로 저장 (나중에 cleanup에서 사용)
cat > .deploy-state.env << EOF
WORKSHOP_NAME=${WORKSHOP_NAME}
AWS_REGION=${AWS_REGION}
ACCOUNT_ID=${ACCOUNT_ID}
CLUSTER_NAME=${CLUSTER_NAME}
AMP_WORKSPACE_ID=${AMP_WORKSPACE_ID}
AMG_WS_ID=${AMG_WS_ID}
AMG_ENDPOINT=${AMG_ENDPOINT}
ADOT_ROLE_ARN=${ADOT_ROLE_ARN}
AMG_ROLE_ARN=${AMG_ROLE_ARN}
EOF

log_success "배포 상태가 .deploy-state.env 에 저장되었습니다."
