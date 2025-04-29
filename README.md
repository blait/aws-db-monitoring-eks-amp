# AWS Workshop: Integrated Database Monitoring with EKS, AMP, and AMG

This workshop guides you through setting up a comprehensive monitoring solution for Aurora databases using Amazon EKS, Amazon Managed Service for Prometheus (AMP), and Amazon Managed Grafana (AMG).

## Workshop Modules

1. **Module 1**: Environment Setup
2. **Module 2**: Networking and Database Infrastructure
3. **Module 3**: EKS Cluster Setup
4. **Module 4**: Amazon Managed Prometheus Setup
5. **Module 5**: Amazon Managed Grafana Setup
6. **Module 6**: ADOT Collector and Database Exporters
7. **Module 7**: Dashboard and Alerting Configuration
8. **Module 8**: Monitoring Best Practices

## Prerequisites

Before starting this workshop, ensure you have:

- An AWS account with administrator access
- AWS CLI (version 2.0.0 or later) installed and configured with appropriate credentials
- kubectl (version 1.23.0 or later) installed
- helm (version 3.8.0 or later) installed
- eksctl (version 0.123.0 or later) installed

### Installation Guide

#### AWS CLI
```bash
# macOS
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Windows
# Download and run the installer from: https://awscli.amazonaws.com/AWSCLIV2.msi

# Verify installation
aws --version
```

#### kubectl
```bash
# macOS
brew install kubectl
# OR
curl -LO "https://dl.k8s.io/release/v1.23.0/bin/darwin/amd64/kubectl"
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl

# Linux
curl -LO "https://dl.k8s.io/release/v1.23.0/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/kubectl

# Windows
# Download from: https://dl.k8s.io/release/v1.23.0/bin/windows/amd64/kubectl.exe
# Add to PATH

# Verify installation
kubectl version --client
```

#### Helm
```bash
# macOS
brew install helm
# OR
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Linux
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Windows
# Download from: https://get.helm.sh/helm-v3.8.0-windows-amd64.zip
# Extract and add to PATH

# Verify installation
helm version
```

#### eksctl
```bash
# macOS
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl
# OR
curl --silent --location "https://github.com/weaveworks/eksctl/releases/download/v0.123.0/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# Linux
curl --silent --location "https://github.com/weaveworks/eksctl/releases/download/v0.123.0/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# Windows
# Download from: https://github.com/weaveworks/eksctl/releases/download/v0.123.0/eksctl_Windows_amd64.zip
# Extract and add to PATH

# Verify installation
eksctl version
```

## Module 1: Environment Setup

### Step 1: Set up environment variables

```bash
# Set environment variables
export WORKSHOP_NAME=db-monitoring-workshop
export AWS_REGION=$(aws configure get region)
export VPC_CIDR="10.0.0.0/16"
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Verify environment setup
echo "Workshop Name: $WORKSHOP_NAME"
echo "AWS Region: $AWS_REGION"
echo "AWS Account ID: $ACCOUNT_ID"
echo "Using VPC CIDR: $VPC_CIDR"
```

### Step 2: Clone the workshop repository (if applicable)

If you're following along with a provided repository, clone it now. Otherwise, create the necessary files as we go through the workshop.

## Module 2: Networking and Database Infrastructure

In this module, we'll use CloudFormation to set up the networking and database infrastructure.

### Step 1: Deploy the Networking Stack

```bash
aws cloudformation create-stack \
  --stack-name ${WORKSHOP_NAME}-network \
  --template-body file://networking-stack.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${WORKSHOP_NAME} \
    ParameterKey=VpcCidr,ParameterValue=${VPC_CIDR} \
  --capabilities CAPABILITY_IAM

# Wait for stack creation to complete
aws cloudformation wait stack-create-complete \
  --stack-name ${WORKSHOP_NAME}-network

# Validate stack outputs
aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-network \
  --query 'Stacks[0].Outputs'
```

### Step 2: Store networking outputs as environment variables

```bash
export VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-network \
  --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' \
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

echo "VPC ID: $VPC_ID"
echo "Private Subnets: $PRIVATE_SUBNETS"
echo "Database Subnets: $DATABASE_SUBNETS"
echo "Private Subnet CIDRs: $PRIVATE_SUBNET_CIDRS"
```

### Step 3: Deploy the Database Stack

