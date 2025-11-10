# Aurora Discovery Troubleshooting Guide

## Common Issues and Solutions

### 1. CronJob Not Running

#### Symptoms
- CronJob shows as created but no jobs are executed
- `kubectl get cronjobs` shows `LAST SCHEDULE` as `<none>`

#### Diagnosis
```bash
# Check CronJob status
kubectl describe cronjob aurora-discovery -n observability

# Check CronJob events
kubectl get events -n observability --field-selector involvedObject.name=aurora-discovery
```

#### Common Causes and Solutions

**Invalid Cron Schedule**
```bash
# Check if schedule is valid
kubectl get cronjob aurora-discovery -n observability -o jsonpath='{.spec.schedule}'

# Fix: Update with valid cron expression
helm upgrade db-monitoring helm-charts/db-monitoring \
    --set aurora-discovery.schedule="0 * * * *" \
    --namespace observability
```

**Suspended CronJob**
```bash
# Check if CronJob is suspended
kubectl get cronjob aurora-discovery -n observability -o jsonpath='{.spec.suspend}'

# Fix: Unsuspend the CronJob
kubectl patch cronjob aurora-discovery -n observability -p '{"spec":{"suspend":false}}'
```

### 2. Job Failures

#### Symptoms
- Jobs are created but fail to complete
- Pod status shows `Error` or `CrashLoopBackOff`

#### Diagnosis
```bash
# List recent jobs
kubectl get jobs -n observability -l app.kubernetes.io/name=aurora-discovery --sort-by=.metadata.creationTimestamp

# Get latest job logs
LATEST_JOB=$(kubectl get jobs -n observability -l app.kubernetes.io/name=aurora-discovery --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl logs job/$LATEST_JOB -n observability

# Check pod events
kubectl describe job $LATEST_JOB -n observability
```

#### Common Causes and Solutions

**AWS Permission Issues**
```bash
# Error: "AccessDenied" or "UnauthorizedOperation"
# Check IAM role and permissions

# Verify service account annotations
kubectl get serviceaccount aurora-discovery -n observability -o yaml

# Test AWS permissions manually
kubectl run aws-cli --rm -it --image=amazon/aws-cli:latest --restart=Never -- \
    aws rds describe-db-clusters --region us-east-1
```

**Solution**: Update IAM role with required permissions (see DEPLOYMENT.md)

**Image Pull Issues**
```bash
# Error: "ImagePullBackOff" or "ErrImagePull"
# Check image repository and tag

kubectl describe pod -n observability -l job-name=$LATEST_JOB
```

**Solution**: Verify image exists and update image configuration:
```yaml
aurora-discovery:
  image:
    repository: your-registry/aurora-discovery
    tag: "1.0.0"
```

**Resource Constraints**
```bash
# Error: "OutOfMemory" or "OutOfCpu"
# Check resource usage

kubectl top pod -n observability -l job-name=$LATEST_JOB
```

**Solution**: Increase resource limits:
```yaml
aurora-discovery:
  resources:
    limits:
      cpu: 1000m
      memory: 1Gi
```

### 3. AWS API Issues

#### Symptoms
- Jobs complete but no clusters are discovered
- Logs show AWS API errors

#### Common AWS Errors

**Rate Limiting**
```
Error: Throttling: Rate exceeded
```

**Solution**: Implement exponential backoff (already included in code) or reduce discovery frequency:
```yaml
aurora-discovery:
  schedule: "0 */2 * * *"  # Every 2 hours instead of hourly
```

**Invalid Region**
```
Error: InvalidParameterValue: Invalid region
```

**Solution**: Verify AWS region configuration:
```yaml
aurora-discovery:
  aws:
    region: us-east-1  # Correct region
```

**Secrets Manager Access**
```
Error: AccessDenied: User is not authorized to perform: secretsmanager:GetSecretValue
```

**Solution**: Add Secrets Manager permissions to IAM role:
```json
{
    "Effect": "Allow",
    "Action": [
        "secretsmanager:GetSecretValue"
    ],
    "Resource": "arn:aws:secretsmanager:*:*:secret:*"
}
```

### 4. Kubernetes Resource Issues

#### Symptoms
- Exporters are not being created
- ConfigMap updates fail

