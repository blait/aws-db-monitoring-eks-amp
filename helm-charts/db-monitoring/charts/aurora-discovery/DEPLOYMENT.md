# Aurora Discovery Deployment Guide

## Overview

Aurora Discovery is an automated system that discovers Amazon Aurora clusters in your AWS account and dynamically creates Prometheus exporters for monitoring. This guide covers the deployment, configuration, and troubleshooting of the Aurora Discovery feature.

## Prerequisites

### AWS Requirements

1. **Amazon Aurora Clusters**: Aurora MySQL or PostgreSQL clusters in your AWS account
2. **AWS Secrets Manager**: Each Aurora cluster must have associated secrets in AWS Secrets Manager containing database credentials
3. **IAM Permissions**: Proper IAM role with required permissions (see IAM Setup section)
4. **EKS Cluster**: Running EKS cluster with the db-monitoring Helm chart deployed
5. **ECR Repository**: Amazon ECR repository for Aurora Discovery container images (see Container Image Setup section)

### Kubernetes Requirements

1. **Kubernetes Version**: 1.19+
2. **Helm Version**: 3.0+
3. **IRSA Support**: EKS cluster with IAM Roles for Service Accounts (IRSA) enabled
4. **Namespace**: `observability` namespace (or custom namespace)

### Local Development Requirements

1. **Docker**: Docker installed for building container images
2. **AWS CLI**: AWS CLI v2 configured with appropriate credentials
3. **Git**: Git for cloning the repository

## Container Image Setup

Before deploying Aurora Discovery, you need to build and push the container image to Amazon ECR.

### Step 1: Create ECR Repository

First, create an ECR repository using CloudFormation:

```bash
# Set your environment name (should match your deployment)
export WORKSHOP_NAME="integrated-db-monitoring"

# Deploy the ECR stack
aws cloudformation create-stack \
  --stack-name ${WORKSHOP_NAME}-ecr \
  --template-body file://ecr-stack.yaml \
  --parameters ParameterKey=EnvironmentName,ParameterValue=${WORKSHOP_NAME}

# Wait for stack creation to complete
aws cloudformation wait stack-create-complete \
  --stack-name ${WORKSHOP_NAME}-ecr

# Get the ECR repository URI
export ECR_REPOSITORY_URI=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-ecr \
  --query 'Stacks[0].Outputs[?OutputKey==`RepositoryUri`].OutputValue' \
  --output text)

echo "ECR Repository URI: ${ECR_REPOSITORY_URI}"
```

### Step 2: Build Container Image

Navigate to the Aurora Discovery application directory and build the Docker image:

```bash
# Navigate to the application directory
cd helm-charts/db-monitoring/charts/aurora-discovery/app

# Build the Docker image
docker build --platform linux/amd64 -t aurora-discovery:latest .

# Tag the image for ECR
docker tag aurora-discovery:latest ${ECR_REPOSITORY_URI}:latest
docker tag aurora-discovery:latest ${ECR_REPOSITORY_URI}:1.0.0

# Verify the image was built successfully
docker images | grep aurora-discovery
```

### Step 3: Push Image to ECR

Authenticate Docker to your ECR registry and push the image:

```bash
# Get AWS account ID and region
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=$(aws configure get region)

# Authenticate Docker to ECR
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Push the images
docker push ${ECR_REPOSITORY_URI}:latest
docker push ${ECR_REPOSITORY_URI}:1.0.0

echo "Container image pushed successfully!"
echo "Image URI: ${ECR_REPOSITORY_URI}:1.0.0"
```

### Step 4: Verify Image in ECR

Verify that the image was pushed successfully:

```bash
# List images in the repository
aws ecr describe-images \
  --repository-name ${WORKSHOP_NAME}-aurora-discovery \
  --query 'imageDetails[*].[imageTags[0],imagePushedAt,imageSizeInBytes]' \
  --output table

# Get image scan findings (optional - scan may take a few minutes to complete)
aws ecr describe-image-scan-findings \
  --repository-name ${WORKSHOP_NAME}-aurora-discovery \
  --image-id imageTag=1.0.0 \
  --query 'imageScanFindings.findingSeverityCounts' \
  --output json 2>/dev/null || echo "Image scan not yet complete. Check again in a few minutes."
```

