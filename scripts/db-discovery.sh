#!/bin/bash
# =============================================================================
# DB Discovery 통합 스크립트 (Aurora + RDS 인스턴스 자동 발견)
# =============================================================================
# 용도: Aurora 클러스터와 일반 RDS 인스턴스를 모두 디스커버리하여
#       각 인스턴스에 맞는 Exporter Pod를 자동 배포/업데이트
# 
# 기존 Aurora Discovery 대비 추가된 기능:
#   1. RDS (non-Aurora) 인스턴스 디스커버리
#   2. MS SQL Server 인스턴스 지원
#   3. 엔진별 Exporter 자동 매핑
#   4. 인스턴스 추가/삭제 시 동적 대응
# =============================================================================

set -euo pipefail

# ─── 설정 ───
NAMESPACE="${NAMESPACE:-observability}"
ENVIRONMENT="${WORKSHOP_NAME:-integrated-db-monitoring}"
AWS_REGION="${AWS_REGION:-$(aws configure get region)}"
DISCOVERY_INTERVAL="${DISCOVERY_INTERVAL:-300}"  # 5분 주기

# 색상 출력
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }

# =============================================================================
# 1. Aurora 클러스터 디스커버리
# =============================================================================
discover_aurora_clusters() {
    log_info "Aurora 클러스터 디스커버리 시작..."
    
    # 환경 태그가 있는 Aurora 클러스터만 필터링
    local clusters=$(aws rds describe-db-clusters \
        --region ${AWS_REGION} \
        --query "DBClusters[?contains(TagList[?Key=='Name'].Value | [0], '${ENVIRONMENT}')].[DBClusterIdentifier,Engine,Endpoint,ReaderEndpoint,Status]" \
        --output json)
    
    echo "$clusters" | jq -r '.[] | @tsv' | while IFS=$'\t' read -r cluster_id engine endpoint reader_endpoint status; do
        if [ "$status" != "available" ]; then
            log_warn "클러스터 $cluster_id 상태: $status (스킵)"
            continue
        fi
        
        log_info "발견된 Aurora 클러스터: $cluster_id (엔진: $engine)"
        
        # 클러스터의 개별 인스턴스 목록 조회
        local instances=$(aws rds describe-db-instances \
            --region ${AWS_REGION} \
            --filters "Name=db-cluster-id,Values=${cluster_id}" \
            --query "DBInstances[].[DBInstanceIdentifier,Endpoint.Address,Endpoint.Port,DBInstanceStatus,PromotionTier]" \
            --output json)
        
        echo "$instances" | jq -r '.[] | @tsv' | while IFS=$'\t' read -r instance_id inst_endpoint port inst_status tier; do
            if [ "$inst_status" != "available" ]; then
                log_warn "  인스턴스 $instance_id 상태: $inst_status (스킵)"
                continue
            fi
            
            # Writer(tier=0) / Reader(tier>0) 구분
            local role="reader"
            if [ "$tier" == "0" ]; then
                role="writer"
            fi
            
            log_info "  → 인스턴스: $instance_id (역할: $role, 엔드포인트: $inst_endpoint:$port)"
            
            # 엔진에 맞는 Exporter 배포
            deploy_exporter "$engine" "$instance_id" "$inst_endpoint" "$port" "$role" "$cluster_id"
        done
    done
}

# =============================================================================
# 2. RDS (non-Aurora) 인스턴스 디스커버리
# =============================================================================
discover_rds_instances() {
    log_info "RDS (non-Aurora) 인스턴스 디스커버리 시작..."
    
    # Aurora가 아닌 RDS 인스턴스 조회 (DBClusterIdentifier가 없는 것)
    local instances=$(aws rds describe-db-instances \
        --region ${AWS_REGION} \
        --query "DBInstances[?!DBClusterIdentifier && contains(TagList[?Key=='Name'].Value | [0], '${ENVIRONMENT}')].[DBInstanceIdentifier,Engine,Endpoint.Address,Endpoint.Port,DBInstanceStatus]" \
        --output json)
    
    echo "$instances" | jq -r '.[] | @tsv' | while IFS=$'\t' read -r instance_id engine endpoint port status; do
        if [ "$status" != "available" ]; then
            log_warn "RDS 인스턴스 $instance_id 상태: $status (스킵)"
            continue
        fi
        
        log_info "발견된 RDS 인스턴스: $instance_id (엔진: $engine, 엔드포인트: $endpoint:$port)"
        
        # RDS는 단일 인스턴스이므로 writer 역할
        deploy_exporter "$engine" "$instance_id" "$endpoint" "$port" "writer" "standalone"
    done
}