#### Diagnosis
```bash
# Check RBAC permissions
kubectl auth can-i create deployments --as=system:serviceaccount:observability:aurora-discovery -n observability
kubectl auth can-i create services --as=system:serviceaccount:observability:aurora-discovery -n observability
kubectl auth can-i create secrets --as=system:serviceaccount:observability:aurora-discovery -n observability
kubectl auth can-i create configmaps --as=system:serviceaccount:observability:aurora-discovery -n observability

# Check existing resources
kubectl get deployments,services,secrets -n observability -l app.kubernetes.io/name=aurora-exporter
```

#### Common Causes and Solutions

**RBAC Issues**
```bash
# Check ClusterRole and ClusterRoleBinding
kubectl get clusterrole aurora-discovery
kubectl get clusterrolebinding aurora-discovery

# Verify service account binding
kubectl describe clusterrolebinding aurora-discovery
```

**Solution**: Ensure proper RBAC is configured (automatically handled by Helm chart)

**Resource Quotas**
```bash
# Check resource quotas
kubectl describe resourcequota -n observability

# Check if quota is exceeded
kubectl get events -n observability --field-selector reason=FailedCreate
```

**Solution**: Increase resource quotas or optimize resource requests

**Namespace Issues**
```bash
# Verify namespace exists
kubectl get namespace observability

# Check if resources are in correct namespace
kubectl get all -n observability -l app.kubernetes.io/name=aurora-discovery
```

### 5. State Management Issues

#### Symptoms
- Duplicate exporters being created
- Exporters not being cleaned up
- ConfigMap corruption errors

#### Diagnosis
```bash
# Check ConfigMap content
kubectl get configmap aurora-discovery-state -n observability -o yaml

# Validate JSON structure
kubectl get configmap aurora-discovery-state -n observability -o jsonpath='{.data.clusters\.json}' | jq .
```

#### Solutions

**ConfigMap Corruption**
```bash
# Delete corrupted ConfigMap (will be recreated)
kubectl delete configmap aurora-discovery-state -n observability

# Trigger manual job to recreate state
kubectl create job aurora-discovery-manual --from=cronjob/aurora-discovery -n observability
```

**Concurrent Access Issues**
```bash
# Check for multiple running jobs
kubectl get jobs -n observability -l app.kubernetes.io/name=aurora-discovery --field-selector status.active=1

# Ensure concurrency policy is set
kubectl get cronjob aurora-discovery -n observability -o jsonpath='{.spec.concurrencyPolicy}'
```

**Solution**: Verify concurrency policy is set to `Forbid`:
```yaml
aurora-discovery:
  concurrencyPolicy: Forbid
```

### 6. Service Discovery Issues

#### Symptoms
- ADOT Collector not discovering exporters
- Metrics not being scraped

#### Diagnosis
```bash
# Check exporter services have correct labels
kubectl get services -n observability -l app.kubernetes.io/name=aurora-exporter --show-labels

# Check ADOT Collector configuration
kubectl get configmap adot-collector-config -n observability -o yaml

# Check ADOT Collector logs
kubectl logs -n observability deployment/adot-collector
```

#### Solutions

**Missing Service Labels**
```bash
# Check if services have required labels
kubectl get service -n observability -l app.kubernetes.io/name=aurora-exporter -o yaml

# Required labels should include:
# - app.kubernetes.io/name: aurora-exporter
# - app.kubernetes.io/component: mysql-exporter or postgresql-exporter
# - prometheus.io/scrape: "true"
```

**ADOT Configuration Issues**
```bash
# Verify Service Discovery configuration in ADOT ConfigMap
kubectl get configmap adot-collector-config -n observability -o jsonpath='{.data.config\.yaml}' | grep -A 20 kubernetes_sd_configs
```

### 7. Performance Issues

#### Symptoms
- Jobs taking too long to complete
- High memory usage
- AWS API throttling

#### Diagnosis
```bash
# Check job execution time
kubectl get jobs -n observability -l app.kubernetes.io/name=aurora-discovery -o custom-columns=NAME:.metadata.name,DURATION:.status.completionTime

# Monitor resource usage
kubectl top pod -n observability -l app.kubernetes.io/name=aurora-discovery

# Check for AWS throttling in logs
kubectl logs -n observability job/$LATEST_JOB | grep -i throttl
```

#### Solutions

