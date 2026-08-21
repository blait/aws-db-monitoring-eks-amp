#!/bin/bash
# =============================================================================
# 멀티 어카운트/리전 DB 자동 디스커버리 스크립트
# =============================================================================
# 
# 기존 db-discovery-updated.sh를 확장하여 여러 AWS 계정과 리전의 
# DB 리소스를 자동으로 디스커버리하고 Exporter Pod을 생성/삭제합니다.
#
# 실행: CronJob에 의해 주기적으로 실행됨
# 설정: multi-account-config.yaml (ConfigMap)에서 읽어옴
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 전역 설정
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_NAME="db-discovery-multi-account"
LOG_PREFIX="[${SCRIPT_NAME}]"
CONFIG_PATH="/config/accounts.yaml"       # ConfigMap 마운트 경로
NAMESPACE="${TARGET_NAMESPACE:-observability}"
DRY_RUN="${DRY_RUN:-false}"
EXTERNAL_ID="${EXTERNAL_ID:-db-monitoring-cross-account}"
EXPORTER_REPLICAS="${EXPORTER_REPLICAS:-2}"
TEMPLATES_DIR="/templates"                # Exporter 템플릿 마운트 경로

# 색상 출력
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# 유틸리티 함수
# ─────────────────────────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}${LOG_PREFIX} [INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}${LOG_PREFIX} [WARN]${NC} $1"; }
log_error() { echo -e "${RED}${LOG_PREFIX} [ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}${LOG_PREFIX} [DEBUG]${NC} $1"; }

