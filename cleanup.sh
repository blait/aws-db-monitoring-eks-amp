#!/bin/bash
###############################################################################
# AWS 데이터베이스 통합 모니터링 - 전체 리소스 정리 스크립트
# 모든 리소스를 역순으로 안전하게 삭제합니다.
#
# 사용법: ./cleanup.sh [--force] [--keep-vpc]
###############################################################################

set -euo pipefail

#==============================================================================
# 색상 및 포맷팅
#==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

log_info() { echo -e "  ${CYAN}ℹ${NC}  $1"; }
log_success() { echo -e "  ${GREEN}✔${NC}  $1"; }
log_warning() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
log_error() { echo -e "  ${RED}✘${NC}  $1"; }
log_wait() { echo -e "  ${PURPLE:-\033[0;35m}⏳${NC} $1"; }

#==============================================================================
# 설정 로드
#==============================================================================
FORCE=false
KEEP_VPC=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f) FORCE=true; shift ;;
        --keep-vpc) KEEP_VPC=true; shift ;;
        --help|-h)
            echo "사용법: $0 [옵션]"
            echo "  --force, -f    확인 없이 즉시 삭제"
            echo "  --keep-vpc     VPC/네트워킹 스택 유지"
            exit 0
            ;;
        *) shift ;;
    esac
done

# .deploy-state.env 파일에서 설정 로드
if [ -f ".deploy-state.env" ]; then
    source .deploy-state.env
    log_info "배포 상태 파일에서 설정을 로드했습니다."
else
    # 기본값 설정
    WORKSHOP_NAME="${WORKSHOP_NAME:-integrated-db-monitoring}"
    AWS_REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || echo 'ap-northeast-2')}"
    ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo '')}"
    CLUSTER_NAME="${CLUSTER_NAME:-${WORKSHOP_NAME}-eks}"
    log_warning ".deploy-state.env 파일이 없습니다. 기본값을 사용합니다."
fi

#==============================================================================
# 경고 및 확인
#==============================================================================
echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  ⚠️  경고: 모든 리소스가 삭제됩니다!                             ║${NC}"
echo -e "${RED}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║  삭제 대상:                                                      ║${NC}"
echo -e "${RED}║    • Helm 배포 (ADOT, Exporters)                                ║${NC}"
echo -e "${RED}║    • EKS 클러스터: ${CLUSTER_NAME}$(printf '%*s' $((34 - ${#CLUSTER_NAME})) '')║${NC}"
echo -e "${RED}║    • AMP 워크스페이스: ${AMP_WORKSPACE_ID:-unknown}$(printf '%*s' $((31 - ${#AMP_WORKSPACE_ID:-unknown})) '')║${NC}"
echo -e "${RED}║    • AMG 워크스페이스                                            ║${NC}"
echo -e "${RED}║    • CloudFormation 스택 (DB, Cache, Network)                   ║${NC}"
echo -e "${RED}║    • IAM 역할                                                   ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$FORCE" = false ]; then
    read -p "정말 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다. (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "취소되었습니다."
        exit 0
    fi
fi

CLEANUP_START=$(date +%s)

#==============================================================================
# Step 1: Helm 릴리스 삭제
#==============================================================================
echo ""
echo -e "${BOLD}${BLUE}[1/7]${NC} ${WHITE}Helm 릴리스 삭제${NC}"

# kubeconfig가 설정되어 있는지 확인
if kubectl cluster-info &>/dev/null 2>&1; then
    for release in mssql-exporter redis-exporter postgres-exporter mysql-exporter adot-collector; do
        if helm status $release -n observability &>/dev/null 2>&1; then
            log_info "삭제 중: ${release}"
            helm uninstall $release -n observability --wait 2>/dev/null || true
            log_success "${release} 삭제 완료"
        else
            log_warning "${release} 없음 (건너뜀)"
        fi
    done

    # 네임스페이스 삭제
    kubectl delete namespace observability --wait=false 2>/dev/null || true
    log_success "observability 네임스페이스 삭제 요청 완료"
else
    log_warning "EKS 클러스터에 연결할 수 없습니다. Helm 삭제를 건너뜁니다."
fi

#==============================================================================
# Step 2: EKS 클러스터 삭제
#==============================================================================
echo ""
echo -e "${BOLD}${BLUE}[2/7]${NC} ${WHITE}EKS 클러스터 삭제${NC}"

if eksctl get cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} &>/dev/null 2>&1; then
    log_wait "EKS 클러스터 삭제 중... (약 10~15분)"
    eksctl delete cluster --name ${CLUSTER_NAME} --region ${AWS_REGION} --wait || \
        log_warning "eksctl 삭제 실패. CloudFormation에서 직접 삭제를 시도합니다."
    log_success "EKS 클러스터 삭제 완료: ${CLUSTER_NAME}"
else
    log_warning "EKS 클러스터 '${CLUSTER_NAME}' 을 찾을 수 없습니다. (건너뜀)"
fi

#==============================================================================
# Step 3: Amazon Managed Grafana (AMG) 삭제
#==============================================================================
echo ""
echo -e "${BOLD}${BLUE}[3/7]${NC} ${WHITE}AMG 워크스페이스 삭제${NC}"

AMG_WS_ID="${AMG_WS_ID:-}"
if [ -z "$AMG_WS_ID" ]; then
    AMG_WS_ID=$(aws grafana list-workspaces \
        --region ${AWS_REGION} \
        --query "workspaces[?name=='${WORKSHOP_NAME}-grafana'].id" \
        --output text 2>/dev/null || echo "")
fi

