#!/usr/bin/env python3
"""
Aurora Discovery Service

Automatically discovers Aurora clusters and manages Prometheus exporters.
"""

import argparse
import logging
import sys
import os
import signal
import threading
import time
from typing import Optional
from http.server import HTTPServer, BaseHTTPRequestHandler

from aurora_discovery import AuroraDiscoveryService
from metrics import get_metrics, initialize_metrics


class StructuredFormatter(logging.Formatter):
    """Custom formatter to include extra fields in JSON logs."""
    
    def format(self, record):
        # Base log structure
        log_data = {
            "timestamp": self.formatTime(record, self.datefmt),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage()
        }
        
        # Add extra fields if present
        if hasattr(record, 'error'):
            log_data['error'] = record.error
        if hasattr(record, 'error_type'):
            log_data['error_type'] = record.error_type
        if hasattr(record, 'traceback'):
            log_data['traceback'] = record.traceback
        
        import json
        return json.dumps(log_data)


def setup_logging(log_level: str = "INFO") -> None:
    """Configure structured logging with the specified level."""
    # Convert string level to logging constant
    numeric_level = getattr(logging, log_level.upper(), logging.INFO)
    
    # Configure logging with custom formatter
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(StructuredFormatter(datefmt='%Y-%m-%dT%H:%M:%S'))
    
    logging.basicConfig(
        level=numeric_level,
        handlers=[handler]
    )
    
    # Set boto3 and kubernetes client logging to WARNING to reduce noise
    logging.getLogger('boto3').setLevel(logging.WARNING)
    logging.getLogger('botocore').setLevel(logging.WARNING)
    logging.getLogger('kubernetes').setLevel(logging.WARNING)
    logging.getLogger('urllib3').setLevel(logging.WARNING)


class MetricsHandler(BaseHTTPRequestHandler):
    """HTTP handler for Prometheus metrics endpoint."""
    
    def do_GET(self):
        """Handle GET requests for metrics."""
        if self.path == '/metrics':
            metrics = get_metrics()
            self.send_response(200)
            self.send_header('Content-Type', metrics.get_content_type())
            self.end_headers()
            self.wfile.write(metrics.get_metrics().encode('utf-8'))
        elif self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        """Override to use structured logging."""
        logger = logging.getLogger('metrics_server')
        logger.debug(format % args)


def start_metrics_server(port: int) -> HTTPServer:
    """Start the metrics HTTP server."""
    server = HTTPServer(('', port), MetricsHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def parse_arguments() -> argparse.Namespace:
    """Parse command-line arguments."""
    parser = argparse.ArgumentParser(
        description="Aurora Discovery Service - Automatically discover and manage Aurora cluster monitoring"
    )
    
    parser.add_argument(
        "--aws-region",
        default=os.getenv("AWS_REGION", "us-east-1"),
        help="AWS region to scan for Aurora clusters (default: %(default)s)"
    )
    
    parser.add_argument(
        "--namespace",
        default=os.getenv("NAMESPACE", "observability"),
        help="Kubernetes namespace for resources (default: %(default)s)"
    )
    
    parser.add_argument(
        "--log-level",
        default=os.getenv("LOG_LEVEL", "INFO"),
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        help="Logging level (default: %(default)s)"
    )
    
    parser.add_argument(
        "--metrics-port",
        type=int,
        default=int(os.getenv("METRICS_PORT", "8080")),
        help="Port for Prometheus metrics endpoint (default: %(default)s)"
    )
    
    return parser.parse_args()


def main() -> int:
    """Main entry point for the Aurora Discovery Service."""
    # Global flag for graceful shutdown
    shutdown_requested = False
    
    try:
        # Parse command-line arguments
        args = parse_arguments()
        
        # Set up logging
        setup_logging(args.log_level)
        logger = logging.getLogger(__name__)
        
        # Load Kubernetes configuration (once for all components)
        try:
            from kubernetes import config
            config.load_incluster_config()
            logger.info("Loaded in-cluster Kubernetes configuration")
        except Exception:
            try:
                from kubernetes import config
                config.load_kube_config()
                logger.info("Loaded Kubernetes configuration from kubeconfig")
            except Exception as e:
                logger.error(f"Failed to load Kubernetes configuration: {e}")
                return 1
        
        # Initialize metrics
        initialize_metrics()
        
        # Start metrics server
        metrics_server = start_metrics_server(args.metrics_port)
        logger.info(f"Metrics server started on port {args.metrics_port}")
        
        # Set up signal handlers for graceful shutdown
        def shutdown_handler(signum, frame):
            nonlocal shutdown_requested
            logger.info(f"Received signal {signum}, initiating graceful shutdown")
            shutdown_requested = True
            metrics_server.shutdown()
        
        signal.signal(signal.SIGTERM, shutdown_handler)
        signal.signal(signal.SIGINT, shutdown_handler)
        
        logger.info("Starting Aurora Discovery Service", extra={
            "aws_region": args.aws_region,
            "namespace": args.namespace,
            "metrics_port": args.metrics_port
        })
        
        # Initialize the discovery service
        service = AuroraDiscoveryService(
            aws_region=args.aws_region,
            namespace=args.namespace
        )
        
        # Execute the discovery and management cycle
        # Check for shutdown signal before starting
        if not shutdown_requested:
            service.run()
        
        if shutdown_requested:
            logger.info("Aurora Discovery Service shutdown gracefully")
            return 130
        else:
            logger.info("Aurora Discovery Service completed successfully")
            # Keep metrics server running for a short time to allow scraping
            time.sleep(30)
            metrics_server.shutdown()
            return 0
        
    except KeyboardInterrupt:
        logger = logging.getLogger(__name__)
        logger.info("Aurora Discovery Service interrupted by user")
        return 130
        
    except Exception as e:
        logger = logging.getLogger(__name__)
        logger.error("Aurora Discovery Service failed", extra={
            "error": str(e),
            "error_type": type(e).__name__
        })
        return 1


if __name__ == "__main__":
    sys.exit(main())