# AWS Workshop: Integrated Database Monitoring with EKS, AMP, and AMG

This workshop guides you through setting up a comprehensive monitoring solution for Aurora databases using Amazon EKS, Amazon Managed Service for Prometheus (AMP), and Amazon Managed Grafana (AMG).

## Prerequisites

Before starting this workshop, ensure you have:

- An AWS account with administrator access
- AWS CLI (version 2.0.0 or later) installed and configured
- kubectl (version 1.23.0 or later) installed
- Helm (version 3.8.0 or later) installed
- eksctl (version 0.123.0 or later) installed

### Quick Installation Guide

```bash
# Install Helm (if not already installed)
# macOS
brew install helm

# Linux
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Verify installation
helm version
```

## Workshop Modules

1. **Module 1**: Environment Setup
2. **Module 2**: Networking and Database Infrastructure  
3. **Module 3**: EKS Cluster Setup (EKS 1.30)
4. **Module 4**: Amazon Managed Prometheus Setup
5. **Module 5**: Amazon Managed Grafana Setup
6. **Module 6**: Deploy Monitoring Stack with Helm
7. **Module 7**: Dashboard Configuration (MySQL + PostgreSQL)
8. **Module 8**: Monitoring Best Practices

## Module 1: Environment Setup

### Step 1: Set up environment variables

```bash
# Set environment variables
export WORKSHOP_NAME=integrated-db-monitoring
export AWS_REGION=$(aws configure get region)
export VPC_CIDR="10.0.0.0/16"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Verify environment setup
echo "Workshop Name: $WORKSHOP_NAME"
echo "AWS Region: $AWS_REGION"
echo "AWS Account ID: $ACCOUNT_ID"
echo "Using VPC CIDR: $VPC_CIDR"
```

### Step 2: Clone the workshop repository

```bash
git clone git@github.com:madebybk/db-monitoring-eks-amp.git
cd db-monitoring-eks-amp
```

## Module 2: Networking and Database Infrastructure

Deploy the networking and database infrastructure using CloudFormation:

```bash
# Deploy networking stack
aws cloudformation create-stack \
  --stack-name ${WORKSHOP_NAME}-network \
  --template-body file://networking-stack.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${WORKSHOP_NAME} \
    ParameterKey=VpcCidr,ParameterValue=${VPC_CIDR} \
  --capabilities CAPABILITY_IAM

# Wait for completion
aws cloudformation wait stack-create-complete \
  --stack-name ${WORKSHOP_NAME}-network

# Store networking outputs
export VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
  --output text)

export PUBLIC_SUBNETS=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`PublicSubnets`].OutputValue' \
  --output text)

export PRIVATE_SUBNETS=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnets`].OutputValue' \
  --output text)

export DATABASE_SUBNETS=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`DatabaseSubnets`].OutputValue' \
  --output text)

export PRIVATE_SUBNET_CIDRS=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnetCidrs`].OutputValue' \
  --output text)

# Deploy database stack
aws cloudformation create-stack \
  --stack-name ${WORKSHOP_NAME}-database \
  --template-body file://database-stack.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${WORKSHOP_NAME} \
    ParameterKey=VpcId,ParameterValue=$VPC_ID \
    ParameterKey=DatabaseSubnets,ParameterValue=\"$DATABASE_SUBNETS\" \
    ParameterKey=PrivateSubnetCidrs,ParameterValue=\"$PRIVATE_SUBNET_CIDRS\" \
    ParameterKey=PublicSubnets,ParameterValue=\"$PUBLIC_SUBNETS\" \
    ParameterKey=MySQLMasterUsername,ParameterValue=admin \
    ParameterKey=MySQLMasterPassword,ParameterValue=adminadmin \
    ParameterKey=PostgreSQLMasterUsername,ParameterValue=root \
    ParameterKey=PostgreSQLMasterPassword,ParameterValue=rootroot 


# Wait for completion (15-20 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name ${WORKSHOP_NAME}-db

# Store database endpoints
export MYSQL_ENDPOINT1=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-db \
  --query 'Stacks[0].Outputs[?OutputKey==`MySQLInstance1Endpoint`].OutputValue' \
  --output text)

export MYSQL_ENDPOINT2=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-db \
  --query 'Stacks[0].Outputs[?OutputKey==`MySQLInstance2Endpoint`].OutputValue' \
  --output text)

export POSTGRESQL_ENDPOINT1=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-db \
  --query 'Stacks[0].Outputs[?OutputKey==`PostgreSQLInstance1Endpoint`].OutputValue' \
  --output text)

export POSTGRESQL_ENDPOINT2=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-db \
  --query 'Stacks[0].Outputs[?OutputKey==`PostgreSQLInstance2Endpoint`].OutputValue' \
  --output text)
  
# Deploy cache stack
aws cloudformation create-stack \
  --stack-name ${WORKSHOP_NAME}-cache \
  --template-body file://cache-stack.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${WORKSHOP_NAME} \
    ParameterKey=VpcId,ParameterValue=$VPC_ID \
    ParameterKey=DatabaseSubnets,ParameterValue=\"$DATABASE_SUBNETS\" \
    ParameterKey=PrivateSubnetCidrs,ParameterValue=\"$PRIVATE_SUBNET_CIDRS\" \
  --capabilities CAPABILITY_IAM

# Wait for completion
aws cloudformation wait stack-create-complete \
  --stack-name ${WORKSHOP_NAME}-cache

# Store ElastiCache Valkey endpoint
export ELASTICACHE_VALKEY_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-cache \
  --query 'Stacks[0].Outputs[?OutputKey==`ElastiCacheRedisEndpoint`].OutputValue' \
  --output text)

export ELASTICACHE_VALKEY_PORT=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-cache \
  --query 'Stacks[0].Outputs[?OutputKey==`ElastiCacheRedisPort`].OutputValue' \
  --output text)

echo "ElastiCache Valkey Endpoint: $ELASTICACHE_VALKEY_ENDPOINT"
echo "ElastiCache Valkey Port: $ELASTICACHE_VALKEY_PORT"
```

