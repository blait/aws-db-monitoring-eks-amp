#!/bin/bash
# =============================================================================
# 통합 DB 자동 디스커버리 스크립트
# Aurora + RDS (MySQL/PostgreSQL/SQL Server) + ElastiCache (Redis/Valkey)
# =============================================================================
# 이 스크립트는 EKS CronJob에서 주기적으로 실행되어:
# 1. AWS API로 모든 DB 인스턴스/클러스터를 조회
# 2. 현재 EKS에 배포된 Exporter와 비교
# 3. 새로 추가된 DB → Exporter 자동 배포
# 4. 삭제된 DB → orphaned Exporter 자동 제거
# =============================================================================

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# 환경 변수 및 설정
# ─────────────────────────────────────────────────────────────────────────────
NAMESPACE="${NAMESPACE:-observability}"
LABEL_SELECTOR="db-discovery/managed-by=auto-discovery"
DRY_RUN="${DRY_RUN:-false}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
TEMPLATE_DIR="${TEMPLATE_DIR:-/etc/discovery/templates}"

# 태그 기반 필터링 (선택사항)
# "monitoring:enabled" 태그가 있는 리소스만 디스커버리
TAG_FILTER_ENABLED="${TAG_FILTER_ENABLED:-false}"
TAG_FILTER_KEY="${TAG_FILTER_KEY:-monitoring}"
TAG_FILTER_VALUE="${TAG_FILTER_VALUE:-enabled}"

# VPC 필터링 (EKS와 같은 VPC 내 리소스만)
VPC_FILTER_ENABLED="${VPC_FILTER_ENABLED:-false}"
TARGET_VPC_ID="${TARGET_VPC_ID:-}"

# DB 접속 시크릿 이름 패턴
MYSQL_SECRET_NAME="${MYSQL_SECRET_NAME:-db-monitoring-mysql-credentials}"
POSTGRESQL_SECRET_NAME="${POSTGRESQL_SECRET_NAME:-db-monitoring-postgresql-credentials}"
MSSQL_SECRET_NAME="${MSSQL_SECRET_NAME:-db-monitoring-mssql-credentials}"

# ─────────────────────────────────────────────────────────────────────────────
# 로깅 함수
# ─────────────────────────────────────────────────────────────────────────────
log() {
    local level="$1"
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] $*"
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { [[ "$LOG_LEVEL" == "DEBUG" ]] && log "DEBUG" "$@" || true; }

# ─────────────────────────────────────────────────────────────────────────────
# 유틸리티 함수
# ─────────────────────────────────────────────────────────────────────────────

# 리소스 이름을 Kubernetes 호환 형식으로 변환
sanitize_name() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | cut -c1-63
}

# kubectl 명령 실행 (dry-run 모드 지원)
kubectl_apply() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] kubectl apply 실행 예정:"
        cat "$1"
        echo "---"
    else
        kubectl apply -f "$1" -n "$NAMESPACE"
    fi
}

kubectl_delete() {
    local resource_type="$1"
    local resource_name="$2"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] kubectl delete ${resource_type}/${resource_name} 실행 예정"
    else
        kubectl delete "$resource_type" "$resource_name" -n "$NAMESPACE" --ignore-not-found=true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 태그 필터링 확인 함수
# ─────────────────────────────────────────────────────────────────────────────

# RDS 리소스 태그 확인
check_rds_tags() {
    local arn="$1"
    if [[ "$TAG_FILTER_ENABLED" != "true" ]]; then
        return 0  # 필터링 비활성화 시 모든 리소스 허용
    fi
    
    local tags
    tags=$(aws rds list-tags-for-resource --resource-name "$arn" \
        --query "TagList[?Key=='${TAG_FILTER_KEY}' && Value=='${TAG_FILTER_VALUE}']" \
        --output text 2>/dev/null)
    
    if [[ -n "$tags" ]]; then
        return 0  # 태그 존재
    else
        return 1  # 태그 없음
    fi
}

