#!/bin/bash

# Aurora Discovery Helm Template Unit Tests
# This script runs unit tests for the Aurora Discovery Helm templates

set -e

CHART_DIR="$(dirname "$0")/.."
TESTS_DIR="$(dirname "$0")"

echo "Running Aurora Discovery Helm template unit tests..."
echo "Chart directory: $CHART_DIR"
echo "Tests directory: $TESTS_DIR"

# Check if helm unittest plugin is installed
if ! helm plugin list | grep -q unittest; then
    echo "Installing helm unittest plugin..."
    helm plugin install https://github.com/helm-unittest/helm-unittest
fi

# Run the tests
echo "Running CronJob template tests..."
helm unittest -f "$TESTS_DIR/cronjob_test.yaml" "$CHART_DIR"

echo "Running RBAC template tests..."
helm unittest -f "$TESTS_DIR/rbac_test.yaml" "$CHART_DIR"

echo "Running ServiceAccount template tests..."
helm unittest -f "$TESTS_DIR/serviceaccount_test.yaml" "$CHART_DIR"

# Run all tests together
echo "Running all template tests..."
helm unittest "$CHART_DIR"

echo "All tests completed successfully!"