```bash
aws cloudformation create-stack \
  --stack-name ${WORKSHOP_NAME}-db \
  --template-body file://database-stack.yaml \
  --parameters \
    ParameterKey=EnvironmentName,ParameterValue=${WORKSHOP_NAME} \
    ParameterKey=VpcId,ParameterValue=$VPC_ID \
    ParameterKey=DatabaseSubnets,ParameterValue=\"$DATABASE_SUBNETS\" \
    ParameterKey=PrivateSubnetCidrs,ParameterValue=\"$PRIVATE_SUBNET_CIDRS\" \
    ParameterKey=MySQLMasterUsername,ParameterValue=admin \
    ParameterKey=MySQLMasterPassword,ParameterValue=adminadmin \
    ParameterKey=PostgreSQLMasterUsername,ParameterValue=root \
    ParameterKey=PostgreSQLMasterPassword,ParameterValue=rootroot

# Wait for stack creation to complete (this may take 15-20 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name ${WORKSHOP_NAME}-db

# Validate database endpoints
aws cloudformation describe-stacks \
  --stack-name ${WORKSHOP_NAME}-db \
  --query 'Stacks[0].Outputs'
```

### Step 4: Store database endpoints as environment variables

```bash
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

echo "MySQL Endpoint 1: $MYSQL_ENDPOINT1"
echo "MySQL Endpoint 2: $MYSQL_ENDPOINT2"
echo "PostgreSQL Endpoint 1: $POSTGRESQL_ENDPOINT1"
echo "PostgreSQL Endpoint 2: $POSTGRESQL_ENDPOINT2"
```

## Module 3: EKS Cluster Setup

In this module, we'll set up an Amazon EKS cluster using eksctl and the AWS CLI.

### Step 1: Create an EKS cluster using eksctl

First, extract the subnet IDs into separate environment variables:

```bash
# Extract individual subnet IDs from the comma-separated list
export PRIVATE_SUBNET_1=$(echo $PRIVATE_SUBNETS | cut -d',' -f1)
export PRIVATE_SUBNET_2=$(echo $PRIVATE_SUBNETS | cut -d',' -f2)
export PRIVATE_SUBNET_3=$(echo $PRIVATE_SUBNETS | cut -d',' -f3)

# Verify the subnet IDs
echo "Private Subnet 1: $PRIVATE_SUBNET_1"
echo "Private Subnet 2: $PRIVATE_SUBNET_2"
echo "Private Subnet 3: $PRIVATE_SUBNET_3"
```

Create a file named `eks-cluster.yaml` with the following content:

```yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${WORKSHOP_NAME}-eks
  region: ${AWS_REGION}
  version: "1.31"

vpc:
  id: ${VPC_ID}
  subnets:
    private:
      private-0:
        id: ${PRIVATE_SUBNET_1}
      private-1:
        id: ${PRIVATE_SUBNET_2}
      private-2:
        id: ${PRIVATE_SUBNET_3}

managedNodeGroups:
  - name: ${WORKSHOP_NAME}-ng
    instanceType: m5.xlarge
    desiredCapacity: 3
    minSize: 3
    maxSize: 5
    privateNetworking: true
    labels:
      role: worker
    tags:
      nodegroup-role: worker
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        ebs: true
        albIngress: true
        cloudWatch: true
        externalDNS: true

cloudWatch:
  clusterLogging:
    enableTypes: ["*"]
```

Now create the cluster:

```bash
# Create the EKS cluster (this will take 15-20 minutes)
envsubst < eks-cluster.yaml > eks-cluster-resolved.yaml
eksctl create cluster -f eks-cluster-resolved.yaml

# Verify the cluster is ready
kubectl get nodes
```

### Step 2: Enable OIDC provider for the EKS cluster

```bash
# Check if OIDC provider exists
eksctl utils associate-iam-oidc-provider \
  --region $AWS_REGION \
  --cluster ${WORKSHOP_NAME}-eks \
  --approve

# Get the OIDC provider URL
export OIDC_PROVIDER=$(aws eks describe-cluster \
  --name ${WORKSHOP_NAME}-eks \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed -e "s/^https:\/\///")

echo "OIDC Provider: $OIDC_PROVIDER"
```

### Step 3: Create an observability namespace

```bash
kubectl create namespace observability
```

## Module 4: Amazon Managed Prometheus Setup

In this module, we'll set up Amazon Managed Prometheus (AMP) using the AWS CLI.

### Step 1: Create an AMP workspace

