-- =============================================================================
-- Redis/Valkey 커스텀 메트릭 수집 Lua 스크립트
-- =============================================================================
-- redis_exporter의 --script 옵션으로 실행
-- 
-- 반환 형식: { metric_name, metric_help, metric_type, value, labels }
-- metric_type: "gauge" 또는 "counter"
--
-- ⚠️ ElastiCache 제한사항:
--   - DEBUG/CONFIG 명령 사용 불가
--   - CLUSTER 명령은 클러스터 모드에서만 가능
--   - MEMORY USAGE는 개별 키에만 사용 가능 (전체 스캔 시 부하 주의)
-- =============================================================================

local result = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Slow Log 분석
-- ─────────────────────────────────────────────────────────────────────────────
local slowlog = redis.call("SLOWLOG", "GET", "10")
local slowlog_length = redis.call("SLOWLOG", "LEN")

-- Slow Log 전체 길이
table.insert(result, {
    "redis_custom_slowlog_length",
    "현재 Slow Log에 저장된 엔트리 수",
    "gauge",
    slowlog_length
})

-- 최근 Slow Log 실행 시간 (마이크로초)
if #slowlog > 0 then
    local latest_duration = slowlog[1][3]  -- duration in microseconds
    table.insert(result, {
        "redis_custom_slowlog_latest_duration_us",
        "가장 최근 Slow Log 엔트리의 실행 시간 (마이크로초)",
        "gauge",
        latest_duration
    })
    
    -- 최근 10개 Slow Log의 최대 실행 시간
    local max_duration = 0
    for i, entry in ipairs(slowlog) do
        if entry[3] > max_duration then
            max_duration = entry[3]
        end
    end
    table.insert(result, {
        "redis_custom_slowlog_max_duration_us",
        "최근 10개 Slow Log 중 최대 실행 시간 (마이크로초)",
        "gauge",
        max_duration
    })
    
    -- Slow Log 명령어 분포
    local cmd_counts = {}
    for i, entry in ipairs(slowlog) do
        local cmd = entry[4][1]  -- command name
        if cmd then
            cmd = string.upper(cmd)
            cmd_counts[cmd] = (cmd_counts[cmd] or 0) + 1
        end
    end
    for cmd, count in pairs(cmd_counts) do
        table.insert(result, {
            "redis_custom_slowlog_commands",
            "Slow Log에서 명령어별 출현 수",
            "gauge",
            count,
            {command = cmd}
        })
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. 키 패턴별 수량 (SCAN 기반, 부하 제한)
-- ─────────────────────────────────────────────────────────────────────────────
local patterns = {"session:*", "cache:*", "queue:*", "lock:*", "rate_limit:*"}
local max_scan_count = 1000  -- SCAN 한 번에 반환할 최대 수 (부하 제한)

for _, pattern in ipairs(patterns) do
    local cursor = "0"
    local count = 0
    local iterations = 0
    local max_iterations = 10  -- 최대 10회 반복 (부하 방지)
    
    repeat
        local scan_result = redis.call("SCAN", cursor, "MATCH", pattern, "COUNT", max_scan_count)
        cursor = scan_result[1]
        count = count + #scan_result[2]
        iterations = iterations + 1
    until cursor == "0" or iterations >= max_iterations
    
    -- 패턴 이름에서 라벨 생성 (: 이전 부분)
    local label = string.gsub(pattern, ":.*", "")
    
    table.insert(result, {
        "redis_custom_key_count_by_pattern",
        "키 패턴별 키 수 (SCAN 기반 추정)",
        "gauge",
        count,
        {pattern = label}
    })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Keyspace TTL 분석
-- 키 중 TTL이 설정된 비율 (만료 정책 확인)
-- ─────────────────────────────────────────────────────────────────────────────
local info_keyspace = redis.call("INFO", "keyspace")
-- 파싱: db0:keys=123,expires=45,avg_ttl=6789
for db, keys, expires in string.gmatch(info_keyspace, "db(%d+):keys=(%d+),expires=(%d+)") do
    local total_keys = tonumber(keys)
    local total_expires = tonumber(expires)
    local ratio = 0
    if total_keys > 0 then
        ratio = total_expires / total_keys
    end
    table.insert(result, {
        "redis_custom_keyspace_expires_ratio",
        "TTL이 설정된 키의 비율 (0~1)",
        "gauge",
        ratio,
        {db = "db" .. db}
    })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. 클라이언트 연결 분석
-- ─────────────────────────────────────────────────────────────────────────────
local client_list = redis.call("CLIENT", "LIST")
local client_counts = {idle_long = 0, blocked = 0, total = 0}

for line in string.gmatch(client_list, "[^\n]+") do
    client_counts.total = client_counts.total + 1
    
    -- idle > 300초인 클라이언트
    local idle = string.match(line, "idle=(%d+)")
    if idle and tonumber(idle) > 300 then
        client_counts.idle_long = client_counts.idle_long + 1
    end
    
    -- 블로킹 중인 클라이언트
    local flags = string.match(line, "flags=(%S+)")
    if flags and string.find(flags, "b") then
        client_counts.blocked = client_counts.blocked + 1
    end
end

table.insert(result, {
    "redis_custom_clients_idle_long",
    "5분 이상 유휴 상태인 클라이언트 수",
    "gauge",
    client_counts.idle_long
})

table.insert(result, {
    "redis_custom_clients_blocked",
    "블로킹 명령 대기 중인 클라이언트 수",
    "gauge",
    client_counts.blocked
})

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Memory Fragmentation 상세
-- ─────────────────────────────────────────────────────────────────────────────
local info_memory = redis.call("INFO", "memory")

local mem_fragmentation = string.match(info_memory, "mem_fragmentation_ratio:([%d%.]+)")
local mem_allocator_frag = string.match(info_memory, "allocator_frag_ratio:([%d%.]+)")

if mem_fragmentation then
    table.insert(result, {
        "redis_custom_memory_fragmentation_ratio",
        "메모리 단편화 비율 (1.0 이상이면 단편화, 1.0 미만이면 스왑 가능성)",
        "gauge",
        tonumber(mem_fragmentation)
    })
end

if mem_allocator_frag then
    table.insert(result, {
        "redis_custom_allocator_frag_ratio",
        "Allocator 내부 단편화 비율",
        "gauge",
        tonumber(mem_allocator_frag)
    })
end

-- ─────────────────────────────────────────────────────────────────────────────
-- 결과 반환
-- ─────────────────────────────────────────────────────────────────────────────
return result