## Module 3: EKS Cluster Setup (EKS 1.30)

Create an EKS cluster using the optimized version for ADOT compatibility:

```bash
# Extract individual subnet IDs
export PRIVATE_SUBNET_1=$(echo $PRIVATE_SUBNETS | cut -d',' -f1)
export PRIVATE_SUBNET_2=$(echo $PRIVATE_SUBNETS | cut -d',' -f2)
export PRIVATE_SUBNET_3=$(echo $PRIVATE_SUBNETS | cut -d',' -f3)

# Create the EKS cluster (15-20 minutes)
envsubst < eks-cluster.yaml > eks-cluster-resolved.yaml
eksctl create cluster -f eks-cluster-resolved.yaml

# Enable OIDC provider
eksctl utils associate-iam-oidc-provider \
  --region $AWS_REGION \
  --cluster ${WORKSHOP_NAME}-eks \
  --approve

# Get OIDC provider URL
export OIDC_PROVIDER=$(aws eks describe-cluster \
  --name ${WORKSHOP_NAME}-eks \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed -e "s/^https:\/\///")

# Verify cluster
kubectl get nodes
```

## Module 4: Amazon Managed Prometheus Setup

```bash
# Create AMP workspace
aws amp create-workspace \
  --alias ${WORKSHOP_NAME}-amp \
  --tags Name=${WORKSHOP_NAME}-amp

# Get workspace details
export AMP_WORKSPACE_ID=$(aws amp list-workspaces \
  --alias ${WORKSHOP_NAME}-amp \
  --query 'workspaces[0].workspaceId' \
  --output text)

export AMP_ENDPOINT="https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/api/v1/remote_write"

# Create IAM role for ADOT Collector
cat > adot-trust-policy.json << EOF
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
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:observability:adot-collector",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name ${WORKSHOP_NAME}-adot-collector-role \
  --assume-role-policy-document file://adot-trust-policy.json

aws iam attach-role-policy \
  --role-name ${WORKSHOP_NAME}-adot-collector-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess

export ADOT_ROLE_ARN=$(aws iam get-role \
  --role-name ${WORKSHOP_NAME}-adot-collector-role \
  --query 'Role.Arn' \
  --output text)
```

## Module 5: Amazon Managed Grafana Setup

In this module, we'll set up Amazon Managed Grafana (AMG) using the AWS CLI for IAM role creation and the AWS Console for workspace configuration.

### Step 1: Create an IAM Role for Grafana using CLI

```bash
# Create IAM policy document for Grafana
cat > grafana-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "grafana.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create the IAM role
aws iam create-role \
  --role-name ${WORKSHOP_NAME}-grafana-role \
  --assume-role-policy-document file://grafana-trust-policy.json

# Attach necessary policies to the role
# For Prometheus metrics access
aws iam attach-role-policy \
  --role-name ${WORKSHOP_NAME}-grafana-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusFullAccess

# For CloudWatch metrics access (needed for Aurora CPU and Network metrics)
aws iam attach-role-policy \
  --role-name ${WORKSHOP_NAME}-grafana-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess

# Verify the attached policies
aws iam list-attached-role-policies \
  --role-name ${WORKSHOP_NAME}-grafana-role

# Get the role ARN
export GRAFANA_ROLE_ARN=$(aws iam get-role \
  --role-name ${WORKSHOP_NAME}-grafana-role \
  --query 'Role.Arn' \
  --output text)

echo "Grafana Role ARN: $GRAFANA_ROLE_ARN"
```

