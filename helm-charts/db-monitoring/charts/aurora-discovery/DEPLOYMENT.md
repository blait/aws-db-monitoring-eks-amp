# Aurora Discovery Deployment Guide

## Overview

Aurora Discovery is an automated system that discovers Amazon Aurora clusters in your AWS account and dynamically creates Prometheus exporters for monitoring. This guide covers the deployment, configuration, and troubleshooting of the Aurora Discovery feature.

## Prerequisites

### AWS Requirements

1. **Amazon Aurora Clusters**: Aurora MySQL or PostgreSQL clusters in your AWS account
2. **AWS Secrets Manager**: Each Aurora cluster must have associated secrets in AWS Secrets Manager containing database credentials
3. **IAM Permissions**: Proper IAM role with required permissions (see IAM Setup section)
4. **EKS Cluster**: Running EKS cluster with the db-monitoring Helm chart deployed

### Kubernetes Requirements

1. **Kubernetes Version**: 1.19+
2. **Helm Version**: 3.0+
3. **IRSA Support**: EKS cluster with IAM Roles for Service Accounts (IRSA) enabled
4. **Namespace**: `observability` namespace (or custom namespace)

## IAM Setup

### Required AWS Permissions

Create an IAM policy with the following permissions:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AuroraDiscovery",
            "Effect": "Allow",
            "Action": [
                "rds:DescribeDBClusters",
                "rds:ListTagsForResource"
            ],
            "Resource": "*"
        },
        {
            "Sid": "SecretsManagerAccess",
            "Effect": "Allow",
            "Action": [
                "secretsmanager:GetSecretValue"
            ],
            "Resource": "arn:aws:secretsmanager:*:*:secret:*"
        }
    ]
}
```

### IAM Role for Service Account (IRSA)

1. Create an IAM role for the Aurora Discovery service account:

```bash
# Set variables
CLUSTER_NAME="your-eks-cluster"
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="AuroraDiscoveryRole"

# Create trust policy
cat > trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${REGION}.amazonaws.com/id/$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5)"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "oidc.eks.${REGION}.amazonaws.com/id/$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5):sub": "system:serviceaccount:observability:aurora-discovery",
                    "oidc.eks.${REGION}.amazonaws.com/id/$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.identity.oidc.issuer" --output text | cut -d '/' -f 5):aud": "sts.amazonaws.com"
                }
            }
        }
    ]
}
EOF

# Create IAM role
aws iam create-role --role-name ${ROLE_NAME} --assume-role-policy-document file://trust-policy.json

# Attach the policy
aws iam attach-role-policy --role-name ${ROLE_NAME} --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AuroraDiscoveryPolicy
```

2. Note the role ARN for use in Helm values:

```bash
aws iam get-role --role-name ${ROLE_NAME} --query Role.Arn --output text
```

## Deployment Steps

### Step 1: Enable Aurora Discovery

Update your Helm values file to enable Aurora Discovery:

```yaml
# values.yaml
aurora-discovery:
  enabled: true
  aws:
    region: us-east-1  # Your AWS region
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/AuroraDiscoveryRole"
```

### Step 2: Configure Aurora Clusters

Ensure your Aurora clusters have associated Secrets Manager secrets:

1. **Create Secrets Manager Secret (if not exists)**:

```bash
# For Aurora MySQL
aws secretsmanager create-secret \
    --name "aurora-mysql-cluster-credentials" \
    --description "Aurora MySQL cluster credentials" \
    --secret-string '{
        "username": "admin",
        "password": "your-password",
        "engine": "mysql",
        "host": "aurora-mysql-cluster.cluster-xyz.us-east-1.rds.amazonaws.com",
        "port": 3306,
        "dbname": "mysql"
    }'