**Optimize Resource Allocation**
```yaml
aurora-discovery:
  resources:
    requests:
      cpu: 500m      # Increase for faster processing
      memory: 512Mi  # Increase for large cluster counts
    limits:
      cpu: 1000m
      memory: 1Gi
```

**Reduce Discovery Frequency**
```yaml
aurora-discovery:
  schedule: "0 */2 * * *"  # Every 2 hours instead of hourly
```

**Implement Batching** (if needed for large numbers of clusters)
- Consider splitting discovery across multiple jobs
- Implement cluster filtering by tags or regions

## Debugging Commands

### Quick Health Check
```bash
#!/bin/bash
echo "=== Aurora Discovery Health Check ==="

echo "1. CronJob Status:"
kubectl get cronjob aurora-discovery -n observability

echo -e "\n2. Recent Jobs:"
kubectl get jobs -n observability -l app.kubernetes.io/name=aurora-discovery --sort-by=.metadata.creationTimestamp | tail -5

echo -e "\n3. Service Account:"
kubectl get serviceaccount aurora-discovery -n observability

echo -e "\n4. ConfigMap State:"
kubectl get configmap aurora-discovery-state -n observability

echo -e "\n5. Created Exporters:"
kubectl get deployments,services -n observability -l app.kubernetes.io/name=aurora-exporter

echo -e "\n6. Recent Events:"
kubectl get events -n observability --field-selector involvedObject.name=aurora-discovery | tail -10
```

### Detailed Diagnostics
```bash
#!/bin/bash
echo "=== Detailed Aurora Discovery Diagnostics ==="

# Get latest job
LATEST_JOB=$(kubectl get jobs -n observability -l app.kubernetes.io/name=aurora-discovery --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')

echo "Latest Job: $LATEST_JOB"

echo -e "\n=== Job Logs ==="
kubectl logs job/$LATEST_JOB -n observability

echo -e "\n=== Job Description ==="
kubectl describe job $LATEST_JOB -n observability

echo -e "\n=== ConfigMap Content ==="
kubectl get configmap aurora-discovery-state -n observability -o jsonpath='{.data.clusters\.json}' | jq .

echo -e "\n=== RBAC Check ==="
kubectl auth can-i create deployments --as=system:serviceaccount:observability:aurora-discovery -n observability
kubectl auth can-i create services --as=system:serviceaccount:observability:aurora-discovery -n observability
kubectl auth can-i create secrets --as=system:serviceaccount:observability:aurora-discovery -n observability
kubectl auth can-i update configmaps --as=system:serviceaccount:observability:aurora-discovery -n observability
```

## Getting Help

### Log Analysis
When reporting issues, include:

1. **CronJob and Job status**:
```bash
kubectl get cronjob,jobs -n observability -l app.kubernetes.io/name=aurora-discovery
```

2. **Complete logs from latest job**:
```bash
kubectl logs job/$LATEST_JOB -n observability > aurora-discovery-logs.txt
```

3. **Configuration**:
```bash
helm get values db-monitoring -n observability > current-values.yaml
```

4. **Resource status**:
```bash
kubectl get all -n observability -l app.kubernetes.io/name=aurora-discovery -o yaml > aurora-discovery-resources.yaml
```

### Support Checklist

Before seeking support, verify:

- [ ] IAM role has correct permissions
- [ ] Service account has correct annotations
- [ ] Aurora clusters have associated Secrets Manager secrets
- [ ] RBAC permissions are correctly configured
- [ ] Resource quotas are not exceeded
- [ ] Network connectivity to AWS APIs
- [ ] Helm chart values are correctly configured
- [ ] Recent logs have been reviewed

### Common Resolution Steps

1. **Restart the system**:
```bash
# Delete current job (if stuck)
kubectl delete job -n observability -l app.kubernetes.io/name=aurora-discovery

# Trigger new job
kubectl create job aurora-discovery-manual --from=cronjob/aurora-discovery -n observability
```

2. **Reset state**:
```bash
# Delete state ConfigMap
kubectl delete configmap aurora-discovery-state -n observability

# Clean up orphaned exporters
kubectl delete deployments,services,secrets -n observability -l app.kubernetes.io/name=aurora-exporter
```

3. **Verify configuration**:
```bash
# Check Helm values
helm get values db-monitoring -n observability

# Update if needed
helm upgrade db-monitoring helm-charts/db-monitoring --namespace observability --values values.yaml
```