### Step 2: Create an AMG workspace

1. Open the AWS Console and navigate to Amazon Managed Grafana
2. Click "Create workspace"
3. Enter a workspace name: `${WORKSHOP_NAME}-grafana` (e.g., "integrated-db-monitoring-grafana")
4. Under "Access method", select "AWS IAM Identity Center (successor to AWS SSO)"
5. Under "Permission type", select "Service managed"
6. Under "Service role", select "Use an existing service role"
7. Select the role you created in Step 1 from the dropdown
8. Under "Data sources", select "Amazon Managed Service for Prometheus"
9. Review your settings and click "Create workspace"
10. Wait for the workspace to be created (this may take a few minutes)

### Step 3: Configure AMG workspace authentication

1. Once the workspace is created, click on the workspace name to view its details
2. Click on "Authentication" in the left sidebar
3. Under "AWS IAM Identity Center (successor to AWS SSO)", click "Configure user access"
4. Add yourself as an Admin user:
   - Click "Assign new user or group"
   - Search for your username
   - Select your username and click "Assign users and groups"
   - Set the permission level to "Admin"
5. Click "Save changes"

### Step 4: Configure AMP as a data source in AMG

1. In the AMG workspace details page, click on the "Grafana workspace URL" to open the Grafana UI
2. Log in with your AWS SSO credentials
3. In Grafana, click on "Configuration" (gear icon) in the left sidebar
4. Select "Data sources"
5. Click "Add data source"
6. Select "Amazon Managed Service for Prometheus"
7. Configure the data source:
   - Name: AMP
   - Workspace: Select your AMP workspace (created in Module 4)
   - Region: Select your AWS region
8. Click "Save & test"
9. You should see a "Data source is working" message

### Step 5: Configure CloudWatch as a data source in AMG

1. Click "Add data source" again
2. Select "CloudWatch"
3. Configure the data source:
   - Name: CloudWatch
   - Authentication Provider: AWS IAM Roles for Service Accounts
   - Default Region: Select your AWS region
4. Click "Save & test"
5. You should see a "Data source is working" message

### Step 5: Store the AMG workspace ID as an environment variable

For use in later modules, store the AMG workspace ID as an environment variable:

```bash
# Get the workspace ID from the AWS Console and set it as an environment variable
# The workspace ID is visible in the URL when viewing the workspace details
# For example: https://console.aws.amazon.com/grafana/home?region=us-east-1#/workspaces/g-1234567890
# In this case, the workspace ID is g-1234567890
export AMG_WORKSPACE_ID=<your-workspace-id>
echo "AMG Workspace ID: $AMG_WORKSPACE_ID"
```

## Module 6: Deploy Monitoring Stack with Helm

Instead of manually deploying multiple YAML files, we use a single command:

```bash
# Deploy the complete monitoring stack with production configuration
./scripts/deploy-monitoring.sh
```

The deployment script will:
- ✅ Validate all required environment variables
- ✅ Check Helm and kubectl connectivity  
- ✅ Create production-grade configuration
- ✅ Deploy all components atomically with enhanced resources
- ✅ Verify deployment status
- ✅ Provide helpful next steps

### Manual Helm Deployment (Alternative) - 아직 잘 안됨

If you prefer manual control:

```bash
# Install the monitoring stack
helm install db-monitoring ./helm-charts/db-monitoring \
  --namespace observability \
  --set amp.workspaceId="$AMP_WORKSPACE_ID" \
  --set amp.endpoint="$AMP_ENDPOINT" \
  --set adot.serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$ADOT_ROLE_ARN" \
  --set mysql.instances[0].endpoint="$MYSQL_ENDPOINT1" \
  --set mysql.instances[1].endpoint="$MYSQL_ENDPOINT2" \
  --set postgresql.instances[0].endpoint="$POSTGRESQL_ENDPOINT1" \
  --set postgresql.instances[1].endpoint="$POSTGRESQL_ENDPOINT2" \
  --create-namespace \
  --wait

# Verify deployment
helm list -n observability
kubectl get pods -n observability
```

### Helm Management Commands

