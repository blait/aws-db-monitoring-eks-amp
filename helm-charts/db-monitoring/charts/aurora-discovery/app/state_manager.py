"""
State management for Aurora Discovery Service using Kubernetes ConfigMaps.
"""

import logging
from datetime import datetime
from typing import Optional, Dict, Set, Tuple
from kubernetes import client
from kubernetes.client.rest import ApiException

from models import ClusterState, AuroraCluster


logger = logging.getLogger(__name__)


class StateManager:
    """Manages Aurora cluster state using Kubernetes ConfigMaps."""
    
    def __init__(self, k8s_client: client.CoreV1Api, namespace: str, configmap_name: str):
        """
        Initialize StateManager.
        
        Args:
            k8s_client: Kubernetes CoreV1Api client
            namespace: Kubernetes namespace for the ConfigMap
            configmap_name: Name of the ConfigMap to use for state storage
        """
        self.k8s_client = k8s_client
        self.namespace = namespace
        self.configmap_name = configmap_name
        self._resource_version: Optional[str] = None
    
    def load_state(self) -> Optional[ClusterState]:
        """
        Load cluster state from ConfigMap.
        
        Returns:
            ClusterState if found and valid, None if not found or corrupted
        """
        try:
            configmap = self.k8s_client.read_namespaced_config_map(
                name=self.configmap_name,
                namespace=self.namespace
            )
            
            # Store resource version for optimistic locking
            self._resource_version = configmap.metadata.resource_version
            
            if not configmap.data or 'clusters.json' not in configmap.data:
                logger.warning(f"ConfigMap {self.configmap_name} exists but has no cluster data")
                return None
            
            clusters_json = configmap.data['clusters.json']
            
            # Validate JSON data is not empty or malformed
            if not clusters_json.strip():
                logger.warning(f"ConfigMap {self.configmap_name} has empty cluster data")
                return None
            
            state = ClusterState.from_json(clusters_json)
            
            # Validate state structure
            if not isinstance(state.clusters, dict):
                logger.error(f"ConfigMap {self.configmap_name} has invalid cluster data structure")
                return None
            
            logger.info(f"Loaded state with {len(state.clusters)} clusters from ConfigMap")
            return state
            
        except ApiException as e:
            if e.status == 404:
                logger.info(f"ConfigMap {self.configmap_name} not found, will create new state")
                return None
            elif e.status == 403:
                logger.error(f"Insufficient permissions to read ConfigMap {self.configmap_name}: {e}")
                raise
            else:
                logger.error(f"Failed to read ConfigMap {self.configmap_name}: {e}")
                raise
        except (ValueError, KeyError, TypeError) as e:
            logger.error(f"ConfigMap {self.configmap_name} contains corrupted data: {e}")
            return None
        except Exception as e:
            logger.error(f"Unexpected error loading state from ConfigMap: {e}")
            return None
    
    def save_state(self, state: ClusterState) -> bool:
        """
        Save cluster state to ConfigMap.
        
        Args:
            state: ClusterState to save
            
        Returns:
            True if successful, False otherwise
        """
        try:
            # Update the last_updated timestamp
            state.last_updated = datetime.utcnow()
            
            configmap_data = {
                'clusters.json': state.to_json()
            }
            
            # Try to update existing ConfigMap first
            if self._resource_version:
                try:
                    configmap = client.V1ConfigMap(
                        metadata=client.V1ObjectMeta(
                            name=self.configmap_name,
                            namespace=self.namespace,
                            resource_version=self._resource_version
                        ),
                        data=configmap_data
                    )
                    
                    updated_configmap = self.k8s_client.replace_namespaced_config_map(
                        name=self.configmap_name,
                        namespace=self.namespace,
                        body=configmap
                    )
                    
                    self._resource_version = updated_configmap.metadata.resource_version
                    logger.info(f"Updated ConfigMap {self.configmap_name} with {len(state.clusters)} clusters")
                    return True
                    
                except ApiException as e:
                    if e.status == 409:  # Conflict - resource version mismatch
                        logger.warning(f"ConfigMap {self.configmap_name} was modified by another process, retrying")
                        # Clear resource version to force create/replace
                        self._resource_version = None
                    else:
                        raise
            
            # Create new ConfigMap or replace without resource version
            configmap = client.V1ConfigMap(
                metadata=client.V1ObjectMeta(
                    name=self.configmap_name,
                    namespace=self.namespace
                ),
                data=configmap_data
            )
            
            try:
                created_configmap = self.k8s_client.create_namespaced_config_map(
                    namespace=self.namespace,
                    body=configmap
                )
                self._resource_version = created_configmap.metadata.resource_version
                logger.info(f"Created ConfigMap {self.configmap_name} with {len(state.clusters)} clusters")
                return True
                
            except ApiException as e:
                if e.status == 409:  # Already exists
                    # Replace the existing ConfigMap
                    replaced_configmap = self.k8s_client.replace_namespaced_config_map(
                        name=self.configmap_name,
                        namespace=self.namespace,
                        body=configmap
                    )
                    self._resource_version = replaced_configmap.metadata.resource_version
                    logger.info(f"Replaced ConfigMap {self.configmap_name} with {len(state.clusters)} clusters")
                    return True
                else:
                    raise
                    
        except ApiException as e:
            if e.status == 403:
                logger.error(f"Insufficient permissions to save ConfigMap {self.configmap_name}: {e}")
            elif e.status == 422:
                logger.error(f"Invalid ConfigMap data for {self.configmap_name}: {e}")
            else:
                logger.error(f"Kubernetes API error saving ConfigMap {self.configmap_name}: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error saving state to ConfigMap {self.configmap_name}: {e}")
            return False
    
    def create_empty_state(self) -> ClusterState:
        """
        Create a new empty cluster state.
        
        Returns:
            Empty ClusterState with current timestamp
        """
        return ClusterState(
            last_updated=datetime.utcnow(),
            clusters={}
        )
    
    def is_state_corrupted(self, state: Optional[ClusterState]) -> bool:
        """
        Check if the loaded state appears to be corrupted.
        
        Args:
            state: ClusterState to validate
            
        Returns:
            True if state appears corrupted, False otherwise
        """
        if state is None:
            return False
        
        try:
            # Check if last_updated is reasonable (not too old or in future)
            now = datetime.utcnow()
            time_diff = abs((now - state.last_updated).total_seconds())
            
            # Consider state corrupted if it's more than 7 days old or in the future by more than 1 hour
            if time_diff > 7 * 24 * 3600 or (state.last_updated > now and time_diff > 3600):
                logger.warning(f"State timestamp appears corrupted: {state.last_updated}")
                return True
            
            # Validate cluster data structure
            for cluster_id, cluster in state.clusters.items():
                if not isinstance(cluster_id, str) or not cluster_id.strip():
                    logger.warning(f"Invalid cluster identifier: {cluster_id}")
                    return True
                
                if not isinstance(cluster, AuroraCluster):
                    logger.warning(f"Invalid cluster object for {cluster_id}")
                    return True
                
                # Basic validation of cluster fields
                if not cluster.endpoint or not cluster.engine or not cluster.secrets_arn:
                    logger.warning(f"Cluster {cluster_id} has missing required fields")
                    return True
            
            return False
            
        except Exception as e:
            logger.error(f"Error validating state: {e}")
            return True
    
    def recover_from_corruption(self, current_clusters: Dict[str, AuroraCluster]) -> ClusterState:
        """
        Recover from ConfigMap corruption by creating new state from current clusters.
        
        Args:
            current_clusters: Dictionary of current Aurora clusters discovered from AWS
            
        Returns:
            New ClusterState based on current clusters
        """
        logger.warning("Recovering from ConfigMap corruption, rebuilding state from current AWS clusters")
        
        # Update last_seen timestamp for all current clusters
        now = datetime.utcnow()
        for cluster in current_clusters.values():
            cluster.last_seen = now
        
        new_state = ClusterState(
            last_updated=now,
            clusters=current_clusters
        )
        
        # Save the recovered state
        if self.save_state(new_state):
            logger.info(f"Successfully recovered state with {len(current_clusters)} clusters")
        else:
            logger.error("Failed to save recovered state")
        
        return new_state
    
    def load_state_with_recovery(self, current_clusters: Dict[str, AuroraCluster]) -> ClusterState:
        """
        Load state with automatic corruption recovery.
        
        Args:
            current_clusters: Current clusters from AWS discovery for fallback
            
        Returns:
            Valid ClusterState (recovered if necessary)
        """
        try:
            state = self.load_state()
            
            if state is None:
                logger.info("No existing state found, creating new state")
                return self.create_empty_state()
            
            if self.is_state_corrupted(state):
                logger.warning("Detected corrupted state, initiating recovery")
                return self.recover_from_corruption(current_clusters)
            
            return state
            
        except Exception as e:
            logger.error(f"Failed to load state, recovering from current clusters: {e}")
            return self.recover_from_corruption(current_clusters)


