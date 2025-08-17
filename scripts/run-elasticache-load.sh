#!/bin/bash

# ElastiCache Load Generator Runner Script
# This script sets up and runs the ElastiCache load generator

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Default ElastiCache configuration (update these values)
DEFAULT_ELASTICACHE_ENDPOINT="integrated-db-monitoring-valkey.3yzzj1.clustercfg.apn2.cache.amazonaws.com"
DEFAULT_ELASTICACHE_PORT="6379"

# Check if required environment variables are set
check_env_vars() {
    if [[ -z "$ELASTICACHE_VALKEY_ENDPOINT" ]]; then
        print_warning "ELASTICACHE_VALKEY_ENDPOINT not set, using default: $DEFAULT_ELASTICACHE_ENDPOINT"
        export ELASTICACHE_VALKEY_ENDPOINT="$DEFAULT_ELASTICACHE_ENDPOINT"
    fi
    
    if [[ -z "$ELASTICACHE_VALKEY_PORT" ]]; then
        print_warning "ELASTICACHE_VALKEY_PORT not set, using default: $DEFAULT_ELASTICACHE_PORT"
        export ELASTICACHE_VALKEY_PORT="$DEFAULT_ELASTICACHE_PORT"
    fi
    
    # Validate endpoint is not the default placeholder
    if [[ "$ELASTICACHE_VALKEY_ENDPOINT" == "your-elasticache-endpoint.cache.amazonaws.com" ]]; then
        print_error "Please update DEFAULT_ELASTICACHE_ENDPOINT in the script or set ELASTICACHE_VALKEY_ENDPOINT environment variable"
        echo "You can find your ElastiCache endpoint using:"
        echo "aws elasticache describe-replication-groups --replication-group-id integrated-db-monitoring-valkey"
        exit 1
    fi
}

# Install Python dependencies
install_dependencies() {
    print_status "Installing Python dependencies..."
    
    # Check if pip is available
    if ! command -v pip3 &> /dev/null; then
        print_error "pip3 is not installed. Please install Python 3 and pip3 first."
        exit 1
    fi
    
    # Install redis-py
    pip3 install redis --quiet
    print_success "Dependencies installed successfully"
}

# Create Kubernetes deployment for load generator
create_k8s_deployment() {
    print_status "Creating Kubernetes deployment for load generator..."
    
    cat > /tmp/elasticache-load-generator.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: elasticache-load-generator
  namespace: observability
  labels:
    app: elasticache-load-generator
spec:
  replicas: 2
  selector:
    matchLabels:
      app: elasticache-load-generator
  template:
    metadata:
      labels:
        app: elasticache-load-generator
    spec:
      containers:
      - name: load-generator
        image: python:3.9-slim
        command: ["/bin/bash"]
        args:
          - -c
          - |
            pip install redis
            cat > /app/load_generator.py << 'SCRIPT_EOF'
$(cat elasticache-load-generator.py)
SCRIPT_EOF
            python /app/load_generator.py --host ${ELASTICACHE_VALKEY_ENDPOINT} --port ${ELASTICACHE_VALKEY_PORT} --threads 3
        env:
        - name: ELASTICACHE_ENDPOINT
          value: "${ELASTICACHE_VALKEY_ENDPOINT}"
        - name: ELASTICACHE_PORT
          value: "${ELASTICACHE_VALKEY_PORT}"
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          exec:
            command:
            - python
            - -c
            - "import redis; r=redis.Redis(host='${ELASTICACHE_VALKEY_ENDPOINT}', port=${ELASTICACHE_VALKEY_PORT}); r.ping()"
          initialDelaySeconds: 30
          periodSeconds: 30
        readinessProbe:
          exec:
            command:
            - python
            - -c
            - "import redis; r=redis.Redis(host='${ELASTICACHE_VALKEY_ENDPOINT}', port=${ELASTICACHE_VALKEY_PORT}); r.ping()"
          initialDelaySeconds: 10
          periodSeconds: 10
      restartPolicy: Always
EOF

    # Apply the deployment
    kubectl apply -f /tmp/elasticache-load-generator.yaml
    
    print_success "Kubernetes deployment created"
    print_status "Waiting for pods to be ready..."
    kubectl wait --for=condition=ready pod -l app=elasticache-load-generator -n observability --timeout=120s
    
    print_success "Load generator pods are ready"
}

# Run load generator locally
run_local() {
    print_status "Running ElastiCache load generator locally..."
    print_status "Target: ${ELASTICACHE_VALKEY_ENDPOINT}:${ELASTICACHE_VALKEY_PORT}"
    print_status "Press Ctrl+C to stop"
    
    python3 elasticache-load-generator.py \
        --host "${ELASTICACHE_VALKEY_ENDPOINT}" \
        --port "${ELASTICACHE_VALKEY_PORT}" \
        --threads 5 \
        --connections 10
}

# Show usage
show_usage() {
    echo "Usage: $0 [local|k8s|stop]"
    echo ""
    echo "Commands:"
    echo "  local  - Run load generator locally"
    echo "  k8s    - Deploy load generator to Kubernetes"
    echo "  stop   - Stop Kubernetes deployment"
    echo "  status - Show status of Kubernetes deployment"
    echo ""
    echo "Environment variables required:"
    echo "  ELASTICACHE_VALKEY_ENDPOINT - ElastiCache endpoint"
    echo "  ELASTICACHE_VALKEY_PORT     - ElastiCache port (optional, default: 6379)"
}

# Stop Kubernetes deployment
stop_k8s_deployment() {
    print_status "Stopping ElastiCache load generator deployment..."
    
    if kubectl get deployment elasticache-load-generator -n observability &> /dev/null; then
        kubectl delete deployment elasticache-load-generator -n observability
        print_success "Load generator deployment stopped"
    else
        print_warning "Load generator deployment not found"
    fi
}

# Show deployment status
show_status() {
    print_status "ElastiCache Load Generator Status:"
    echo ""
    
    if kubectl get deployment elasticache-load-generator -n observability &> /dev/null; then
        echo "Deployment Status:"
        kubectl get deployment elasticache-load-generator -n observability
        echo ""
        echo "Pod Status:"
        kubectl get pods -l app=elasticache-load-generator -n observability
        echo ""
        echo "Recent Logs (last 20 lines):"
        kubectl logs -l app=elasticache-load-generator -n observability --tail=20
    else
        print_warning "Load generator deployment not found"
        echo "Use '$0 k8s' to deploy the load generator"
    fi
}

# Main script logic
main() {
    case "${1:-}" in
        "local")
            check_env_vars
            install_dependencies
            run_local
            ;;
        "k8s")
            check_env_vars
            create_k8s_deployment
            ;;
        "stop")
            stop_k8s_deployment
            ;;
        "status")
            show_status
            ;;
        *)
            show_usage
            exit 1
            ;;
    esac
}

main "$@"