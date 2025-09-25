#!/bin/bash

echo "🚀 Running SQL Server load test in EKS cluster..."

# Deploy the pod
kubectl apply -f sql-load-test-pod.yaml

# Wait for pod to be ready
echo "⏳ Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/sql-load-test -n observability --timeout=60s

# Copy the load test script to the pod
echo "📁 Copying load test script to pod..."
kubectl cp /Users/parkgg/Documents/db-monitoring-eks-amp/scripts/sql-server-load-test.py observability/sql-load-test:/tmp/

# Install dependencies and run the test
echo "🔧 Installing dependencies and running load test..."
kubectl exec -n observability sql-load-test -- bash -c "
apt-get update -qq && 
apt-get install -y -qq curl gnupg2 && 
curl -sSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null && 
echo 'deb [arch=amd64,arm64,armhf signed-by=/etc/apt/trusted.gpg.d/microsoft.gpg] https://packages.microsoft.com/debian/12/prod bookworm main' | tee /etc/apt/sources.list.d/mssql-release.list && 
apt-get update -qq && 
ACCEPT_EULA=Y apt-get install -y -qq msodbcsql17 unixodbc-dev && 
pip install -q pyodbc &&
cd /tmp &&
python sql-server-load-test.py --server \$SQLSERVER_ENDPOINT --username \$SQLSERVER_USERNAME --password \$SQLSERVER_PASSWORD --duration 300
"

echo "🧹 Cleaning up..."
kubectl delete pod sql-load-test -n observability