# ElastiCache 리소스 태그 확인
check_elasticache_tags() {
    local arn="$1"
    if [[ "$TAG_FILTER_ENABLED" != "true" ]]; then
        return 0
    fi
    
    local tags
    tags=$(aws elasticache list-tags-for-resource --resource-name "$arn" \
        --query "TagList[?Key=='${TAG_FILTER_KEY}' && Value=='${TAG_FILTER_VALUE}']" \
        --output text 2>/dev/null)
    
    if [[ -n "$tags" ]]; then
        return 0
    else
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Aurora 클러스터 디스커버리
# ─────────────────────────────────────────────────────────────────────────────
discover_aurora() {
    log_info "=== Aurora 클러스터 디스커버리 시작 ==="
    
    local clusters
    clusters=$(aws rds describe-db-clusters \
        --query 'DBClusters[?Engine==`aurora-mysql` || Engine==`aurora-postgresql`].[DBClusterIdentifier,Engine,DBClusterArn]' \
        --output text 2>/dev/null)
    
    if [[ -z "$clusters" ]]; then
        log_info "Aurora 클러스터가 없습니다."
        return
    fi
    
    while IFS=$'\t' read -r cluster_id engine cluster_arn; do
        log_debug "Aurora 클러스터 발견: ${cluster_id} (엔진: ${engine})"
        
        # 태그 필터 확인
        if ! check_rds_tags "$cluster_arn"; then
            log_debug "태그 필터에 의해 건너뜀: ${cluster_id}"
            continue
        fi
        
        # 클러스터 내 인스턴스 조회
        local instances
        instances=$(aws rds describe-db-instances \
            --filters "Name=db-cluster-id,Values=${cluster_id}" \
            --query 'DBInstances[].[DBInstanceIdentifier,Endpoint.Address,Endpoint.Port,DBInstanceStatus]' \
            --output text 2>/dev/null)
        
        while IFS=$'\t' read -r instance_id endpoint port status; do
            if [[ "$status" != "available" ]]; then
                log_warn "Aurora 인스턴스 ${instance_id} 상태: ${status} (건너뜀)"
                continue
            fi
            
            # VPC 필터링
            if [[ "$VPC_FILTER_ENABLED" == "true" && -n "$TARGET_VPC_ID" ]]; then
                local instance_vpc
                instance_vpc=$(aws rds describe-db-instances \
                    --db-instance-identifier "$instance_id" \
                    --query 'DBInstances[0].DBSubnetGroup.VpcId' \
                    --output text 2>/dev/null)
                if [[ "$instance_vpc" != "$TARGET_VPC_ID" ]]; then
                    log_debug "VPC 필터에 의해 건너뜀: ${instance_id} (VPC: ${instance_vpc})"
                    continue
                fi
            fi
            
            local exporter_type
            case "$engine" in
                aurora-mysql)    exporter_type="mysql" ;;
                aurora-postgresql) exporter_type="postgresql" ;;
                *)               log_warn "알 수 없는 Aurora 엔진: ${engine}"; continue ;;
            esac
            
            # 디스커버리 목록에 추가
            echo "${instance_id}|${endpoint}|${port}|${exporter_type}|aurora|${cluster_id}" >> /tmp/discovered_targets.txt
            log_info "  → Aurora 인스턴스 추가: ${instance_id} (${exporter_type}, 엔드포인트: ${endpoint}:${port})"
            
        done <<< "$instances"
        
    done <<< "$clusters"
    
    log_info "=== Aurora 디스커버리 완료 ==="
}

# ─────────────────────────────────────────────────────────────────────────────
# 일반 RDS 인스턴스 디스커버리
# ─────────────────────────────────────────────────────────────────────────────
discover_rds() {
    log_info "=== RDS (non-Aurora) 인스턴스 디스커버리 시작 ==="
    
    # Aurora가 아닌 RDS 인스턴스만 조회
    # DBClusterIdentifier가 없는 인스턴스 = standalone RDS
    local instances
    instances=$(aws rds describe-db-instances \
        --query 'DBInstances[?!DBClusterIdentifier].[DBInstanceIdentifier,Engine,Endpoint.Address,Endpoint.Port,DBInstanceStatus,DBInstanceArn]' \
        --output text 2>/dev/null)
    
    if [[ -z "$instances" ]]; then
        log_info "standalone RDS 인스턴스가 없습니다."
        return
    fi
    
    while IFS=$'\t' read -r instance_id engine endpoint port status instance_arn; do
        if [[ "$status" != "available" ]]; then
            log_warn "RDS 인스턴스 ${instance_id} 상태: ${status} (건너뜀)"
            continue
        fi
        
        # 태그 필터 확인
        if ! check_rds_tags "$instance_arn"; then
            log_debug "태그 필터에 의해 건너뜀: ${instance_id}"
            continue
        fi
        
        # VPC 필터링
        if [[ "$VPC_FILTER_ENABLED" == "true" && -n "$TARGET_VPC_ID" ]]; then
            local instance_vpc
            instance_vpc=$(aws rds describe-db-instances \
                --db-instance-identifier "$instance_id" \
                --query 'DBInstances[0].DBSubnetGroup.VpcId' \
                --output text 2>/dev/null)
            if [[ "$instance_vpc" != "$TARGET_VPC_ID" ]]; then
                log_debug "VPC 필터에 의해 건너뜀: ${instance_id} (VPC: ${instance_vpc})"
                continue
            fi
        fi
        
        # 엔진 종류에 따라 Exporter 타입 결정
        local exporter_type
        case "$engine" in
            mysql)
                exporter_type="mysql" ;;
            postgres)
                exporter_type="postgresql" ;;
            sqlserver-ee|sqlserver-se|sqlserver-ex|sqlserver-web)
                exporter_type="mssql" ;;
            mariadb)
                exporter_type="mysql" ;;  # MariaDB도 mysqld_exporter 사용 가능
            *)
                log_warn "지원하지 않는 RDS 엔진: ${engine} (인스턴스: ${instance_id})"
                continue
                ;;
        esac
        
        # 디스커버리 목록에 추가
        echo "${instance_id}|${endpoint}|${port}|${exporter_type}|rds|standalone" >> /tmp/discovered_targets.txt
        log_info "  → RDS 인스턴스 추가: ${instance_id} (엔진: ${engine}, Exporter: ${exporter_type})"
        
    done <<< "$instances"
    
    log_info "=== RDS 디스커버리 완료 ==="
}

