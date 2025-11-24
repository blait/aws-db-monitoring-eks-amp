#!/bin/bash

# Aurora Discovery Container Build Script

set -e

# Default values
IMAGE_NAME="aurora-discovery"
IMAGE_TAG="latest"
REGISTRY=""
PLATFORM="linux/amd64"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --image-name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        --tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --push)
            PUSH=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --image-name NAME    Container image name (default: aurora-discovery)"
            echo "  --tag TAG           Image tag (default: latest)"
            echo "  --registry REGISTRY Registry prefix (optional)"
            echo "  --platform PLATFORM Target platform (default: linux/amd64)"
            echo "  --push              Push image to registry after build"
            echo "  --help              Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Construct full image name
if [ -n "$REGISTRY" ]; then
    FULL_IMAGE_NAME="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
else
    FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"
fi

echo "Building Aurora Discovery container image..."
echo "Image: $FULL_IMAGE_NAME"
echo "Platform: $PLATFORM"

# Build the container image
docker build \
    --platform "$PLATFORM" \
    --tag "$FULL_IMAGE_NAME" \
    --file Dockerfile \
    .

echo "Build completed successfully!"

# Push if requested
if [ "$PUSH" = true ]; then
    echo "Pushing image to registry..."
    
    # If registry is ECR, authenticate first
    if [[ "$REGISTRY" == *.dkr.ecr.*.amazonaws.com ]]; then
        echo "Detected ECR registry, authenticating..."
        
        # Extract region from ECR URL
        ECR_REGION=$(echo "$REGISTRY" | sed -n 's/.*\.dkr\.ecr\.\([^.]*\)\.amazonaws\.com/\1/p')
        
        if [ -z "$ECR_REGION" ]; then
            echo "Warning: Could not extract region from ECR URL, using default region"
            ECR_REGION=$(aws configure get region)
        fi
        
        echo "ECR Region: $ECR_REGION"
        
        # Authenticate Docker to ECR
        aws ecr get-login-password --region "$ECR_REGION" | \
            docker login --username AWS --password-stdin "$REGISTRY"
        
        if [ $? -ne 0 ]; then
            echo "Error: Failed to authenticate to ECR"
            exit 1
        fi
        
        echo "ECR authentication successful"
    fi
    
    docker push "$FULL_IMAGE_NAME"
    echo "Push completed successfully!"
fi

echo "Aurora Discovery container image ready: $FULL_IMAGE_NAME"