# Aurora Discovery Container

This directory contains the containerized Aurora Discovery application that automatically discovers Aurora clusters and manages Prometheus exporters.

## Building the Container

### Using the build script (recommended):

```bash
# Build with default settings
./build.sh

# Build with custom image name and tag
./build.sh --image-name my-aurora-discovery --tag v1.0.0

# Build and push to registry
./build.sh --registry my-registry.com --tag v1.0.0 --push

# Build for multiple platforms
./build.sh --platform linux/amd64,linux/arm64
```

### Using Docker directly:

```bash
# Build the image
docker build -t aurora-discovery:latest .

# Build for specific platform
docker build --platform linux/amd64 -t aurora-discovery:latest .
```

## Container Features

### Health Checks

The container exposes health check endpoints on port 8080:

- `/health` - Basic health check (always returns 200)
- `/ready` - Readiness check (returns 200 when application is ready)

### Signal Handling

The container properly handles shutdown signals:

- `SIGTERM` - Graceful shutdown with 30-second timeout
- `SIGINT` - Graceful shutdown (Ctrl+C)
- `SIGQUIT` - Graceful shutdown

### Security

- Runs as non-root user (`aurora:aurora`, UID/GID 1000)
- Minimal base image (Python 3.11 slim)
- No unnecessary packages installed

### Environment Variables

The container accepts the following environment variables:

- `AWS_REGION` - AWS region to scan (default: us-east-1)
- `NAMESPACE` - Kubernetes namespace (default: observability)
- `STATE_CONFIGMAP_NAME` - ConfigMap name for state (default: aurora-discovery-state)
- `LOG_LEVEL` - Logging level (default: INFO)
- `HEALTH_CHECK_PORT` - Health check port (default: 8080)

## Running the Container

### Local testing:

```bash
docker run --rm \
  -e AWS_REGION=us-east-1 \
  -e NAMESPACE=observability \
  -e LOG_LEVEL=DEBUG \
  aurora-discovery:latest
```

### With health checks:

```bash
docker run --rm \
  -p 8080:8080 \
  -e AWS_REGION=us-east-1 \
  aurora-discovery:latest
```

Test health endpoints:
```bash
curl http://localhost:8080/health
curl http://localhost:8080/ready
```

## Kubernetes Deployment

The container is designed to run as a CronJob in Kubernetes with proper RBAC and service account configuration. See the Helm chart templates for complete deployment configuration.