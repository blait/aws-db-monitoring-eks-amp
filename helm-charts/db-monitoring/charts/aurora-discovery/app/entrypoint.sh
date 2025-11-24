#!/bin/bash

# Aurora Discovery Container Entrypoint Script
# Handles signal forwarding and graceful shutdown

set -e

# Global variables
PID=""
HEALTH_CHECK_PORT=${HEALTH_CHECK_PORT:-8080}

# Signal handler for graceful shutdown
cleanup() {
    echo "$(date): Received shutdown signal, initiating graceful shutdown..."
    
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "$(date): Sending SIGTERM to Aurora Discovery process (PID: $PID)"
        kill -TERM "$PID"
        
        # Wait for process to terminate gracefully
        local count=0
        while kill -0 "$PID" 2>/dev/null && [ $count -lt 30 ]; do
            sleep 1
            count=$((count + 1))
        done
        
        # Force kill if still running
        if kill -0 "$PID" 2>/dev/null; then
            echo "$(date): Process did not terminate gracefully, sending SIGKILL"
            kill -KILL "$PID"
        fi
    fi
    
    echo "$(date): Aurora Discovery container shutdown complete"
    exit 0
}

# Health check is now handled by main.py metrics server
# No separate health check server needed

# Set up signal handlers
trap cleanup SIGTERM SIGINT SIGQUIT

# Validate required environment variables
if [ -z "$AWS_REGION" ]; then
    echo "$(date): WARNING: AWS_REGION not set, using default"
fi

if [ -z "$NAMESPACE" ]; then
    echo "$(date): WARNING: NAMESPACE not set, using default"
fi

echo "$(date): Starting Aurora Discovery container"
echo "$(date): AWS Region: ${AWS_REGION:-us-east-1}"
echo "$(date): Namespace: ${NAMESPACE:-observability}"
echo "$(date): Log Level: ${LOG_LEVEL:-INFO}"

# Health check and metrics are handled by main.py
# No need for separate health check server

# Create readiness indicator
touch /dev/shm/aurora-discovery.ready

# Start the main application
echo "$(date): Starting Aurora Discovery application with args: $@"
"$@" &
PID=$!

echo "$(date): Aurora Discovery started with PID: $PID"

# Wait for the main process to complete
wait $PID
EXIT_CODE=$?

# Clean up readiness indicator
rm -f /dev/shm/aurora-discovery.ready

echo "$(date): Aurora Discovery process completed with exit code: $EXIT_CODE"

exit $EXIT_CODE