# For Aurora PostgreSQL
aws secretsmanager create-secret \
    --name "aurora-postgresql-cluster-credentials" \
    --description "Aurora PostgreSQL cluster credentials" \
    --secret-string '{
        "username": "postgres",
        "password": "your-password",
        "engine": "postgres",
        "host": "aurora-postgresql-cluster.cluster-xyz.us-east-1.rds.amazonaws.com",
        "port": 5432,
        "dbname": "postgres"
    }'
```

2. **Associate Secret with Aurora Cluster**:

```bash
# Modify Aurora cluster to use the secret
aws rds modify-db-cluster \
    --db-cluster-identifier aurora-mysql-cluster \
    --master-user-secret-kms-key-id alias/aws/secretsmanager \
    --manage-master-user-password
```

### Step 3: Deploy with Helm

```bash
# Update Helm dependencies
helm dependency update helm-charts/db-monitoring

# Deploy or upgrade the chart
helm upgrade --install db-monitoring helm-charts/db-monitoring \
    --namespace observability \
    --create-namespace \
    --values values.yaml
```

### Step 4: Verify Deployment

1. **Check CronJob Status**:

```bash
kubectl get cronjobs -n observability
kubectl describe cronjob aurora-discovery -n observability
```

2. **Check Service Account and RBAC**:

```bash
kubectl get serviceaccount aurora-discovery -n observability
kubectl describe serviceaccount aurora-discovery -n observability
```

3. **Monitor Logs**:

```bash
# Get the latest job
kubectl get jobs -n observability -l app.kubernetes.io/name=aurora-discovery

# Check logs
kubectl logs -n observability job/aurora-discovery-<timestamp>
```

## Configuration Options

### Complete Configuration Reference

```yaml
aurora-discovery:
  enabled: true
  
  # CronJob schedule (default: every hour)
  schedule: "0 * * * *"
  
  # Container image configuration
  image:
    repository: aurora-discovery
    tag: "1.0.0"
    pullPolicy: IfNotPresent
  
  # Resource limits and requests
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  
  # AWS configuration
  aws:
    region: us-east-1
  
  # Service Account configuration
  serviceAccount:
    create: true
    name: aurora-discovery
    annotations:
      eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/AuroraDiscoveryRole"
  
  # State management
  stateConfigMap:
    name: aurora-discovery-state
  
  # Logging configuration
  logging:
    level: INFO  # DEBUG, INFO, WARN, ERROR
  
  # CronJob configuration
  concurrencyPolicy: Forbid  # Prevent overlapping executions
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  
  # Job timeout (default: 30 minutes)
  activeDeadlineSeconds: 1800
```

### Environment-Specific Configurations

#### Development Environment

```yaml
aurora-discovery:
  enabled: true
  schedule: "*/15 * * * *"  # Every 15 minutes for faster testing
  logging:
    level: DEBUG
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

#### Production Environment

```yaml
aurora-discovery:
  enabled: true
  schedule: "0 * * * *"  # Every hour
  logging:
    level: INFO
  resources:
    requests:
      cpu: 200m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  successfulJobsHistoryLimit: 5
  failedJobsHistoryLimit: 3
```

## Migration from Static Exporters

### Phase 1: Parallel Deployment

1. Deploy Aurora Discovery alongside existing static exporters
2. Monitor both systems to ensure Aurora Discovery is working correctly
3. Verify metrics are being collected from dynamically created exporters

### Phase 2: Gradual Migration

1. Disable static exporters for clusters that are successfully discovered by Aurora Discovery
2. Update ADOT Collector configuration to prioritize Service Discovery
3. Monitor for any gaps in metric collection

### Phase 3: Complete Migration

1. Remove static exporter configurations from values.yaml
2. Set `aurora-discovery.enabled: true` as default
3. Update documentation and runbooks

### Migration Checklist

