# Aurora EKS AMP Monitoring Infrastructure

This repository contains CloudFormation templates and Kubernetes manifests for deploying a complete monitoring infrastructure for Aurora databases using Amazon EKS and Amazon Managed Service for Prometheus (AMP).

## Architecture Overview

The infrastructure is split into four main components:

1. **Networking Stack**: VPC, subnets, NAT Gateway, and route tables
2. **EKS Stack**: Amazon EKS cluster with managed node groups
3. **Database Stack**: Aurora MySQL and PostgreSQL clusters
4. **Monitoring Stack**: AMP workspace, Grafana, and exporters

## Prerequisites

- AWS CLI configured with appropriate credentials
- `kubectl` installed and configured
- `aws-iam-authenticator` installed
- `helm` installed (version 3.x)
- `envsubst` installed for environment variable substitution

## Deployment Steps

### 0. Set Environment Variables

```bash
# Set the environment name to be used across all stacks
export ENV_NAME=aurora-eks-amp-monitoring
export AWS_REGION=ap-northeast-2

# Verify the variables
echo "Environment Name: $ENV_NAME"
echo "AWS Region: $AWS_REGION"
```

### 1. Deploy the Networking Stack

```bash
# Deploy the networking stack
aws cloudformation create-stack \
  --stack-name ${ENV_NAME}-network \
  --template-body file://networking-stack.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${ENV_NAME} \
    ParameterKey=VpcCidr,ParameterValue=10.0.0.0/16

# Wait for stack creation to complete
aws cloudformation wait stack-create-complete \
  --stack-name ${ENV_NAME}-network

# Validate stack outputs
aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-network \
  --query 'Stacks[0].Outputs'
```

### 2. Deploy the EKS Stack

```bash
# Get networking stack outputs
export VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
  --output text)

export PRIVATE_SUBNETS=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnets`].OutputValue' \
  --output text)

# Deploy the EKS stack
aws cloudformation create-stack \
  --stack-name ${ENV_NAME}-eks \
  --template-body file://eks-stack.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${ENV_NAME} \
    ParameterKey=VpcId,ParameterValue=$VPC_ID \
    ParameterKey=PrivateSubnets,ParameterValue=$PRIVATE_SUBNETS

# Wait for stack creation to complete
aws cloudformation wait stack-create-complete \
  --stack-name ${ENV_NAME}-eks

# Configure kubectl
aws eks update-kubeconfig \
  --name ${ENV_NAME}-eks \
  --region $AWS_REGION

# Validate EKS cluster
kubectl get nodes
```

### 3. Deploy the Database Stack

```bash
# Get networking stack outputs
export VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
  --output text)

export DATABASE_SUBNETS=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`DatabaseSubnets`].OutputValue' \
  --output text)

export PRIVATE_SUBNET_CIDRS=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnetCidrs`].OutputValue' \
  --output text)

# Deploy the database stack
aws cloudformation create-stack \
  --stack-name ${ENV_NAME}-db \
  --template-body file://database-stack.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${ENV_NAME} \
    ParameterKey=VpcId,ParameterValue=$VPC_ID \
    ParameterKey=DatabaseSubnets,ParameterValue=$DATABASE_SUBNETS \
    ParameterKey=PrivateSubnetCidrs,ParameterValue=$PRIVATE_SUBNET_CIDRS \
    ParameterKey=MySQLMasterUsername,ParameterValue=admin \
    ParameterKey=MySQLMasterPassword,ParameterValue=adminadmin \
    ParameterKey=PostgreSQLMasterUsername,ParameterValue=root \
    ParameterKey=PostgreSQLMasterPassword,ParameterValue=rootroot

# Wait for stack creation to complete
aws cloudformation wait stack-create-complete \
  --stack-name ${ENV_NAME}-db

# Validate database endpoints
aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-db \
  --query 'Stacks[0].Outputs'
```

### 4. Deploy the Monitoring Stack

```bash
# Create observability namespace
kubectl create namespace observability

# Get required parameters
export VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
  --output text)

export OIDC_PROVIDER_URL=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-eks \
  --query 'Stacks[0].Outputs[?OutputKey==`OIDCProviderUrl`].OutputValue' \
  --output text)

# Deploy the monitoring stack
aws cloudformation create-stack \
  --stack-name ${ENV_NAME}-monitoring \
  --template-body file://monitoring-stack.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${ENV_NAME} \
    ParameterKey=EksOidcProviderUrl,ParameterValue=$OIDC_PROVIDER_URL \
    ParameterKey=VpcId,ParameterValue=$VPC_ID \
    ParameterKey=Region,ParameterValue=$AWS_REGION

# Wait for stack creation to complete
aws cloudformation wait stack-create-complete \
  --stack-name ${ENV_NAME}-monitoring

# Validate monitoring stack outputs
aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-monitoring \
  --query 'Stacks[0].Outputs'
```