if [ -n "$AMG_WS_ID" ] && [ "$AMG_WS_ID" != "None" ]; then
    log_info "AMG 워크스페이스 삭제: ${AMG_WS_ID}"
    aws grafana delete-workspace \
        --workspace-id ${AMG_WS_ID} \
        --region ${AWS_REGION} 2>/dev/null || log_warning "AMG 삭제 실패"
    log_success "AMG 워크스페이스 삭제 완료"
else
    log_warning "AMG 워크스페이스를 찾을 수 없습니다. (건너뜀)"
fi

#==============================================================================
# Step 4: Amazon Managed Prometheus (AMP) 삭제
#==============================================================================
echo ""
echo -e "${BOLD}${BLUE}[4/7]${NC} ${WHITE}AMP 워크스페이스 삭제${NC}"

AMP_WORKSPACE_ID="${AMP_WORKSPACE_ID:-}"
if [ -z "$AMP_WORKSPACE_ID" ]; then
    AMP_WORKSPACE_ID=$(aws amp list-workspaces \
        --alias ${WORKSHOP_NAME}-amp \
        --query 'workspaces[0].workspaceId' \
        --output text --region ${AWS_REGION} 2>/dev/null || echo "")
fi

if [ -n "$AMP_WORKSPACE_ID" ] && [ "$AMP_WORKSPACE_ID" != "None" ]; then
    log_info "AMP 워크스페이스 삭제: ${AMP_WORKSPACE_ID}"
    aws amp delete-workspace \
        --workspace-id ${AMP_WORKSPACE_ID} \
        --region ${AWS_REGION} 2>/dev/null || log_warning "AMP 삭제 실패"
    log_success "AMP 워크스페이스 삭제 완료"
else
    log_warning "AMP 워크스페이스를 찾을 수 없습니다. (건너뜀)"
fi

#==============================================================================
# Step 5: CloudFormation 스택 삭제
#==============================================================================
echo ""
echo -e "${BOLD}${BLUE}[5/7]${NC} ${WHITE}CloudFormation 스택 삭제${NC}"

# 역순으로 삭제: cache → db → network
delete_cfn_stack() {
    local stack_name=$1
    if aws cloudformation describe-stacks --stack-name ${stack_name} --region ${AWS_REGION} &>/dev/null 2>&1; then
        log_info "스택 삭제 중: ${stack_name}"
        aws cloudformation delete-stack \
            --stack-name ${stack_name} \
            --region ${AWS_REGION}
        log_wait "스택 삭제 대기: ${stack_name}..."
        aws cloudformation wait stack-delete-complete \
            --stack-name ${stack_name} \
            --region ${AWS_REGION} 2>/dev/null || log_warning "${stack_name} 삭제 대기 타임아웃"
        log_success "${stack_name} 삭제 완료"
    else
        log_warning "${stack_name} 스택이 없습니다. (건너뜀)"
    fi
}

# Cache 스택
delete_cfn_stack "${WORKSHOP_NAME}-cache"

# Database 스택
delete_cfn_stack "${WORKSHOP_NAME}-db"

# Network 스택
if [ "$KEEP_VPC" = false ]; then
    delete_cfn_stack "${WORKSHOP_NAME}-network"
else
    log_warning "VPC/네트워킹 스택 유지 (--keep-vpc 옵션)"
fi

#==============================================================================
# Step 6: IAM 역할 삭제
#==============================================================================
echo ""
echo -e "${BOLD}${BLUE}[6/7]${NC} ${WHITE}IAM 역할 삭제${NC}"

delete_iam_role() {
    local role_name=$1
    if aws iam get-role --role-name ${role_name} &>/dev/null 2>&1; then
        # 연결된 정책 분리
        POLICIES=$(aws iam list-attached-role-policies \
            --role-name ${role_name} \
            --query 'AttachedPolicies[].PolicyArn' \
            --output text 2>/dev/null || echo "")
        for policy in $POLICIES; do
            aws iam detach-role-policy --role-name ${role_name} --policy-arn ${policy} 2>/dev/null || true
        done
        
        # 역할 삭제
        aws iam delete-role --role-name ${role_name} 2>/dev/null || true
        log_success "IAM 역할 삭제: ${role_name}"
    else
        log_warning "IAM 역할 '${role_name}' 없음 (건너뜀)"
    fi
}

delete_iam_role "${WORKSHOP_NAME}-adot-collector-role"
delete_iam_role "${WORKSHOP_NAME}-amg-role"

#==============================================================================
# Step 7: 임시 파일 정리
#==============================================================================
echo ""
echo -e "${BOLD}${BLUE}[7/7]${NC} ${WHITE}임시 파일 정리${NC}"

rm -f /tmp/adot-trust-policy.json 2>/dev/null || true
rm -f /tmp/amg-trust-policy.json 2>/dev/null || true
rm -f eks-cluster-resolved.yaml 2>/dev/null || true
rm -f .deploy-state.env 2>/dev/null || true

log_success "임시 파일 정리 완료"

#==============================================================================
# 완료
#==============================================================================
CLEANUP_END=$(date +%s)
TOTAL_ELAPSED=$((CLEANUP_END - CLEANUP_START))
TOTAL_MIN=$((TOTAL_ELAPSED / 60))
TOTAL_SEC=$((TOTAL_ELAPSED % 60))

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  🧹 모든 리소스가 정리되었습니다!                                ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  ⏱ 소요 시간: ${TOTAL_MIN}분 ${TOTAL_SEC}초$(printf '%*s' $((42 - ${#TOTAL_MIN} - ${#TOTAL_SEC})) '')║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$KEEP_VPC" = true ]; then
    log_info "VPC 스택(${WORKSHOP_NAME}-network)은 유지되었습니다."
    log_info "완전히 삭제하려면: aws cloudformation delete-stack --stack-name ${WORKSHOP_NAME}-network --region ${AWS_REGION}"
fi
