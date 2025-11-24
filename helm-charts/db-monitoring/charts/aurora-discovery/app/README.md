# Aurora Discovery Application

This Python application automatically discovers Aurora clusters and manages Prometheus exporters for database monitoring.

## Features

- Discovers Aurora MySQL and PostgreSQL clusters using AWS RDS API
- Retrieves database credentials from AWS Secrets Manager
- Manages Kubernetes resources for Prometheus exporters
- Tracks cluster state using Kubernetes ConfigMaps
- Structured logging with configurable levels
- Comprehensive error handling and retry logic

## Usage

```bash
python main.py --help
```

### Environment Variables

- `AWS_REGION`: AWS region to scan for Aurora clusters (default: us-east-1)
- `NAMESPACE`: Kubernetes namespace for resources (default: observability)
- `STATE_CONFIGMAP_NAME`: Name of the ConfigMap for state storage (default: aurora-discovery-state)
- `LOG_LEVEL`: Logging level (default: INFO)

### Command Line Arguments

- `--aws-region`: Override AWS region
- `--namespace`: Override Kubernetes namespace
- `--state-configmap-name`: Override ConfigMap name
- `--log-level`: Set logging level (DEBUG, INFO, WARNING, ERROR)
- `--dry-run`: Perform discovery without making changes

## Docker Build

```bash
docker build -t aurora-discovery:latest .
```

## Requirements

- Python 3.11+
- boto3 (AWS SDK)
- kubernetes (Kubernetes client)
- pyyaml

## Architecture

The application consists of several modules:

- `main.py`: Entry point with CLI argument parsing
- `aurora_discovery.py`: Main service orchestrator
- `aws_client.py`: AWS RDS and Secrets Manager integration
- `models.py`: Data models for clusters and credentials
- `state_manager.py`: Kubernetes ConfigMap state management (placeholder)
- `resource_manager.py`: Kubernetes resource management (placeholder)

## Logging

The application uses structured JSON logging for better observability:

```json
{
  "timestamp": "2024-01-15T10:30:00",
  "level": "INFO",
  "logger": "aurora_discovery",
  "message": "Aurora discovery cycle completed successfully"
}
```