### 5. Deploy Kubernetes Components

#### 5.1 Install AWS Load Balancer Controller

```bash
# Add and update Helm repository
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Get Load Balancer Controller role ARN
export LB_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-eks \
  --query 'Stacks[0].Outputs[?OutputKey==`LoadBalancerControllerRoleArn`].OutputValue' \
  --output text)

# Install AWS Load Balancer Controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=${ENV_NAME}-eks \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$LB_ROLE_ARN

# Validate installation
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

#### 5.2 Deploy ADOT Collector

```bash
# Get required parameters
export AMP_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-monitoring \
  --query 'Stacks[0].Outputs[?OutputKey==`AdotCollectorServiceAccountRoleArn`].OutputValue' \
  --output text)

export AMP_ENDPOINT=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-monitoring \
  --query 'Stacks[0].Outputs[?OutputKey==`PrometheusEndpoint`].OutputValue' \
  --output text)

export AWS_REGION=$AWS_REGION

# Deploy ADOT Collector
envsubst < k8s/adot-collector.yaml | kubectl apply -f -

# Validate deployment
kubectl get pods -n observability -l app=adot-collector
kubectl logs -n observability -l app=adot-collector
```

#### 5.3 Deploy Grafana

```bash
# Get required parameters
export GRAFANA_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-monitoring \
  --query 'Stacks[0].Outputs[?OutputKey==`GrafanaServiceAccountRoleArn`].OutputValue' \
  --output text)

export GRAFANA_SG_ID=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-monitoring \
  --query 'Stacks[0].Outputs[?OutputKey==`GrafanaSecurityGroupId`].OutputValue' \
  --output text)

export AWS_REGION=$AWS_REGION
export AMP_ENDPOINT=$AMP_ENDPOINT

# Deploy Grafana
envsubst < k8s/grafana.yaml | kubectl apply -f -

# Validate deployment
kubectl get pods -n observability -l app=grafana
kubectl get svc -n observability grafana
```

#### 5.4 Deploy Database Exporters

```bash
# Get database endpoints
export MYSQL_ENDPOINT1=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-db \
  --query 'Stacks[0].Outputs[?OutputKey==`MySQLInstance1Endpoint`].OutputValue' \
  --output text)

export MYSQL_ENDPOINT2=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-db \
  --query 'Stacks[0].Outputs[?OutputKey==`MySQLInstance2Endpoint`].OutputValue' \
  --output text)

# Deploy MySQL exporters
export MYSQL_USER_B64=$(echo -n "admin" | base64)
export MYSQL_PASSWORD_B64=$(echo -n "adminadmin" | base64)
export MYSQL_USER=admin
export MYSQL_PASSWORD=adminadmin

envsubst < k8s/mysql-exporter.yaml | kubectl apply -f -

# Get PostgreSQL endpoints
export POSTGRESQL_ENDPOINT1=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-db \
  --query 'Stacks[0].Outputs[?OutputKey==`PostgreSQLInstance1Endpoint`].OutputValue' \
  --output text)

export POSTGRESQL_ENDPOINT2=$(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-db \
  --query 'Stacks[0].Outputs[?OutputKey==`PostgreSQLInstance2Endpoint`].OutputValue' \
  --output text)

# Deploy PostgreSQL exporters
export POSTGRESQL_USER_B64=$(echo -n "root" | base64)
export POSTGRESQL_PASSWORD_B64=$(echo -n "rootroot" | base64)
export POSTGRESQL_USER=root
export POSTGRESQL_PASSWORD=rootroot

envsubst < k8s/postgresql-exporter.yaml | kubectl apply -f -

# Validate exporters
kubectl get pods -n observability -l app=mysql-exporter-one
kubectl get pods -n observability -l app=mysql-exporter-two
kubectl get pods -n observability -l app=postgresql-exporter-one
kubectl get pods -n observability -l app=postgresql-exporter-two
```

## Validation Steps

### 1. Check Infrastructure Components

```bash
# Check EKS cluster
kubectl get nodes
kubectl get pods --all-namespaces

# Check Load Balancer Controller
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check ADOT Collector
kubectl get pods -n observability -l app=adot-collector
kubectl logs -n observability -l app=adot-collector

