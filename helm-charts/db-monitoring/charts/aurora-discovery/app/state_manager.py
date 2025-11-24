"""
State management for Aurora Discovery Service using Kubernetes ConfigMaps.
"""

import logging
from datetime import datetime
from typing import Optional, Dict
from kubernetes import client
from kubernetes.client.rest import ApiException

from models import ClusterState, AuroraCluster


logger = logging.getLogger(__name__)


class StateManager:
    """Manages Aurora cluster state using Kubernetes ConfigMaps."""
    
    def __init__(self, namespace: str, configmap_name: str):
        """
        Initialize StateManager.
        
        Args:
            namespace: Kubernetes namespace for the ConfigMap
            configmap_name: Name of the ConfigMap to use for state storage
        
        Note:
            Kubernetes configuration must be loaded before instantiating this class.
            This is typically done in main.py.
        """
        self.k8s_client = client.CoreV1Api()
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
    