### Alternative: Using the Build Script

You can also use the provided build script for a streamlined process:

```bash
# Navigate to the application directory
cd helm-charts/db-monitoring/charts/aurora-discovery/app

# Build and push using the script
./build.sh \
  --registry ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com \
  --image-name ${WORKSHOP_NAME}-aurora-discovery \
  --tag 1.0.0 \
  --push

# Also tag and push as latest
./build.sh \
  --registry ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com \
  --image-name ${WORKSHOP_NAME}-aurora-discovery \
  --tag latest \
  --push
```

## IAM Setup

### Step 1: Set Environment Variables

First, set up the required environment variables:

```bash
# Set your environment name (should match your deployment)
export WORKSHOP_NAME="aurora-eks-amp-monitoring"

# Get AWS account and region information
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=$(aws configure get region)

# Get EKS cluster information
export CLUSTER_NAME="${WORKSHOP_NAME}-eks"
export OIDC_PROVIDER=$(aws eks describe-cluster \
  --name ${CLUSTER_NAME} \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed -e "s/^https:\/\///")

echo "Account ID: ${ACCOUNT_ID}"
echo "Region: ${AWS_REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo "OIDC Provider: ${OIDC_PROVIDER}"
```

### Step 2: Create IAM Policy for Aurora Discovery

Create an IAM policy with permissions to discover Aurora clusters and access Secrets Manager:

```bash
# Create IAM policy document
cat > aurora-discovery-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AuroraDiscovery",
            "Effect": "Allow",
            "Action": [
                "rds:DescribeDBClusters",
                "rds:DescribeDBInstances",
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
EOF

# Create the IAM policy
aws iam create-policy \
  --policy-name ${WORKSHOP_NAME}-aurora-discovery-policy \
  --policy-document file://aurora-discovery-policy.json

# Get the policy ARN
export AURORA_DISCOVERY_POLICY_ARN=$(aws iam list-policies \
  --query "Policies[?PolicyName=='${WORKSHOP_NAME}-aurora-discovery-policy'].Arn" \
  --output text)

echo "Aurora Discovery Policy ARN: ${AURORA_DISCOVERY_POLICY_ARN}"
```

### Step 3: Create IAM Role for Service Account (IRSA)

Create an IAM role that can be assumed by the Aurora Discovery Kubernetes service account:

```bash
# Create trust policy for IRSA
cat > aurora-discovery-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:observability:aurora-discovery",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# Create IAM role
aws iam create-role \
  --role-name ${WORKSHOP_NAME}-aurora-discovery-role \
  --assume-role-policy-document file://aurora-discovery-trust-policy.json

# Attach the Aurora Discovery policy to the role
aws iam attach-role-policy \
  --role-name ${WORKSHOP_NAME}-aurora-discovery-role \
  --policy-arn ${AURORA_DISCOVERY_POLICY_ARN}

# Get the role ARN for use in Helm values
export AURORA_DISCOVERY_ROLE_ARN=$(aws iam get-role \
  --role-name ${WORKSHOP_NAME}-aurora-discovery-role \
  --query 'Role.Arn' \
  --output text)

echo "Aurora Discovery Role ARN: ${AURORA_DISCOVERY_ROLE_ARN}"
```

### Step 4: Verify IAM Setup

Verify that the IAM role and policy are correctly configured:

```bash
# Verify the role exists
aws iam get-role --role-name ${WORKSHOP_NAME}-aurora-discovery-role --output json

# Verify the policy is attached
aws iam list-attached-role-policies --role-name ${WORKSHOP_NAME}-aurora-discovery-role --output json

# Display the role ARN (you'll need this for Helm deployment)
echo "Use this Role ARN in your Helm values:"
echo "${AURORA_DISCOVERY_ROLE_ARN}"
```

## Deployment Steps

### Step 1: Verify Aurora Clusters with Secrets Manager

If you deployed Aurora clusters using the provided CloudFormation template with `ManageMasterUserPassword: true`, the Secrets Manager secrets are automatically created and associated with the clusters. You can verify this:

```bash
# List Aurora clusters
aws rds describe-db-clusters \
  --query 'DBClusters[?Engine==`aurora-mysql` || Engine==`aurora-postgresql`].[DBClusterIdentifier,Engine,MasterUsername,MasterUserSecret.SecretArn]' \
  --output table

# Get specific cluster's secret ARN
export MYSQL_CLUSTER_ID=$(aws rds describe-db-clusters \
  --query 'DBClusters[?Engine==`aurora-mysql`].DBClusterIdentifier' \
  --output text | head -1)

export MYSQL_SECRET_ARN=$(aws rds describe-db-clusters \
  --db-cluster-identifier ${MYSQL_CLUSTER_ID} \
  --query 'DBClusters[0].MasterUserSecret.SecretArn' \
  --output text)

echo "MySQL Cluster: ${MYSQL_CLUSTER_ID}"
echo "MySQL Secret ARN: ${MYSQL_SECRET_ARN}"

# Verify secret contents (optional)
aws secretsmanager get-secret-value \
  --secret-id ${MYSQL_SECRET_ARN} \
  --query SecretString \
  --output text | jq .
```

**Note**: If you created Aurora clusters manually without Secrets Manager integration, you'll need to create secrets manually. See the "Manual Secret Creation" section below.

### Step 2: Deploy with Helm

Deploy or upgrade the db-monitoring chart with Aurora Discovery enabled using `--set` flags:

```bash
# Ensure ECR_REPOSITORY_URI is set (from Container Image Setup section)
# If not set, retrieve it:
export ECR_REPOSITORY_URI=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-ecr \
  --query 'Stacks[0].Outputs[?OutputKey==`RepositoryUri`].OutputValue' \
  --output text)

# Navigate to the Helm chart directory
cd helm-charts/db-monitoring

# Update Helm dependencies
helm dependency update

# Deploy the chart with environment-specific values
helm upgrade --install db-monitoring . \
  --namespace observability \
  --create-namespace \
  --set global.region=${AWS_REGION} \
  --set amp.workspaceId=${AMP_WORKSPACE_ID} \
  --set amp.endpoint=${AMP_ENDPOINT} \
  --set amp.region=${AWS_REGION} \
  --set aurora-discovery.enabled=true \
  --set aurora-discovery.image.repository=${ECR_REPOSITORY_URI} \
  --set aurora-discovery.aws.region=${AWS_REGION} \
  --set aurora-discovery.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${AURORA_DISCOVERY_ROLE_ARN} \
  --set adot-collector.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=${ADOT_ROLE_ARN} \
  --set adot-collector.amp.endpoint=${AMP_ENDPOINT} \
  --set adot-collector.amp.region=${AWS_REGION} \
  --set "redis-exporter.instances[0].endpoint=${ELASTICACHE_VALKEY_ENDPOINT}" \
  --set "redis-exporter.instances[0].port=${ELASTICACHE_VALKEY_PORT}" \
  --set sql-exporter.endpoint=${SQLSERVER_ENDPOINT} 

echo "Aurora Discovery deployed successfully!"
```

**Notes**: 
- This command assumes the `observability` namespace already exists from the initial setup
- If the namespace doesn't exist, create it first: `kubectl create namespace observability`
- The command uses the base `values.yaml` file and overrides only environment-specific values via `--set` flags
- The `aurora-discovery.image.repository` is set to the ECR repository URI from the Container Image Setup section
- ServiceMonitor and PrometheusRule are disabled by default as ADOT Collector uses Kubernetes Service Discovery
- If you're using Prometheus Operator instead of ADOT Collector, enable them with `--set aurora-discovery.alerting.enabled=true`

### Step 3: Verify Deployment

Verify that Aurora Discovery is running correctly:

```bash
# Check CronJob status
kubectl get cronjobs -n observability
kubectl describe cronjob db-monitoring-aurora-discovery -n observability

# Check if any jobs have run
kubectl get jobs -n observability -l app.kubernetes.io/name=aurora-discovery

# Check service account and IRSA annotation
kubectl get serviceaccount aurora-discovery -n observability -o yaml | grep eks.amazonaws.com/role-arn

# Manually trigger a job to test (optional)
kubectl create job aurora-discovery-manual-test \
  --from=cronjob/db-monitoring-aurora-discovery \
  -n observability

# Watch the job
kubectl get jobs -n observability -w

# Check logs
kubectl logs -n observability job/aurora-discovery-manual-test --follow
```

### Step 4: Verify Dynamic Exporters

