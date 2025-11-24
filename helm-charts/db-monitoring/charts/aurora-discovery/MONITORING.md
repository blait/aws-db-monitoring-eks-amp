# Aurora Discovery Monitoring Guide

## Overview

Aurora Discovery exposes comprehensive metrics and alerting to monitor its operation and health. This guide covers the available metrics, alerting rules, and monitoring best practices.

## Metrics

Aurora Discovery exposes Prometheus metrics on port 8080 at the `/metrics` endpoint. The metrics are automatically scraped by Prometheus when the ServiceMonitor is enabled.

### Discovery Metrics

| Metric | Type | Description | Labels |
|--------|------|-------------|--------|
| `aurora_discovery_clusters_discovered_total` | Counter | Total number of Aurora clusters discovered | `engine_type` |
| `aurora_discovery_clusters_filtered_total` | Counter | Total number of Aurora clusters included in monitoring | `engine_type` |
| `aurora_discovery_clusters_skipped_total` | Counter | Total number of Aurora clusters skipped | `reason` |

### Resource Management Metrics

| Metric | Type | Description | Labels |
|--------|------|-------------|--------|
| `aurora_discovery_exporters_created_total` | Counter | Total number of exporters created | `engine_type` |
| `aurora_discovery_exporters_updated_total` | Counter | Total number of exporters updated | `engine_type` |
| `aurora_discovery_exporters_deleted_total` | Counter | Total number of exporters deleted | `engine_type` |

### Error Metrics

| Metric | Type | Description | Labels |
|--------|------|-------------|--------|
| `aurora_discovery_errors_total` | Counter | Total number of errors by type and component | `error_type`, `component` |

### AWS API Metrics

| Metric | Type | Description | Labels |
|--------|------|-------------|--------|
| `aurora_discovery_aws_api_calls_total` | Counter | Total number of AWS API calls | `service`, `operation`, `status` |
| `aurora_discovery_aws_api_duration_seconds` | Histogram | Duration of AWS API calls in seconds | `service`, `operation` |

### Kubernetes API Metrics

| Metric | Type | Description | Labels |
|--------|------|-------------|--------|
| `aurora_discovery_k8s_api_calls_total` | Counter | Total number of Kubernetes API calls | `resource_type`, `operation`, `status` |
| `aurora_discovery_k8s_api_duration_seconds` | Histogram | Duration of Kubernetes API calls in seconds | `resource_type`, `operation` |

### Execution Metrics

| Metric | Type | Description | Labels |
|--------|------|-------------|--------|
| `aurora_discovery_execution_duration_seconds` | Histogram | Duration of Aurora Discovery execution phases | `phase` |
| `aurora_discovery_last_execution_timestamp` | Gauge | Timestamp of the last execution | |
| `aurora_discovery_last_execution_success` | Gauge | Whether the last execution was successful (1) or failed (0) | |

### State Metrics

| Metric | Type | Description | Labels |
|--------|------|-------------|--------|
| `aurora_discovery_managed_clusters_total` | Gauge | Total number of clusters currently managed | `engine_type` |
| `aurora_discovery_state_configmap_size_bytes` | Gauge | Size of the state ConfigMap in bytes | |

## Alerting Rules

Aurora Discovery includes comprehensive alerting rules that cover various failure scenarios and performance issues.

### Critical Alerts

#### AuroraDiscoveryExporterCreationFailed
- **Severity**: Critical
- **Condition**: More than 3 exporter creation failures in 10 minutes
- **Impact**: New Aurora clusters are not being monitored
- **Action**: Check Kubernetes resources, RBAC permissions, and recent logs

### Warning Alerts

#### AuroraDiscoveryCronJobFailed
- **Severity**: Warning
- **Condition**: CronJob hasn't completed successfully in 2 hours OR last execution failed
- **Impact**: Cluster discovery is not running
- **Action**: Check CronJob status, AWS permissions, and connectivity

#### AuroraDiscoveryHighErrorRate
- **Severity**: Warning
- **Condition**: Error rate > 0.1 errors/sec for 5 minutes
- **Impact**: System is experiencing issues that may affect reliability
- **Action**: Check error breakdown by component and address specific issues

#### AuroraDiscoveryAWSAPIThrottling
- **Severity**: Warning
- **Condition**: AWS API throttling rate > 0.05 requests/sec for 2 minutes
- **Impact**: Delays in cluster discovery and management
- **Action**: Consider reducing discovery frequency or check AWS service limits

#### AuroraDiscoveryKubernetesAPIErrors
- **Severity**: Warning
- **Condition**: Kubernetes API error rate > 0.05 errors/sec for 3 minutes
- **Impact**: Resource management may be impaired
- **Action**: Check RBAC permissions, resource quotas, and cluster health

#### AuroraDiscoverySlowExecution
- **Severity**: Warning
- **Condition**: 95th percentile execution time > 30 minutes
- **Impact**: May cause CronJob timeouts and delayed discovery
- **Action**: Check cluster count, AWS API latency, and resource allocation

#### AuroraDiscoveryStateConfigMapLarge
- **Severity**: Warning
- **Condition**: State ConfigMap size > 1MB
- **Impact**: Performance degradation and potential etcd limits
- **Action**: Consider state cleanup or monitoring cluster growth

### Info Alerts

#### AuroraDiscoveryAWSAPIHighLatency
- **Severity**: Info
- **Condition**: 95th percentile AWS API latency > 10 seconds for 5 minutes
- **Impact**: Slower execution but not critical
- **Action**: Monitor AWS service status and network connectivity

#### AuroraDiscoveryNoManagedClusters
- **Severity**: Info
- **Condition**: No clusters being managed for 10 minutes (but execution successful)
- **Impact**: May be expected or indicate discovery issues
- **Action**: Verify Aurora clusters exist and have proper configuration