# ─────────────────────────────────────────────────────────────────────────────
# ElastiCache 디스커버리 (Redis/Valkey)
# ─────────────────────────────────────────────────────────────────────────────
discover_elasticache() {
    log_info "=== ElastiCache 디스커버리 시작 ==="
    
    # Replication Group 기반 조회 (클러스터 모드)
    local repl_groups
    repl_groups=$(aws elasticache describe-replication-groups \
        --query 'ReplicationGroups[].[ReplicationGroupId,Status,NodeGroups[0].PrimaryEndpoint.Address,NodeGroups[0].PrimaryEndpoint.Port,ARN]' \
        --output text 2>/dev/null)
    
    if [[ -n "$repl_groups" ]]; then
        while IFS=$'\t' read -r group_id status endpoint port arn; do
            if [[ "$status" != "available" ]]; then
                log_warn "ElastiCache Replication Group ${group_id} 상태: ${status} (건너뜀)"
                continue
            fi
            
            # 태그 필터 확인
            if ! check_elasticache_tags "$arn"; then
                log_debug "태그 필터에 의해 건너뜀: ${group_id}"
                continue
            fi
            
            # Primary 엔드포인트가 없을 수 있음 (클러스터 모드 활성화 시)
            if [[ "$endpoint" == "None" || -z "$endpoint" ]]; then
                # 클러스터 모드 활성화 - Configuration Endpoint 사용
                local config_endpoint
                config_endpoint=$(aws elasticache describe-replication-groups \
                    --replication-group-id "$group_id" \
                    --query 'ReplicationGroups[0].ConfigurationEndpoint.Address' \
                    --output text 2>/dev/null)
                local config_port
                config_port=$(aws elasticache describe-replication-groups \
                    --replication-group-id "$group_id" \
                    --query 'ReplicationGroups[0].ConfigurationEndpoint.Port' \
                    --output text 2>/dev/null)
                
                if [[ -n "$config_endpoint" && "$config_endpoint" != "None" ]]; then
                    endpoint="$config_endpoint"
                    port="$config_port"
                else
                    log_warn "ElastiCache ${group_id}: 엔드포인트를 찾을 수 없습니다."
                    continue
                fi
            fi
            
            # 디스커버리 목록에 추가
            echo "${group_id}|${endpoint}|${port}|redis|elasticache|replication-group" >> /tmp/discovered_targets.txt
            log_info "  → ElastiCache 추가: ${group_id} (엔드포인트: ${endpoint}:${port})"
            
        done <<< "$repl_groups"
    fi
    
    # Standalone 캐시 클러스터 (Replication Group에 속하지 않는 것)
    local standalone_clusters
    standalone_clusters=$(aws elasticache describe-cache-clusters \
        --show-cache-node-info \
        --query 'CacheClusters[?!ReplicationGroupId && (Engine==`redis` || Engine==`valkey`)].[CacheClusterId,Engine,CacheNodes[0].Endpoint.Address,CacheNodes[0].Endpoint.Port,CacheClusterStatus,ARN]' \
        --output text 2>/dev/null)
    
    if [[ -n "$standalone_clusters" ]]; then
        while IFS=$'\t' read -r cluster_id engine endpoint port status arn; do
            if [[ "$status" != "available" ]]; then
                log_warn "ElastiCache 클러스터 ${cluster_id} 상태: ${status} (건너뜀)"
                continue
            fi
            
            if ! check_elasticache_tags "$arn"; then
                log_debug "태그 필터에 의해 건너뜀: ${cluster_id}"
                continue
            fi
            
            echo "${cluster_id}|${endpoint}|${port}|redis|elasticache|standalone" >> /tmp/discovered_targets.txt
            log_info "  → ElastiCache Standalone 추가: ${cluster_id} (엔진: ${engine})"
            
        done <<< "$standalone_clusters"
    fi
    
    if [[ ! -f /tmp/discovered_targets.txt ]] || ! grep -q "elasticache" /tmp/discovered_targets.txt 2>/dev/null; then
        log_info "ElastiCache 인스턴스가 없습니다."
    fi
    
    log_info "=== ElastiCache 디스커버리 완료 ==="
}