```bash
# Check deployment status
helm status db-monitoring -n observability

# Upgrade deployment
helm upgrade db-monitoring ./helm-charts/db-monitoring \
  --namespace observability

# Rollback if needed
helm rollback db-monitoring 1 -n observability

# Uninstall
helm uninstall db-monitoring -n observability
```

## Module 7: Dashboard Configuration

### Import MySQL Dashboard

1. Access your AMG workspace
2. Import dashboard from `dashboards/mysql.json`
3. Configure data source as "AMP"

### Import PostgreSQL Dashboard

1. Import the comprehensive PostgreSQL dashboard from `dashboards/postgresql.json`
2. Configure data sources:
   - **AMP (Prometheus)**: Application-level metrics, table performance, Performance Insights
   - **CloudWatch**: AWS infrastructure metrics (CPU, Memory, Network I/O)
3. The dashboard includes:
   - Active connections monitoring
   - Transaction rate tracking
   - Cache hit ratio analysis
   - Row activity metrics
   - Write activity monitoring
   - Lock monitoring
   - Database size tracking
   - Table performance metrics
   - **AWS Infrastructure metrics** (CPU, Memory, Connections)
   - **Performance Insights** (Database Load, Wait Events) via AMP

### Dashboard Features

Both dashboards include:
- **Real-time metrics** with 30-second refresh
- **Multi-instance support** with template variables
- **Comprehensive coverage** of key database metrics
- **Professional styling** with appropriate thresholds
- **Responsive design** for different screen sizes

## Module 8: Monitoring Best Practices

### Key Metrics Monitored

**MySQL Metrics:**
- Connection count and utilization
- Query performance and slow queries
- InnoDB buffer pool efficiency
- Lock contention and waits
- Replication lag (if applicable)

**PostgreSQL Metrics:**
- Active connections and backends
- Transaction commit/rollback rates
- Cache hit ratios (table and index level)
- Row-level activity (inserts, updates, deletes)
- Lock monitoring and conflict detection
- Database and table sizes
- Index usage and efficiency
- Vacuum/autovacuum operations
- Long-running transaction detection

### Alerting Best Practices

1. **Set appropriate thresholds** based on baseline performance
2. **Use time-based conditions** to avoid false positives
3. **Implement alert severity levels** (Critical, Warning, Info)
4. **Include actionable information** in alert messages
5. **Test alert channels** regularly

### Helm Chart Benefits

- **Version control**: Track changes to monitoring configuration
- **Environment consistency**: Same charts across dev/staging/prod
- **Easy rollbacks**: Instant rollback to previous working version
- **Dependency management**: Automatic handling of component dependencies
- **Configuration templating**: Environment-specific values without code duplication

## Troubleshooting

4. **Helm deployment issues**: Check values file and template rendering
   ```bash
   helm template db-monitoring ./helm-charts/db-monitoring
   ```

### Debugging Commands

```bash
# Check Helm release status
helm status db-monitoring -n observability

# View all resources created by Helm
kubectl get all -n observability -l app.kubernetes.io/managed-by=Helm

# Check configuration
kubectl get configmap -n observability adot-collector-config -o yaml

# Test connectivity
kubectl exec -n observability deployment/adot-collector -- wget -qO- http://mysql-instance-1:9104/metrics
```

## Cleanup

```bash
# Uninstall Helm release
helm uninstall db-monitoring -n observability

# Delete namespace
kubectl delete namespace observability

# Delete EKS cluster
eksctl delete cluster --name ${WORKSHOP_NAME}-eks --region ${AWS_REGION}

# Delete CloudFormation stacks
aws cloudformation delete-stack --stack-name ${WORKSHOP_NAME}-db
aws cloudformation delete-stack --stack-name ${WORKSHOP_NAME}-network

# Delete AMP workspace
aws amp delete-workspace --workspace-id ${AMP_WORKSPACE_ID}

# Delete AMG workspace (via AWS Console or CLI if available)
aws grafana delete-workspace --workspace-id ${AMG_WORKSPACE_ID}

# Delete IAM roles
# Delete ADOT Collector role
aws iam detach-role-policy \
  --role-name ${WORKSHOP_NAME}-adot-collector-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess
aws iam delete-role --role-name ${WORKSHOP_NAME}-adot-collector-role

# Delete Grafana role
aws iam detach-role-policy \
  --role-name ${WORKSHOP_NAME}-grafana-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusFullAccess
aws iam detach-role-policy \
  --role-name ${WORKSHOP_NAME}-grafana-role \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess
aws iam delete-role --role-name ${WORKSHOP_NAME}-grafana-role
```
