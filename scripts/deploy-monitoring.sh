#!/bin/bash

# Database Monitoring Helm Deployment Script
# This script deploys the complete monitoring stack using Helm charts with production configuration

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
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

# Function to check if required environment variables are set
check_env_vars() {
    local required_vars=(
        "WORKSHOP_NAME"
        "AWS_REGION"
        "AMP_WORKSPACE_ID"
        "AMP_ENDPOINT"
        "ADOT_ROLE_ARN"
        "MYSQL_ENDPOINT1"
        "MYSQL_ENDPOINT2"
        "POSTGRESQL_ENDPOINT1"
        "POSTGRESQL_ENDPOINT2"
        "ELASTICACHE_VALKEY_ENDPOINT"
        "ELASTICACHE_VALKEY_PORT"
    )
    
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        print_error "Missing required environment variables:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        echo ""
        echo "Please set these variables before running the script."
        echo "Example:"
        echo "  export WORKSHOP_NAME=integrated-db-monitoring"
        echo "  export AWS_REGION=us-east-1"
        echo "  # ... set other variables"
        exit 1
    fi
}

# Function to validate Helm installation
check_helm() {
    if ! command -v helm &> /dev/null; then
        print_error "Helm is not installed. Please install Helm first."
        echo "Visit: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    
    local helm_version=$(helm version --short --client | cut -d'+' -f1)
    print_status "Using Helm version: $helm_version"
}

# Function to validate kubectl connection
check_kubectl() {
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        exit 1
    fi
    
    local cluster_name=$(kubectl config current-context)
    print_status "Connected to cluster: $cluster_name"
}