def compare_cluster_states(previous_state: Optional[ClusterState], 
                          current_clusters: Dict[str, AuroraCluster]) -> Tuple[Set[str], Set[str], Set[str]]:
    """
    Compare previous and current cluster states to identify changes.
    
    Args:
        previous_state: Previous cluster state from ConfigMap (None if first run)
        current_clusters: Current clusters discovered from AWS
        
    Returns:
        Tuple of (new_clusters, modified_clusters, deleted_clusters) cluster identifiers
    """
    if previous_state is None:
        # First run - all current clusters are new
        return set(current_clusters.keys()), set(), set()
    
    previous_clusters = previous_state.clusters
    current_cluster_ids = set(current_clusters.keys())
    previous_cluster_ids = set(previous_clusters.keys())
    
    # Identify new clusters
    new_clusters = current_cluster_ids - previous_cluster_ids
    
    # Identify deleted clusters
    deleted_clusters = previous_cluster_ids - current_cluster_ids
    
    # Identify modified clusters (existing clusters with changes)
    modified_clusters = set()
    for cluster_id in current_cluster_ids & previous_cluster_ids:
        current_cluster = current_clusters[cluster_id]
        previous_cluster = previous_clusters[cluster_id]
        
        # Compare relevant fields (excluding last_seen timestamp)
        if (current_cluster.endpoint != previous_cluster.endpoint or
            current_cluster.port != previous_cluster.port or
            current_cluster.secrets_arn != previous_cluster.secrets_arn or
            current_cluster.status != previous_cluster.status):
            modified_clusters.add(cluster_id)
    
    logger.info(f"Cluster comparison: {len(new_clusters)} new, {len(modified_clusters)} modified, {len(deleted_clusters)} deleted")
    
    if new_clusters:
        logger.info(f"New clusters: {', '.join(new_clusters)}")
    if modified_clusters:
        logger.info(f"Modified clusters: {', '.join(modified_clusters)}")
    if deleted_clusters:
        logger.info(f"Deleted clusters: {', '.join(deleted_clusters)}")
    
    return new_clusters, modified_clusters, deleted_clusters