After the CronJob runs, verify that dynamic exporters are created:

```bash
# List Aurora exporters created by Aurora Discovery
kubectl get deployments -n observability -l app.kubernetes.io/name=aurora-exporter

# List services for Aurora exporters
kubectl get services -n observability -l app.kubernetes.io/name=aurora-exporter

# Check exporter logs
kubectl logs -n observability -l app.kubernetes.io/name=aurora-exporter --tail=50

# Verify ADOT Collector is discovering the exporters
kubectl logs -n observability deployment/db-monitoring-adot-collector | grep aurora
```

## Manual Secret Creation (Optional)

If your Aurora clusters don't have Secrets Manager integration, create secrets manually:

```bash
# Get Aurora cluster endpoints
export MYSQL_CLUSTER_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier ${MYSQL_CLUSTER_ID} \
  --query 'DBClusters[0].Endpoint' \
  --output text)

export PG_CLUSTER_ID=$(aws rds describe-db-clusters \
  --query 'DBClusters[?Engine==`aurora-postgresql`].DBClusterIdentifier' \
  --output text | head -1)

export PG_CLUSTER_ENDPOINT=$(aws rds describe-db-clusters \
  --db-cluster-identifier ${PG_CLUSTER_ID} \
  --query 'DBClusters[0].Endpoint' \
  --output text)

# For Aurora MySQL
aws secretsmanager create-secret \
    --name "aurora-mysql-manual-credentials" \
    --description "Aurora MySQL cluster credentials" \
    --secret-string "{
        \"username\": \"admin\",
        \"password\": \"your-secure-password\",
        \"engine\": \"mysql\",
        \"host\": \"${MYSQL_CLUSTER_ENDPOINT}\",
        \"port\": 3306,
        \"dbname\": \"aurora_mysql_db\"
    }"

# For Aurora PostgreSQL
aws secretsmanager create-secret \
    --name "aurora-postgresql-manual-credentials" \
    --description "Aurora PostgreSQL cluster credentials" \
    --secret-string "{
        \"username\": \"postgres\",
        \"password\": \"your-secure-password\",
        \"engine\": \"postgres\",
        \"host\": \"${PG_CLUSTER_ENDPOINT}\",
        \"port\": 5432,
        \"dbname\": \"aurora_postgresql_db\"
    }"

# Associate secrets with Aurora clusters
aws rds modify-db-cluster \
    --db-cluster-identifier ${MYSQL_CLUSTER_ID} \
    --master-user-secret-kms-key-id alias/aws/secretsmanager \
    --manage-master-user-password

aws rds modify-db-cluster \
    --db-cluster-identifier ${PG_CLUSTER_ID} \
    --master-user-secret-kms-key-id alias/aws/secretsmanager \
    --manage-master-user-password
```

<!-- ## Monitoring Aurora Discovery

### Check CronJob Execution

```bash
# View CronJob schedule and status
kubectl get cronjobs -n observability

# Describe CronJob for detailed information
kubectl describe cronjob aurora-discovery -n observability

# List recent jobs
kubectl get jobs -n observability -l app.kubernetes.io/name=aurora-discovery --sort-by=.metadata.creationTimestamp

# Get logs from the latest job
LATEST_JOB=$(kubectl get jobs -n observability -l app.kubernetes.io/name=aurora-discovery --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl logs -n observability job/${LATEST_JOB}
```

### Check Created Exporters

```bash
# List all Aurora exporters
kubectl get deployments,services,secrets -n observability -l app.kubernetes.io/name=aurora-exporter

# Check specific exporter logs
kubectl logs -n observability -l app.kubernetes.io/name=aurora-exporter,app.kubernetes.io/component=mysql-exporter --tail=50

# Check exporter metrics endpoint
kubectl port-forward -n observability deployment/aurora-mysql-<cluster-id> 9104:9104
# Then visit http://localhost:9104/metrics
```

### Verify Service Discovery

```bash
# Check ADOT Collector configuration
kubectl get configmap adot-collector-config -n observability -o yaml

# Check ADOT Collector logs for service discovery
kubectl logs -n observability deployment/adot-collector | grep -i "aurora\|service.*discovery"

# Verify metrics are being scraped
kubectl logs -n observability deployment/adot-collector | grep -i "scrape"
```

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
``` -->

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

<!-- ## Migration from Static Exporters

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
- [ ] Documentation updated -->

<!-- ## Monitoring Aurora Discovery

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
``` -->

