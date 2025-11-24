# ADOT Collector Aurora Discovery Migration Guide

## Overview

This guide explains how to migrate from static exporter configurations to Aurora Discovery Service Discovery in the ADOT Collector.

## Migration Strategy

The migration follows a phased approach to ensure zero downtime:

### Phase 1: Deploy Aurora Discovery (Parallel Operation)
1. Enable Aurora Discovery in your values.yaml:
   ```yaml
   aurora-discovery:
     enabled: true
   ```
2. Deploy the updated Helm chart
3. Aurora Discovery will start creating dynamic exporters alongside existing static ones
4. Both static and dynamic exporters will be scraped simultaneously

### Phase 2: Enable Service Discovery in ADOT Collector
1. Update your values.yaml to enable Aurora Discovery in ADOT Collector:
   ```yaml
   adot-collector:
     auroraDiscovery:
       enabled: true
   ```
2. Deploy the updated configuration
3. ADOT Collector will now use Service Discovery for Aurora exporters
4. Static configurations are automatically disabled when `auroraDiscovery.enabled: true`

### Phase 3: Cleanup (Optional)
1. Remove any manual static exporter deployments that are now managed by Aurora Discovery
2. Verify metrics are being collected from dynamically discovered exporters

## Configuration Changes

### Before (Static Configuration)
```yaml
# MySQL Exporters - Static configuration
- job_name: mysql-exporters
  static_configs:
  - targets:
    - mysql-cluster.observability.svc.cluster.local:9104
```

### After (Service Discovery)
```yaml
# Aurora MySQL Exporters - Service Discovery
- job_name: aurora-mysql-exporters
  kubernetes_sd_configs:
  - role: service
    namespaces:
      names: [observability]
  relabel_configs:
  - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_name]
    action: keep
    regex: aurora-exporter
  - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_component]
    action: keep
    regex: mysql-exporter
```

## Backward Compatibility

The migration maintains full backward compatibility:

- **Static exporters continue to work**: Existing static exporter configurations remain active when Aurora Discovery is disabled
- **Gradual migration**: You can enable Aurora Discovery without immediately switching ADOT Collector to Service Discovery
- **Rollback capability**: Set `auroraDiscovery.enabled: false` to revert to static configurations

## Verification Steps

### 1. Verify Aurora Discovery is Working
```bash
# Check Aurora Discovery CronJob
kubectl get cronjobs -n observability

# Check Aurora Discovery logs
kubectl logs -n observability job/aurora-discovery-<timestamp>

# Verify dynamic exporters are created
kubectl get deployments -n observability -l app.kubernetes.io/name=aurora-exporter
kubectl get services -n observability -l app.kubernetes.io/name=aurora-exporter
```

### 2. Verify ADOT Collector Service Discovery
```bash
# Check ADOT Collector configuration
kubectl get configmap -n observability adot-collector-config -o yaml

# Check ADOT Collector logs for service discovery
kubectl logs -n observability deployment/adot-collector | grep "aurora-"

# Verify targets are discovered
kubectl port-forward -n observability svc/adot-collector 8888:8888
# Visit http://localhost:8888/debug/targets to see discovered targets
```

### 3. Verify Metrics Collection
```bash
# Check if Aurora metrics are being collected
# Query your Prometheus/AMP instance for aurora_* metrics
```

## Troubleshooting

### Aurora Discovery Issues
- **CronJob not running**: Check RBAC permissions and ServiceAccount configuration
- **No exporters created**: Verify Aurora clusters have Secrets Manager ARNs configured
- **AWS permissions**: Ensure IRSA is configured with RDS and Secrets Manager permissions

### Service Discovery Issues
- **Targets not discovered**: Check service labels match the relabel_configs
- **Wrong ports**: Verify prometheus.io/port annotations on services
- **Namespace issues**: Ensure ADOT Collector has permissions to discover services

### Rollback Procedure
If issues occur, you can quickly rollback:

1. Set `auroraDiscovery.enabled: false` in values.yaml
2. Deploy the Helm chart
3. Static configurations will be restored
4. Manually clean up any Aurora Discovery resources if needed

## Support

For issues during migration:
1. Check the troubleshooting section above
2. Review Aurora Discovery and ADOT Collector logs
3. Verify all RBAC permissions are correctly configured
4. Ensure AWS IAM roles have required permissions