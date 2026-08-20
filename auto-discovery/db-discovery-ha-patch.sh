#!/bin/bash
# =============================================================================
# db-discovery HA 패치 스크립트
# =============================================================================
# 
# 기존 db-discovery-updated.sh의 deploy_exporter() 함수를 HA 버전으로 수정합니다.
# 변경사항:
#   - replicas: 1 → replicas: 2
#   - podAntiAffinity 추가 (다른 노드/AZ에 분산)
#   - topologySpreadConstraints 추가
#   - PodDisruptionBudget 자동 생성
#   - Headless Service 사용 (각 Pod 개별 scrape)
#   - 빠른 복구 Probe 설정 적용
#
# 사용법:
#   이 스크립트의 deploy_exporter_ha() 함수로 기존 deploy_exporter()를 교체합니다.
#   또는 기존 스크립트에서 source로 로드:
#     source ./db-discovery-ha-patch.sh
# =============================================================================

# HA 설정값
HA_REPLICAS="${HA_REPLICAS:-2}"
HA_MIN_AVAILABLE="${HA_MIN_AVAILABLE:-1}"

# =============================================================================
# deploy_exporter_ha() — HA 버전 Exporter 배포
# =============================================================================
# 기존 deploy_exporter()를 대체합니다.
# 
# 인자:
#   $1: DB_IDENTIFIER  (예: aurora-mysql-instance-1)
#   $2: DB_ENDPOINT    (예: aurora-mysql.cluster-xxx.region.rds.amazonaws.com)
#   $3: DB_PORT        (예: 3306)
#   $4: DB_ENGINE      (예: mysql, postgresql, sqlserver, redis)
#   $5: CLUSTER_ID     (예: aurora-mysql-cluster-1, 없으면 "standalone")
#   $6: SOURCE_TYPE    (예: aurora, rds, elasticache)
# =============================================================================
deploy_exporter_ha() {
    local DB_IDENTIFIER="$1"
    local DB_ENDPOINT="$2"
    local DB_PORT="$3"
    local DB_ENGINE="$4"
    local CLUSTER_ID="${5:-standalone}"
    local SOURCE_TYPE="${6:-unknown}"

    # 엔진별 설정 분기
    local EXPORTER_IMAGE=""
    local EXPORTER_PORT=""
    local EXPORTER_APP=""
    local SECRET_NAME=""

    case "$DB_ENGINE" in
        mysql)
            EXPORTER_IMAGE="prom/mysqld-exporter:v0.15.1"
            EXPORTER_PORT="9104"
            EXPORTER_APP="mysql-exporter"
            SECRET_NAME="db-cred-mysql-${DB_IDENTIFIER}"
            ;;
        postgresql|postgres)
            EXPORTER_IMAGE="prometheuscommunity/postgres-exporter:v0.15.0"
            EXPORTER_PORT="9187"
            EXPORTER_APP="postgresql-exporter"
            SECRET_NAME="db-cred-pg-${DB_IDENTIFIER}"
            ;;
        sqlserver*)
            EXPORTER_IMAGE="awarber/prometheus-mssql-exporter:latest"
            EXPORTER_PORT="4000"
            EXPORTER_APP="mssql-exporter"
            SECRET_NAME="db-cred-mssql-${DB_IDENTIFIER}"
            ;;
        redis|valkey)
            EXPORTER_IMAGE="oliver006/redis_exporter:v1.58.0"
            EXPORTER_PORT="9121"
            EXPORTER_APP="redis-exporter"
            SECRET_NAME="db-cred-redis-${DB_IDENTIFIER}"
            ;;
        *)
            log "ERROR" "지원하지 않는 엔진: $DB_ENGINE"
            return 1
            ;;
    esac

    local DEPLOY_NAME="exp-${DB_IDENTIFIER}"
    local NAMESPACE="${TARGET_NAMESPACE:-observability}"
    local CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    log "INFO" "HA Exporter 배포: ${DEPLOY_NAME} (${DB_ENGINE}, replicas: ${HA_REPLICAS})"

    # ─────────────────────────────────────────────────────────────────────────
    # Deployment 생성 (replicas: 2, podAntiAffinity, topologySpread)
    # ─────────────────────────────────────────────────────────────────────────
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${EXPORTER_APP}
    db-discovery/managed-by: auto-discovery
    db-discovery/exporter-type: ${DB_ENGINE}
    db-discovery/source-type: ${SOURCE_TYPE}
  annotations:
    db-discovery/db-identifier: "${DB_IDENTIFIER}"
    db-discovery/endpoint: "${DB_ENDPOINT}"
    db-discovery/port: "${DB_PORT}"
    db-discovery/engine: "${DB_ENGINE}"
    db-discovery/cluster-id: "${CLUSTER_ID}"
    db-discovery/ha-enabled: "true"
    db-discovery/ha-replicas: "${HA_REPLICAS}"
    db-discovery/created-at: "${CREATED_AT}"