# YAML 파싱 (경량 — yq 사용)
parse_config() {
    if ! command -v yq &> /dev/null; then
        log_error "yq가 설치되어 있지 않습니다."
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Cross-Account AssumeRole
# ─────────────────────────────────────────────────────────────────────────────
assume_role() {
    local role_arn=$1
    local session_name=$2
    local account_name=$3

    log_info "AssumeRole: ${account_name} (${role_arn})"

    local credentials
    credentials=$(aws sts assume-role \
        --role-arn "${role_arn}" \
        --role-session-name "${session_name}" \
        --external-id "${EXTERNAL_ID}" \
        --duration-seconds 3600 \
        --output json 2>/dev/null) || {
        log_error "AssumeRole 실패: ${account_name} (${role_arn})"
        return 1
    }

    # 임시 자격증명 설정
    export AWS_ACCESS_KEY_ID=$(echo "$credentials" | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo "$credentials" | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo "$credentials" | jq -r '.Credentials.SessionToken')

    log_info "AssumeRole 성공: ${account_name}"
    return 0
}

# AssumeRole 해제 (로컬 계정 자격증명으로 복귀)
clear_assumed_role() {
    unset AWS_ACCESS_KEY_ID
    unset AWS_SECRET_ACCESS_KEY
    unset AWS_SESSION_TOKEN
}

# ─────────────────────────────────────────────────────────────────────────────
# DB 디스커버리 함수들
# ─────────────────────────────────────────────────────────────────────────────

# Aurora 클러스터 디스커버리
discover_aurora() {
    local account_id=$1
    local account_name=$2
    local region=$3
    local tag_key=$4
    local tag_value=$5

    log_info "  Aurora 디스커버리: account=${account_name}, region=${region}"

    local clusters
    clusters=$(aws rds describe-db-clusters \
        --region "${region}" \
        --query "DBClusters[?Engine=='aurora-mysql' || Engine=='aurora-postgresql']" \
        --output json 2>/dev/null) || {
        log_warn "  Aurora 디스커버리 실패: ${account_name}/${region}"
        return
    }

    local cluster_count=$(echo "$clusters" | jq 'length')
    log_info "  발견된 Aurora 클러스터: ${cluster_count}개"

    echo "$clusters" | jq -c '.[]' | while read -r cluster; do
        local cluster_id=$(echo "$cluster" | jq -r '.DBClusterIdentifier')
        local engine=$(echo "$cluster" | jq -r '.Engine')
        local vpc_id=$(echo "$cluster" | jq -r '.DBSubnetGroup // empty | .VpcId // empty')

        # 태그 필터링 (설정된 경우)
        if [[ -n "$tag_key" && -n "$tag_value" ]]; then
            local cluster_arn=$(echo "$cluster" | jq -r '.DBClusterArn')
            local has_tag=$(aws rds list-tags-for-resource \
                --region "${region}" \
                --resource-name "${cluster_arn}" \
                --query "TagList[?Key=='${tag_key}' && Value=='${tag_value}']" \
                --output text 2>/dev/null)
            if [[ -z "$has_tag" ]]; then
                log_debug "  태그 필터 미충족, 스킵: ${cluster_id}"
                continue
            fi
        fi

        # 클러스터 내 인스턴스 디스커버리
        local instances
        instances=$(aws rds describe-db-instances \
            --region "${region}" \
            --filters "Name=db-cluster-id,Values=${cluster_id}" \
            --output json 2>/dev/null)

        echo "$instances" | jq -c '.DBInstances[]' | while read -r instance; do
            local db_id=$(echo "$instance" | jq -r '.DBInstanceIdentifier')
            local endpoint=$(echo "$instance" | jq -r '.Endpoint.Address')
            local port=$(echo "$instance" | jq -r '.Endpoint.Port')
            local role=$(echo "$instance" | jq -r 'if .IsClusterWriter then "writer" else "reader" end')

            # Exporter 정보 기록
            echo "${account_id}|${account_name}|${region}|${engine}|aurora|${cluster_id}|${db_id}|${endpoint}|${port}|${role}|${vpc_id}" >> /tmp/discovered_dbs.txt
        done
    done
}

# 일반 RDS 인스턴스 디스커버리 (Aurora가 아닌 것)
discover_rds() {
    local account_id=$1
    local account_name=$2
    local region=$3
    local tag_key=$4
    local tag_value=$5

    log_info "  RDS 디스커버리: account=${account_name}, region=${region}"

    local instances
    instances=$(aws rds describe-db-instances \
        --region "${region}" \
        --query "DBInstances[?!DBClusterIdentifier]" \
        --output json 2>/dev/null) || {
        log_warn "  RDS 디스커버리 실패: ${account_name}/${region}"
        return
    }

    local instance_count=$(echo "$instances" | jq 'length')
    log_info "  발견된 RDS 인스턴스: ${instance_count}개"

    echo "$instances" | jq -c '.[]' | while read -r instance; do
        local db_id=$(echo "$instance" | jq -r '.DBInstanceIdentifier')
        local engine=$(echo "$instance" | jq -r '.Engine')
        local endpoint=$(echo "$instance" | jq -r '.Endpoint.Address')
        local port=$(echo "$instance" | jq -r '.Endpoint.Port')
        local vpc_id=$(echo "$instance" | jq -r '.DBSubnetGroup.VpcId // empty')

        # 태그 필터링
        if [[ -n "$tag_key" && -n "$tag_value" ]]; then
            local instance_arn=$(echo "$instance" | jq -r '.DBInstanceArn')
            local has_tag=$(aws rds list-tags-for-resource \
                --region "${region}" \
                --resource-name "${instance_arn}" \
                --query "TagList[?Key=='${tag_key}' && Value=='${tag_value}']" \
                --output text 2>/dev/null)
            if [[ -z "$has_tag" ]]; then
                continue
            fi
        fi

        echo "${account_id}|${account_name}|${region}|${engine}|rds|none|${db_id}|${endpoint}|${port}|writer|${vpc_id}" >> /tmp/discovered_dbs.txt
    done
}

# ElastiCache 디스커버리
discover_elasticache() {
    local account_id=$1
    local account_name=$2
    local region=$3
    local tag_key=$4
    local tag_value=$5

    log_info "  ElastiCache 디스커버리: account=${account_name}, region=${region}"

    # Replication Groups (클러스터 모드)
    local rep_groups
    rep_groups=$(aws elasticache describe-replication-groups \
        --region "${region}" \
        --output json 2>/dev/null) || {
        log_warn "  ElastiCache 디스커버리 실패: ${account_name}/${region}"
        return
    }

    echo "$rep_groups" | jq -c '.ReplicationGroups[]' | while read -r group; do
        local group_id=$(echo "$group" | jq -r '.ReplicationGroupId')
        local engine=$(echo "$group" | jq -r '.CacheNodeType')

        # 각 노드 그룹의 Primary Endpoint
        echo "$group" | jq -c '.NodeGroups[].PrimaryEndpoint' | while read -r ep; do
            local endpoint=$(echo "$ep" | jq -r '.Address')
            local port=$(echo "$ep" | jq -r '.Port')

            echo "${account_id}|${account_name}|${region}|redis|elasticache|${group_id}|${group_id}|${endpoint}|${port}|primary|" >> /tmp/discovered_dbs.txt
        done
    done
}

# DynamoDB 테이블 디스커버리
discover_dynamodb() {
    local account_id=$1
    local account_name=$2
    local region=$3
    local tag_key=$4
    local tag_value=$5

    log_info "  DynamoDB 디스커버리: account=${account_name}, region=${region}"

    local tables
    tables=$(aws dynamodb list-tables \
        --region "${region}" \
        --output json 2>/dev/null) || {
        log_warn "  DynamoDB 디스커버리 실패: ${account_name}/${region}"
        return
    }

    echo "$tables" | jq -r '.TableNames[]' | while read -r table_name; do
        # 태그 필터링
        if [[ -n "$tag_key" && -n "$tag_value" ]]; then
            local table_arn=$(aws dynamodb describe-table \
                --region "${region}" \
                --table-name "${table_name}" \
                --query 'Table.TableArn' --output text 2>/dev/null)
            local has_tag=$(aws dynamodb list-tags-of-resource \
                --region "${region}" \
                --resource-arn "${table_arn}" \
                --query "Tags[?Key=='${tag_key}' && Value=='${tag_value}']" \
                --output text 2>/dev/null)
            if [[ -z "$has_tag" ]]; then
                continue
            fi
        fi

        # DynamoDB는 Exporter가 아닌 CloudWatch Receiver로 수집하므로
        # ConfigMap에 테이블 목록만 기록
        echo "${account_id}|${account_name}|${region}|dynamodb|dynamodb|none|${table_name}|cloudwatch|443|table|" >> /tmp/discovered_dbs.txt
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Exporter 생성/삭제 (Reconciliation)
# ─────────────────────────────────────────────────────────────────────────────

# 현재 배포된 Exporter 목록 가져오기
get_current_exporters() {
    kubectl get deployments -n "${NAMESPACE}" \
        -l "db-discovery/managed-by=auto-discovery" \
        -o json | jq -c '.items[] | {
            name: .metadata.name,
            account_id: .metadata.annotations["db-discovery/account-id"],
            region: .metadata.annotations["db-discovery/region"],
            db_identifier: .metadata.annotations["db-discovery/db-identifier"],
            engine: .metadata.annotations["db-discovery/engine"]
        }' > /tmp/current_exporters.txt 2>/dev/null || true
}

# Exporter 배포 (HA: replicas 2)
deploy_exporter() {
    local account_id=$1
    local account_name=$2
    local region=$3
    local engine=$4
    local source_type=$5
    local cluster_id=$6
    local db_id=$7
    local endpoint=$8
    local port=$9
    local role=${10}
    local vpc_id=${11}

    # DynamoDB는 Exporter가 아닌 ConfigMap 업데이트
    if [[ "$engine" == "dynamodb" ]]; then
        log_info "  DynamoDB 테이블 등록: ${db_id} (CloudWatch Receiver에서 수집)"
        return
    fi

    # 엔진에 따른 Exporter 유형 결정
    local exporter_type=""
    local exporter_image=""
    local exporter_port=""
    case "$engine" in
        aurora-mysql|mysql)
            exporter_type="mysql-exporter"
            exporter_image="${MYSQL_EXPORTER_IMAGE:-prom/mysqld-exporter:v0.15.1}"
            exporter_port="9104"
            ;;
        aurora-postgresql|postgres)
            exporter_type="postgresql-exporter"
            exporter_image="${PG_EXPORTER_IMAGE:-prometheuscommunity/postgres-exporter:v0.15.0}"
            exporter_port="9187"
            ;;
        sqlserver-ee|sqlserver-se|sqlserver-ex|sqlserver-web)
            exporter_type="mssql-exporter"
            exporter_image="${MSSQL_EXPORTER_IMAGE:-awarber/prometheus-mssql-exporter:0.4.0}"
            exporter_port="4000"
            ;;
        redis|valkey)
            exporter_type="redis-exporter"
            exporter_image="${REDIS_EXPORTER_IMAGE:-oliver006/redis_exporter:v1.58.0}"
            exporter_port="9121"
            ;;
        *)
            log_warn "  미지원 엔진: ${engine}, 스킵"
            return
            ;;
    esac

    # 배포 이름 생성 (고유하게: account-region-dbid)
    local deploy_name="${exporter_type}-${account_id:(-4)}-${db_id}"
    # Kubernetes 이름 규칙에 맞게 정규화 (63자 이내, 소문자, 하이픈만)
    deploy_name=$(echo "$deploy_name" | tr '[:upper:]' '[:lower:]' | tr '_.' '-' | cut -c1-63)

    # 이미 존재하는지 확인
    if kubectl get deployment "${deploy_name}" -n "${NAMESPACE}" &>/dev/null; then
        log_debug "  이미 존재: ${deploy_name}"
        return
    fi

    log_info "  Exporter 생성: ${deploy_name} (${engine}, ${endpoint}:${port})"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "  [DRY-RUN] 생성하지 않음: ${deploy_name}"
        return
    fi

    # 템플릿으로 Exporter 생성
    export DEPLOY_NAME="${deploy_name}"
    export TARGET_NAMESPACE="${NAMESPACE}"
    export DB_IDENTIFIER="${db_id}"
    export DB_ENDPOINT="${endpoint}"
    export DB_PORT="${port}"
    export CLUSTER_ID="${cluster_id}"
    export SOURCE_TYPE="${source_type}"
    export EXPORTER_IMAGE="${exporter_image}"
    export SECRET_NAME="db-cred-${account_id:(-4)}-${db_id}"
    export ACCOUNT_ID_LABEL="${account_id}"
    export ACCOUNT_NAME_LABEL="${account_name}"
    export REGION_LABEL="${region}"
    export VPC_ID_LABEL="${vpc_id}"
    export DB_ROLE_LABEL="${role}"
    export REPLICA_COUNT="${EXPORTER_REPLICAS}"

    # 템플릿 적용
    local template_file="${TEMPLATES_DIR}/${exporter_type}-template.yaml"
    if [[ -f "$template_file" ]]; then
        envsubst < "$template_file" | kubectl apply -f - 2>/dev/null || {
            log_error "  Exporter 생성 실패: ${deploy_name}"
        }
    else
        log_error "  템플릿 없음: ${template_file}"
    fi
}