```bash
# Create AMP workspace
aws amp create-workspace \
  --alias ${WORKSHOP_NAME}-amp \
  --tags Name=${WORKSHOP_NAME}-amp

# Get the workspace ID
export AMP_WORKSPACE_ID=$(aws amp list-workspaces \
  --alias ${WORKSHOP_NAME}-amp \
  --query 'workspaces[0].workspaceId' \
  --output text)

echo "AMP Workspace ID: $AMP_WORKSPACE_ID"

# Get the AMP endpoint
# Note: The correct endpoint format is crucial for the ADOT collector to work properly. If the endpoint doesn't work, find the "remote write URL" endpoint in the AWS Console (AMP)
export AMP_ENDPOINT="https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}/api/v1/remote_write"
echo "AMP Endpoint: $AMP_ENDPOINT"

```

### Step 2: Create IAM role for ADOT Collector

```bash
# Create IAM policy document for ADOT Collector
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

# Create IAM role for ADOT Collector
aws iam create-role \
  --role-name ${WORKSHOP_NAME}-adot-collector-role \
  --assume-role-policy-document file://adot-trust-policy.json

# Attach AMP remote write policy to the role
aws iam attach-role-policy \
  --role-name ${WORKSHOP_NAME}-adot-collector-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess

# Get the role ARN
export ADOT_ROLE_ARN=$(aws iam get-role \
  --role-name ${WORKSHOP_NAME}-adot-collector-role \
  --query 'Role.Arn' \
  --output text)

echo "ADOT Collector Role ARN: $ADOT_ROLE_ARN"
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
aws iam attach-role-policy \
  --role-name ${WORKSHOP_NAME}-grafana-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusFullAccess

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
3. Enter a workspace name: `${WORKSHOP_NAME}-grafana` (e.g., "db-monitoring-workshop-grafana")
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

## Module 6: ADOT Collector and Database Exporters

In this module, we'll deploy the AWS Distro for OpenTelemetry (ADOT) Collector and database exporters.

### Step 1: Create ADOT Collector configuration

Create a file named `adot-collector.yaml` with the following content:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  namespace: observability
  name: adot-collector
  annotations:
    eks.amazonaws.com/role-arn: ${ADOT_ROLE_ARN}

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: adot-collector
rules:
- apiGroups: [""]
  resources:
  - nodes
  - nodes/proxy
  - nodes/metrics
  - services
  - endpoints
  - pods
  verbs: ["get", "list", "watch"]
- apiGroups:
  - extensions
  resources:
  - ingresses
  verbs: ["get", "list", "watch"]
- nonResourceURLs: ["/metrics"]
  verbs: ["get"]

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: adot-collector
subjects:
- kind: ServiceAccount
  namespace: observability
  name: adot-collector
roleRef:
  kind: ClusterRole
  name: adot-collector
  apiGroup: rbac.authorization.k8s.io

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: adot-collector
  namespace: observability
data:
  adot-collector-config.yaml: |
    receivers:
      prometheus:
        config:
          global:
            scrape_interval: 30s
            scrape_timeout: 10s

          scrape_configs:
          - job_name: kubernetes-apiservers
            bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
            kubernetes_sd_configs:
            - role: endpoints
            relabel_configs:
            - action: keep
              regex: default;kubernetes;https
              source_labels:
              - __meta_kubernetes_namespace
              - __meta_kubernetes_service_name
              - __meta_kubernetes_endpoint_port_name
            scheme: https
            tls_config:
              ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              insecure_skip_verify: true

          - job_name: kubernetes-nodes
            bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
            kubernetes_sd_configs:
            - role: node
            relabel_configs:
            - action: labelmap
              regex: __meta_kubernetes_node_label_(.+)
            - replacement: kubernetes.default.svc:443
              target_label: __address__
            - regex: (.+)
              replacement: /api/v1/nodes/$1/proxy/metrics
              source_labels:
              - __meta_kubernetes_node_name
              target_label: __metrics_path__
            scheme: https
            tls_config:
              ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              insecure_skip_verify: true

          - job_name: kubernetes-nodes-cadvisor
            bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
            kubernetes_sd_configs:
            - role: node
            relabel_configs:
            - action: labelmap
              regex: __meta_kubernetes_node_label_(.+)
            - replacement: kubernetes.default.svc:443
              target_label: __address__
            - regex: (.+)
              replacement: /api/v1/nodes/$1/proxy/metrics/cadvisor
              source_labels:
              - __meta_kubernetes_node_name
              target_label: __metrics_path__
            scheme: https
            tls_config:
              ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              insecure_skip_verify: true

          - job_name: kubernetes-service-endpoints
            kubernetes_sd_configs:
            - role: endpoints
            relabel_configs:
            - action: keep
              regex: true
              source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_scrape
            - action: replace
              regex: (https?)
              source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_scheme
              target_label: __scheme__
            - action: replace
              regex: (.+)
              source_labels:
              - __meta_kubernetes_service_annotation_prometheus_io_path
              target_label: __metrics_path__
            - action: replace
              regex: ([^:]+)(?::\d+)?;(\d+)
              replacement: $1:$2
              source_labels:
              - __address__
              - __meta_kubernetes_service_annotation_prometheus_io_port
              target_label: __address__
            - action: labelmap
              regex: __meta_kubernetes_service_label_(.+)
            - action: replace
              source_labels:
              - __meta_kubernetes_namespace
              target_label: kubernetes_namespace
            - action: replace
              source_labels:
              - __meta_kubernetes_service_name
              target_label: kubernetes_name

    exporters:
      prometheusremotewrite:
        endpoint: ${AMP_ENDPOINT}
        auth:
          authenticator: sigv4auth

    extensions:
      health_check:
      sigv4auth:
        region: ${AWS_REGION}

    service:
      extensions: [health_check, sigv4auth]
      pipelines:
        metrics:
          receivers: [prometheus]
          exporters: [prometheusremotewrite]

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: adot-collector
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: adot-collector
  template:
    metadata:
      labels:
        app: adot-collector
    spec:
      serviceAccountName: adot-collector
      containers:
      - name: adot-collector
        image: public.ecr.aws/aws-observability/aws-otel-collector:v0.39.1
        args:
        - --config=/conf/adot-collector-config.yaml
        resources:
          requests:
            cpu: "250m"
            memory: "500Mi"
          limits:
            cpu: "250m"
            memory: "500Mi"
        volumeMounts:
        - name: config
          mountPath: /conf
          readOnly: true
        livenessProbe:
          failureThreshold: 3
          httpGet:
            path: /
            port: 13133
            scheme: HTTP
          periodSeconds: 10
          successThreshold: 1
          timeoutSeconds: 1
      volumes:
      - name: config
        configMap:
          name: adot-collector
```

