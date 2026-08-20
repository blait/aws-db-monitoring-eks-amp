#!/bin/bash
# =============================================================================
# DynamoDB 자동 디스커버리 패치
# =============================================================================
# 기존 db-discovery-updated.sh에 추가할 DynamoDB 디스커버리 함수입니다.
#
# DynamoDB는 별도 Exporter Pod이 필요 없고, ADOT Collector의 CloudWatch
# Receiver가 직접 수집합니다. 따라서 이 스크립트는:
#   1. DynamoDB 테이블 목록을 조회
#   2. 태그 기반 필터링
#   3. ADOT Collector의 ConfigMap을 업데이트 (테이블 목록 반영)
#   4. ADOT Collector를 재시작하여 새 설정 적용
#
# 📌 사용법:
#   이 파일의 함수들을 db-discovery-updated.sh에 추가하거나,
#   별도로 DynamoDB 전용 CronJob으로 실행합니다.
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# 설정값
# ─────────────────────────────────────────────────────────────────────────────
DYNAMODB_CONFIGMAP_NAME="${DYNAMODB_CONFIGMAP_NAME:-adot-dynamodb-tables}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-observability}"
FILTER_TAG_KEY="${DYNAMODB_FILTER_TAG_KEY:-monitoring}"
FILTER_TAG_VALUE="${DYNAMODB_FILTER_TAG_VALUE:-enabled}"
FILTER_BY_TAG="${DYNAMODB_FILTER_BY_TAG:-false}"  # true: 태그 필터링, false: 전체
AWS_REGION="${AWS_REGION:-ap-northeast-2}"

# ─────────────────────────────────────────────────────────────────────────────
# discover_dynamodb()
# DynamoDB 테이블 목록을 조회하고 필터링합니다.
# ─────────────────────────────────────────────────────────────────────────────
discover_dynamodb() {
    log_info "[DynamoDB] 테이블 디스커버리 시작..."
    
    # 전체 테이블 목록 조회
    local all_tables
    all_tables=$(aws dynamodb list-tables \
        --region "$AWS_REGION" \
        --query 'TableNames[]' \
        --output text 2>/dev/null)
    
    if [[ $? -ne 0 || -z "$all_tables" ]]; then
        log_warn "[DynamoDB] 테이블을 조회할 수 없거나 테이블이 없습니다."
        return 0
    fi
    
    local table_count
    table_count=$(echo "$all_tables" | wc -w)
    log_info "[DynamoDB] 총 ${table_count}개 테이블 발견"
    
    # 태그 기반 필터링
    local filtered_tables=()
    if [[ "$FILTER_BY_TAG" == "true" ]]; then
        log_info "[DynamoDB] 태그 필터링 적용: ${FILTER_TAG_KEY}=${FILTER_TAG_VALUE}"
        
        for table in $all_tables; do
            local tags
            tags=$(aws dynamodb describe-table \
                --table-name "$table" \
                --region "$AWS_REGION" \
                --query "Table.Tags[?Key=='${FILTER_TAG_KEY}'].Value" \
                --output text 2>/dev/null)
            
            if [[ "$tags" == "$FILTER_TAG_VALUE" ]]; then
                filtered_tables+=("$table")
                log_debug "[DynamoDB] ✅ 포함: $table (태그 일치)"
            else
                log_debug "[DynamoDB] ⏭️  제외: $table (태그 불일치)"
            fi
        done
    else
        # 필터링 없이 전체 포함
        for table in $all_tables; do
            filtered_tables+=("$table")
        done
    fi
    
    log_info "[DynamoDB] 모니터링 대상: ${#filtered_tables[@]}개 테이블"
    
    # 결과 출력 (파이프라인에서 사용)
    printf '%s\n' "${filtered_tables[@]}"
}

# ─────────────────────────────────────────────────────────────────────────────
# get_dynamodb_table_details()
# 테이블의 상세 정보를 조회합니다 (용량 모드, GSI 등).
# ─────────────────────────────────────────────────────────────────────────────
get_dynamodb_table_details() {
    local table_name="$1"
    
    local details
    details=$(aws dynamodb describe-table \
        --table-name "$table_name" \
        --region "$AWS_REGION" \
        --query '{
            TableName: Table.TableName,
            TableStatus: Table.TableStatus,
            BillingMode: Table.BillingModeSummary.BillingMode,
            ItemCount: Table.ItemCount,
            TableSizeBytes: Table.TableSizeBytes,
            GSICount: length(Table.GlobalSecondaryIndexes || `[]`),
            GSINames: Table.GlobalSecondaryIndexes[].IndexName
        }' \
        --output json 2>/dev/null)
    
    echo "$details"
}