# Orphaned Exporter 삭제
remove_orphaned_exporters() {
    log_info "Orphaned Exporter 정리 중..."

    while IFS= read -r exporter_json; do
        local exp_name=$(echo "$exporter_json" | jq -r '.name')
        local exp_account=$(echo "$exporter_json" | jq -r '.account_id')
        local exp_region=$(echo "$exporter_json" | jq -r '.region')
        local exp_db_id=$(echo "$exporter_json" | jq -r '.db_identifier')

        # 발견된 DB 목록에 없으면 삭제
        if ! grep -q "${exp_account}.*${exp_db_id}" /tmp/discovered_dbs.txt 2>/dev/null; then
            log_warn "  Orphaned Exporter 삭제: ${exp_name} (DB: ${exp_db_id})"
            if [[ "$DRY_RUN" != "true" ]]; then
                kubectl delete deployment "${exp_name}" -n "${NAMESPACE}" --ignore-not-found
                kubectl delete service "${exp_name}" -n "${NAMESPACE}" --ignore-not-found
            fi
        fi
    done < /tmp/current_exporters.txt
}

# DynamoDB 테이블 목록을 ConfigMap으로 업데이트 (ADOT CloudWatch Receiver용)
update_dynamodb_configmap() {
    log_info "DynamoDB 테이블 ConfigMap 업데이트..."

    local tables=""
    if [[ -f /tmp/discovered_dbs.txt ]]; then
        tables=$(grep "|dynamodb|" /tmp/discovered_dbs.txt | \
            awk -F'|' '{print $1 "," $3 "," $7}' | sort -u)
    fi

    if [[ -z "$tables" ]]; then
        log_info "  DynamoDB 테이블 없음"
        return
    fi

    # ConfigMap 생성/업데이트
    local cm_data=""
    while IFS=',' read -r acct region table; do
        cm_data="${cm_data}    - account_id: \"${acct}\"\n      region: \"${region}\"\n      table_name: \"${table}\"\n"
    done <<< "$tables"

    if [[ "$DRY_RUN" != "true" ]]; then
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: dynamodb-tables-config
  namespace: ${NAMESPACE}
data:
  tables.yaml: |
    dynamodb_tables:
$(echo -e "$cm_data")
EOF
    fi

    log_info "  DynamoDB 테이블 ConfigMap 업데이트 완료"
}