### Step 2: Deploy ADOT Collector

```bash
# Deploy ADOT Collector
envsubst < adot-collector.yaml | kubectl apply -f -

# Verify deployment
kubectl get pods -n observability -l app=adot-collector
kubectl logs -n observability -l app=adot-collector
```

### Step 3: Create MySQL exporter configuration

Create a file named `mysql-exporter.yaml` with the following content:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mysql-exporter-secret
  namespace: observability
type: Opaque
data:
  username: YWRtaW4=  # admin in base64
  password: YWRtaW5hZG1pbg==  # adminadmin in base64

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql-exporter-one
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql-exporter-one
  template:
    metadata:
      labels:
        app: mysql-exporter-one
    spec:
      containers:
        - name: mysql-exporter
          image: prom/mysqld-exporter:v0.14.0
          args:
            - --collect.info_schema.tables
            - --collect.info_schema.innodb_metrics
            - --collect.global_status
            - --collect.global_variables
            - --collect.slave_status
            - --collect.info_schema.processlist
          ports:
            - containerPort: 9104
          env:
            - name: DATA_SOURCE_NAME
              value: "admin:adminadmin@(${MYSQL_ENDPOINT1}:3306)/"
          livenessProbe:
            httpGet:
              path: /metrics
              port: 9104
            initialDelaySeconds: 10
            timeoutSeconds: 5

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql-exporter-two
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql-exporter-two
  template:
    metadata:
      labels:
        app: mysql-exporter-two
    spec:
      containers:
        - name: mysql-exporter
          image: prom/mysqld-exporter:v0.14.0
          args:
            - --collect.info_schema.tables
            - --collect.info_schema.innodb_metrics
            - --collect.global_status
            - --collect.global_variables
            - --collect.slave_status
            - --collect.info_schema.processlist
          ports:
            - containerPort: 9104
          env:
            - name: DATA_SOURCE_NAME
              value: "admin:adminadmin@(${MYSQL_ENDPOINT2}:3306)/"
          livenessProbe:
            httpGet:
              path: /metrics
              port: 9104
            initialDelaySeconds: 10
            timeoutSeconds: 5

---
apiVersion: v1
kind: Service
metadata:
  name: mysql-exporter-one
  namespace: observability
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9104"
spec:
  selector:
    app: mysql-exporter-one
  ports:
    - port: 9104
      targetPort: 9104

---
apiVersion: v1
kind: Service
metadata:
  name: mysql-exporter-two
  namespace: observability
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9104"
spec:
  selector:
    app: mysql-exporter-two
  ports:
    - port: 9104
      targetPort: 9104
