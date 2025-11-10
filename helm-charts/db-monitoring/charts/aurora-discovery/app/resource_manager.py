"""
Kubernetes resource management for Aurora Discovery Service.
"""

import base64
import logging
import time
from typing import Dict, List, Optional, Tuple
from kubernetes import client, config
from kubernetes.client.rest import ApiException
from models import AuroraCluster, ClusterCredentials


logger = logging.getLogger(__name__)


class ExporterResourceManager:
    """Manages Kubernetes resources for Aurora exporters."""
    
    def __init__(self, namespace: str = "observability"):
        """Initialize the resource manager.
        
        Args:
            namespace: Kubernetes namespace for resources
        """
        self.namespace = namespace
        self.apps_v1 = client.AppsV1Api()
        self.core_v1 = client.CoreV1Api()
        
        # Exporter configurations
        self.mysql_exporter_config = {
            "image": "prom/mysqld-exporter:v0.15.1",
            "port": 9104,
            "env_var": "DATA_SOURCE_NAME"
        }
        
        self.postgresql_exporter_config = {
            "image": "prometheuscommunity/postgres-exporter:v0.15.0",
            "port": 9187,
            "env_var": "DATA_SOURCE_NAME"
        }
    
    def _get_exporter_config(self, engine: str) -> Dict:
        """Get exporter configuration for the given engine type."""
        if engine == "aurora-mysql":
            return self.mysql_exporter_config
        elif engine == "aurora-postgresql":
            return self.postgresql_exporter_config
        else:
            raise ValueError(f"Unsupported engine type: {engine}")
    
    def _get_resource_names(self, cluster: AuroraCluster) -> Tuple[str, str, str]:
        """Get standardized resource names for a cluster.
        
        Returns:
            Tuple of (deployment_name, service_name, secret_name)
        """
        engine_short = cluster.engine.replace("aurora-", "")
        base_name = f"aurora-{engine_short}-{cluster.identifier}"
        
        deployment_name = base_name
        service_name = base_name
        secret_name = f"{base_name}-credentials"
        
        return deployment_name, service_name, secret_name
    
    def _create_deployment_template(self, cluster: AuroraCluster) -> client.V1Deployment:
        """Create a Deployment template for the exporter.
        
        Args:
            cluster: Aurora cluster configuration
            
        Returns:
            Kubernetes Deployment object
        """
        deployment_name, _, secret_name = self._get_resource_names(cluster)
        exporter_config = self._get_exporter_config(cluster.engine)
        engine_short = cluster.engine.replace("aurora-", "")
        
        # Common labels for all resources
        labels = {
            "app.kubernetes.io/name": "aurora-exporter",
            "app.kubernetes.io/component": f"{engine_short}-exporter",
            "app.kubernetes.io/instance": cluster.identifier,
            "aurora.aws/cluster-identifier": cluster.identifier,
            "aurora.aws/engine": cluster.engine
        }
        
        # Pod selector labels
        selector_labels = {
            "app": f"aurora-{cluster.identifier}",
            "component": f"{engine_short}-exporter"
        }
        
        container = client.V1Container(
            name="exporter",
            image=exporter_config["image"],
            ports=[client.V1ContainerPort(
                container_port=exporter_config["port"],
                name="metrics"
            )],
            env=[
                client.V1EnvVar(
                    name=exporter_config["env_var"],
                    value_from=client.V1EnvVarSource(
                        secret_key_ref=client.V1SecretKeySelector(
                            name=secret_name,
                            key="data-source-name"
                        )
                    )
                )
            ],
            resources=client.V1ResourceRequirements(
                requests={
                    "cpu": "50m",
                    "memory": "64Mi"
                },
                limits={
                    "cpu": "200m",
                    "memory": "256Mi"
                }
            ),
            liveness_probe=client.V1Probe(
                http_get=client.V1HTTPGetAction(
                    path="/metrics",
                    port=exporter_config["port"]
                ),
                initial_delay_seconds=30,
                period_seconds=30,
                timeout_seconds=10,
                failure_threshold=3
            ),
            readiness_probe=client.V1Probe(
                http_get=client.V1HTTPGetAction(
                    path="/metrics",
                    port=exporter_config["port"]
                ),
                initial_delay_seconds=5,
                period_seconds=10,
                timeout_seconds=5,
                failure_threshold=3
            )
        )
        
        pod_template = client.V1PodTemplateSpec(
            metadata=client.V1ObjectMeta(
                labels={**labels, **selector_labels}
            ),
            spec=client.V1PodSpec(
                containers=[container],
                restart_policy="Always"
            )
        )
        
        deployment_spec = client.V1DeploymentSpec(
            replicas=1,
            selector=client.V1LabelSelector(
                match_labels=selector_labels
            ),
            template=pod_template,
            strategy=client.V1DeploymentStrategy(
                type="RollingUpdate",
                rolling_update=client.V1RollingUpdateDeployment(
                    max_unavailable=0,
                    max_surge=1
                )
            )
        )
        
        return client.V1Deployment(
            api_version="apps/v1",
            kind="Deployment",
            metadata=client.V1ObjectMeta(
                name=deployment_name,
                namespace=self.namespace,
                labels=labels
            ),
            spec=deployment_spec
        )
    
    def _create_service_template(self, cluster: AuroraCluster) -> client.V1Service:
        """Create a Service template for the exporter.
        
        Args:
            cluster: Aurora cluster configuration
            
        Returns:
            Kubernetes Service object
        """
        _, service_name, _ = self._get_resource_names(cluster)
        exporter_config = self._get_exporter_config(cluster.engine)
        engine_short = cluster.engine.replace("aurora-", "")
        
        # Common labels for all resources
        labels = {
            "app.kubernetes.io/name": "aurora-exporter",
            "app.kubernetes.io/component": f"{engine_short}-exporter",
            "app.kubernetes.io/instance": cluster.identifier,
            "aurora.aws/cluster-identifier": cluster.identifier,
            "aurora.aws/engine": cluster.engine
        }
        
        # Service selector labels (must match deployment pod labels)
        selector_labels = {
            "app": f"aurora-{cluster.identifier}",
            "component": f"{engine_short}-exporter"
        }
        
        # Service Discovery annotations for Prometheus
        annotations = {
            "prometheus.io/scrape": "true",
            "prometheus.io/port": str(exporter_config["port"]),
            "prometheus.io/path": "/metrics"
        }
        
        service_port = client.V1ServicePort(
            name="metrics",
            port=exporter_config["port"],
            target_port=exporter_config["port"],
            protocol="TCP"
        )
        
        service_spec = client.V1ServiceSpec(
            selector=selector_labels,
            ports=[service_port],
            type="ClusterIP"
        )
        
        return client.V1Service(
            api_version="v1",
            kind="Service",
            metadata=client.V1ObjectMeta(
                name=service_name,
                namespace=self.namespace,
                labels=labels,
                annotations=annotations
            ),
            spec=service_spec
        )
    
    def create_exporter_secret(self, cluster: AuroraCluster, credentials: ClusterCredentials) -> client.V1Secret:
        """Create a Secret with database credentials for the exporter.
        
        Args:
            cluster: Aurora cluster configuration
            credentials: Database credentials
            
        Returns:
            Kubernetes Secret object
        """
        _, _, secret_name = self._get_resource_names(cluster)
        engine_short = cluster.engine.replace("aurora-", "")
        
        # Common labels for all resources
        labels = {
            "app.kubernetes.io/name": "aurora-exporter",
            "app.kubernetes.io/component": f"{engine_short}-exporter",
            "app.kubernetes.io/instance": cluster.identifier,
            "aurora.aws/cluster-identifier": cluster.identifier,
            "aurora.aws/engine": cluster.engine
        }
        
        # Generate the appropriate DSN based on engine type
        if cluster.engine == "aurora-mysql":
            dsn = credentials.get_mysql_dsn()
        elif cluster.engine == "aurora-postgresql":
            dsn = credentials.get_postgresql_dsn()
        else:
            raise ValueError(f"Unsupported engine type: {cluster.engine}")
        
        # Base64 encode the DSN
        dsn_encoded = base64.b64encode(dsn.encode('utf-8')).decode('utf-8')
        
        return client.V1Secret(
            api_version="v1",
            kind="Secret",
            metadata=client.V1ObjectMeta(
                name=secret_name,
                namespace=self.namespace,
                labels=labels
            ),
            type="Opaque",
            data={
                "data-source-name": dsn_encoded
            }
        )   
 
    def _retry_with_backoff(self, operation, max_retries: int = 3, base_delay: float = 1.0):
        """Execute an operation with exponential backoff retry logic.
        
        Args:
            operation: Function to execute
            max_retries: Maximum number of retry attempts
            base_delay: Base delay in seconds for exponential backoff
            
        Returns:
            Result of the operation
            
        Raises:
            Last exception if all retries fail
        """
        last_exception = None
        
        for attempt in range(max_retries + 1):
            try:
                return operation()
            except ApiException as e:
                last_exception = e
                
                # Don't retry for certain error codes
                if e.status in [400, 401, 403, 404, 409]:  # Bad Request, Unauthorized, Forbidden, Not Found, Conflict
                    if e.status == 403:
                        logger.error(f"RBAC permission denied: {e.reason}. Check ServiceAccount permissions.")
                    elif e.status == 409:
                        logger.warning(f"Resource conflict (already exists): {e.reason}")
                    raise e
                
                if attempt < max_retries:
                    delay = base_delay * (2 ** attempt)
                    logger.warning(f"Operation failed (attempt {attempt + 1}/{max_retries + 1}): {e.reason}. Retrying in {delay}s...")
                    time.sleep(delay)
                else:
                    logger.error(f"Operation failed after {max_retries + 1} attempts: {e.reason}")
            except Exception as e:
                last_exception = e
                if attempt < max_retries:
                    delay = base_delay * (2 ** attempt)
                    logger.warning(f"Unexpected error (attempt {attempt + 1}/{max_retries + 1}): {str(e)}. Retrying in {delay}s...")
                    time.sleep(delay)
                else:
                    logger.error(f"Unexpected error after {max_retries + 1} attempts: {str(e)}")
        
        raise last_exception
    
    def resource_exists(self, resource_type: str, name: str) -> bool:
        """Check if a Kubernetes resource exists.
        
        Args:
            resource_type: Type of resource ('deployment', 'service', 'secret')
            name: Name of the resource
            
        Returns:
            True if resource exists, False otherwise
        """
        try:
            if resource_type == "deployment":
                self.apps_v1.read_namespaced_deployment(name=name, namespace=self.namespace)
            elif resource_type == "service":
                self.core_v1.read_namespaced_service(name=name, namespace=self.namespace)
            elif resource_type == "secret":
                self.core_v1.read_namespaced_secret(name=name, namespace=self.namespace)
            else:
                raise ValueError(f"Unsupported resource type: {resource_type}")
            
            return True
        except ApiException as e:
            if e.status == 404:
                return False
            raise e
    
    def create_exporter_resources(self, cluster: AuroraCluster, credentials: ClusterCredentials) -> bool:
        """Create all exporter resources for a cluster.
        
        Args:
            cluster: Aurora cluster configuration
            credentials: Database credentials
            
        Returns:
            True if all resources were created successfully, False otherwise
        """
        deployment_name, service_name, secret_name = self._get_resource_names(cluster)
        
        try:
            logger.info(f"Creating exporter resources for cluster {cluster.identifier} ({cluster.engine})")
            
            # Create Secret first (required by Deployment)
            if not self.resource_exists("secret", secret_name):
                secret = self.create_exporter_secret(cluster, credentials)
                self._retry_with_backoff(
                    lambda: self.core_v1.create_namespaced_secret(
                        namespace=self.namespace,
                        body=secret
                    )
                )
                logger.info(f"Created Secret: {secret_name}")
            else:
                # Update existing secret with new credentials
                secret = self.create_exporter_secret(cluster, credentials)
                self._retry_with_backoff(
                    lambda: self.core_v1.replace_namespaced_secret(
                        name=secret_name,
                        namespace=self.namespace,
                        body=secret
                    )
                )
                logger.info(f"Updated Secret: {secret_name}")
            
            # Create Deployment
            if not self.resource_exists("deployment", deployment_name):
                deployment = self._create_deployment_template(cluster)
                self._retry_with_backoff(
                    lambda: self.apps_v1.create_namespaced_deployment(
                        namespace=self.namespace,
                        body=deployment
                    )
                )
                logger.info(f"Created Deployment: {deployment_name}")
            else:
                logger.info(f"Deployment {deployment_name} already exists, skipping creation")
            
            # Create Service
            if not self.resource_exists("service", service_name):
                service = self._create_service_template(cluster)
                self._retry_with_backoff(
                    lambda: self.core_v1.create_namespaced_service(
                        namespace=self.namespace,
                        body=service
                    )
                )
                logger.info(f"Created Service: {service_name}")
            else:
                logger.info(f"Service {service_name} already exists, skipping creation")
            
            logger.info(f"Successfully created/updated all resources for cluster {cluster.identifier}")
            return True
            
        except ApiException as e:
            if e.status == 422:  # Unprocessable Entity - often resource quota exceeded
                logger.error(f"Resource quota exceeded or validation failed for cluster {cluster.identifier}: {e.reason}")
            else:
                logger.error(f"Failed to create resources for cluster {cluster.identifier}: {e.reason}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error creating resources for cluster {cluster.identifier}: {str(e)}")
            return False
    
    def delete_exporter_resources(self, cluster: AuroraCluster) -> bool:
        """Delete all exporter resources for a cluster.
        
        Args:
            cluster: Aurora cluster configuration
            
        Returns:
            True if all resources were deleted successfully, False otherwise
        """
        deployment_name, service_name, secret_name = self._get_resource_names(cluster)
        success = True
        
        logger.info(f"Deleting exporter resources for cluster {cluster.identifier}")
        
        # Delete Deployment
        try:
            if self.resource_exists("deployment", deployment_name):
                self._retry_with_backoff(
                    lambda: self.apps_v1.delete_namespaced_deployment(
                        name=deployment_name,
                        namespace=self.namespace,
                        body=client.V1DeleteOptions(
                            propagation_policy="Foreground"
                        )
                    )
                )
                logger.info(f"Deleted Deployment: {deployment_name}")
            else:
                logger.info(f"Deployment {deployment_name} does not exist, skipping deletion")
        except Exception as e:
            logger.error(f"Failed to delete Deployment {deployment_name}: {str(e)}")
            success = False
        
        # Delete Service
        try:
            if self.resource_exists("service", service_name):
                self._retry_with_backoff(
                    lambda: self.core_v1.delete_namespaced_service(
                        name=service_name,
                        namespace=self.namespace
                    )
                )
                logger.info(f"Deleted Service: {service_name}")
            else:
                logger.info(f"Service {service_name} does not exist, skipping deletion")
        except Exception as e:
            logger.error(f"Failed to delete Service {service_name}: {str(e)}")
            success = False
        
        # Delete Secret
        try:
            if self.resource_exists("secret", secret_name):
                self._retry_with_backoff(
                    lambda: self.core_v1.delete_namespaced_secret(
                        name=secret_name,
                        namespace=self.namespace
                    )
                )
                logger.info(f"Deleted Secret: {secret_name}")
            else:
                logger.info(f"Secret {secret_name} does not exist, skipping deletion")
        except Exception as e:
            logger.error(f"Failed to delete Secret {secret_name}: {str(e)}")
            success = False
        
        if success:
            logger.info(f"Successfully deleted all resources for cluster {cluster.identifier}")
        else:
            logger.warning(f"Some resources for cluster {cluster.identifier} could not be deleted")
        
        return success
    
    def list_managed_exporters(self) -> List[str]:
        """List all managed exporter deployments.
        
        Returns:
            List of cluster identifiers for managed exporters
        """
        try:
            deployments = self.apps_v1.list_namespaced_deployment(
                namespace=self.namespace,
                label_selector="app.kubernetes.io/name=aurora-exporter"
            )
            
            cluster_identifiers = []
            for deployment in deployments.items:
                if deployment.metadata.labels:
                    cluster_id = deployment.metadata.labels.get("aurora.aws/cluster-identifier")
                    if cluster_id:
                        cluster_identifiers.append(cluster_id)
            
            return cluster_identifiers
            
        except Exception as e:
            logger.error(f"Failed to list managed exporters: {str(e)}")
            return []