# ─────────────────────────────────────────────────────────────────────────────
# 메인 실행
# ─────────────────────────────────────────────────────────────────────────────
main() {
    log_info "============================================"
    log_info "멀티 어카운트 DB 디스커버리 시작"
    log_info "============================================"
    log_info "DRY_RUN: ${DRY_RUN}"
    log_info "NAMESPACE: ${NAMESPACE}"
    log_info "REPLICAS: ${EXPORTER_REPLICAS}"

    # 초기화
    > /tmp/discovered_dbs.txt
    > /tmp/current_exporters.txt

    # 설정 파일 파싱
    parse_config

    # 현재 배포된 Exporter 목록
    get_current_exporters

    # 대상 계정 목록 읽기
    local account_count=$(yq '.target_accounts | length' "${CONFIG_PATH}")
    log_info "대상 계정 수: ${account_count}"

    # 각 계정/리전 순회
    for ((i=0; i<account_count; i++)); do
        local acct_id=$(yq ".target_accounts[${i}].id" "${CONFIG_PATH}")
        local acct_name=$(yq ".target_accounts[${i}].name" "${CONFIG_PATH}")
        local role_arn=$(yq ".target_accounts[${i}].role_arn" "${CONFIG_PATH}")
        local tag_key=$(yq ".target_accounts[${i}].tag_filter.key // \"\"" "${CONFIG_PATH}")
        local tag_value=$(yq ".target_accounts[${i}].tag_filter.value // \"\"" "${CONFIG_PATH}")

        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log_info "계정: ${acct_name} (${acct_id})"
        log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Cross-Account AssumeRole
        if ! assume_role "${role_arn}" "DBDiscovery-${acct_name}" "${acct_name}"; then
            log_error "계정 ${acct_name} 스킵 (AssumeRole 실패)"
            continue
        fi

        # 해당 계정의 리전 목록
        local region_count=$(yq ".target_accounts[${i}].regions | length" "${CONFIG_PATH}")
        
        for ((r=0; r<region_count; r++)); do
            local region=$(yq ".target_accounts[${i}].regions[${r}]" "${CONFIG_PATH}")
            
            log_info "  리전: ${region}"

            # 각 DB 서비스 디스커버리
            discover_aurora "${acct_id}" "${acct_name}" "${region}" "${tag_key}" "${tag_value}"
            discover_rds "${acct_id}" "${acct_name}" "${region}" "${tag_key}" "${tag_value}"
            discover_elasticache "${acct_id}" "${acct_name}" "${region}" "${tag_key}" "${tag_value}"
            discover_dynamodb "${acct_id}" "${acct_name}" "${region}" "${tag_key}" "${tag_value}"
        done

        # AssumeRole 해제
        clear_assumed_role
    done

    # ─────────────────────────────────────────────────────────────────────
    # Reconciliation: 발견된 DB vs 현재 Exporter
    # ─────────────────────────────────────────────────────────────────────
    log_info "============================================"
    log_info "Reconciliation 시작"
    log_info "============================================"

    local total_discovered=$(wc -l < /tmp/discovered_dbs.txt 2>/dev/null || echo "0")
    log_info "총 발견된 DB 리소스: ${total_discovered}"

    # 새로 발견된 DB에 대해 Exporter 생성
    while IFS='|' read -r acct_id acct_name region engine src_type cluster_id db_id endpoint port role vpc_id; do
        deploy_exporter "$acct_id" "$acct_name" "$region" "$engine" "$src_type" "$cluster_id" "$db_id" "$endpoint" "$port" "$role" "$vpc_id"
    done < /tmp/discovered_dbs.txt

    # Orphaned Exporter 삭제
    remove_orphaned_exporters

    # DynamoDB ConfigMap 업데이트
    update_dynamodb_configmap

    # ─────────────────────────────────────────────────────────────────────
    # 요약
    # ─────────────────────────────────────────────────────────────────────
    log_info "============================================"
    log_info "디스커버리 완료 요약"
    log_info "============================================"
    log_info "총 발견: ${total_discovered}개"
    
    if [[ -f /tmp/discovered_dbs.txt ]]; then
        log_info "  Aurora MySQL: $(grep -c 'aurora-mysql' /tmp/discovered_dbs.txt 2>/dev/null || echo 0)개"
        log_info "  Aurora PostgreSQL: $(grep -c 'aurora-postgresql' /tmp/discovered_dbs.txt 2>/dev/null || echo 0)개"
        log_info "  RDS MySQL: $(grep -c '|mysql|rds|' /tmp/discovered_dbs.txt 2>/dev/null || echo 0)개"
        log_info "  RDS PostgreSQL: $(grep -c '|postgres|rds|' /tmp/discovered_dbs.txt 2>/dev/null || echo 0)개"
        log_info "  RDS SQL Server: $(grep -c 'sqlserver' /tmp/discovered_dbs.txt 2>/dev/null || echo 0)개"
        log_info "  ElastiCache: $(grep -c 'elasticache' /tmp/discovered_dbs.txt 2>/dev/null || echo 0)개"
        log_info "  DynamoDB: $(grep -c 'dynamodb' /tmp/discovered_dbs.txt 2>/dev/null || echo 0)개"
    fi

    log_info "DRY_RUN: ${DRY_RUN}"
    log_info "완료!"

    # 정리
    rm -f /tmp/discovered_dbs.txt /tmp/current_exporters.txt
}

# 실행
main "$@"
