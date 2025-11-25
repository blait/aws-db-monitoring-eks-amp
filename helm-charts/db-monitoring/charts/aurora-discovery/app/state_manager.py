"""
State management for Aurora Discovery Service using Kubernetes resource annotations.
"""

import logging
from datetime import datetime
from typing import Optional, Dict, Set
from kubernetes import client
from kubernetes.client.rest import ApiException

from models import ClusterState, AuroraCluster, AuroraInstance


logger = logging.getLogger(__name__)


class StateManager:
    """Manages Aurora cluster state by reading Kubernetes resource annotations."""
    
    def __init__(self, namespace: str):
        """
        Initialize StateManager.
        
        Args:
            namespace: Kubernetes namespace to query for resources
        
        Note:
            Kubernetes configuration must be loaded before instantiating this class.
            This is typically done in main.py.
        """
        self.k8s_client = client.CoreV1Api()
        self.apps_client = client.AppsV1Api()
        self.namespace = namespace
    
    def load_state(self) -> Optional[ClusterState]:
        """
        Load cluster state from Kubernetes resource annotations.
        
        Queries all Services with the aurora.aws/cluster-identifier annotation
        and reconstructs the cluster state from their annotations.
        
        Returns:
            ClusterState if resources found, None if no resources exist
        """
        try:
            # Query all services with aurora-exporter label selector
            services = self.k8s_client.list_namespaced_service(
                namespace=self.namespace,
                label_selector='app.kubernetes.io/name=aurora-exporter'
            )
            
            if not services.items:
                logger.info("No Aurora resources found in Kubernetes")
                return None
            
            # Reconstruct clusters from service annotations
            clusters: Dict[str, AuroraCluster] = {}
            
            for service in services.items:
                annotations = service.metadata.annotations or {}
                
                # Skip services without cluster identifier
                if 'aurora.aws/cluster-identifier' not in annotations:
                    logger.warning(f"Service {service.metadata.name} missing cluster identifier annotation")
                    continue
                
                cluster_id = annotations['aurora.aws/cluster-identifier']
                
                # Check if this is a cluster-level service or instance-level service
                if 'aurora.aws/instance-identifier' in annotations:
                    # This is an instance service
                    instance = AuroraInstance.from_annotations(annotations)
                    
                    # Add instance to its cluster (create cluster if needed)
                    if cluster_id not in clusters:
                        # We'll need to find the cluster-level service or create a minimal cluster
                        clusters[cluster_id] = self._get_or_create_cluster_from_instance(
                            cluster_id, instance, services.items
                        )
                    
                    # Add instance to cluster if not already present
                    if not any(inst.identifier == instance.identifier for inst in clusters[cluster_id].instances):
                        clusters[cluster_id].instances.append(instance)
                else:
                    # This is a cluster-level service (if we support them in the future)
                    if cluster_id not in clusters:
                        cluster = AuroraCluster.from_annotations(annotations)
                        clusters[cluster_id] = cluster
            
            if not clusters:
                logger.info("No valid Aurora clusters found in Kubernetes resources")
                return None
            
            logger.info(f"Loaded state with {len(clusters)} clusters from Kubernetes resources")
            for cluster_id, cluster in clusters.items():
                logger.info(f"  Cluster {cluster_id}: {len(cluster.instances)} instances")
            
            return ClusterState(
                last_updated=datetime.utcnow(),
                clusters=clusters
            )
            
        except ApiException as e:
            if e.status == 403:
                logger.error(f"Insufficient permissions to list Services in namespace {self.namespace}: {e}")
                raise
            else:
                logger.error(f"Failed to list Services in namespace {self.namespace}: {e}")
                raise
        except Exception as e:
            logger.error(f"Unexpected error loading state from Kubernetes resources: {e}")
            return None
    
    def _get_or_create_cluster_from_instance(
        self, 
        cluster_id: str, 
        instance: AuroraInstance,
        all_services: list
    ) -> AuroraCluster:
        """
        Get cluster information from a cluster-level service or create from instance data.
        
        Args:
            cluster_id: Cluster identifier
            instance: Instance that belongs to this cluster
            all_services: All services to search for cluster-level service
            
        Returns:
            AuroraCluster object
        """
        # Try to find a cluster-level service (without instance-identifier annotation)
        for service in all_services:
            annotations = service.metadata.annotations or {}
            if (annotations.get('aurora.aws/cluster-identifier') == cluster_id and
                'aurora.aws/instance-identifier' not in annotations):
                return AuroraCluster.from_annotations(annotations)
        
        # No cluster-level service found, create minimal cluster from instance data
        # This handles the case where we only have instance-level resources
        logger.debug(f"Creating cluster {cluster_id} from instance data")
        
        # Infer engine from instance endpoint or use a default
        # In practice, we'll get this from AWS discovery, but for state reconstruction
        # we need to handle missing data gracefully
        engine = 'aurora-mysql'  # Default, will be corrected on next AWS sync
        
        return AuroraCluster(
            identifier=cluster_id,
            engine=engine,
            endpoint='',  # Will be updated from AWS
            port=instance.port,
            secrets_arn='',  # Will be updated from AWS
            status=instance.status,
            last_seen=instance.last_seen or datetime.utcnow(),
            discovered_at=instance.discovered_at,
            instances=[]
        )
    
    def get_deployed_cluster_identifiers(self) -> Set[str]:
        """
        Get set of cluster identifiers that are currently deployed in Kubernetes.
        
        Returns:
            Set of cluster identifier strings
        """
        try:
            services = self.k8s_client.list_namespaced_service(
                namespace=self.namespace,
                label_selector='app.kubernetes.io/name=aurora-exporter'
            )
            
            cluster_ids = set()
            for service in services.items:
                annotations = service.metadata.annotations or {}
                if 'aurora.aws/cluster-identifier' in annotations:
                    cluster_ids.add(annotations['aurora.aws/cluster-identifier'])
            
            return cluster_ids
            
        except ApiException as e:
            logger.error(f"Failed to list cluster identifiers: {e}")
            return set()
    
    def get_deployed_instance_identifiers(self, cluster_id: str) -> Set[str]:
        """
        Get set of instance identifiers for a specific cluster that are deployed in Kubernetes.
        
        Args:
            cluster_id: Cluster identifier to query instances for
            
        Returns:
            Set of instance identifier strings
        """
        try:
            # Query services for this specific cluster
            # Note: We use annotation-based filtering since cluster ID is in annotations, not labels
            services = self.k8s_client.list_namespaced_service(
                namespace=self.namespace,
                label_selector='app.kubernetes.io/name=aurora-exporter'
            )
            
            instance_ids = set()
            for service in services.items:
                annotations = service.metadata.annotations or {}
                # Filter by cluster ID and get instance identifiers
                if (annotations.get('aurora.aws/cluster-identifier') == cluster_id and
                    'aurora.aws/instance-identifier' in annotations):
                    instance_ids.add(annotations['aurora.aws/instance-identifier'])
            
            return instance_ids
            
        except ApiException as e:
            logger.error(f"Failed to list instance identifiers for cluster {cluster_id}: {e}")
            return set()
    