# Function to deploy the monitoring stack
deploy_monitoring() {
    local release_name="db-monitoring"
    local namespace="observability"
    local chart_path="helm-charts/db-monitoring"
    local values_file="/tmp/db-monitoring-values.yaml"
    
    print_status "Deploying monitoring stack with production configuration"
    
    # Create values file
    print_status "Creating production values file"
    
    # Start with the standard values file
    cp "helm-charts/db-monitoring/values.yaml" "$values_file"
    
    # Replace placeholders with actual values using the new subchart structure
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS sed syntax - use simpler patterns
        sed -i '' \
            -e "s|workspaceId: \"\"|workspaceId: \"${AMP_WORKSPACE_ID}\"|g" \
            -e "s|clusterName: \"\"|clusterName: \"${WORKSHOP_NAME}-eks\"|g" \
            -e "s|eks.amazonaws.com/role-arn: \"\"|eks.amazonaws.com/role-arn: \"${ADOT_ROLE_ARN}\"|g" \
            -e "s|region: us-east-1|region: ${AWS_REGION}|g" \
            "$values_file"
        
        # Replace ALL empty endpoint fields with AMP endpoint first
        sed -i '' "s|endpoint: \"\"|endpoint: \"${AMP_ENDPOINT}\"|g" "$values_file"
        
        # Then fix the database endpoints - use primary instances for cluster monitoring
        sed -i '' \
            -e "/mysql-cluster/,/enabled: true/ s|endpoint: \"${AMP_ENDPOINT}\"|endpoint: \"${MYSQL_ENDPOINT1}\"|" \
            -e "/postgresql-cluster/,/enabled: true/ s|endpoint: \"${AMP_ENDPOINT}\"|endpoint: \"${POSTGRESQL_ENDPOINT1}\"|" \
            -e "/elasticache-valkey-cluster/,/enabled: true/ s|endpoint: \"${AMP_ENDPOINT}\"|endpoint: \"${ELASTICACHE_VALKEY_ENDPOINT}\"|" \
            -e "/elasticache-valkey-cluster/,/enabled: true/ s|port: \"\"|port: \"${ELASTICACHE_VALKEY_PORT}\"|" \
            "$values_file"
    else
        # Linux sed syntax - use simpler patterns
        sed -i \
            -e "s|workspaceId: \"\"|workspaceId: \"${AMP_WORKSPACE_ID}\"|g" \
            -e "s|clusterName: \"\"|clusterName: \"${WORKSHOP_NAME}-eks\"|g" \
            -e "s|eks.amazonaws.com/role-arn: \"\"|eks.amazonaws.com/role-arn: \"${ADOT_ROLE_ARN}\"|g" \
            -e "s|region: us-east-1|region: ${AWS_REGION}|g" \
            "$values_file"
        
        # Replace ALL empty endpoint fields with AMP endpoint first
        sed -i "s|endpoint: \"\"|endpoint: \"${AMP_ENDPOINT}\"|g" "$values_file"
        
        # Then fix the database endpoints - use primary instances for cluster monitoring
        sed -i \
            -e "/mysql-cluster/,/enabled: true/ s|endpoint: \"${AMP_ENDPOINT}\"|endpoint: \"${MYSQL_ENDPOINT1}\"|" \
            -e "/postgresql-cluster/,/enabled: true/ s|endpoint: \"${AMP_ENDPOINT}\"|endpoint: \"${POSTGRESQL_ENDPOINT1}\"|" \
            -e "/elasticache-valkey-cluster/,/enabled: true/ s|endpoint: \"${AMP_ENDPOINT}\"|endpoint: \"${ELASTICACHE_VALKEY_ENDPOINT}\"|" \
            -e "/elasticache-valkey-cluster/,/enabled: true/ s|port: \"\"|port: \"${ELASTICACHE_VALKEY_PORT}\"|" \
            "$values_file"
    fi
    
    # Validate values file was created
    if [[ ! -f "$values_file" ]]; then
        print_error "Failed to create values file"
        exit 1
    fi
    
    print_status "Values file created successfully"
    
    # Update Helm dependencies
    print_status "Updating Helm dependencies..."
    helm dependency update "$chart_path"
    
    # Debug: Show a few lines of the values file to verify substitution worked
    print_status "Verifying values file content..."
    local amp_count=$(grep -c "${AMP_ENDPOINT}" "$values_file" || echo "0")
    if grep -q "${AMP_WORKSPACE_ID}" "$values_file" && [[ $amp_count -ge 2 ]] && grep -q "${ADOT_ROLE_ARN}" "$values_file" && grep -q "${MYSQL_ENDPOINT1}" "$values_file"; then
        print_status "Values file substitution successful"
        print_status "AMP endpoint appears $amp_count times (should be 2: main amp section + adot section)"
    else
        print_warning "Values file may not have been substituted correctly"
        echo "Checking for key values:"
        echo "AMP Workspace ID: $(grep -c "${AMP_WORKSPACE_ID}" "$values_file" || echo "0") occurrences"
        echo "AMP Endpoint: $amp_count occurrences (should be 2)"
        echo "ADOT Role ARN: $(grep -c "${ADOT_ROLE_ARN}" "$values_file" || echo "0") occurrences"
        echo "MySQL Endpoint 1: $(grep -c "${MYSQL_ENDPOINT1}" "$values_file" || echo "0") occurrences"
        echo "Valkey Endpoint: $(grep -c "${ELASTICACHE_VALKEY_ENDPOINT}" "$values_file" || echo "0") occurrences"
        echo "Valkey Port: $(grep -c "${ELASTICACHE_VALKEY_PORT}" "$values_file" || echo "0") occurrences"
        echo ""
        echo "First 50 lines of values file:"
        head -50 "$values_file"
        echo ""
        echo "Redis-exporter section:"
        grep -A 10 "redis-exporter:" "$values_file" || echo "Redis-exporter section not found"
    fi
    
    # Handle namespace - ensure it exists before Helm operations
    print_status "Managing namespace: $namespace"
    if kubectl get namespace "$namespace" &> /dev/null; then
        print_status "Namespace $namespace already exists, ensuring Helm can manage it..."
        
        # Check if namespace has Helm labels/annotations
        local helm_managed=$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
        local helm_release=$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
        
        if [[ "$helm_managed" == "Helm" && "$helm_release" == "$release_name" ]]; then
            print_status "Namespace $namespace is already properly managed by Helm"
        else
            print_status "Adding Helm ownership metadata to namespace $namespace..."
            
            # Add/update Helm labels and annotations
            kubectl label namespace "$namespace" app.kubernetes.io/managed-by=Helm --overwrite
            kubectl annotate namespace "$namespace" meta.helm.sh/release-name="$release_name" --overwrite
            kubectl annotate namespace "$namespace" meta.helm.sh/release-namespace="$namespace" --overwrite
            
            # Verify the metadata was applied
            local updated_helm_managed=$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || echo "")
            local updated_helm_release=$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null || echo "")
            
            if [[ "$updated_helm_managed" == "Helm" && "$updated_helm_release" == "$release_name" ]]; then
                print_status "Namespace $namespace is now properly managed by Helm"
            else
                print_error "Failed to update namespace metadata. Please check permissions."
                exit 1
            fi
        fi
    else
        print_status "Creating namespace $namespace..."
        kubectl create namespace "$namespace"
        
        # Add Helm ownership metadata to the newly created namespace
        print_status "Adding Helm ownership metadata to namespace $namespace..."
        kubectl label namespace "$namespace" app.kubernetes.io/managed-by=Helm --overwrite
        kubectl annotate namespace "$namespace" meta.helm.sh/release-name="$release_name" --overwrite
        kubectl annotate namespace "$namespace" meta.helm.sh/release-namespace="$namespace" --overwrite
        
        print_status "Namespace $namespace created and configured for Helm management"
    fi
    
    # Check if release already exists
    if helm list -n "$namespace" | grep -q "$release_name"; then
        print_status "Upgrading existing release: $release_name"
        helm upgrade "$release_name" "$chart_path" \
            --namespace "$namespace" \
            --values "$values_file" \
            --timeout 10m
    else
        print_status "Installing new release: $release_name"
        helm install "$release_name" "$chart_path" \
            --namespace "$namespace" \
            --values "$values_file" \
            --timeout 10m
    fi
    
    # Clean up temporary values file
    rm -f "$values_file"
    
    print_success "Monitoring stack deployed successfully with production configuration!"
}