```

### Step 4: Create PostgreSQL exporter configuration

Create a file named `postgresql-exporter.yaml` with the following content:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-exporter-secret
  namespace: observability
type: Opaque
data:
  username: cm9vdA==  # root in base64
  password: cm9vdHJvb3Q=  # rootroot in base64

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql-exporter-one
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresql-exporter-one
  template:
    metadata:
      labels:
        app: postgresql-exporter-one
    spec:
      containers:
        - name: postgresql-exporter
          image: wrouesnel/postgres_exporter:v0.10.1
          ports:
            - containerPort: 9187
          env:
            - name: DATA_SOURCE_NAME
              value: "postgresql://root:rootroot@${POSTGRESQL_ENDPOINT1}:5432/postgres?sslmode=disable"
          livenessProbe:
            httpGet:
              path: /metrics
              port: 9187
            initialDelaySeconds: 10
            timeoutSeconds: 5

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql-exporter-two
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgresql-exporter-two
  template:
    metadata:
      labels:
        app: postgresql-exporter-two
    spec:
      containers:
        - name: postgresql-exporter
          image: wrouesnel/postgres_exporter:v0.10.1
          ports:
            - containerPort: 9187
          env:
            - name: DATA_SOURCE_NAME
              value: "postgresql://root:rootroot@${POSTGRESQL_ENDPOINT2}:5432/postgres?sslmode=disable"
          livenessProbe:
            httpGet:
              path: /metrics
              port: 9187
            initialDelaySeconds: 10
            timeoutSeconds: 5

---
apiVersion: v1
kind: Service
metadata:
  name: postgresql-exporter-one
  namespace: observability
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9187"
spec:
  selector:
    app: postgresql-exporter-one
  ports:
    - port: 9187
      targetPort: 9187

---
apiVersion: v1
kind: Service
metadata:
  name: postgresql-exporter-two
  namespace: observability
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9187"
spec:
  selector:
    app: postgresql-exporter-two
  ports:
    - port: 9187
      targetPort: 9187
```

### Step 5: Deploy database exporters

```bash
# Deploy MySQL exporters
envsubst < mysql-exporter.yaml | kubectl apply -f -

# Deploy PostgreSQL exporters
envsubst < postgresql-exporter.yaml | kubectl apply -f -

# Verify deployments
kubectl get pods -n observability -l app=mysql-exporter-one
kubectl get pods -n observability -l app=mysql-exporter-two
kubectl get pods -n observability -l app=postgresql-exporter-one
kubectl get pods -n observability -l app=postgresql-exporter-two
```

## Module 7: Dashboard and Alerting Configuration

In this module, we'll configure dashboards and alerts in Amazon Managed Grafana.

### Step 1: Access Amazon Managed Grafana

1. Navigate to the Amazon Managed Grafana console
2. Select your workspace
3. Click on "Grafana workspace URL" to open the Grafana UI
4. Log in with your AWS SSO credentials

### Step 2: Import MySQL Dashboard

1. In Grafana, click on the "+" icon in the left sidebar and select "Import"
2. Enter dashboard ID `7362` (MySQL Overview dashboard) or upload the JSON file if provided
3. Select "AMP" as the data source
4. Click "Import"
5. Customize the dashboard:
   - Set the MySQL instance variable to match your Aurora MySQL instances (e.g., `mysql-exporter-one.observability.svc.cluster.local:9104`)
   - Adjust time ranges as needed

### Step 3: Import PostgreSQL Dashboard

1. In Grafana, click on the "+" icon in the left sidebar and select "Import"
2. Enter dashboard ID `9628` (PostgreSQL Overview dashboard) or upload the JSON file if provided
3. Select "AMP" as the data source
4. Click "Import"
5. Customize the dashboard:
   - Set the PostgreSQL instance variable to match your Aurora PostgreSQL instances (e.g., `postgresql-exporter-one.observability.svc.cluster.local:9187`)
   - Adjust time ranges as needed

### Step 4: Create a Custom Dashboard for Key Database Metrics

1. Click on the "+" icon in the left sidebar and select "Dashboard"
2. Click "Add new panel"

#### For MySQL Key Metrics:

3. Create a panel for MySQL Connections:
   - Select "AMP" as the data source
   - Enter PromQL query: `mysql_global_status_threads_connected{job="mysql-exporters"}`
   - Set visualization type: "Stat" or "Time series"
   - Set panel title: "MySQL Active Connections"
   - Click "Apply"

