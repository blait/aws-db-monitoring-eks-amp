"""
Aurora Discovery Service

Main service class that orchestrates Aurora cluster discovery and exporter management.
"""

import logging
from typing import Dict, List, Optional
from collections import defaultdict

from aws_client import AWSClient
from state_manager import StateManager
from resource_manager import ResourceManager
from models import AuroraCluster
from metrics import get_metrics


class AuroraDiscoveryService:
    """Main service class for Aurora cluster discovery and management."""
    
    def __init__(
        self,
        aws_region: str,
        namespace: str,
        state_configmap_name: str,
        dry_run: bool = False
    ):
        """Initialize the Aurora Discovery Service.
        
        Args:
            aws_region: AWS region to scan for Aurora clusters
            namespace: Kubernetes namespace for resources
            state_configmap_name: Name of the ConfigMap for state storage
            dry_run: If True, perform discovery without making changes
        """
        self.logger = logging.getLogger(__name__)
        self.aws_region = aws_region
        self.namespace = namespace
        self.state_configmap_name = state_configmap_name
        self.dry_run = dry_run
        
        # Initialize components
        self.aws_client = AWSClient(aws_region)
        self.state_manager = StateManager(namespace, state_configmap_name)
        self.resource_manager = ResourceManager(namespace, dry_run)
        self.metrics = get_metrics()
        
        self.logger.info("Aurora Discovery Service initialized", extra={
            "aws_region": aws_region,
            "namespace": namespace,
            "state_configmap_name": state_configmap_name,
            "dry_run": dry_run
        })
    
    def run(self) -> None:
        """Execute the complete discovery and management cycle."""
        try:
            self.logger.info("Starting Aurora discovery cycle")
            
            with self.metrics.time_execution_phase("full_cycle"):
                # Step 1: Discover current Aurora clusters
                with self.metrics.time_execution_phase("discovery"):
                    current_clusters = self._discover_clusters()
                    self.logger.info(f"Discovered {len(current_clusters)} Aurora clusters")
                
                # Step 2: Load previous state
                with self.metrics.time_execution_phase("state_load"):
                    previous_state = self.state_manager.load_state()
                    previous_clusters = previous_state.clusters if previous_state else {}
                
                # Step 3: Compare states and determine actions
                with self.metrics.time_execution_phase("state_comparison"):
                    actions = self._compare_states(current_clusters, previous_clusters)
                
                # Step 4: Execute resource management actions
                with self.metrics.time_execution_phase("resource_management"):
                    if not self.dry_run:
                        self._execute_actions(actions, current_clusters)
                    else:
                        self.logger.info("Dry run mode - skipping resource changes", extra={
                            "actions": {
                                "create": len(actions["create"]),
                                "update": len(actions["update"]),
                                "delete": len(actions["delete"])
                            }
                        })
                
                # Step 5: Update state and metrics
                with self.metrics.time_execution_phase("state_save"):
                    if not self.dry_run:
                        self.state_manager.save_state(current_clusters)
                        self._update_metrics(current_clusters)
            
            # Record successful execution
            self.metrics.record_execution_success()
            self.logger.info("Aurora discovery cycle completed successfully")
            
        except Exception as e:
            self.metrics.record_execution_failure()
            self.metrics.record_error(type(e).__name__, "aurora_discovery")
            self.logger.error("Aurora discovery cycle failed", extra={
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
                
                # Check if cluster configuration has changed
                if (current.endpoint != previous.endpoint or 
                    current.port != previous.port or 
                    current.secrets_arn != previous.secrets_arn):
                    actions["update"].append(cluster_id)
                    self.logger.info("Cluster configuration changed", extra={
                        "cluster_id": cluster_id,
                        "changes": {
                            "endpoint": current.endpoint != previous.endpoint,
                            "port": current.port != previous.port,
                            "secrets_arn": current.secrets_arn != previous.secrets_arn
                        }
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
    
    def _execute_actions(self, actions: Dict[str, List[str]], current_clusters: Dict[str, AuroraCluster]) -> None:
        """Execute the required resource management actions."""
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
                
                # Get cluster credentials
                credentials = self.aws_client.get_cluster_credentials(cluster.secrets_arn)
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