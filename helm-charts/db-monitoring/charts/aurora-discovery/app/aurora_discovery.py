"""
Aurora Discovery Service

Main service class that orchestrates Aurora cluster discovery and exporter management.
"""

import logging
from typing import Dict, List, Optional
from collections import defaultdict
from datetime import datetime

from aws_client import AWSClient
from state_manager import StateManager
from resource_manager import ResourceManager
from models import AuroraCluster, AuroraInstance, ClusterState
from metrics import get_metrics


class AuroraDiscoveryService:
    """Main service class for Aurora cluster discovery and management."""
    
    def __init__(
        self,
        aws_region: str,
        namespace: str
    ):
        """Initialize the Aurora Discovery Service.
        
        Args:
            aws_region: AWS region to scan for Aurora clusters
            namespace: Kubernetes namespace for resources
        """
        self.logger = logging.getLogger(__name__)
        self.aws_region = aws_region
        self.namespace = namespace
        
        # Initialize components
        self.aws_client = AWSClient(aws_region)
        self.state_manager = StateManager(namespace)
        self.resource_manager = ResourceManager(namespace)
        self.metrics = get_metrics()
        
        self.logger.info("Aurora Discovery Service initialized", extra={
            "aws_region": aws_region,
            "namespace": namespace
        })
    
    def run(self) -> None:
        """Execute the reconciliation loop to sync AWS and Kubernetes state."""
        try:
            self.logger.info("Starting Aurora reconciliation cycle")
            
            with self.metrics.time_execution_phase("full_cycle"):
                # Step 1: Discover current Aurora clusters from AWS
                with self.metrics.time_execution_phase("discovery"):
                    aws_clusters = self._discover_clusters()
                    self.logger.info(f"Discovered {len(aws_clusters)} Aurora clusters from AWS")
                
                # Step 2: Load deployed clusters from Kubernetes
                with self.metrics.time_execution_phase("state_load"):
                    k8s_state = self.state_manager.load_state()
                    k8s_clusters = k8s_state.clusters if k8s_state else {}
                    self.logger.info(f"Found {len(k8s_clusters)} clusters deployed in Kubernetes")
                
                # Step 3: Reconcile states and determine actions
                with self.metrics.time_execution_phase("state_comparison"):
                    actions = self._reconcile_states(aws_clusters, k8s_clusters)
                    self.logger.info("Reconciliation actions determined", extra={
                        "to_create": len(actions['to_create']),
                        "to_delete": len(actions['to_delete']),
                        "to_update": len(actions['to_update']),
                        "to_refresh": len(actions['to_refresh'])
                    })
                
                # Step 4: Execute reconciliation actions
                with self.metrics.time_execution_phase("resource_management"):
                    self._execute_reconciliation(actions, aws_clusters)
                
                # Step 5: Update metrics (no ConfigMap save)
                self._update_metrics(aws_clusters)
            
            # Record successful execution
            self.metrics.record_execution_success()
            self.logger.info("Aurora reconciliation cycle completed successfully")
            
        except Exception as e:
            self.metrics.record_execution_failure()
            self.metrics.record_error(type(e).__name__, "aurora_discovery")
            self.logger.error("Aurora reconciliation cycle failed", extra={
                "error": str(e),
                "error_type": type(e).__name__
            })
            raise
    
    def _discover_clusters(self) -> Dict[str, AuroraCluster]:
        """Discover all Aurora clusters in the configured region."""
        self.logger.info("Discovering Aurora clusters", extra={"region": self.aws_region})
        
        try:
            # Discover Aurora clusters using AWS client
            clusters = self.aws_client.discover_aurora_clusters()
            
            # Filter clusters that have Secrets Manager ARNs
            filtered_clusters = {}
            for cluster_id, cluster in clusters.items():
                # Record discovery metrics
                engine_type = cluster.engine.replace('aurora-', '')
                self.metrics.record_cluster_discovered(engine_type)
                
                if cluster.secrets_arn:
                    filtered_clusters[cluster_id] = cluster
                    self.metrics.record_cluster_filtered(engine_type)
                    self.logger.debug("Cluster included in monitoring", extra={
                        "cluster_id": cluster_id,
                        "engine": cluster.engine,
                        "endpoint": cluster.endpoint
                    })
                else:
                    self.metrics.record_cluster_skipped("no_secrets_manager_arn")
                    self.logger.warning("Cluster skipped - no Secrets Manager ARN", extra={
                        "cluster_id": cluster_id,
                        "engine": cluster.engine
                    })
            
            self.logger.info("Cluster discovery completed", extra={
                "total_discovered": len(clusters),
                "filtered_count": len(filtered_clusters)
            })
            
            return filtered_clusters
            
        except Exception as e:
            self.logger.error("Failed to discover Aurora clusters", extra={
                "error": str(e),
                "error_type": type(e).__name__
            })
            raise
    
    def _reconcile_states(
        self,
        aws_clusters: Dict[str, AuroraCluster],
        k8s_clusters: Dict[str, AuroraCluster]
    ) -> Dict[str, List]:
        """Reconcile AWS and Kubernetes states to determine required actions.
        
        Compares the current AWS state with deployed Kubernetes resources and
        determines what actions need to be taken to synchronize them.
        
        Args:
            aws_clusters: Clusters discovered from AWS
            k8s_clusters: Clusters deployed in Kubernetes
            
        Returns:
            Dictionary with action lists:
            - to_create: List of (cluster_id, instance) tuples for new resources
            - to_delete: List of (cluster_id, instance_id) tuples for removed resources
            - to_update: List of (cluster_id, instance) tuples for changed resources
            - to_refresh: List of (cluster_id, instance) tuples for last_seen updates only
        """
        actions = {
            'to_create': [],
            'to_delete': [],
            'to_update': [],
            'to_refresh': []
        }
        
        # Process AWS clusters
        for cluster_id, aws_cluster in aws_clusters.items():
            if cluster_id not in k8s_clusters:
                # New cluster - create all instances
                for instance in aws_cluster.instances:
                    actions['to_create'].append((cluster_id, instance))
                    self.logger.info(f"New cluster detected: {cluster_id}, instance: {instance.identifier}")
            else:
                # Existing cluster - check instances
                k8s_cluster = k8s_clusters[cluster_id]
                aws_instance_map = {inst.identifier: inst for inst in aws_cluster.instances}
                k8s_instance_map = {inst.identifier: inst for inst in k8s_cluster.instances}
                
                # Check for new instances
                for inst_id, aws_instance in aws_instance_map.items():
                    if inst_id not in k8s_instance_map:
                        actions['to_create'].append((cluster_id, aws_instance))
                        self.logger.info(f"New instance detected: {inst_id} in cluster {cluster_id}")
                    else:
                        # Instance exists - check if it needs update
                        k8s_instance = k8s_instance_map[inst_id]
                        if self._instance_needs_update(aws_instance, k8s_instance):
                            actions['to_update'].append((cluster_id, aws_instance))
                            self.logger.info(f"Instance needs update: {inst_id} in cluster {cluster_id}")
                        else:
                            # No changes, just refresh last_seen
                            actions['to_refresh'].append((cluster_id, aws_instance))
                
                # Check for removed instances
                for inst_id in k8s_instance_map:
                    if inst_id not in aws_instance_map:
                        actions['to_delete'].append((cluster_id, inst_id))
                        self.logger.info(f"Instance removed: {inst_id} in cluster {cluster_id}")
        
        # Process removed clusters
        for cluster_id, k8s_cluster in k8s_clusters.items():
            if cluster_id not in aws_clusters:
                # Cluster removed - delete all instances
                for instance in k8s_cluster.instances:
                    actions['to_delete'].append((cluster_id, instance.identifier))
                self.logger.info(f"Cluster removed: {cluster_id}")
        
        return actions
    
    def _instance_needs_update(self, aws_instance: AuroraInstance, k8s_instance: AuroraInstance) -> bool:
        """Check if an instance configuration has changed and needs update.
        
        Compares critical configuration fields between AWS and Kubernetes states
        to determine if resources need to be recreated.
        
        Args:
            aws_instance: Instance from AWS
            k8s_instance: Instance from Kubernetes
            
        Returns:
            True if instance needs update, False otherwise
        """
        # Check critical configuration changes that require resource recreation
        if aws_instance.endpoint != k8s_instance.endpoint:
            self.logger.info(f"Endpoint changed for {aws_instance.identifier}: "
                           f"{k8s_instance.endpoint} -> {aws_instance.endpoint}")
            return True
        
        if aws_instance.port != k8s_instance.port:
            self.logger.info(f"Port changed for {aws_instance.identifier}: "
                           f"{k8s_instance.port} -> {aws_instance.port}")
            return True
        
        if aws_instance.status != k8s_instance.status:
            self.logger.info(f"Status changed for {aws_instance.identifier}: "
                           f"{k8s_instance.status} -> {aws_instance.status}")
            return True
        
        if aws_instance.role != k8s_instance.role:
            self.logger.info(f"Role changed for {aws_instance.identifier}: "
                           f"{k8s_instance.role} -> {aws_instance.role}")
            return True
        
        if aws_instance.availability_zone != k8s_instance.availability_zone:
            self.logger.info(f"Availability zone changed for {aws_instance.identifier}: "
                           f"{k8s_instance.availability_zone} -> {aws_instance.availability_zone}")
            return True
        
        return False
    
    def _compare_states(
        self,
        current_clusters: Dict[str, AuroraCluster],
        previous_clusters: Dict[str, AuroraCluster]
    ) -> Dict[str, List[str]]:
        """Compare current and previous cluster states to determine required actions."""
        actions = {
            "create": [],
            "update": [],
            "delete": []
        }
        
        # Find clusters to create (new clusters)
        for cluster_id in current_clusters:
            if cluster_id not in previous_clusters:
                actions["create"].append(cluster_id)
                self.logger.info("New cluster detected", extra={"cluster_id": cluster_id})
        
        # Find clusters to update (existing clusters with changes)
        for cluster_id in current_clusters:
            if cluster_id in previous_clusters:
                current = current_clusters[cluster_id]
                previous = previous_clusters[cluster_id]
                
                # Check if cluster configuration or instances have changed
                cluster_changed = (current.endpoint != previous.endpoint or 
                                 current.port != previous.port or 
                                 current.secrets_arn != previous.secrets_arn)
                
                instances_changed = self._instances_changed(current.instances, previous.instances)
                
                if cluster_changed or instances_changed:
                    actions["update"].append(cluster_id)
                    self.logger.info("Cluster or instances changed", extra={
                        "cluster_id": cluster_id,
                        "cluster_changed": cluster_changed,
                        "instances_changed": instances_changed
                    })
        
        # Find clusters to delete (removed clusters)
        for cluster_id in previous_clusters:
            if cluster_id not in current_clusters:
                actions["delete"].append(cluster_id)
                self.logger.info("Cluster removed", extra={"cluster_id": cluster_id})
        
        self.logger.info("State comparison completed", extra={
            "create_count": len(actions["create"]),
            "update_count": len(actions["update"]),
            "delete_count": len(actions["delete"])
        })
        
        return actions
    
    def _instances_changed(self, current_instances: List, previous_instances: List) -> bool:
        """Check if instances have changed between states."""
        # Compare instance identifiers
        current_ids = {inst.identifier for inst in current_instances}
        previous_ids = {inst.identifier for inst in previous_instances}
        
        # Check for added or removed instances
        if current_ids != previous_ids:
            return True
        
        # Check for instance configuration changes
        current_map = {inst.identifier: inst for inst in current_instances}
        previous_map = {inst.identifier: inst for inst in previous_instances}
        
        for inst_id in current_ids:
            curr = current_map[inst_id]
            prev = previous_map[inst_id]
            if (curr.endpoint != prev.endpoint or 
                curr.port != prev.port or 
                curr.role != prev.role or
                curr.status != prev.status):
                return True
        
        return False
    
    def _execute_reconciliation(
        self,
        actions: Dict[str, List],
        aws_clusters: Dict[str, AuroraCluster]
    ) -> None:
        """Execute reconciliation actions to sync Kubernetes with AWS state.
        
        Args:
            actions: Dictionary of action lists from _reconcile_states()
            aws_clusters: Current AWS cluster state
        """
        # Step 1: Handle deletions first
        for cluster_id, instance_id in actions['to_delete']:
            try:
                self.resource_manager.delete_instance_resources(cluster_id, instance_id)
                self.metrics.record_exporter_deleted("unknown")
                self.logger.info(f"Deleted resources for instance {instance_id} in cluster {cluster_id}")
            except Exception as e:
                self.metrics.record_error(type(e).__name__, "resource_manager")
                self.logger.error(f"Failed to delete instance {instance_id}: {str(e)}")
        
        # Step 2: Handle creations
        for cluster_id, instance in actions['to_create']:
            try:
                cluster = aws_clusters.get(cluster_id)
                if not cluster:
                    self.logger.error(f"Cluster {cluster_id} not found in AWS state")
                    continue
                
                # Set discovered_at timestamp for new instances
                if not instance.discovered_at:
                    instance.discovered_at = datetime.utcnow()
                
                # Set last_seen timestamp
                instance.last_seen = datetime.utcnow()
                
                # Get credentials
                credentials = self.aws_client.get_cluster_credentials(cluster)
                if not credentials:
                    self.metrics.record_error("CredentialsRetrievalFailed", "aws_client")
                    self.logger.error(f"Failed to retrieve credentials for cluster {cluster_id}")
                    continue
                
                # Create resources
                self.resource_manager._create_instance_exporter(cluster, instance, credentials)
                
                engine_type = cluster.engine.replace('aurora-', '')
                self.metrics.record_exporter_created(engine_type)
                self.logger.info(f"Created resources for instance {instance.identifier} in cluster {cluster_id}")
                
            except Exception as e:
                self.metrics.record_error(type(e).__name__, "resource_manager")
                self.logger.error(f"Failed to create instance {instance.identifier}: {str(e)}")
        
        # Step 3: Handle updates
        for cluster_id, instance in actions['to_update']:
            try:
                cluster = aws_clusters.get(cluster_id)
                if not cluster:
                    self.logger.error(f"Cluster {cluster_id} not found in AWS state")
                    continue
                
                # Update last_seen timestamp
                instance.last_seen = datetime.utcnow()
                
                # Get credentials
                credentials = self.aws_client.get_cluster_credentials(cluster)
                if not credentials:
                    self.metrics.record_error("CredentialsRetrievalFailed", "aws_client")
                    self.logger.error(f"Failed to retrieve credentials for cluster {cluster_id}")
                    continue
                
                # Update resources (recreate with new configuration)
                self.resource_manager._create_instance_exporter(cluster, instance, credentials)
                
                engine_type = cluster.engine.replace('aurora-', '')
                self.metrics.record_exporter_updated(engine_type)
                self.logger.info(f"Updated resources for instance {instance.identifier} in cluster {cluster_id}")
                
            except Exception as e:
                self.metrics.record_error(type(e).__name__, "resource_manager")
                self.logger.error(f"Failed to update instance {instance.identifier}: {str(e)}")
        
        # Step 4: Handle refreshes (last_seen updates only)
        for cluster_id, instance in actions['to_refresh']:
            try:
                cluster = aws_clusters.get(cluster_id)
                if not cluster:
                    self.logger.error(f"Cluster {cluster_id} not found in AWS state")
                    continue
                
                # Update last_seen timestamp
                instance.last_seen = datetime.utcnow()
                
                # Update only the last_seen annotation
                self.resource_manager.update_last_seen_annotations(cluster, instance)
                self.logger.debug(f"Refreshed last_seen for instance {instance.identifier} in cluster {cluster_id}")
                
            except Exception as e:
                self.logger.error(f"Failed to refresh instance {instance.identifier}: {str(e)}")
    
    def _execute_actions(self, actions: Dict[str, List[str]], current_clusters: Dict[str, AuroraCluster], previous_clusters: Dict[str, AuroraCluster]) -> None:
        """Execute the required resource management actions.
        
        DEPRECATED: This method is kept for backward compatibility but is no longer used.
        Use _execute_reconciliation() instead.
        """
        # Handle deletions first
        for cluster_id in actions["delete"]:
            try:
                # We don't have the cluster info for deleted clusters, so we'll try to infer engine type
                # from existing resources or use a generic metric
                self.resource_manager.delete_exporter_resources(cluster_id)
                self.metrics.record_exporter_deleted("unknown")  # Engine type unknown for deleted clusters
                self.logger.info("Deleted exporter resources", extra={"cluster_id": cluster_id})
            except Exception as e:
                self.metrics.record_error(type(e).__name__, "resource_manager")
                self.logger.error("Failed to delete exporter resources", extra={
                    "cluster_id": cluster_id,
                    "error": str(e)
                })
        
        # Handle creations and updates
        for cluster_id in actions["create"] + actions["update"]:
            try:
                # Get cluster information
                cluster = current_clusters.get(cluster_id)
                if not cluster:
                    self.logger.error("Cluster not found during action execution", extra={
                        "cluster_id": cluster_id
                    })
                    continue
                
                # For updates, check if any instances were removed and clean them up
                if cluster_id in actions["update"]:
                    previous_cluster = previous_clusters.get(cluster_id)
                    if previous_cluster:
                        current_instance_ids = {inst.identifier for inst in cluster.instances}
                        previous_instance_ids = {inst.identifier for inst in previous_cluster.instances}
                        removed_instance_ids = previous_instance_ids - current_instance_ids
                        
                        if removed_instance_ids:
                            self.logger.info(f"Detected {len(removed_instance_ids)} removed instances", extra={
                                "cluster_id": cluster_id,
                                "removed_instances": list(removed_instance_ids)
                            })
                            
                            for instance_id in removed_instance_ids:
                                try:
                                    self.resource_manager.delete_instance_resources(cluster_id, instance_id)
                                    self.logger.info("Deleted resources for removed instance", extra={
                                        "cluster_id": cluster_id,
                                        "instance_id": instance_id
                                    })
                                except Exception as e:
                                    self.logger.error("Failed to delete resources for removed instance", extra={
                                        "cluster_id": cluster_id,
                                        "instance_id": instance_id,
                                        "error": str(e)
                                    })
                
                # Get cluster credentials
                credentials = self.aws_client.get_cluster_credentials(cluster)
                if not credentials:
                    self.metrics.record_error("CredentialsRetrievalFailed", "aws_client")
                    self.logger.error("Failed to retrieve cluster credentials", extra={
                        "cluster_id": cluster_id,
                        "secrets_arn": cluster.secrets_arn
                    })
                    continue
                
                # Create or update exporter resources
                action_type = "create" if cluster_id in actions["create"] else "update"
                engine_type = cluster.engine.replace('aurora-', '')
                
                self.resource_manager.create_exporter_resources(cluster, credentials)
                
                # Record metrics
                if action_type == "create":
                    self.metrics.record_exporter_created(engine_type)
                else:
                    self.metrics.record_exporter_updated(engine_type)
                
                self.logger.info(f"Successfully {action_type}d exporter resources", extra={
                    "cluster_id": cluster_id,
                    "action": action_type
                })
                
            except Exception as e:
                self.metrics.record_error(type(e).__name__, "resource_manager")
                self.logger.error("Failed to execute action for cluster", extra={
                    "cluster_id": cluster_id,
                    "error": str(e),
                    "error_type": type(e).__name__
                })
    
    def _update_metrics(self, current_clusters: Dict[str, AuroraCluster]) -> None:
        """Update metrics with current cluster state."""
        # Count clusters by engine type
        clusters_by_engine = defaultdict(int)
        for cluster in current_clusters.values():
            engine_type = cluster.engine.replace('aurora-', '')
            clusters_by_engine[engine_type] += 1
        
        # Update managed clusters metrics
        self.metrics.update_managed_clusters(dict(clusters_by_engine))