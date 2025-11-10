# Aurora Discovery Helm Template Unit Tests

This directory contains unit tests for the Aurora Discovery Helm chart templates. The tests validate that the templates render correctly with various configuration values and ensure proper RBAC permissions and ServiceAccount configurations.

## Test Structure

### Test Files

- `cronjob_test.yaml` - Tests for the CronJob template
- `rbac_test.yaml` - Tests for RBAC (ClusterRole and ClusterRoleBinding) templates
- `serviceaccount_test.yaml` - Tests for ServiceAccount template
- `test-values.yaml` - Test value configurations for different scenarios
- `run-tests.sh` - Shell script to run all tests
- `Makefile` - Make targets for running tests

### Test Coverage

#### CronJob Template Tests (`cronjob_test.yaml`)

- **Default Values Rendering**: Validates CronJob renders with default configuration
- **Custom Values Rendering**: Tests with custom schedule, image, and resource settings
- **Environment Variables**: Ensures correct environment variable injection
- **Resource Limits**: Validates CPU and memory resource configuration
- **Security Context**: Tests security settings and non-root user configuration
- **Conditional Rendering**: Tests that CronJob is not rendered when disabled
- **Labels and Metadata**: Validates proper Kubernetes labels

#### RBAC Template Tests (`rbac_test.yaml`)

- **ClusterRole Permissions**: Validates all required Kubernetes API permissions
  - ConfigMap permissions for state management
  - Secret permissions for database credentials
  - Service permissions for exporter services
  - Deployment permissions for exporter deployments
  - Pod permissions for monitoring exporter status
- **ClusterRoleBinding**: Tests proper binding between ServiceAccount and ClusterRole
- **Custom Names**: Tests with custom ServiceAccount and namespace configurations
- **Conditional Rendering**: Tests that RBAC resources are not rendered when disabled
- **Labels and Metadata**: Validates proper Kubernetes labels

#### ServiceAccount Template Tests (`serviceaccount_test.yaml`)

- **Default Configuration**: Tests ServiceAccount with default settings
- **IRSA Annotations**: Validates IAM Roles for Service Accounts (IRSA) annotations
- **Multiple Annotations**: Tests handling of multiple custom annotations
- **Custom Names and Namespaces**: Tests with custom ServiceAccount names and namespaces
- **Global vs Local Values**: Tests precedence of global over local namespace values
- **Conditional Rendering**: Tests that ServiceAccount is not rendered when disabled
- **Annotation Handling**: Tests graceful handling of empty or null annotations

## Requirements Validation

The tests validate the following requirements from the specification:

### Requirement 6.1 - CronJob Configuration
- ✅ CronJob runs with 1-hour schedule
- ✅ Proper resource limits and requests
- ✅ Security context with non-root user
- ✅ Environment variable configuration

### Requirement 7.4 - RBAC and ServiceAccount
- ✅ ServiceAccount creation with IRSA annotations
- ✅ ClusterRole with required Kubernetes permissions
- ✅ ClusterRoleBinding connecting ServiceAccount to ClusterRole
- ✅ Proper namespace and naming configuration

## Running Tests

### Prerequisites

1. **Helm**: Ensure Helm is installed and available in your PATH
2. **helm unittest plugin**: The tests use the helm unittest plugin

### Installation

The helm unittest plugin will be automatically installed when running tests, or you can install it manually:

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest
```

### Running All Tests

```bash
# Using the shell script
./run-tests.sh

# Using Make
make test

# Using helm unittest directly
helm unittest ..
```

### Running Specific Test Suites

```bash
# CronJob tests only
make test-cronjob
helm unittest -f cronjob_test.yaml ..

# RBAC tests only
make test-rbac
helm unittest -f rbac_test.yaml ..

# ServiceAccount tests only
make test-serviceaccount
helm unittest -f serviceaccount_test.yaml ..
```

### Validating Templates

To validate template rendering without running tests:

```bash
make validate
helm template aurora-discovery .. --dry-run --debug
```

## Test Scenarios

The tests cover multiple scenarios defined in `test-values.yaml`:

1. **Default Configuration**: Standard values as defined in `values.yaml`
2. **Custom Configuration**: Modified schedule, image, resources, and AWS settings
3. **Disabled Features**: Tests when components are disabled
4. **Global Overrides**: Tests global value precedence over local values
5. **IRSA Configuration**: Tests various IRSA annotation scenarios

## Expected Output

Successful test runs should show output similar to:

```
### Chart [ aurora-discovery ] .

 PASS  test cronjob template	tests/cronjob_test.yaml
 PASS  test rbac template	tests/rbac_test.yaml
 PASS  test serviceaccount template	tests/serviceaccount_test.yaml

Charts:      1 passed, 0 failed, 1 total
Test Suites: 3 passed, 0 failed, 3 total
Tests:       XX passed, 0 failed, XX total
Snapshot:    0 passed, 0 failed, 0 total
Time:        XXXms
```

## Troubleshooting

### Common Issues

1. **Plugin Not Found**: Install the helm unittest plugin
2. **Template Errors**: Check template syntax and helper functions
3. **Value Errors**: Verify test values match template expectations
4. **Path Errors**: Ensure correct relative paths to chart directory

### Debug Mode

Run tests with verbose output:

```bash
helm unittest --debug ..
```

### Template Debugging

Render templates to see actual output:

```bash
helm template aurora-discovery .. --values test-values.yaml --debug
```

## Contributing

When adding new templates or modifying existing ones:

1. Add corresponding test cases to the appropriate test file
2. Test both positive and negative scenarios
3. Validate required permissions and configurations
4. Ensure tests cover all conditional rendering logic
5. Run all tests to ensure no regressions