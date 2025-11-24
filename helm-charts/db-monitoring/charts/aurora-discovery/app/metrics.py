"""
Prometheus Metrics for Aurora Discovery Service

Provides metrics collection and exposure for monitoring Aurora Discovery operations.
"""

import logging
import time
from typing import Dict, Optional
from contextlib import contextmanager

from prometheus_client import Counter, Gauge, Histogram, CollectorRegistry, generate_latest, CONTENT_TYPE_LATEST


class AuroraDiscoveryMetrics:
    """Prometheus metrics collector for Aurora Discovery Service."""
    
    def __init__(self, registry: Optional[CollectorRegistry] = None):
        """Initialize metrics with optional custom registry."""
        self.logger = logging.getLogger(__name__)
        self.registry = registry or CollectorRegistry()
        
        # Discovery metrics
        self.clusters_discovered_total = Counter(
            'aurora_discovery_clusters_discovered_total',
            'Total number of Aurora clusters discovered',
            ['engine_type'],
            registry=self.registry
        )
        
        self.clusters_filtered_total = Counter(
            'aurora_discovery_clusters_filtered_total',
            'Total number of Aurora clusters filtered (included in monitoring)',
            ['engine_type'],
            registry=self.registry
        )
        
        self.clusters_skipped_total = Counter(
            'aurora_discovery_clusters_skipped_total',
            'Total number of Aurora clusters skipped',
            ['reason'],
            registry=self.registry
        )
        
        # Resource management metrics
        self.exporters_created_total = Counter(
            'aurora_discovery_exporters_created_total',
            'Total number of exporters created',
            ['engine_type'],
            registry=self.registry
        )
        
        self.exporters_updated_total = Counter(
            'aurora_discovery_exporters_updated_total',
            'Total number of exporters updated',
            ['engine_type'],
            registry=self.registry
        )
        
        self.exporters_deleted_total = Counter(
            'aurora_discovery_exporters_deleted_total',
            'Total number of exporters deleted',
            ['engine_type'],
            registry=self.registry
        )
        
        # Error metrics
        self.errors_total = Counter(
            'aurora_discovery_errors_total',
            'Total number of errors by type and component',
            ['error_type', 'component'],
            registry=self.registry
        )
        
        # AWS API metrics
        self.aws_api_calls_total = Counter(
            'aurora_discovery_aws_api_calls_total',
            'Total number of AWS API calls',
            ['service', 'operation', 'status'],
            registry=self.registry
        )
        
        self.aws_api_duration_seconds = Histogram(
            'aurora_discovery_aws_api_duration_seconds',
            'Duration of AWS API calls in seconds',
            ['service', 'operation'],
            registry=self.registry
        )
        
        # Kubernetes API metrics
        self.k8s_api_calls_total = Counter(
            'aurora_discovery_k8s_api_calls_total',
            'Total number of Kubernetes API calls',
            ['resource_type', 'operation', 'status'],
            registry=self.registry
        )
        
        self.k8s_api_duration_seconds = Histogram(
            'aurora_discovery_k8s_api_duration_seconds',
            'Duration of Kubernetes API calls in seconds',
            ['resource_type', 'operation'],
            registry=self.registry
        )
        
        # Execution metrics
        self.execution_duration_seconds = Histogram(
            'aurora_discovery_execution_duration_seconds',
            'Duration of Aurora Discovery execution cycles in seconds',
            ['phase'],
            registry=self.registry
        )
        
        self.last_execution_timestamp = Gauge(
            'aurora_discovery_last_execution_timestamp',
            'Timestamp of the last successful execution',
            registry=self.registry
        )
        
        self.last_execution_success = Gauge(
            'aurora_discovery_last_execution_success',
            'Whether the last execution was successful (1) or failed (0)',
            registry=self.registry
        )
        
        # State metrics
        self.managed_clusters_total = Gauge(
            'aurora_discovery_managed_clusters_total',
            'Total number of clusters currently managed',
            ['engine_type'],
            registry=self.registry
        )
        
        self.state_configmap_size_bytes = Gauge(
            'aurora_discovery_state_configmap_size_bytes',
            'Size of the state ConfigMap in bytes',
            registry=self.registry
        )
        
        self.logger.info("Aurora Discovery metrics initialized")
    
    def record_cluster_discovered(self, engine_type: str) -> None:
        """Record a cluster discovery."""
        self.clusters_discovered_total.labels(engine_type=engine_type).inc()
    
    def record_cluster_filtered(self, engine_type: str) -> None:
        """Record a cluster being filtered (included in monitoring)."""
        self.clusters_filtered_total.labels(engine_type=engine_type).inc()
    
    def record_cluster_skipped(self, reason: str) -> None:
        """Record a cluster being skipped."""
        self.clusters_skipped_total.labels(reason=reason).inc()
    
    def record_exporter_created(self, engine_type: str) -> None:
        """Record an exporter creation."""
        self.exporters_created_total.labels(engine_type=engine_type).inc()
    
    def record_exporter_updated(self, engine_type: str) -> None:
        """Record an exporter update."""
        self.exporters_updated_total.labels(engine_type=engine_type).inc()
    
    def record_exporter_deleted(self, engine_type: str) -> None:
        """Record an exporter deletion."""
        self.exporters_deleted_total.labels(engine_type=engine_type).inc()
    
    def record_error(self, error_type: str, component: str) -> None:
        """Record an error occurrence."""
        self.errors_total.labels(error_type=error_type, component=component).inc()
    
    def record_aws_api_call(self, service: str, operation: str, status: str, duration: float) -> None:
        """Record an AWS API call."""
        self.aws_api_calls_total.labels(service=service, operation=operation, status=status).inc()
        self.aws_api_duration_seconds.labels(service=service, operation=operation).observe(duration)
    
    def record_k8s_api_call(self, resource_type: str, operation: str, status: str, duration: float) -> None:
        """Record a Kubernetes API call."""
        self.k8s_api_calls_total.labels(resource_type=resource_type, operation=operation, status=status).inc()
        self.k8s_api_duration_seconds.labels(resource_type=resource_type, operation=operation).observe(duration)
    
    def record_execution_success(self) -> None:
        """Record a successful execution."""
        self.last_execution_timestamp.set_to_current_time()
        self.last_execution_success.set(1)
    
    def record_execution_failure(self) -> None:
        """Record a failed execution."""
        self.last_execution_timestamp.set_to_current_time()
        self.last_execution_success.set(0)
    
    def update_managed_clusters(self, clusters_by_engine: Dict[str, int]) -> None:
        """Update the count of managed clusters by engine type."""
        for engine_type, count in clusters_by_engine.items():
            self.managed_clusters_total.labels(engine_type=engine_type).set(count)
    
    def update_state_configmap_size(self, size_bytes: int) -> None:
        """Update the state ConfigMap size metric."""
        self.state_configmap_size_bytes.set(size_bytes)
    
    @contextmanager
    def time_execution_phase(self, phase: str):
        """Context manager to time execution phases."""
        start_time = time.time()
        try:
            yield
        finally:
            duration = time.time() - start_time
            self.execution_duration_seconds.labels(phase=phase).observe(duration)
    
    @contextmanager
    def time_aws_api_call(self, service: str, operation: str):
        """Context manager to time AWS API calls."""
        start_time = time.time()
        status = "success"
        try:
            yield
        except Exception as e:
            status = "error"
            self.record_error(type(e).__name__, f"aws_{service}")
            raise
        finally:
            duration = time.time() - start_time
            self.record_aws_api_call(service, operation, status, duration)
    
    @contextmanager
    def time_k8s_api_call(self, resource_type: str, operation: str):
        """Context manager to time Kubernetes API calls."""
        start_time = time.time()
        status = "success"
        try:
            yield
        except Exception as e:
            status = "error"
            self.record_error(type(e).__name__, f"k8s_{resource_type}")
            raise
        finally:
            duration = time.time() - start_time
            self.record_k8s_api_call(resource_type, operation, status, duration)
    
    def get_metrics(self) -> str:
        """Get metrics in Prometheus format."""
        return generate_latest(self.registry).decode('utf-8')
    
    def get_content_type(self) -> str:
        """Get the content type for metrics endpoint."""
        return CONTENT_TYPE_LATEST


# Global metrics instance
_metrics_instance: Optional[AuroraDiscoveryMetrics] = None


def get_metrics() -> AuroraDiscoveryMetrics:
    """Get the global metrics instance."""
    global _metrics_instance
    if _metrics_instance is None:
        _metrics_instance = AuroraDiscoveryMetrics()
    return _metrics_instance


def initialize_metrics(registry: Optional[CollectorRegistry] = None) -> AuroraDiscoveryMetrics:
    """Initialize the global metrics instance."""
    global _metrics_instance
    _metrics_instance = AuroraDiscoveryMetrics(registry)
    return _metrics_instance