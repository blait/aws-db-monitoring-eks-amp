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

# Start health check server in background
start_health_check() {
    echo "$(date): Starting health check server on port $HEALTH_CHECK_PORT"
    
    # Simple HTTP server for health checks
    python3 -c "
import http.server
import socketserver
import threading
import sys
import os

class HealthCheckHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{\"status\": \"healthy\", \"service\": \"aurora-discovery\"}')
        elif self.path == '/ready':
            # Check if main process is running
            if os.path.exists('/tmp/aurora-discovery.ready'):
                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{\"status\": \"ready\", \"service\": \"aurora-discovery\"}')
            else:
                self.send_response(503)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{\"status\": \"not ready\", \"service\": \"aurora-discovery\"}')
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        # Suppress default HTTP server logging
        pass

try:
    with socketserver.TCPServer(('', $HEALTH_CHECK_PORT), HealthCheckHandler) as httpd:
        httpd.serve_forever()
except Exception as e:
    print(f'Health check server error: {e}', file=sys.stderr)
" &
    
    HEALTH_PID=$!
    echo "$(date): Health check server started with PID: $HEALTH_PID"
}

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

# Start health check server
start_health_check

# Create readiness indicator
touch /tmp/aurora-discovery.ready

# Start the main application
echo "$(date): Starting Aurora Discovery application with args: $@"
"$@" &
PID=$!

echo "$(date): Aurora Discovery started with PID: $PID"

# Wait for the main process to complete
wait $PID
EXIT_CODE=$?

# Clean up readiness indicator
rm -f /tmp/aurora-discovery.ready

echo "$(date): Aurora Discovery process completed with exit code: $EXIT_CODE"

# Kill health check server
if [ -n "$HEALTH_PID" ]; then
    kill $HEALTH_PID 2>/dev/null || true
fi

exit $EXIT_CODE