# =============================================================================
# 3. ElastiCache 클러스터 디스커버리
# =============================================================================
discover_elasticache() {
    log_info "ElastiCache 클러스터 디스커버리 시작..."
    
    # Valkey/Redis 클러스터 조회
    local clusters=$(aws elasticache describe-cache-clusters \
        --region ${AWS_REGION} \
        --show-cache-node-info \
        --query "CacheClusters[?contains(CacheClusterId, '${ENVIRONMENT}')].[CacheClusterId,Engine,CacheNodes[0].Endpoint.Address,CacheNodes[0].Endpoint.Port,CacheClusterStatus]" \
        --output json)
    
    echo "$clusters" | jq -r '.[] | @tsv' | while IFS=$'\t' read -r cluster_id engine endpoint port status; do
        if [ "$status" != "available" ]; then
            log_warn "ElastiCache 클러스터 $cluster_id 상태: $status (스킵)"
            continue
        fi
        
        log_info "발견된 ElastiCache: $cluster_id (엔진: $engine, 엔드포인트: $endpoint:$port)"
        deploy_redis_exporter "$cluster_id" "$endpoint" "$port"
    done
}

# =============================================================================
# 4. Exporter 배포 함수
# =============================================================================
deploy_exporter() {
    local engine="$1"
    local instance_id="$2"
    local endpoint="$3"
    local port="$4"
    local role="$5"
    local cluster_id="$6"
    
    # 엔진별 Exporter 이미지 및 포트 매핑
    local exporter_image=""
    local exporter_port=""
    local exporter_name=""
    local app_label=""
    
    case "$engine" in
        aurora-mysql|mysql)
            exporter_image="prom/mysqld-exporter:v0.15.1"
            exporter_port="9104"
            exporter_name="mysql-exporter-${instance_id}"
            app_label="mysql-exporter"
            ;;
        aurora-postgresql|postgres|postgresql)
            exporter_image="prometheuscommunity/postgres-exporter:v0.15.0"
            exporter_port="9187"
            exporter_name="postgresql-exporter-${instance_id}"
            app_label="postgresql-exporter"
            ;;
        sqlserver-ex|sqlserver-se|sqlserver-ee|sqlserver-web)
            exporter_image="awaragi/prometheus-mssql-exporter:0.7.1"
            exporter_port="4000"
            exporter_name="mssql-exporter-${instance_id}"
            app_label="mssql-exporter"
            ;;
        *)
            log_error "미지원 엔진: $engine (인스턴스: $instance_id)"
            return 1
            ;;
    esac
    
    # 이미 배포된 Exporter가 있는지 확인
    if kubectl get deployment "${exporter_name}" -n ${NAMESPACE} &>/dev/null; then
        log_info "  ✓ Exporter 이미 존재: ${exporter_name}"
        return 0
    fi
    
    log_info "  📦 Exporter 배포: ${exporter_name} (이미지: ${exporter_image})"
    
    # Deployment 매니페스트 생성 및 적용
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${exporter_name}
  namespace: ${NAMESPACE}
  labels:
    app: ${app_label}
    db.instance: ${instance_id}
    db.role: ${role}
    db.engine: ${engine}
    db.cluster: ${cluster_id}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${app_label}
      db.instance: ${instance_id}
  template:
    metadata:
      labels:
        app: ${app_label}
        db_instance: ${instance_id}
        db_role: ${role}
        db_engine: ${engine}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "${exporter_port}"
        prometheus.io/path: "/metrics"
    spec:
      serviceAccountName: db-exporter
      containers:
        - name: exporter
          image: ${exporter_image}
          ports:
            - containerPort: ${exporter_port}
          env:
            - name: DB_HOST
              value: "${endpoint}"
            - name: DB_PORT
              value: "${port}"
$(generate_env_vars "$engine" "$endpoint" "$port")
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /metrics
              port: ${exporter_port}
            initialDelaySeconds: 30
            periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: ${exporter_name}
  namespace: ${NAMESPACE}
  labels:
    app: ${app_label}
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "${exporter_port}"
    prometheus.io/path: "/metrics"
spec:
  type: ClusterIP
  ports:
    - port: ${exporter_port}
      targetPort: ${exporter_port}
  selector:
    app: ${app_label}
    db.instance: ${instance_id}
EOF
    
    log_info "  ✅ Exporter 배포 완료: ${exporter_name}"
}

# =============================================================================
# 5. 엔진별 환경변수 생성
# =============================================================================
generate_env_vars() {
    local engine="$1"
    local endpoint="$2"
    local port="$3"
    
    case "$engine" in
        aurora-mysql|mysql)
            cat <<ENVEOF
            - name: DATA_SOURCE_NAME
              valueFrom:
                secretKeyRef:
                  name: mysql-exporter-credentials
                  key: datasource
ENVEOF
            ;;
        aurora-postgresql|postgres|postgresql)
            cat <<ENVEOF
            - name: DATA_SOURCE_URI
              value: "${endpoint}:${port}/postgres?sslmode=require"
            - name: DATA_SOURCE_USER
              valueFrom:
                secretKeyRef:
                  name: postgresql-exporter-credentials
                  key: username
            - name: DATA_SOURCE_PASS
              valueFrom:
                secretKeyRef:
                  name: postgresql-exporter-credentials
                  key: password