<!-- ## Backup and Recovery

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
``` -->

<!-- ## Security Best Practices

1. **Least Privilege IAM**: Only grant minimum required AWS permissions
2. **Secret Rotation**: Regularly rotate Aurora cluster passwords in Secrets Manager
3. **Network Policies**: Implement Kubernetes Network Policies to restrict traffic
4. **Resource Quotas**: Set appropriate resource quotas for the observability namespace
5. **RBAC**: Use Kubernetes RBAC to limit access to Aurora Discovery resources -->

<!-- ## Performance Tuning

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
3. **State ConfigMap Size**: Monitor ConfigMap size with large numbers of clusters -->

## Updating the Container Image

When you make changes to the Aurora Discovery application code, follow these steps to update the deployed version:

### Step 1: Build and Push New Image

```bash
# Set environment variables
export WORKSHOP_NAME="aurora-eks-amp-monitoring"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=$(aws configure get region)
export ECR_REPOSITORY_URI=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-ecr \
  --query 'Stacks[0].Outputs[?OutputKey==`RepositoryUri`].OutputValue' \
  --output text)

# Increment version (e.g., 1.0.0 -> 1.0.1)
export NEW_VERSION="1.0.1"

# Navigate to application directory
cd helm-charts/db-monitoring/charts/aurora-discovery/app

# Build new image
docker build -t aurora-discovery:${NEW_VERSION} .

# Tag for ECR
docker tag aurora-discovery:${NEW_VERSION} ${ECR_REPOSITORY_URI}:${NEW_VERSION}
docker tag aurora-discovery:${NEW_VERSION} ${ECR_REPOSITORY_URI}:latest

# Authenticate to ECR
aws ecr get-login-password --region ${AWS_REGION} | \
  docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Push images
docker push ${ECR_REPOSITORY_URI}:${NEW_VERSION}
docker push ${ECR_REPOSITORY_URI}:latest

echo "New image version ${NEW_VERSION} pushed successfully!"
```

### Step 2: Update Helm Deployment

```bash
# Navigate to Helm chart directory
cd helm-charts/db-monitoring

# Upgrade with new image version
helm upgrade db-monitoring . \
  --namespace observability \
  --reuse-values \
  --set aurora-discovery.image.tag=${NEW_VERSION} \
  --wait

echo "Aurora Discovery updated to version ${NEW_VERSION}!"
```

### Step 3: Verify Update

```bash
# Check the CronJob is using the new image
kubectl get cronjob aurora-discovery -n observability -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}'

# Manually trigger a job to test the new version
kubectl create job aurora-discovery-test-${NEW_VERSION} \
  --from=cronjob/aurora-discovery \
  -n observability

# Check logs
kubectl logs -n observability job/aurora-discovery-test-${NEW_VERSION} --follow
```

## Cleanup

To remove the Aurora Discovery deployment and ECR repository:

### Remove Helm Deployment

```bash
# Disable Aurora Discovery (keeps other components)
helm upgrade db-monitoring . \
  --namespace observability \
  --reuse-values \
  --set aurora-discovery.enabled=false

# Or completely uninstall the chart
helm uninstall db-monitoring --namespace observability
```

### Delete ECR Repository

```bash
# Delete all images in the repository first
aws ecr batch-delete-image \
  --repository-name ${WORKSHOP_NAME}-aurora-discovery \
  --image-ids "$(aws ecr list-images \
    --repository-name ${WORKSHOP_NAME}-aurora-discovery \
    --query 'imageIds[*]' \
    --output json)" || true

# Delete the CloudFormation stack
aws cloudformation delete-stack \
  --stack-name ${WORKSHOP_NAME}-ecr

# Wait for deletion to complete
aws cloudformation wait stack-delete-complete \
  --stack-name ${WORKSHOP_NAME}-ecr

echo "ECR repository deleted successfully!"
```

## Next Steps

After successful deployment:

1. Monitor the system for 24-48 hours
2. Verify all Aurora clusters are being discovered
3. Check that metrics are flowing correctly
4. Update monitoring dashboards if needed
5. Train team members on the new system
6. Update incident response procedures