# Function to verify deployment
verify_deployment() {
    local namespace="observability"
    
    print_status "Verifying deployment..."
    
    # Check if all pods are running
    local pods_not_ready=$(kubectl get pods -n "$namespace" --no-headers | grep -v Running | wc -l)
    
    if [[ $pods_not_ready -gt 0 ]]; then
        print_warning "Some pods are not ready yet. Checking status..."
        kubectl get pods -n "$namespace"
        
        print_status "Waiting for pods to be ready..."
        kubectl wait --for=condition=Ready pods --all -n "$namespace" --timeout=300s
    fi
    
    # Display final status
    echo ""
    print_success "Deployment verification complete!"
    echo ""
    echo "Production monitoring components status:"
    kubectl get pods -n "$namespace" -o wide
    echo ""
    echo "Services:"
    kubectl get svc -n "$namespace"
    echo ""
    
    # Show helpful information
    print_status "Production configuration deployed with:"
    echo "• ADOT Collector: 500m CPU, 1Gi RAM (requests) / 1000m CPU, 2Gi RAM (limits)"
    echo "• MySQL Exporters: 200m CPU, 256Mi RAM (requests) / 500m CPU, 512Mi RAM (limits)"
    echo "• PostgreSQL Exporters: 200m CPU, 256Mi RAM (requests) / 500m CPU, 512Mi RAM (limits)"
    echo "• Redis/Valkey Exporters: 100m CPU, 128Mi RAM (requests) / 200m CPU, 256Mi RAM (limits)"
    echo "• Scrape Interval: 15 seconds (high-frequency monitoring)"
    echo "• Network Policies: Enabled"
    echo ""
    print_status "Next steps:"
    echo "1. Check ADOT Collector logs: kubectl logs -n $namespace -l app.kubernetes.io/name=adot-collector"
    echo "2. Check MySQL exporter logs: kubectl logs -n $namespace -l app.kubernetes.io/name=mysql-exporter"
    echo "3. Check PostgreSQL exporter logs: kubectl logs -n $namespace -l app.kubernetes.io/name=postgresql-exporter"
    echo "4. Check Redis/Valkey exporter logs: kubectl logs -n $namespace -l app.kubernetes.io/name=redis-exporter"
    echo "5. Access Grafana dashboard using your AMG workspace URL"
    echo "6. Import the dashboard JSON files from the dashboards/ directory"
}

# Function to show usage
show_usage() {
    echo "Usage: $0"
    echo ""
    echo "This script deploys the database monitoring stack with production configuration."
    echo ""
    echo "Required environment variables:"
    echo "  WORKSHOP_NAME, AWS_REGION, AMP_WORKSPACE_ID, AMP_ENDPOINT,"
    echo "  ADOT_ROLE_ARN, MYSQL_ENDPOINT1, MYSQL_ENDPOINT2,"
    echo "  POSTGRESQL_ENDPOINT1, POSTGRESQL_ENDPOINT2"
    echo ""
    echo "Example:"
    echo "  export WORKSHOP_NAME=integrated-db-monitoring"
    echo "  export AWS_REGION=us-east-1"
    echo "  # ... set other variables"
    echo "  $0"
}

# Main execution
main() {
    print_status "Starting production monitoring stack deployment"
    
    # Run all checks
    check_env_vars
    check_helm
    check_kubectl
    
    # Deploy monitoring stack
    deploy_monitoring
    
    # Verify deployment
    verify_deployment
    
    print_success "Database monitoring stack deployment completed successfully!"
    print_success "Production-grade monitoring is now active with enhanced performance and security!"
}

# Handle help flag
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_usage
    exit 0
fi

# Reject any parameters
if [[ $# -gt 0 ]]; then
    print_error "This script does not accept parameters."
    echo ""
    show_usage
    exit 1
fi

# Run main function
main