# ─────────────────────────────────────────────────────────────────────────────
# 현재 배포된 Exporter 목록 조회
# ─────────────────────────────────────────────────────────────────────────────
get_current_exporters() {
    log_info "=== 현재 배포된 Exporter 목록 조회 ==="
    
    kubectl get deployments -n "$NAMESPACE" -l "$LABEL_SELECTOR" \
        -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.annotations.db-discovery/db-identifier}|{.metadata.annotations.db-discovery/endpoint}|{.metadata.annotations.db-discovery/exporter-type}{"\n"}{end}' \
        > /tmp/current_exporters.txt 2>/dev/null || true
    
    local count
    count=$(wc -l < /tmp/current_exporters.txt 2>/dev/null | tr -d ' ')
    log_info "현재 배포된 Exporter 수: ${count:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Exporter 배포 함수
# ─────────────────────────────────────────────────────────────────────────────
deploy_exporter() {
    local db_identifier="$1"
    local endpoint="$2"
    local port="$3"
    local exporter_type="$4"
    local source_type="$5"  # aurora, rds, elasticache
    local cluster_id="$6"
    
    local deploy_name
    deploy_name="exporter-$(sanitize_name "${exporter_type}-${db_identifier}")"
    
    log_info "Exporter 배포 중: ${deploy_name} (타입: ${exporter_type}, 대상: ${endpoint}:${port})"
    
    # 템플릿 파일 선택
    local template_file="${TEMPLATE_DIR}/${exporter_type}-exporter-template.yaml"
    
    if [[ ! -f "$template_file" ]]; then
        log_error "템플릿 파일 없음: ${template_file}"
        return 1
    fi
    
    # 환경변수 치환으로 매니페스트 생성
    local manifest_file="/tmp/manifest-${deploy_name}.yaml"
    
    export DEPLOY_NAME="$deploy_name"
    export DB_IDENTIFIER="$db_identifier"
    export DB_ENDPOINT="$endpoint"
    export DB_PORT="$port"
    export EXPORTER_TYPE="$exporter_type"
    export SOURCE_TYPE="$source_type"
    export CLUSTER_ID="$cluster_id"
    export TARGET_NAMESPACE="$NAMESPACE"
    
    # 엔진별 추가 설정
    case "$exporter_type" in
        mysql)
            export EXPORTER_IMAGE="prom/mysqld-exporter:v0.15.1"
            export EXPORTER_PORT="9104"
            export SECRET_NAME="$MYSQL_SECRET_NAME"
            ;;
        postgresql)
            export EXPORTER_IMAGE="prometheuscommunity/postgres-exporter:v0.15.0"
            export EXPORTER_PORT="9187"
            export SECRET_NAME="$POSTGRESQL_SECRET_NAME"
            ;;
        mssql)
            export EXPORTER_IMAGE="awarber/prometheus-mssql-exporter:latest"
            export EXPORTER_PORT="4000"
            export SECRET_NAME="$MSSQL_SECRET_NAME"
            ;;
        redis)
            export EXPORTER_IMAGE="oliver006/redis_exporter:v1.58.0"
            export EXPORTER_PORT="9121"
            export SECRET_NAME=""  # Redis는 보통 패스워드 없이 또는 AUTH 토큰 사용
            ;;
        *)
            log_error "알 수 없는 Exporter 타입: ${exporter_type}"
            return 1
            ;;
    esac
    
    envsubst < "$template_file" > "$manifest_file"
    kubectl_apply "$manifest_file"
    
    # 정리
    rm -f "$manifest_file"
    
    log_info "  ✅ Exporter 배포 완료: ${deploy_name}"
}