4. Create a panel for MySQL Query Rate:
   - Click "Add panel"
   - Select "AMP" as the data source
   - Enter PromQL query: `rate(mysql_global_status_questions{job="mysql-exporters"}[5m])`
   - Set visualization type: "Time series"
   - Set panel title: "MySQL Query Rate (5m avg)"
   - Click "Apply"

5. Create a panel for MySQL Buffer Pool Usage:
   - Click "Add panel"
   - Select "AMP" as the data source
   - Enter PromQL query: `mysql_global_status_innodb_buffer_pool_pages_free{job="mysql-exporters"} / mysql_global_status_innodb_buffer_pool_pages_total{job="mysql-exporters"} * 100`
   - Set visualization type: "Gauge"
   - Set panel title: "MySQL Buffer Pool Free (%)"
   - Set thresholds: 20 (red), 40 (yellow), 60 (green)
   - Click "Apply"

#### For PostgreSQL Key Metrics:

6. Create a panel for PostgreSQL Connections:
   - Click "Add panel"
   - Select "AMP" as the data source
   - Enter PromQL query: `pg_stat_activity_count{job="postgresql-exporters"}`
   - Set visualization type: "Stat" or "Time series"
   - Set panel title: "PostgreSQL Active Connections"
   - Click "Apply"

7. Create a panel for PostgreSQL Transaction Rate:
   - Click "Add panel"
   - Select "AMP" as the data source
   - Enter PromQL query: `rate(pg_stat_database_xact_commit{job="postgresql-exporters"}[5m]) + rate(pg_stat_database_xact_rollback{job="postgresql-exporters"}[5m])`
   - Set visualization type: "Time series"
   - Set panel title: "PostgreSQL Transaction Rate (5m avg)"
   - Click "Apply"

8. Create a panel for PostgreSQL Cache Hit Ratio:
   - Click "Add panel"
   - Select "AMP" as the data source
   - Enter PromQL query: `pg_stat_database_blks_hit{job="postgresql-exporters"} / (pg_stat_database_blks_hit{job="postgresql-exporters"} + pg_stat_database_blks_read{job="postgresql-exporters"}) * 100`
   - Set visualization type: "Gauge"
   - Set panel title: "PostgreSQL Cache Hit Ratio (%)"
   - Set thresholds: 80 (red), 90 (yellow), 95 (green)
   - Click "Apply"

9. Organize your panels into rows:
   - Click "Add panel" then "Add a new row"
   - Name the row "MySQL Metrics"
   - Drag MySQL panels under this row
   - Repeat for PostgreSQL metrics

10. Add a dashboard description:
    - Click the gear icon in the top right
    - Add a description explaining the dashboard purpose and metrics
    - Set appropriate refresh interval (e.g., 30s or 1m)

11. Save the dashboard with a descriptive name like "Aurora Database Overview"

### Step 5: Create Alert Rules for Critical Metrics

1. Navigate to the "Alerting" section in the left sidebar
2. Click "Create alert rule"

### Step 5: Set Up Alerting

1. Navigate to the "Alerting" section in the left sidebar
2. Click "Create alert rule"
3. Configure the alert:
   - Name: "High MySQL Connections"
   - Query: `mysql_global_status_threads_connected > 100`
   - Condition: When value is above 100 for 5 minutes
   - Evaluation interval: 1m
4. Add labels and annotations
5. Create a notification policy:
   - Go to "Notification policies"
   - Create a new policy
   - Configure notification channels (e.g., email, Slack)
6. Save the alert rule

## Module 8: Monitoring Best Practices

In this module, we'll cover best practices for monitoring Aurora databases with Prometheus and Grafana.

### Database Monitoring Best Practices

#### Key Metrics to Monitor for MySQL

1. **Connection Metrics**
   - `mysql_global_status_threads_connected`: Current number of client connections
   - `mysql_global_status_max_used_connections`: Maximum number of connections used simultaneously
   - `mysql_global_status_threads_running`: Number of threads that are not sleeping

2. **Query Performance**
   - `mysql_global_status_questions`: Number of statements executed by the server
   - `mysql_global_status_slow_queries`: Number of queries that took more than long_query_time seconds
   - `mysql_global_status_queries`: Number of statements executed by the server

3. **Buffer Pool Metrics**
   - `mysql_global_status_innodb_buffer_pool_pages_total`: Total size of buffer pool in pages
   - `mysql_global_status_innodb_buffer_pool_pages_free`: Free pages in the buffer pool
   - `mysql_global_status_innodb_buffer_pool_read_requests`: Number of logical read requests