# Check Grafana
kubectl get pods -n observability -l app=grafana
kubectl get svc -n observability grafana

# Check Database Exporters
kubectl get pods -n observability -l app=mysql-exporter-one
kubectl get pods -n observability -l app=postgresql-exporter-one
```

### 2. Access Grafana Dashboard

1. Get the Grafana Load Balancer URL:
```bash
kubectl get svc -n observability grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

2. Open the URL in your browser
3. Log in with default credentials (admin/admin)
4. Change the password when prompted
5. Verify data sources are connected:
   - AMP
   - CloudWatch

## Troubleshooting

### Common Issues

1. **EKS Cluster Access**
```bash
# Refresh AWS credentials
aws sts get-caller-identity

# Update kubeconfig
aws eks update-kubeconfig --name ${ENV_NAME}-eks --region $AWS_REGION

# Check authentication
kubectl auth can-i get pods
```

2. **Database Connectivity**
```bash
# Check MySQL exporter logs
kubectl logs -n observability -l app=mysql-exporter-one

# Check PostgreSQL exporter logs
kubectl logs -n observability -l app=postgresql-exporter-one

# Verify security group rules
aws ec2 describe-security-groups --group-ids $(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-db \
  --query 'Stacks[0].Outputs[?OutputKey==`MySQLSecurityGroup`].OutputValue' \
  --output text)
```

3. **Metrics Collection**
```bash
# Check ADOT Collector logs
kubectl logs -n observability -l app=adot-collector

# Verify AMP workspace
aws amp describe-workspace --workspace-id $(aws cloudformation describe-stacks \
  --stack-name ${ENV_NAME}-monitoring \
  --query 'Stacks[0].Outputs[?OutputKey==`PrometheusWorkspaceId`].OutputValue' \
  --output text)
```

4. **Grafana Issues**
```bash
# Check Grafana pod logs
kubectl logs -n observability -l app=grafana

# Verify security group
aws ec2 describe-security-groups --group-ids $GRAFANA_SG_ID
```

## Cleanup

To delete all resources in reverse order:

```bash
# 1. Delete Kubernetes resources
kubectl delete -f k8s/postgresql-exporter.yaml
kubectl delete -f k8s/mysql-exporter.yaml
kubectl delete -f k8s/grafana.yaml
kubectl delete -f k8s/adot-collector.yaml
helm uninstall aws-load-balancer-controller -n kube-system

# 2. Delete CloudFormation stacks
aws cloudformation delete-stack --stack-name ${ENV_NAME}-monitoring
aws cloudformation delete-stack --stack-name ${ENV_NAME}-db
aws cloudformation delete-stack --stack-name ${ENV_NAME}-eks
aws cloudformation delete-stack --stack-name ${ENV_NAME}-network

# 3. Wait for stack deletion
aws cloudformation wait stack-delete-complete --stack-name ${ENV_NAME}-monitoring
aws cloudformation wait stack-delete-complete --stack-name ${ENV_NAME}-db
aws cloudformation wait stack-delete-complete --stack-name ${ENV_NAME}-eks
aws cloudformation wait stack-delete-complete --stack-name ${ENV_NAME}-network
```

## Security Best Practices

1. **Network Security**
   - Use private subnets for EKS nodes and databases
   - Implement network policies
   - Enable VPC flow logs

2. **Access Control**
   - Use IAM roles for service accounts (IRSA)
   - Implement least privilege principle
   - Rotate database credentials regularly

3. **Monitoring**
   - Enable CloudWatch logs
   - Set up alerts for security events
   - Monitor API activity with CloudTrail

4. **Data Protection**
   - Enable encryption at rest
   - Use SSL/TLS for database connections
   - Implement regular backups

## Cost Optimization

1. **Compute**
   - Use Spot Instances for non-critical workloads
   - Right-size EKS nodes
   - Implement cluster autoscaling

2. **Database**
   - Use appropriate instance sizes
   - Consider serverless Aurora for dev/test
   - Monitor and optimize query performance

3. **Monitoring**
   - Configure appropriate retention periods
   - Use metric filters effectively
   - Implement log aggregation

## Next Steps

1. **High Availability**
   - Deploy across multiple AZs
   - Implement disaster recovery
   - Set up cross-region replication

2. **Monitoring Enhancement**
   - Create custom dashboards
   - Set up alerting rules
   - Implement log aggregation

3. **Security Hardening**
   - Implement pod security policies
   - Set up AWS WAF
   - Enable AWS Shield 