# ─────────────────────────────────────────────────────────────────────────────
# update_dynamodb_configmap()
# ADOT Collector가 참조하는 ConfigMap을 업데이트합니다.
# CloudWatch Receiver의 dimension_regex를 동적으로 구성합니다.
# ─────────────────────────────────────────────────────────────────────────────
update_dynamodb_configmap() {
    local tables=("$@")
    
    if [[ ${#tables[@]} -eq 0 ]]; then
        log_warn "[DynamoDB] 모니터링 대상 테이블이 없습니다. ConfigMap 업데이트 스킵."
        return 0
    fi
    
    # 테이블 이름을 regex 패턴으로 변환
    # 예: table1|table2|table3
    local table_regex
    table_regex=$(IFS='|'; echo "${tables[*]}")
    
    # GSI 정보도 수집
    local gsi_list=""
    for table in "${tables[@]}"; do
        local details
        details=$(get_dynamodb_table_details "$table")
        local gsi_names
        gsi_names=$(echo "$details" | jq -r '.GSINames[]? // empty' 2>/dev/null)
        if [[ -n "$gsi_names" ]]; then
            gsi_list="${gsi_list}${gsi_names}\n"
        fi
    done
    
    local gsi_regex=".*"  # 기본: 모든 GSI
    if [[ -n "$gsi_list" ]]; then
        gsi_regex=$(echo -e "$gsi_list" | sort -u | tr '\n' '|' | sed 's/|$//')
    fi
    
    # ConfigMap 생성/업데이트
    cat <<EOF | kubectl apply -f - 2>/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${DYNAMODB_CONFIGMAP_NAME}
  namespace: ${TARGET_NAMESPACE}
  labels:
    app: adot-collector
    db-discovery/managed-by: auto-discovery
    db-discovery/component: dynamodb
  annotations:
    db-discovery/last-updated: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    db-discovery/table-count: "${#tables[@]}"
data:
  # ADOT CloudWatch Receiver에서 참조하는 테이블 목록
  table-regex: "${table_regex}"
  gsi-regex: "${gsi_regex}"
  table-count: "${#tables[@]}"
  # 개별 테이블 목록 (디버깅/참조용)
  tables.txt: |
$(for t in "${tables[@]}"; do echo "    $t"; done)
EOF
    
    if [[ $? -eq 0 ]]; then
        log_info "[DynamoDB] ConfigMap '${DYNAMODB_CONFIGMAP_NAME}' 업데이트 완료 (${#tables[@]}개 테이블)"
    else
        log_error "[DynamoDB] ConfigMap 업데이트 실패"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# reconcile_dynamodb()
# 현재 ConfigMap vs AWS 실제 상태를 비교하고 필요시 업데이트합니다.
# ─────────────────────────────────────────────────────────────────────────────
reconcile_dynamodb() {
    log_info "[DynamoDB] Reconciliation 시작..."
    
    # 1. 현재 AWS의 DynamoDB 테이블 목록
    local discovered_tables
    mapfile -t discovered_tables < <(discover_dynamodb)
    
    # 2. 현재 ConfigMap의 테이블 목록
    local current_tables
    current_tables=$(kubectl get configmap "${DYNAMODB_CONFIGMAP_NAME}" \
        -n "${TARGET_NAMESPACE}" \
        -o jsonpath='{.data.table-regex}' 2>/dev/null)
    
    # 3. 새로 발견된 테이블을 regex로 변환하여 비교
    local new_regex
    new_regex=$(IFS='|'; echo "${discovered_tables[*]}")
    
    if [[ "$current_tables" == "$new_regex" ]]; then
        log_info "[DynamoDB] 변경 없음. ConfigMap이 최신 상태입니다."
        return 0
    fi
    
    # 4. 변경 감지 → ConfigMap 업데이트
    log_info "[DynamoDB] 변경 감지! ConfigMap 업데이트 중..."
    log_info "[DynamoDB]   이전: ${current_tables:-'(없음)'}"
    log_info "[DynamoDB]   현재: ${new_regex}"
    
    update_dynamodb_configmap "${discovered_tables[@]}"
    
    # 5. ADOT Collector 재시작 (ConfigMap 변경 반영)
    # 방법 1: Rollout restart (무중단)
    log_info "[DynamoDB] ADOT Collector 롤링 재시작..."
    kubectl rollout restart statefulset/adot-collector \
        -n "${TARGET_NAMESPACE}" 2>/dev/null
    
    # 방법 2: Pod annotation 업데이트 (더 빠른 방법)
    # kubectl patch statefulset adot-collector -n ${TARGET_NAMESPACE} \
    #     -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"dynamodb-config-hash\":\"$(echo $new_regex | md5sum | cut -d' ' -f1)\"}}}}}"
    
    log_info "[DynamoDB] Reconciliation 완료."
}

# ─────────────────────────────────────────────────────────────────────────────
# 메인 실행 (CronJob에서 호출 시)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # 로깅 함수 (단독 실행 시)
    log_info()  { echo "[$(date -u +%H:%M:%S)] [INFO]  $*"; }
    log_warn()  { echo "[$(date -u +%H:%M:%S)] [WARN]  $*"; }
    log_error() { echo "[$(date -u +%H:%M:%S)] [ERROR] $*" >&2; }
    log_debug() { [[ "${DEBUG:-false}" == "true" ]] && echo "[$(date -u +%H:%M:%S)] [DEBUG] $*"; }
    
    echo "========================================"
    echo " DynamoDB 자동 디스커버리"
    echo " $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "========================================"
    
    reconcile_dynamodb
    
    echo "========================================"
    echo " 완료"
    echo "========================================"
fi