4. **InnoDB Metrics**
   - `mysql_global_status_innodb_row_lock_time`: Total time spent in acquiring row locks
   - `mysql_global_status_innodb_row_lock_waits`: Number of times a row lock had to be waited for
   - `mysql_global_status_innodb_data_reads`: Number of data reads

#### Key Metrics to Monitor for PostgreSQL

1. **Connection Metrics**
   - `pg_stat_activity_count`: Number of active connections
   - `pg_stat_database_numbackends`: Number of backends currently connected to this database

2. **Transaction Metrics**
   - `pg_stat_database_xact_commit`: Number of transactions committed
   - `pg_stat_database_xact_rollback`: Number of transactions rolled back

3. **Query Performance**
   - `pg_stat_database_tup_returned`: Number of rows returned by queries
   - `pg_stat_database_tup_fetched`: Number of rows fetched by queries
   - `pg_stat_database_tup_inserted`: Number of rows inserted

4. **Buffer Metrics**
   - `pg_stat_bgwriter_buffers_alloc`: Number of buffers allocated
   - `pg_stat_bgwriter_buffers_clean`: Number of buffers written by the background writer
   - `pg_stat_bgwriter_buffers_backend`: Number of buffers written directly by a backend

### Alerting Best Practices

1. **Avoid Alert Fatigue**
   - Set appropriate thresholds based on historical data
   - Use time-based conditions to avoid alerting on transient spikes
   - Implement alert grouping and routing to reduce noise

2. **Create Actionable Alerts**
   - Include clear information about what happened
   - Provide context about the impact
   - Include links to relevant dashboards or runbooks
   - Suggest potential remediation steps

3. **Implement Alert Severity Levels**
   - Critical: Immediate action required (e.g., database down)
   - Warning: Attention needed soon (e.g., high connection count)
   - Info: No immediate action required (e.g., backup completed)

### Dashboard Design Best Practices

1. **Information Hierarchy**
   - Place most important metrics at the top
   - Group related metrics together
   - Use consistent layouts across dashboards

2. **Visual Clarity**
   - Use appropriate visualizations for each metric type
   - Apply consistent color schemes
   - Include units and clear labels
   - Add descriptions to panels

3. **Dashboard Organization**
   - Create overview dashboards for high-level monitoring
   - Create detailed dashboards for troubleshooting
   - Use template variables for filtering

## Cleanup

When you're done with the workshop, follow these steps to clean up the resources:

```bash
# 1. Delete database exporters
kubectl delete -f mysql-exporter.yaml
kubectl delete -f postgresql-exporter.yaml

# 2. Delete ADOT Collector
kubectl delete -f adot-collector.yaml

# 3. Delete observability namespace
kubectl delete namespace observability

# 4. Delete EKS cluster
eksctl delete cluster --name ${WORKSHOP_NAME}-eks --region ${AWS_REGION}

# 5. Delete AMG workspace
aws grafana delete-workspace --workspace-id ${AMG_WORKSPACE_ID}

# 6. Delete AMP workspace
aws amp delete-workspace --workspace-id ${AMP_WORKSPACE_ID}

# 7. Delete IAM role for ADOT Collector
aws iam detach-role-policy \
  --role-name ${WORKSHOP_NAME}-adot-collector-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess

aws iam delete-role --role-name ${WORKSHOP_NAME}-adot-collector-role

# 8. Delete CloudFormation stacks
aws cloudformation delete-stack --stack-name ${WORKSHOP_NAME}-db
aws cloudformation wait stack-delete-complete --stack-name ${WORKSHOP_NAME}-db

aws cloudformation delete-stack --stack-name ${WORKSHOP_NAME}-network
aws cloudformation wait stack-delete-complete --stack-name ${WORKSHOP_NAME}-network
```

## Understanding the Observability Architecture

This section explains how the different components of our observability stack work together to provide comprehensive monitoring for Aurora databases.

### Architecture Overview

The observability architecture consists of several key components that work together:

1. **Amazon EKS (Elastic Kubernetes Service)** - The foundation infrastructure
2. **AWS Distro for OpenTelemetry (ADOT)** - The collector and processor
3. **Amazon Managed Service for Prometheus (AMP)** - The metrics storage backend
4. **Amazon Managed Grafana (AMG)** - The visualization and alerting frontend
5. **Database Exporters** - The metrics collectors for Aurora databases

Here's how data flows through the system:

```
Aurora Databases → Database Exporters → ADOT Collector → Amazon Managed Prometheus → Amazon Managed Grafana
```

### Component Roles and Locations

#### Amazon EKS
- **Location**: AWS Cloud (managed by AWS)
- **Role**: 
  - Provides the Kubernetes infrastructure where monitoring components run
  - Manages the compute resources, networking, and security
  - Hosts the ADOT Collector and database exporters
  - Enables scalable, containerized deployment of monitoring components

#### AWS Distro for OpenTelemetry (ADOT)
- **Location**: Runs as pods within the EKS cluster in the `observability` namespace
- **Role**:
  - Collects metrics from various sources within the Kubernetes cluster
  - Scrapes metrics from database exporters using Prometheus receiver
  - Processes and transforms metrics as needed
  - Forwards metrics to Amazon Managed Prometheus using AWS Sigv4 authentication
  - Acts as the central collection point for all observability data

#### Amazon Managed Service for Prometheus (AMP)
- **Location**: Fully managed AWS service (outside the EKS cluster)
- **Role**:
  - Stores all metrics data in a scalable, highly available time-series database
  - Provides PromQL query capabilities for metrics analysis
  - Handles long-term storage and retention of metrics
  - Eliminates the need to manage Prometheus servers yourself

#### Amazon Managed Grafana (AMG)
- **Location**: Fully managed AWS service (outside the EKS cluster)
- **Role**:
  - Provides visualization dashboards for metrics
  - Connects to AMP as a data source
  - Enables creation of custom dashboards and panels
  - Implements alerting based on metric thresholds
  - Offers a user-friendly interface for monitoring and analysis

#### Database Exporters
- **Location**: Run as pods within the EKS cluster in the `observability` namespace
- **Role**:
  - Connect to Aurora MySQL and PostgreSQL databases
  - Extract performance metrics and statistics
  - Convert database metrics into Prometheus format
  - Expose metrics endpoints for ADOT to scrape
  - Provide specialized metrics collection for each database type

### How It All Works Together

1. **Metrics Collection**:
   - Database exporters connect to Aurora databases and collect metrics
   - Exporters expose these metrics on HTTP endpoints in Prometheus format
   - ADOT Collector discovers these endpoints through Kubernetes service discovery
   - ADOT scrapes metrics from the exporters at regular intervals (30s by default)

2. **Metrics Processing and Storage**:
   - ADOT processes the collected metrics (adding metadata, filtering, etc.)
   - ADOT authenticates with AMP using AWS IAM roles and SigV4 signing
   - ADOT forwards metrics to AMP using Prometheus remote write protocol
   - AMP stores the metrics in a scalable, highly available time-series database

3. **Visualization and Alerting**:
   - AMG connects to AMP as a data source using AWS IAM authentication
   - Users create dashboards in AMG to visualize metrics from AMP
   - AMG executes PromQL queries against AMP to retrieve metrics
   - Alerts are configured in AMG based on metric thresholds
   - When alert conditions are met, notifications are sent via configured channels

4. **Security and IAM Integration**:
   - EKS OIDC provider enables IAM roles for service accounts
   - ADOT uses IAM roles to authenticate with AMP
   - AMG uses IAM/SSO for user authentication and authorization
   - All communication between components uses TLS encryption

This architecture provides several benefits:
- **Fully managed services** reduce operational overhead
- **Scalability** to handle growing metrics volume
- **High availability** with AWS managed services
- **Security** through IAM integration and encryption
- **Comprehensive monitoring** of Aurora databases with specialized exporters

## Conclusion

In this workshop, you've learned how to:

1. Set up a complete monitoring infrastructure for Aurora databases using Amazon EKS, AMP, and AMG
2. Deploy and configure ADOT Collector to collect metrics
3. Set up database exporters for MySQL and PostgreSQL
4. Create dashboards and alerts in Grafana
5. Apply monitoring best practices

This architecture provides a scalable, managed solution for monitoring your Aurora databases with minimal operational overhead. You can extend this solution by:

1. Adding more exporters for other database types
2. Creating custom dashboards for specific use cases
3. Implementing automated remediation for common issues
4. Integrating with other AWS services like CloudWatch and X-Ray

For more information, refer to the following resources:

- [Amazon Managed Service for Prometheus Documentation](https://docs.aws.amazon.com/prometheus/)
- [Amazon Managed Grafana Documentation](https://docs.aws.amazon.com/grafana/)
- [AWS Distro for OpenTelemetry Documentation](https://aws-otel.github.io/)
- [Amazon Aurora Documentation](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/)
