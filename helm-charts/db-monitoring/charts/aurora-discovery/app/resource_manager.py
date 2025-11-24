"""
Kubernetes resource management for Aurora Discovery Service.
"""

import logging
import time
from typing import Dict, List, Optional, Tuple
from kubernetes import client, config
from kubernetes.client.rest import ApiException
from models import AuroraCluster, AuroraInstance, ClusterCredentials


logger = logging.getLogger(__name__)


class ResourceManager:
    """Manages Kubernetes resources for Aurora exporters."""
    
    def __init__(self, namespace: str = "observability"):
        """Initialize the resource manager.
        
        Args:
            namespace: Kubernetes namespace for resources
        
        Note:
            Kubernetes configuration must be loaded before instantiating this class.
            This is typically done in main.py.
        """
        self.namespace = namespace
        self.apps_v1 = client.AppsV1Api()
        self.core_v1 = client.CoreV1Api()
        
        # Exporter configurations
        self.mysql_exporter_config = {
            "image": "prom/mysqld-exporter:v0.14.0",
            "port": 9104,
            "env_var": "DATA_SOURCE_NAME",
            "args": []  # Remove all args to let it use DATA_SOURCE_NAME by default
        }
        
        self.postgresql_exporter_config = {
            "image": "prometheuscommunity/postgres-exporter:v0.15.0",
            "port": 9187,
            "env_var": "DATA_SOURCE_NAME",
            "args": [
                # "--disable-collector=replication",      # Disable replication collector (Aurora managed)
                # "--disable-collector=wal",               # Disable WAL collector (Aurora managed)
                # "--disable-collector=stat_bgwriter",    # Disable bgwriter collector (Aurora managed)
            ]
        }
    
    def _get_exporter_config(self, engine: str) -> Dict:
        """Get exporter configuration for the given engine type."""
        if engine == "aurora-mysql":
            return self.mysql_exporter_config
        elif engine == "aurora-postgresql":
            return self.postgresql_exporter_config
        else:
            raise ValueError(f"Unsupported engine type: {engine}")
    
    def _get_instance_resource_names(self, cluster: AuroraCluster, instance: AuroraInstance) -> Tuple[str, str, str]:
        """Get standardized resource names for an instance.
        
        Extracts meaningful instance name from the full identifier and combines with
        engine type and role to create short, readable resource names.
        
        Example:
            Instance ID: integrated-db-monitoring-db-mysqlinstance1-iatqhpjagau4
            Result: mysql-mysqlinstance1-writer
        
        Returns:
            Tuple of (deployment_name, service_name, secret_name)
        """
        engine_short = cluster.engine.replace("aurora-", "")
        
        # Extract instance name from identifier
        # Pattern: <cluster-prefix>-<instance-name>-<random-suffix>
        parts = instance.identifier.split('-')
        instance_name = None
        
        # Find the part containing 'instance' (e.g., mysqlinstance1, postgresqlinstance2)
        for part in parts:
            if 'instance' in part.lower():
                instance_name = part
                break
        
        # Fallback: use second-to-last part if pattern doesn't match
        if not instance_name:
            instance_name = parts[-2] if len(parts) > 1 else parts[-1]
        
        # Create short, meaningful name: <engine>-<instance-name>-<role>
        base_name = f"{engine_short}-{instance_name}-{instance.role}"
        
        deployment_name = base_name
        service_name = base_name
        secret_name = f"{base_name}-creds"
        
        return deployment_name, service_name, secret_name
    
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
        """Create exporter resources for all instances in a cluster.
        
        Args:
            cluster: Aurora cluster configuration
            credentials: Database credentials
            
        Returns:
            True if all resources were created successfully, False otherwise
        """
        try:
            logger.info(f"Creating exporter resources for cluster {cluster.identifier} with {len(cluster.instances)} instances")
            
            # Create exporter for each instance
            for instance in cluster.instances:
                self._create_instance_exporter(cluster, instance, credentials)
            
            return True
            
        except Exception as e:
            logger.error(f"Failed to create exporter resources for cluster {cluster.identifier}: {e}")
            return False
    
    def _create_instance_exporter(self, cluster: AuroraCluster, instance: AuroraInstance, credentials: ClusterCredentials) -> bool:
        """Create exporter resources for a single instance.
        
        Args:
            cluster: Aurora cluster configuration
            instance: Aurora instance configuration
            credentials: Database credentials
        """
        deployment_name, service_name, secret_name = self._get_instance_resource_names(cluster, instance)
        
        try:
            logger.info(f"Creating exporter for instance {instance.identifier} ({instance.role})")
            
            # Create Secret
            if not self.resource_exists("secret", secret_name):
                secret = self._create_instance_secret(cluster, instance, credentials)
                self._retry_with_backoff(
                    lambda: self.core_v1.create_namespaced_secret(
                        namespace=self.namespace,
                        body=secret
                    )
                )
                logger.info(f"Created Secret: {secret_name}")
            else:
                secret = self._create_instance_secret(cluster, instance, credentials)
                self._retry_with_backoff(
                    lambda: self.core_v1.replace_namespaced_secret(
                        name=secret_name,
                        namespace=self.namespace,
                        body=secret
                    )
                )
                logger.info(f"Updated Secret: {secret_name}")
            
            # Create or Update Deployment
            deployment = self._create_instance_deployment(cluster, instance)
            if not self.resource_exists("deployment", deployment_name):
                self._retry_with_backoff(
                    lambda: self.apps_v1.create_namespaced_deployment(
                        namespace=self.namespace,
                        body=deployment
                    )
                )
                logger.info(f"Created Deployment: {deployment_name}")
            else:
                self._retry_with_backoff(
                    lambda: self.apps_v1.replace_namespaced_deployment(
                        name=deployment_name,
                        namespace=self.namespace,
                        body=deployment
                    )
                )
                logger.info(f"Updated Deployment: {deployment_name}")
            
            # Create or Update Service
            service = self._create_instance_service(cluster, instance)
            if not self.resource_exists("service", service_name):
                self._retry_with_backoff(
                    lambda: self.core_v1.create_namespaced_service(
                        namespace=self.namespace,
                        body=service
                    )
                )
                logger.info(f"Created Service: {service_name}")
            else:
                self._retry_with_backoff(
                    lambda: self.core_v1.replace_namespaced_service(
                        name=service_name,
                        namespace=self.namespace,
                        body=service
                    )
                )
                logger.info(f"Updated Service: {service_name}")
            
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
    
    def delete_instance_resources(self, cluster_id: str, instance_id: str) -> bool:
        """Delete exporter resources for a specific instance.
        
        Args:
            cluster_id: Cluster identifier
            instance_id: Instance identifier
            
        Returns:
            True if all resources were deleted successfully, False otherwise
        """
        success = True
        label_selector = f"aurora.aws/cluster-identifier={cluster_id},aurora.aws/instance-identifier={instance_id}"
        
        logger.info(f"Deleting exporter resources for instance {instance_id} in cluster {cluster_id}")
        
        # Delete Deployment for this instance
        try:
            deployments = self.apps_v1.list_namespaced_deployment(
                namespace=self.namespace,
                label_selector=label_selector
            )
            for deployment in deployments.items:
                try:
                    self._retry_with_backoff(
                        lambda: self.apps_v1.delete_namespaced_deployment(
                            name=deployment.metadata.name,
                            namespace=self.namespace,
                            body=client.V1DeleteOptions(
                                propagation_policy="Foreground"
                            )
                        )
                    )
                    logger.info(f"Deleted Deployment: {deployment.metadata.name}")
                except Exception as e:
                    logger.error(f"Failed to delete Deployment {deployment.metadata.name}: {str(e)}")
                    success = False
        except Exception as e:
            logger.error(f"Failed to list deployments for instance {instance_id}: {str(e)}")
            success = False
        
        # Delete Service for this instance
        try:
            services = self.core_v1.list_namespaced_service(
                namespace=self.namespace,
                label_selector=label_selector
            )
            for service in services.items:
                try:
                    self._retry_with_backoff(
                        lambda: self.core_v1.delete_namespaced_service(
                            name=service.metadata.name,
                            namespace=self.namespace
                        )
                    )
                    logger.info(f"Deleted Service: {service.metadata.name}")
                except Exception as e:
                    logger.error(f"Failed to delete Service {service.metadata.name}: {str(e)}")
                    success = False
        except Exception as e:
            logger.error(f"Failed to list services for instance {instance_id}: {str(e)}")
            success = False
        
        # Delete Secret for this instance
        try:
            secrets = self.core_v1.list_namespaced_secret(
                namespace=self.namespace,
                label_selector=label_selector
            )
            for secret in secrets.items:
                try:
                    self._retry_with_backoff(
                        lambda: self.core_v1.delete_namespaced_secret(
                            name=secret.metadata.name,
                            namespace=self.namespace
                        )
                    )
                    logger.info(f"Deleted Secret: {secret.metadata.name}")
                except Exception as e:
                    logger.error(f"Failed to delete Secret {secret.metadata.name}: {str(e)}")
                    success = False
        except Exception as e:
            logger.error(f"Failed to list secrets for instance {instance_id}: {str(e)}")
            success = False
        
        if success:
            logger.info(f"Successfully deleted all resources for instance {instance_id}")
        else:
            logger.warning(f"Some resources for instance {instance_id} could not be deleted")
        
        return success
    
    def delete_exporter_resources(self, cluster_id: str) -> bool:
        """Delete all exporter resources for a cluster by label selector.
        
        This method deletes all instance-level exporters for a given cluster
        by using label selectors to find all resources associated with the cluster.
        
        Args:
            cluster_id: Cluster identifier
            
        Returns:
            True if all resources were deleted successfully, False otherwise
        """
        success = True
        label_selector = f"aurora.aws/cluster-identifier={cluster_id}"
        
        logger.info(f"Deleting all exporter resources for cluster {cluster_id}")
        
        # Delete all Deployments for this cluster
        try:
            deployments = self.apps_v1.list_namespaced_deployment(
                namespace=self.namespace,
                label_selector=label_selector
            )
            for deployment in deployments.items:
                try:
                    self._retry_with_backoff(
                        lambda: self.apps_v1.delete_namespaced_deployment(
                            name=deployment.metadata.name,
                            namespace=self.namespace,
                            body=client.V1DeleteOptions(
                                propagation_policy="Foreground"
                            )
                        )
                    )
                    logger.info(f"Deleted Deployment: {deployment.metadata.name}")
                except Exception as e:
                    logger.error(f"Failed to delete Deployment {deployment.metadata.name}: {str(e)}")
                    success = False
        except Exception as e:
            logger.error(f"Failed to list deployments for cluster {cluster_id}: {str(e)}")
            success = False
        
        # Delete all Services for this cluster
        try:
            services = self.core_v1.list_namespaced_service(
                namespace=self.namespace,
                label_selector=label_selector
            )
            for service in services.items:
                try:
                    self._retry_with_backoff(
                        lambda: self.core_v1.delete_namespaced_service(
                            name=service.metadata.name,
                            namespace=self.namespace
                        )
                    )
                    logger.info(f"Deleted Service: {service.metadata.name}")
                except Exception as e:
                    logger.error(f"Failed to delete Service {service.metadata.name}: {str(e)}")
                    success = False
        except Exception as e:
            logger.error(f"Failed to list services for cluster {cluster_id}: {str(e)}")
            success = False
        
        # Delete all Secrets for this cluster
        try:
            secrets = self.core_v1.list_namespaced_secret(
                namespace=self.namespace,
                label_selector=label_selector
            )
            for secret in secrets.items:
                try:
                    self._retry_with_backoff(
                        lambda: self.core_v1.delete_namespaced_secret(
                            name=secret.metadata.name,
                            namespace=self.namespace
                        )
                    )
                    logger.info(f"Deleted Secret: {secret.metadata.name}")
                except Exception as e:
                    logger.error(f"Failed to delete Secret {secret.metadata.name}: {str(e)}")
                    success = False
        except Exception as e:
            logger.error(f"Failed to list secrets for cluster {cluster_id}: {str(e)}")
            success = False
        
        if success:
            logger.info(f"Successfully deleted all resources for cluster {cluster_id}")
        else:
            logger.warning(f"Some resources for cluster {cluster_id} could not be deleted")
        
        return success
    
    def _create_instance_secret(self, cluster: AuroraCluster, instance: AuroraInstance, credentials: ClusterCredentials) -> client.V1Secret:
        """Create a Secret for an instance exporter."""
        _, _, secret_name = self._get_instance_resource_names(cluster, instance)
        engine_short = cluster.engine.replace("aurora-", "")
        
        # Generate short hash for unique identification
        import hashlib
        instance_hash = hashlib.md5(instance.identifier.encode()).hexdigest()[:8]
        
        # Minimal labels (short values only)
        labels = {
            "app": "aurora-exporter",
            "component": engine_short,
            "role": instance.role,
            "instance": instance_hash
        }
        
        # Annotations for full identifiers
        annotations = {
            "aurora.aws/cluster-identifier": cluster.identifier,
            "aurora.aws/instance-identifier": instance.identifier,
            "aurora.aws/availability-zone": instance.availability_zone,
            "aurora.aws/engine": cluster.engine
        }
        
        # Use instance endpoint instead of cluster endpoint
        instance_credentials = ClusterCredentials(
            endpoint=instance.endpoint,
            port=instance.port,
            username=credentials.username,
            password=credentials.password,
            database=credentials.database
        )
        
        if cluster.engine == "aurora-mysql":
            ### Hard Coding ###
            instance_credentials = ClusterCredentials(
                endpoint=instance.endpoint,
                port=instance.port,
                username="exporter",
                password="adminadmin",
                database=None
            )
            ### Hard Coding ###

            dsn = instance_credentials.get_mysql_dsn()
        elif cluster.engine == "aurora-postgresql":
            dsn = instance_credentials.get_postgresql_dsn()
        else:
            raise ValueError(f"Unsupported engine type: {cluster.engine}")
        
        # Use stringData for automatic base64 encoding by Kubernetes
        return client.V1Secret(
            api_version="v1",
            kind="Secret",
            metadata=client.V1ObjectMeta(
                name=secret_name,
                namespace=self.namespace,
                labels=labels,
                annotations=annotations
            ),
            type="Opaque",
            string_data={"data-source-name": dsn}
        )
    
    def _create_instance_deployment(self, cluster: AuroraCluster, instance: AuroraInstance) -> client.V1Deployment:
        """Create a Deployment for an instance exporter."""
        deployment_name, _, secret_name = self._get_instance_resource_names(cluster, instance)
        exporter_config = self._get_exporter_config(cluster.engine)
        engine_short = cluster.engine.replace("aurora-", "")
        
        # Generate short hash for unique identification
        import hashlib
        instance_hash = hashlib.md5(instance.identifier.encode()).hexdigest()[:8]
        
        # Minimal labels (short values only)
        labels = {
            "app": "aurora-exporter",
            "component": engine_short,
            "role": instance.role,
            "instance": instance_hash
        }
        
        # Annotations for full identifiers
        annotations = {
            "aurora.aws/cluster-identifier": cluster.identifier,
            "aurora.aws/instance-identifier": instance.identifier,
            "aurora.aws/availability-zone": instance.availability_zone,
            "aurora.aws/engine": cluster.engine
        }
        
        # Minimal selector
        selector = {
            "app": "aurora-exporter",
            "instance": instance_hash
        }
        
        return client.V1Deployment(
            api_version="apps/v1",
            kind="Deployment",
            metadata=client.V1ObjectMeta(
                name=deployment_name,
                namespace=self.namespace,
                labels=labels,
                annotations=annotations
            ),
            spec=client.V1DeploymentSpec(
                replicas=1,
                selector=client.V1LabelSelector(match_labels=selector),
                template=client.V1PodTemplateSpec(
                    metadata=client.V1ObjectMeta(labels=labels),
                    spec=client.V1PodSpec(
                        containers=[
                            client.V1Container(
                                name="exporter",
                                image=exporter_config["image"],
                                args=exporter_config.get("args", []),
                                ports=[client.V1ContainerPort(container_port=exporter_config["port"], name="metrics")],
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
                                    requests={"cpu": "100m", "memory": "128Mi"},
                                    limits={"cpu": "200m", "memory": "256Mi"}
                                )
                            )
                        ]
                    )
                )
            )
        )
    
    def _create_instance_service(self, cluster: AuroraCluster, instance: AuroraInstance) -> client.V1Service:
        """Create a Service for an instance exporter."""
        _, service_name, _ = self._get_instance_resource_names(cluster, instance)
        exporter_config = self._get_exporter_config(cluster.engine)
        engine_short = cluster.engine.replace("aurora-", "")
        
        # Generate short hash for unique identification
        import hashlib
        instance_hash = hashlib.md5(instance.identifier.encode()).hexdigest()[:8]
        
        # Minimal labels (short values only)
        labels = {
            "app": "aurora-exporter",
            "component": engine_short,
            "role": instance.role,
            "instance": instance_hash
        }
        
        # Minimal selector
        selector = {
            "app": "aurora-exporter",
            "instance": instance_hash
        }
        
        # Annotations for full identifiers and Prometheus
        annotations = {
            "prometheus.io/scrape": "true",
            "prometheus.io/port": str(exporter_config["port"]),
            "prometheus.io/path": "/metrics",
            "aurora.aws/cluster-identifier": cluster.identifier,
            "aurora.aws/instance-identifier": instance.identifier,
            "aurora.aws/availability-zone": instance.availability_zone,
            "aurora.aws/engine": cluster.engine
        }
        
        return client.V1Service(
            api_version="v1",
            kind="Service",
            metadata=client.V1ObjectMeta(
                name=service_name,
                namespace=self.namespace,
                labels=labels,
                annotations=annotations
            ),
            spec=client.V1ServiceSpec(
                selector=selector,
                ports=[
                    client.V1ServicePort(
                        name="metrics",
                        port=exporter_config["port"],
                        # target_port="metrics",
                        target_port=exporter_config["port"]
                    )
                ],
                type="ClusterIP"
            )
        )