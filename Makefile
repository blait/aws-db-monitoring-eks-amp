###############################################################################
# AWS 데이터베이스 통합 모니터링 - Makefile
# 사용법: make [target]
#
# 주요 타겟:
#   make deploy     - 전체 인프라 + 모니터링 스택 배포
#   make status     - 현재 배포 상태 확인
#   make dashboard  - Grafana 대시보드 URL 출력
#   make cleanup    - 모든 리소스 삭제
###############################################################################

.PHONY: deploy cleanup status dashboard pods logs help prereq dry-run \
        deploy-infra deploy-eks deploy-monitoring redeploy-monitoring

# 기본 설정
SHELL := /bin/bash
WORKSHOP_NAME ?= integrated-db-monitoring
AWS_REGION ?= $(shell aws configure get region 2>/dev/null || echo 'ap-northeast-2')

# 색상
GREEN  := \033[0;32m
YELLOW := \033[1;33m
CYAN   := \033[0;36m
NC     := \033[0m

#==============================================================================
# 기본 타겟 (help)
#==============================================================================
.DEFAULT_GOAL := help

help: ## 사용 가능한 명령어 목록
	@echo ""
	@echo -e "$(CYAN)AWS 데이터베이스 통합 모니터링 - 명령어$(NC)"
	@echo -e "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-20s$(NC) %s\n", $$1, $$2}'
	@echo ""
	@echo -e "  $(YELLOW)설정:$(NC)"
	@echo -e "    WORKSHOP_NAME = $(WORKSHOP_NAME)"
	@echo -e "    AWS_REGION    = $(AWS_REGION)"
	@echo ""
	@echo -e "  $(YELLOW)예시:$(NC)"
	@echo "    make deploy"
	@echo "    make deploy AWS_REGION=us-west-2"
	@echo "    make status"
	@echo ""

#==============================================================================
# 주요 타겟
#==============================================================================
deploy: prereq ## 전체 인프라 + 모니터링 스택 배포 (원클릭)
	@echo -e "$(GREEN)▶ 전체 배포를 시작합니다...$(NC)"
	@chmod +x deploy-all.sh
	@./deploy-all.sh --region $(AWS_REGION) --name $(WORKSHOP_NAME)

deploy-fast: prereq ## 인프라 건너뛰고 모니터링만 재배포
	@echo -e "$(GREEN)▶ 모니터링 스택만 재배포합니다...$(NC)"
	@chmod +x deploy-all.sh
	@./deploy-all.sh --region $(AWS_REGION) --name $(WORKSHOP_NAME) --skip-infra

cleanup: ## 모든 리소스 삭제
	@echo -e "$(YELLOW)▶ 전체 리소스를 삭제합니다...$(NC)"
	@chmod +x cleanup.sh
	@./cleanup.sh

cleanup-force: ## 확인 없이 즉시 삭제
	@chmod +x cleanup.sh
	@./cleanup.sh --force

status: ## 현재 배포 상태 확인
	@echo -e "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo -e "$(CYAN) 배포 상태 확인$(NC)"
	@echo -e "$(CYAN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo ""
	@echo -e "$(GREEN)[CloudFormation 스택]$(NC)"
	@aws cloudformation list-stacks \
		--stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
		--query "StackSummaries[?contains(StackName,'$(WORKSHOP_NAME)')].{Name:StackName,Status:StackStatus,Created:CreationTime}" \
		--output table --region $(AWS_REGION) 2>/dev/null || echo "  CloudFormation 스택 없음"
	@echo ""
	@echo -e "$(GREEN)[EKS 클러스터]$(NC)"
	@aws eks describe-cluster --name $(WORKSHOP_NAME)-eks --region $(AWS_REGION) \
		--query 'cluster.{Name:name,Status:status,Version:version,Endpoint:endpoint}' \
		--output table 2>/dev/null || echo "  EKS 클러스터 없음"
	@echo ""
	@echo -e "$(GREEN)[모니터링 Pod]$(NC)"
	@kubectl get pods -n observability -o wide 2>/dev/null || echo "  Pod 없음 (클러스터 미연결)"
	@echo ""
	@echo -e "$(GREEN)[AMP 워크스페이스]$(NC)"
	@aws amp list-workspaces --alias $(WORKSHOP_NAME)-amp --region $(AWS_REGION) \
		--query 'workspaces[0].{Id:workspaceId,Status:status.statusCode,Alias:alias}' \
		--output table 2>/dev/null || echo "  AMP 워크스페이스 없음"
	@echo ""
	@echo -e "$(GREEN)[AMG 워크스페이스]$(NC)"
	@aws grafana list-workspaces --region $(AWS_REGION) \
		--query "workspaces[?name=='$(WORKSHOP_NAME)-grafana'].{Id:id,Status:status,Endpoint:endpoint}" \
		--output table 2>/dev/null || echo "  AMG 워크스페이스 없음"

dashboard: ## Grafana 대시보드 URL 출력
	@echo ""
	@if [ -f .deploy-state.env ]; then \
		AMG_URL=$$(grep AMG_ENDPOINT .deploy-state.env | cut -d= -f2); \
		echo -e "$(GREEN)🔗 Grafana 대시보드:$(NC) https://$$AMG_URL"; \
	else \
		AMG_URL=$$(aws grafana list-workspaces --region $(AWS_REGION) \
			--query "workspaces[?name=='$(WORKSHOP_NAME)-grafana'].endpoint" \
			--output text 2>/dev/null); \
		if [ -n "$$AMG_URL" ] && [ "$$AMG_URL" != "None" ]; then \
			echo -e "$(GREEN)🔗 Grafana 대시보드:$(NC) https://$$AMG_URL"; \
		else \
			echo -e "$(YELLOW)AMG 워크스페이스를 찾을 수 없습니다.$(NC)"; \
		fi; \
	fi
	@echo ""

pods: ## 모니터링 Pod 상태 확인
	@kubectl get pods -n observability -o wide

logs: ## ADOT Collector 로그 확인 (최근 50줄)
	@kubectl logs -n observability -l app.kubernetes.io/name=opentelemetry-collector --tail=50

logs-mysql: ## MySQL Exporter 로그
	@kubectl logs -n observability -l app=mysql-exporter --tail=30

logs-pg: ## PostgreSQL Exporter 로그
	@kubectl logs -n observability -l app=postgres-exporter --tail=30

logs-redis: ## Redis Exporter 로그
	@kubectl logs -n observability -l app=redis-exporter --tail=30

logs-mssql: ## MS SQL Exporter 로그
	@kubectl logs -n observability -l app=mssql-exporter --tail=30

#==============================================================================
# 개별 단계 타겟
#==============================================================================
deploy-infra: ## 인프라만 배포 (VPC + DB + Cache)
	@echo -e "$(GREEN)▶ 인프라 배포 (VPC + DB + Cache)$(NC)"
	@chmod +x deploy-all.sh
	@./deploy-all.sh --region $(AWS_REGION) --name $(WORKSHOP_NAME) 2>&1 | \
		sed -n '/Step 1/,/Step 3/p'

deploy-eks: ## EKS 클러스터만 배포
	@echo -e "$(GREEN)▶ EKS 클러스터 배포$(NC)"
	@eksctl create cluster -f eks-cluster-resolved.yaml 2>&1 || \
		echo "eks-cluster-resolved.yaml이 없습니다. 먼저 envsubst를 실행하세요."

redeploy-monitoring: ## 모니터링 스택만 재배포 (Helm)
	@echo -e "$(GREEN)▶ 모니터링 스택 재배포$(NC)"
	@echo "기존 릴리스 삭제..."
	@helm uninstall adot-collector mysql-exporter postgres-exporter redis-exporter mssql-exporter \
		-n observability 2>/dev/null || true
	@echo "재배포..."
	@./deploy-all.sh --skip-infra --region $(AWS_REGION) --name $(WORKSHOP_NAME)

#==============================================================================
# 유틸리티 타겟
#==============================================================================
prereq: ## 사전 조건 확인
	@echo -e "$(CYAN)사전 조건 확인...$(NC)"
	@which aws >/dev/null 2>&1 || (echo "❌ AWS CLI 미설치" && exit 1)
	@which kubectl >/dev/null 2>&1 || (echo "❌ kubectl 미설치" && exit 1)
	@which helm >/dev/null 2>&1 || (echo "❌ Helm 미설치" && exit 1)
	@which eksctl >/dev/null 2>&1 || (echo "❌ eksctl 미설치" && exit 1)
	@aws sts get-caller-identity >/dev/null 2>&1 || (echo "❌ AWS 인증 실패" && exit 1)
	@echo -e "$(GREEN)✔ 모든 사전 조건 충족$(NC)"

dry-run: ## 배포 설정만 확인 (실제 배포 없음)
	@chmod +x deploy-all.sh
	@./deploy-all.sh --dry-run --region $(AWS_REGION) --name $(WORKSHOP_NAME)

port-forward-mysql: ## MySQL Exporter 메트릭 포트포워딩 (localhost:9104)
	@echo "MySQL Exporter: http://localhost:9104/metrics"
	@kubectl port-forward -n observability svc/mysql-exporter-prometheus-mysql-exporter 9104:9104

port-forward-pg: ## PostgreSQL Exporter 메트릭 포트포워딩 (localhost:9187)
	@echo "PostgreSQL Exporter: http://localhost:9187/metrics"
	@kubectl port-forward -n observability svc/postgres-exporter-prometheus-postgres-exporter 9187:9187

port-forward-redis: ## Redis Exporter 메트릭 포트포워딩 (localhost:9121)
	@echo "Redis Exporter: http://localhost:9121/metrics"
	@kubectl port-forward -n observability svc/redis-exporter-prometheus-redis-exporter 9121:9121

events: ## Kubernetes 이벤트 확인
	@kubectl get events -n observability --sort-by='.lastTimestamp' | tail -20

cost: ## 예상 비용 출력
	@echo ""
	@echo -e "$(YELLOW)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo -e "$(YELLOW) 💰 예상 비용 (서울 리전)$(NC)"
	@echo -e "$(YELLOW)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "  EKS 제어 플레인:     ~$$0.10/시간"
	@echo "  EKS 노드 (t3.med×2): ~$$0.10/시간"
	@echo "  Aurora MySQL (×3):   ~$$0.90/시간"
	@echo "  Aurora PG (×3):      ~$$0.90/시간"
	@echo "  RDS SQL Server:      ~$$0.50/시간"
	@echo "  ElastiCache:         ~$$0.07/시간"
	@echo "  AMP:                 ~$$0.10/시간"
	@echo "  AMG:                 ~$$0.09/시간"
	@echo "  ────────────────────────────────"
	@echo -e "  $(GREEN)합계:                 ~$$2.76/시간$(NC)"
	@echo -e "  $(YELLOW)24시간 방치 시:       ~$$66$(NC)"
	@echo ""
