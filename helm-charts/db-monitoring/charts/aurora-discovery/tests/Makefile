# Makefile for Aurora Discovery Helm Template Tests

.PHONY: test test-cronjob test-rbac test-serviceaccount install-unittest clean help

CHART_DIR := ..
TESTS_DIR := .

# Default target
help:
	@echo "Available targets:"
	@echo "  test              - Run all template tests"
	@echo "  test-cronjob      - Run CronJob template tests only"
	@echo "  test-rbac         - Run RBAC template tests only"
	@echo "  test-serviceaccount - Run ServiceAccount template tests only"
	@echo "  install-unittest  - Install helm unittest plugin"
	@echo "  clean             - Clean test artifacts"
	@echo "  help              - Show this help message"

# Install helm unittest plugin if not already installed
install-unittest:
	@if ! helm plugin list | grep -q unittest; then \
		echo "Installing helm unittest plugin..."; \
		helm plugin install https://github.com/helm-unittest/helm-unittest; \
	else \
		echo "helm unittest plugin already installed"; \
	fi

# Run all tests
test: install-unittest
	@echo "Running all Aurora Discovery Helm template tests..."
	helm unittest $(CHART_DIR)

# Run CronJob template tests only
test-cronjob: install-unittest
	@echo "Running CronJob template tests..."
	helm unittest -f $(TESTS_DIR)/cronjob_test.yaml $(CHART_DIR)

# Run RBAC template tests only
test-rbac: install-unittest
	@echo "Running RBAC template tests..."
	helm unittest -f $(TESTS_DIR)/rbac_test.yaml $(CHART_DIR)

# Run ServiceAccount template tests only
test-serviceaccount: install-unittest
	@echo "Running ServiceAccount template tests..."
	helm unittest -f $(TESTS_DIR)/serviceaccount_test.yaml $(CHART_DIR)

# Clean test artifacts
clean:
	@echo "Cleaning test artifacts..."
	@rm -f *.log *.tmp

# Validate templates without running tests
validate:
	@echo "Validating Helm templates..."
	helm template aurora-discovery $(CHART_DIR) --dry-run --debug