## Monitoring Dashboards

### Key Performance Indicators (KPIs)

1. **Discovery Success Rate**: Percentage of successful discovery cycles
2. **Cluster Coverage**: Number of Aurora clusters vs. managed exporters
3. **Error Rate**: Errors per minute across all components
4. **Execution Time**: Average and 95th percentile execution duration
5. **AWS API Health**: Success rate and latency of AWS API calls

### Recommended Dashboard Panels

#### Overview Panel
```promql
# Discovery success rate (last 24h)
rate(aurora_discovery_last_execution_success[24h])

# Managed clusters by engine type
aurora_discovery_managed_clusters_total

# Recent error rate
rate(aurora_discovery_errors_total[5m])
```

#### Discovery Performance Panel
```promql
# Execution duration by phase
histogram_quantile(0.95, rate(aurora_discovery_execution_duration_seconds_bucket[5m]))

# Clusters discovered vs filtered
rate(aurora_discovery_clusters_discovered_total[1h])
rate(aurora_discovery_clusters_filtered_total[1h])
```

#### AWS API Health Panel
```promql
# AWS API success rate
rate(aurora_discovery_aws_api_calls_total{status="success"}[5m]) / rate(aurora_discovery_aws_api_calls_total[5m])

# AWS API latency
histogram_quantile(0.95, rate(aurora_discovery_aws_api_duration_seconds_bucket[5m]))
```

#### Resource Management Panel
```promql
# Exporter operations
rate(aurora_discovery_exporters_created_total[1h])
rate(aurora_discovery_exporters_updated_total[1h])
rate(aurora_discovery_exporters_deleted_total[1h])

# Kubernetes API health
rate(aurora_discovery_k8s_api_calls_total{status="success"}[5m]) / rate(aurora_discovery_k8s_api_calls_total[5m])
```

## Troubleshooting with Metrics

### High Error Rate Investigation

1. **Identify error sources**:
```promql
rate(aurora_discovery_errors_total[5m]) by (component, error_type)
```

2. **Check AWS API issues**:
```promql
rate(aurora_discovery_aws_api_calls_total{status="error"}[5m]) by (service, operation)
```

3. **Check Kubernetes API issues**:
```promql
rate(aurora_discovery_k8s_api_calls_total{status="error"}[5m]) by (resource_type, operation)
```

### Performance Investigation

1. **Execution time breakdown**:
```promql
histogram_quantile(0.95, rate(aurora_discovery_execution_duration_seconds_bucket[5m])) by (phase)
```

2. **AWS API latency by service**:
```promql
histogram_quantile(0.95, rate(aurora_discovery_aws_api_duration_seconds_bucket[5m])) by (service)
```

3. **Resource operation latency**:
```promql
histogram_quantile(0.95, rate(aurora_discovery_k8s_api_duration_seconds_bucket[5m])) by (resource_type)
```

### Discovery Coverage Analysis

1. **Cluster discovery vs management**:
```promql
# Total discovered (rate over time)
rate(aurora_discovery_clusters_discovered_total[1h])

# Currently managed
aurora_discovery_managed_clusters_total

# Skip reasons
rate(aurora_discovery_clusters_skipped_total[1h]) by (reason)
```

## Configuration

### Enabling Metrics and Alerting

```yaml
# values.yaml
aurora-discovery:
  metrics:
    enabled: true
    port: 8080
    path: /metrics
  
  alerting:
    enabled: true
    runbookUrl: "https://your-runbook-url.com"
    
    # Customize thresholds
    highErrorRateThreshold: 0.1
    cronJobFailureThreshold: 7200
    slowExecutionThreshold: 1800
```

### Custom Alert Thresholds

You can customize alert thresholds based on your environment:

```yaml
alerting:
  # For environments with many clusters
  slowExecutionThreshold: 3600  # 1 hour instead of 30 minutes
  
  # For development environments
  cronJobFailureThreshold: 14400  # 4 hours instead of 2 hours
  highErrorRateThreshold: 0.5     # Higher tolerance for errors
  
  # For critical production environments
  cronJobFailureThreshold: 3600   # 1 hour instead of 2 hours
  highErrorRateThreshold: 0.05    # Lower tolerance for errors
```

### Integration with External Monitoring

#### Datadog Integration
```yaml
# Add Datadog annotations to metrics service
aurora-discovery:
  metrics:
    service:
      annotations:
        ad.datadoghq.com/service.check_names: '["prometheus"]'
        ad.datadoghq.com/service.init_configs: '[{}]'
        ad.datadoghq.com/service.instances: '[{"prometheus_url": "http://%%host%%:8080/metrics"}]'
```

#### New Relic Integration
```yaml
# Configure New Relic Prometheus integration
aurora-discovery:
  metrics:
    service:
      annotations:
        newrelic.io/scrape: "true"
        newrelic.io/port: "8080"
        newrelic.io/path: "/metrics"
```

## Best Practices

1. **Monitor Key Metrics**: Focus on execution success, error rates, and cluster coverage
2. **Set Appropriate Thresholds**: Adjust alert thresholds based on your environment and SLAs
3. **Regular Review**: Periodically review metrics to identify trends and optimization opportunities
4. **Correlation**: Correlate Aurora Discovery metrics with AWS service health and Kubernetes cluster metrics
5. **Documentation**: Keep runbooks updated with current troubleshooting procedures
6. **Testing**: Test alerting rules and runbooks regularly to ensure they work as expected

## Metrics Retention

Configure appropriate retention policies for Aurora Discovery metrics:

- **High-frequency metrics** (errors, API calls): 7-30 days
- **Execution metrics**: 90 days
- **State metrics**: 1 year for trend analysis
- **Alerting history**: 6 months for incident analysis