ENVEOF
            ;;
        sqlserver-ex|sqlserver-se|sqlserver-ee|sqlserver-web)
            cat <<ENVEOF
            - name: SERVER
              value: "${endpoint}"
            - name: PORT
              value: "${port}"
            - name: USERNAME
              valueFrom:
                secretKeyRef:
                  name: mssql-exporter-credentials
                  key: username
            - name: PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mssql-exporter-credentials
                  key: password
ENVEOF
            ;;
    esac
}

# =============================================================================
# 6. Redis Exporter 배포
# =============================================================================
deploy_redis_exporter() {
    local cluster_id="$1"
    local endpoint="$2"
    local port="$3"
    local exporter_name="redis-exporter-${cluster_id}"
    
    if kubectl get deployment "${exporter_name}" -n ${NAMESPACE} &>/dev/null; then
        log_info "  ✓ Redis Exporter 이미 존재: ${exporter_name}"
        return 0
    fi
    
    log_info "  📦 Redis Exporter 배포: ${exporter_name}"
    
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${exporter_name}
  namespace: ${NAMESPACE}
  labels:
    app: redis-exporter
    cache.cluster: ${cluster_id}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis-exporter
      cache.cluster: ${cluster_id}
  template:
    metadata:
      labels:
        app: redis-exporter
        cache_cluster: ${cluster_id}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9121"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: redis-exporter
          image: oliver006/redis_exporter:v1.62.0
          ports:
            - containerPort: 9121
          env:
            - name: REDIS_ADDR
              value: "redis://${endpoint}:${port}"
            - name: REDIS_EXPORTER_IS_CLUSTER
              value: "true"
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /health
              port: 9121
            initialDelaySeconds: 15
            periodSeconds: 15
---
apiVersion: v1
kind: Service
metadata:
  name: ${exporter_name}
  namespace: ${NAMESPACE}
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9121"
    prometheus.io/path: "/metrics"
spec:
  type: ClusterIP
  ports:
    - port: 9121
      targetPort: 9121
  selector:
    app: redis-exporter
    cache.cluster: ${cluster_id}
EOF
    
    log_info "  ✅ Redis Exporter 배포 완료: ${exporter_name}"
}

# =============================================================================
# 7. 고아 Exporter 정리 (삭제된 인스턴스의 Exporter 제거)
# =============================================================================
cleanup_orphaned_exporters() {
    log_info "고아 Exporter 정리 시작..."
    
    # 현재 배포된 Exporter 목록
    local deployed_exporters=$(kubectl get deployments -n ${NAMESPACE} \
        -l "app in (mysql-exporter, postgresql-exporter, mssql-exporter, redis-exporter)" \
        -o jsonpath='{.items[*].metadata.labels.db\.instance}')
    
    for instance_id in $deployed_exporters; do
        # AWS에서 인스턴스가 아직 존재하는지 확인
        if ! aws rds describe-db-instances --db-instance-identifier "$instance_id" &>/dev/null; then
            log_warn "  🗑️ 고아 Exporter 발견 및 삭제: $instance_id"
            kubectl delete deployment -n ${NAMESPACE} -l "db.instance=${instance_id}"
            kubectl delete service -n ${NAMESPACE} -l "db.instance=${instance_id}"
        fi
    done
}

# =============================================================================
# 8. 메인 루프
# =============================================================================
main() {
    log_info "=========================================="
    log_info "DB Discovery 통합 스크립트 시작"
    log_info "환경: ${ENVIRONMENT}"
    log_info "리전: ${AWS_REGION}"
    log_info "네임스페이스: ${NAMESPACE}"
    log_info "디스커버리 주기: ${DISCOVERY_INTERVAL}초"
    log_info "=========================================="
    
    # 네임스페이스 생성 (없으면)
    kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
    
    while true; do
        log_info "─── 디스커버리 사이클 시작 ───"
        
        # 1단계: Aurora 클러스터 디스커버리
        discover_aurora_clusters
        
        # 2단계: RDS (non-Aurora) 인스턴스 디스커버리
        discover_rds_instances
        
        # 3단계: ElastiCache 디스커버리
        discover_elasticache
        
        # 4단계: 고아 Exporter 정리
        cleanup_orphaned_exporters
        
        log_info "─── 디스커버리 사이클 완료 ───"
        log_info "다음 사이클까지 ${DISCOVERY_INTERVAL}초 대기..."
        
        sleep ${DISCOVERY_INTERVAL}
    done
}

# 단일 실행 모드 (--once 옵션)
if [ "${1:-}" == "--once" ]; then
    log_info "단일 실행 모드"
    discover_aurora_clusters
    discover_rds_instances
    discover_elasticache
    cleanup_orphaned_exporters
    log_info "단일 실행 완료"
    exit 0
fi

# 루프 모드 (기본)
main
