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
- AWS CLI installed and configured with appropriate credentials
- kubectl installed
- helm installed
- eksctl installed
- A terminal or command-line interface

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
    ParameterKey=DatabaseSubnets,ParameterValue=$DATABASE_SUBNETS \
    ParameterKey=PrivateSubnetCidrs,ParameterValue=$PRIVATE_SUBNET_CIDRS \
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
        id: $(echo $PRIVATE_SUBNETS | cut -d',' -f1)
      private-1:
        id: $(echo $PRIVATE_SUBNETS | cut -d',' -f2)
      private-2:
        id: $(echo $PRIVATE_SUBNETS | cut -d',' -f3)

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
export AMP_ENDPOINT="https://aps-workspaces.${AWS_REGION}.amazonaws.com/workspaces/${AMP_WORKSPACE_ID}"
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

In this module, we'll set up Amazon Managed Grafana (AMG) using the AWS CLI and Console.

### Step 1: Create an AMG workspace

```bash
# Create AMG workspace
aws grafana create-workspace \
  --name ${WORKSHOP_NAME}-grafana \
  --account-access-type CURRENT_ACCOUNT \
  --authentication-providers AWS_SSO \
  --permission-type SERVICE_MANAGED \
  --data-sources AMAZON_PROMETHEUS \
  --tags Name=${WORKSHOP_NAME}-grafana

# Get the workspace ID
export AMG_WORKSPACE_ID=$(aws grafana list-workspaces \
  --query 'workspaces[?name==`'${WORKSHOP_NAME}-grafana'`].id' \
  --output text)

echo "AMG Workspace ID: $AMG_WORKSPACE_ID"
```

### Step 2: Configure AMG workspace (AWS Console)

1. Open the AWS Console and navigate to Amazon Managed Grafana
2. Select the workspace you just created
3. Click on "Authentication" in the left sidebar
4. Under "AWS IAM Identity Center (successor to AWS SSO)", click "Configure user access"
5. Add yourself as an Admin user
6. Click "Save changes"

### Step 3: Configure AMP as a data source in AMG (AWS Console)

1. In the AMG workspace, click on "Data sources" in the left sidebar
2. Click "Add data source"
3. Select "Amazon Managed Service for Prometheus"
4. Configure the data source:
   - Name: AMP
   - Workspace: Select your AMP workspace
   - Region: Select your AWS region
5. Click "Save & test"

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
   - Set the MySQL instance variable to match your Aurora MySQL instances
   - Adjust time ranges as needed

### Step 3: Import PostgreSQL Dashboard

1. In Grafana, click on the "+" icon in the left sidebar and select "Import"
2. Enter dashboard ID `9628` (PostgreSQL Overview dashboard) or upload the JSON file if provided
3. Select "AMP" as the data source
4. Click "Import"
5. Customize the dashboard:
   - Set the PostgreSQL instance variable to match your Aurora PostgreSQL instances
   - Adjust time ranges as needed

### Step 4: Create a Custom Dashboard

1. Click on the "+" icon in the left sidebar and select "Dashboard"
2. Click "Add new panel"
3. Configure the panel:
   - Select "AMP" as the data source
   - Enter a PromQL query (e.g., `rate(mysql_global_status_questions[5m])` for MySQL query rate)
   - Set visualization type (e.g., Time series)
   - Configure panel options (title, description, etc.)
4. Click "Apply"
5. Add more panels as needed
6. Save the dashboard with a descriptive name

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