# ─────────────────────────────────────────────────────────────────────────────
# orphaned Exporter 제거 함수
# ─────────────────────────────────────────────────────────────────────────────
remove_exporter() {
    local deploy_name="$1"
    local db_identifier="$2"
    
    log_info "orphaned Exporter 제거 중: ${deploy_name} (DB: ${db_identifier})"
    
    kubectl_delete "deployment" "$deploy_name"
    kubectl_delete "service" "$deploy_name"
    
    log_info "  🗑️  Exporter 제거 완료: ${deploy_name}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Reconciliation (원하는 상태 vs 현재 상태 비교)
# ─────────────────────────────────────────────────────────────────────────────
reconcile() {
    log_info "=== Reconciliation 시작 ==="
    
    local added=0
    local removed=0
    local unchanged=0
    
    # 1. 디스커버리된 타깃 중 현재 Exporter가 없는 것 → 새로 배포
    if [[ -f /tmp/discovered_targets.txt ]]; then
        while IFS='|' read -r db_id endpoint port exporter_type source_type cluster_id; do
            local expected_name
            expected_name="exporter-$(sanitize_name "${exporter_type}-${db_id}")"
            
            if grep -q "^${expected_name}|" /tmp/current_exporters.txt 2>/dev/null; then
                log_debug "이미 존재: ${expected_name}"
                ((unchanged++)) || true
            else
                log_info "새 DB 감지 → Exporter 배포: ${db_id}"
                deploy_exporter "$db_id" "$endpoint" "$port" "$exporter_type" "$source_type" "$cluster_id"
                ((added++)) || true
            fi
        done < /tmp/discovered_targets.txt
    fi
    
    # 2. 현재 배포된 Exporter 중 디스커버리 목록에 없는 것 → orphaned, 제거
    if [[ -f /tmp/current_exporters.txt && -s /tmp/current_exporters.txt ]]; then
        while IFS='|' read -r deploy_name db_id endpoint exporter_type; do
            if [[ -z "$deploy_name" ]]; then continue; fi
            
            if ! grep -q "^${db_id}|" /tmp/discovered_targets.txt 2>/dev/null; then
                log_warn "orphaned Exporter 감지 → 제거: ${deploy_name} (DB: ${db_id})"
                remove_exporter "$deploy_name" "$db_id"
                ((removed++)) || true
            fi
        done < /tmp/current_exporters.txt
    fi
    
    log_info "=== Reconciliation 완료 ==="
    log_info "  추가: ${added}, 제거: ${removed}, 변경없음: ${unchanged}"
}

# ─────────────────────────────────────────────────────────────────────────────
# ConfigMap에 상태 기록 (annotation 대신 ConfigMap 사용)
# ─────────────────────────────────────────────────────────────────────────────
update_state_configmap() {
    log_info "=== 상태 ConfigMap 업데이트 ==="
    
    local timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local target_count=0
    [[ -f /tmp/discovered_targets.txt ]] && target_count=$(wc -l < /tmp/discovered_targets.txt | tr -d ' ')
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] ConfigMap 업데이트 건너뜀"
        return
    fi
    
    kubectl create configmap db-discovery-state \
        -n "$NAMESPACE" \
        --from-literal="last-run=${timestamp}" \
        --from-literal="target-count=${target_count}" \
        --from-file="discovered-targets=/tmp/discovered_targets.txt" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log_info "상태 ConfigMap 업데이트 완료 (타깃 수: ${target_count}, 시각: ${timestamp})"
}

# ─────────────────────────────────────────────────────────────────────────────
# 메인 실행
# ─────────────────────────────────────────────────────────────────────────────
main() {
    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║    통합 DB 자동 디스커버리 시작                              ║"
    log_info "║    네임스페이스: ${NAMESPACE}"
    log_info "║    DRY-RUN: ${DRY_RUN}"
    log_info "║    태그 필터: ${TAG_FILTER_ENABLED}"
    log_info "║    VPC 필터: ${VPC_FILTER_ENABLED}"
    log_info "╚══════════════════════════════════════════════════════════════╝"
    
    # 임시 파일 초기화
    rm -f /tmp/discovered_targets.txt /tmp/current_exporters.txt
    touch /tmp/discovered_targets.txt
    
    # 1단계: 모든 DB 서비스 디스커버리
    discover_aurora
    discover_rds
    discover_elasticache
    
    # 2단계: 현재 배포된 Exporter 조회
    get_current_exporters
    
    # 3단계: Reconciliation
    reconcile
    
    # 4단계: 상태 기록
    update_state_configmap
    
    # 정리
    rm -f /tmp/discovered_targets.txt /tmp/current_exporters.txt
    
    log_info "╔══════════════════════════════════════════════════════════════╗"
    log_info "║    통합 DB 자동 디스커버리 완료                              ║"
    log_info "╚══════════════════════════════════════════════════════════════╝"
}

# 스크립트 실행
main "$@"