spec:
  replicas: ${HA_REPLICAS}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app: ${EXPORTER_APP}
      db-instance: ${DB_IDENTIFIER}
  template:
    metadata:
      labels:
        app: ${EXPORTER_APP}
        db-instance: ${DB_IDENTIFIER}
        db-discovery/managed-by: auto-discovery
        db-engine: ${DB_ENGINE}
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "${EXPORTER_PORT}"
        prometheus.io/path: "/metrics"
        db-discovery/db-identifier: "${DB_IDENTIFIER}"
        db-discovery/endpoint: "${DB_ENDPOINT}"
        db-discovery/engine: "${DB_ENGINE}"
        db-discovery/cluster-id: "${CLUSTER_ID}"
    spec:
      terminationGracePeriodSeconds: 5
      tolerations:
        - key: "node.kubernetes.io/not-ready"
          operator: "Exists"
          effect: "NoExecute"
          tolerationSeconds: 10
        - key: "node.kubernetes.io/unreachable"
          operator: "Exists"
          effect: "NoExecute"
          tolerationSeconds: 10
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: db-instance
                      operator: In
                      values:
                        - ${DB_IDENTIFIER}
                topologyKey: kubernetes.io/hostname
            - weight: 50
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: db-instance
                      operator: In
                      values:
                        - ${DB_IDENTIFIER}
                topologyKey: topology.kubernetes.io/zone
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              db-instance: ${DB_IDENTIFIER}
      containers:
        - name: exporter
          image: ${EXPORTER_IMAGE}
          ports:
            - containerPort: ${EXPORTER_PORT}
              name: metrics
              protocol: TCP
          env:
            - name: DB_ENDPOINT
              value: "${DB_ENDPOINT}"
            - name: DB_PORT
              value: "${DB_PORT}"
          envFrom:
            - secretRef:
                name: ${SECRET_NAME}
                optional: true
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          startupProbe:
            httpGet:
              path: /metrics
              port: ${EXPORTER_PORT}
            periodSeconds: 2
            failureThreshold: 15
            successThreshold: 1
          livenessProbe:
            httpGet:
              path: /metrics
              port: ${EXPORTER_PORT}
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 2
          readinessProbe:
            httpGet:
              path: /metrics
              port: ${EXPORTER_PORT}
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 1
EOF

    # ─────────────────────────────────────────────────────────────────────────
    # Headless Service 생성 (각 Pod 개별 scrape 가능)
    # ─────────────────────────────────────────────────────────────────────────
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${EXPORTER_APP}
    db-discovery/managed-by: auto-discovery
    db-instance: ${DB_IDENTIFIER}
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "${EXPORTER_PORT}"
    prometheus.io/path: "/metrics"
spec:
  clusterIP: None
  ports:
    - port: ${EXPORTER_PORT}
      targetPort: ${EXPORTER_PORT}
      protocol: TCP
      name: metrics
  selector:
    app: ${EXPORTER_APP}
    db-instance: ${DB_IDENTIFIER}
EOF

    # ─────────────────────────────────────────────────────────────────────────
    # PodDisruptionBudget 생성 (최소 1개 Pod 항상 유지)
    # ─────────────────────────────────────────────────────────────────────────
    cat <<EOF | kubectl apply -f -
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${DEPLOY_NAME}-pdb
  namespace: ${NAMESPACE}
  labels:
    db-discovery/managed-by: auto-discovery
    db-instance: ${DB_IDENTIFIER}
spec:
  minAvailable: ${HA_MIN_AVAILABLE}
  selector:
    matchLabels:
      app: ${EXPORTER_APP}
      db-instance: ${DB_IDENTIFIER}
EOF

    log "INFO" "HA Exporter 배포 완료: ${DEPLOY_NAME} (${HA_REPLICAS} replicas, PDB: min ${HA_MIN_AVAILABLE})"
}

# =============================================================================
# remove_exporter_ha() — HA Exporter 제거 (Deployment + Service + PDB)
# =============================================================================
remove_exporter_ha() {
    local DB_IDENTIFIER="$1"
    local DEPLOY_NAME="exp-${DB_IDENTIFIER}"
    local NAMESPACE="${TARGET_NAMESPACE:-observability}"

    log "INFO" "HA Exporter 제거: ${DEPLOY_NAME}"

    kubectl delete deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    kubectl delete service "${DEPLOY_NAME}" -n "${NAMESPACE}" --ignore-not-found=true
    kubectl delete pdb "${DEPLOY_NAME}-pdb" -n "${NAMESPACE}" --ignore-not-found=true

    log "INFO" "HA Exporter 제거 완료: ${DEPLOY_NAME}"
}

# =============================================================================
# check_exporter_health() — Exporter HA 상태 확인
# =============================================================================
check_exporter_health() {
    local DB_IDENTIFIER="$1"
    local DEPLOY_NAME="exp-${DB_IDENTIFIER}"
    local NAMESPACE="${TARGET_NAMESPACE:-observability}"

    local READY=$(kubectl get deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    local DESIRED=$(kubectl get deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null)

    if [[ -z "$READY" || "$READY" == "0" ]]; then
        echo "CRITICAL"  # 모든 Pod 다운
    elif [[ "$READY" -lt "$DESIRED" ]]; then
        echo "DEGRADED"  # 일부 Pod 다운 (HA 열화)
    else
        echo "HEALTHY"   # 모든 Pod 정상
    fi
}

# =============================================================================
# log() — 로깅 함수
# =============================================================================
log() {
    local LEVEL="$1"
    local MSG="$2"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${LEVEL}] ${MSG}"
}

# =============================================================================
# 사용 예시
# =============================================================================
# source ./db-discovery-ha-patch.sh
#
# deploy_exporter_ha \
#   "aurora-mysql-writer-1" \
#   "aurora-mysql.cluster-xxx.ap-northeast-2.rds.amazonaws.com" \
#   "3306" \
#   "mysql" \
#   "aurora-mysql-cluster-1" \
#   "aurora"
#
# check_exporter_health "aurora-mysql-writer-1"
# → "HEALTHY" 또는 "DEGRADED" 또는 "CRITICAL"
#
# remove_exporter_ha "aurora-mysql-writer-1"
# =============================================================================