- [ ] Aurora Discovery CronJob is running successfully
- [ ] Dynamic exporters are being created for all Aurora clusters
- [ ] ADOT Collector is discovering and scraping dynamic exporters
- [ ] Metrics are flowing to Amazon Managed Prometheus
- [ ] Grafana dashboards are displaying data from dynamic exporters
- [ ] Alerting rules are working with new metric labels
- [ ] Static exporter configurations removed
- [ ] Documentation updated

## Monitoring Aurora Discovery

### Key Metrics to Monitor

1. **CronJob Execution**:
   - `kube_cronjob_status_active`
   - `kube_cronjob_status_last_schedule_time`

2. **Job Success/Failure**:
   - `kube_job_status_succeeded`
   - `kube_job_status_failed`

3. **Aurora Discovery Metrics** (exposed by the application):
   - `aurora_discovery_clusters_total`
   - `aurora_discovery_exporters_created_total`
   - `aurora_discovery_exporters_deleted_total`
   - `aurora_discovery_errors_total`

### Recommended Alerts

```yaml
# CronJob failure alert
- alert: AuroraDiscoveryCronJobFailed
  expr: kube_cronjob_status_last_schedule_time{cronjob="aurora-discovery"} < (time() - 7200)
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Aurora Discovery CronJob has not run successfully"
    description: "Aurora Discovery CronJob has not completed successfully in the last 2 hours"

# High error rate alert
- alert: AuroraDiscoveryHighErrorRate
  expr: rate(aurora_discovery_errors_total[5m]) > 0.1
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High error rate in Aurora Discovery"
    description: "Aurora Discovery is experiencing a high error rate: {{ $value }} errors/sec"
```

## Backup and Recovery

### State Backup

The Aurora Discovery system stores its state in a Kubernetes ConfigMap. To backup the state:

```bash
# Backup state ConfigMap
kubectl get configmap aurora-discovery-state -n observability -o yaml > aurora-discovery-state-backup.yaml
```

### Recovery Procedures

1. **ConfigMap Corruption**: The system will automatically recreate the ConfigMap from current AWS state
2. **Complete State Loss**: Delete the ConfigMap and let the system rebuild it:

```bash
kubectl delete configmap aurora-discovery-state -n observability
```

3. **Exporter Resource Cleanup**: If exporters are orphaned, clean them up manually:

```bash
# List Aurora exporters
kubectl get deployments,services,secrets -n observability -l app.kubernetes.io/name=aurora-exporter

# Clean up specific exporter
kubectl delete deployment,service,secret -n observability -l aurora.aws/cluster-identifier=cluster-name
```

## Security Best Practices

1. **Least Privilege IAM**: Only grant minimum required AWS permissions
2. **Secret Rotation**: Regularly rotate Aurora cluster passwords in Secrets Manager
3. **Network Policies**: Implement Kubernetes Network Policies to restrict traffic
4. **Resource Quotas**: Set appropriate resource quotas for the observability namespace
5. **RBAC**: Use Kubernetes RBAC to limit access to Aurora Discovery resources

## Performance Tuning

### Resource Optimization

1. **CPU/Memory**: Adjust based on number of Aurora clusters:
   - Small (1-10 clusters): 200m CPU, 256Mi memory
   - Medium (10-50 clusters): 500m CPU, 512Mi memory
   - Large (50+ clusters): 1000m CPU, 1Gi memory

2. **Schedule Frequency**: Balance between discovery speed and resource usage:
   - Development: Every 15 minutes
   - Production: Every hour
   - Critical environments: Every 30 minutes

### Scaling Considerations

1. **AWS API Limits**: Monitor AWS API throttling and implement backoff strategies
2. **Kubernetes API Limits**: Consider cluster size when setting resource limits
3. **State ConfigMap Size**: Monitor ConfigMap size with large numbers of clusters

## Next Steps

After successful deployment:

1. Monitor the system for 24-48 hours
2. Verify all Aurora clusters are being discovered
3. Check that metrics are flowing correctly
4. Update monitoring dashboards if needed
5. Train team members on the new system
6. Update incident response procedures