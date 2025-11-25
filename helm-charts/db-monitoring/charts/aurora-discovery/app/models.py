"""
Data models for Aurora Discovery Service.
"""

from dataclasses import dataclass, asdict, field
from datetime import datetime
from typing import Dict, List, Optional
import json
from urllib.parse import quote


@dataclass
class AuroraInstance:
    """Represents an Aurora instance within a cluster."""
    identifier: str
    endpoint: str
    port: int
    role: str  # 'writer' or 'reader'
    availability_zone: str
    status: str
    discovered_at: Optional[datetime] = None
    last_seen: Optional[datetime] = None
    
    def to_dict(self) -> Dict:
        """Convert instance to dictionary for JSON serialization."""
        data = asdict(self)
        if self.discovered_at:
            data['discovered_at'] = self.discovered_at.isoformat()
        if self.last_seen:
            data['last_seen'] = self.last_seen.isoformat()
        return data
    
    @classmethod
    def from_dict(cls, data: Dict) -> 'AuroraInstance':
        """Create instance from dictionary."""
        data = data.copy()
        if 'discovered_at' in data and data['discovered_at']:
            data['discovered_at'] = datetime.fromisoformat(data['discovered_at'])
        if 'last_seen' in data and data['last_seen']:
            data['last_seen'] = datetime.fromisoformat(data['last_seen'])
        return cls(**data)
    
    def to_annotations(self) -> Dict[str, str]:
        """Convert instance information to Kubernetes annotation format.
        
        Returns:
            Dictionary of annotation key-value pairs (all values as strings)
        """
        annotations = {
            'aurora.aws/instance-identifier': self.identifier,
            'aurora.aws/endpoint': self.endpoint,
            'aurora.aws/port': str(self.port),
            'aurora.aws/role': self.role,
            'aurora.aws/availability-zone': self.availability_zone,
            'aurora.aws/status': self.status,
        }
        
        if self.discovered_at:
            annotations['aurora.aws/discovered-at'] = self.discovered_at.isoformat()
        if self.last_seen:
            annotations['aurora.aws/last-seen'] = self.last_seen.isoformat()
            
        return annotations
    
    @classmethod
    def from_annotations(cls, annotations: Dict[str, str]) -> 'AuroraInstance':
        """Create instance from Kubernetes annotations.
        
        Args:
            annotations: Dictionary of annotation key-value pairs
            
        Returns:
            AuroraInstance object reconstructed from annotations
        """
        discovered_at = None
        if 'aurora.aws/discovered-at' in annotations:
            discovered_at = datetime.fromisoformat(annotations['aurora.aws/discovered-at'])
            
        last_seen = None
        if 'aurora.aws/last-seen' in annotations:
            last_seen = datetime.fromisoformat(annotations['aurora.aws/last-seen'])
        
        return cls(
            identifier=annotations['aurora.aws/instance-identifier'],
            endpoint=annotations['aurora.aws/endpoint'],
            port=int(annotations['aurora.aws/port']),
            role=annotations['aurora.aws/role'],
            availability_zone=annotations['aurora.aws/availability-zone'],
            status=annotations['aurora.aws/status'],
            discovered_at=discovered_at,
            last_seen=last_seen
        )


@dataclass
class AuroraCluster:
    """Represents an Aurora cluster configuration."""
    identifier: str
    engine: str  # 'aurora-mysql' or 'aurora-postgresql'
    endpoint: str
    port: int
    secrets_arn: str
    status: str
    last_seen: datetime
    instances: List[AuroraInstance] = field(default_factory=list)
    discovered_at: Optional[datetime] = None
    
    def to_dict(self) -> Dict:
        """Convert cluster to dictionary for JSON serialization."""
        data = asdict(self)
        data['last_seen'] = self.last_seen.isoformat()
        if self.discovered_at:
            data['discovered_at'] = self.discovered_at.isoformat()
        data['instances'] = [inst.to_dict() for inst in self.instances]
        return data
    
    @classmethod
    def from_dict(cls, data: Dict) -> 'AuroraCluster':
        """Create cluster from dictionary."""
        data = data.copy()
        data['last_seen'] = datetime.fromisoformat(data['last_seen'])
        if 'discovered_at' in data and data['discovered_at']:
            data['discovered_at'] = datetime.fromisoformat(data['discovered_at'])
        data['instances'] = [AuroraInstance.from_dict(inst) for inst in data.get('instances', [])]
        return cls(**data)
    
    def to_annotations(self) -> Dict[str, str]:
        """Convert cluster information to Kubernetes annotation format.
        
        Returns:
            Dictionary of annotation key-value pairs (all values as strings)
        """
        annotations = {
            'aurora.aws/cluster-identifier': self.identifier,
            'aurora.aws/engine': self.engine,
            'aurora.aws/endpoint': self.endpoint,
            'aurora.aws/port': str(self.port),
            'aurora.aws/secrets-arn': self.secrets_arn,
            'aurora.aws/status': self.status,
            'aurora.aws/last-seen': self.last_seen.isoformat(),
        }
        
        if self.discovered_at:
            annotations['aurora.aws/discovered-at'] = self.discovered_at.isoformat()
            
        return annotations
    
    @classmethod
    def from_annotations(cls, annotations: Dict[str, str]) -> 'AuroraCluster':
        """Create cluster from Kubernetes annotations.
        
        Args:
            annotations: Dictionary of annotation key-value pairs
            
        Returns:
            AuroraCluster object reconstructed from annotations (without instances)
        """
        discovered_at = None
        if 'aurora.aws/discovered-at' in annotations:
            discovered_at = datetime.fromisoformat(annotations['aurora.aws/discovered-at'])
        
        return cls(
            identifier=annotations['aurora.aws/cluster-identifier'],
            engine=annotations['aurora.aws/engine'],
            endpoint=annotations['aurora.aws/endpoint'],
            port=int(annotations['aurora.aws/port']),
            secrets_arn=annotations['aurora.aws/secrets-arn'],
            status=annotations['aurora.aws/status'],
            last_seen=datetime.fromisoformat(annotations['aurora.aws/last-seen']),
            discovered_at=discovered_at,
            instances=[]  # Instances are loaded separately from their own resources
        )


@dataclass
class ClusterState:
    """Represents the complete state of managed Aurora clusters."""
    last_updated: datetime
    clusters: Dict[str, AuroraCluster]
    
    def to_dict(self) -> Dict:
        """Convert state to dictionary for JSON serialization."""
        return {
            'last_updated': self.last_updated.isoformat(),
            'clusters': {
                cluster_id: cluster.to_dict()
                for cluster_id, cluster in self.clusters.items()
            }
        }
    
    @classmethod
    def from_dict(cls, data: Dict) -> 'ClusterState':
        """Create state from dictionary."""
        return cls(
            last_updated=datetime.fromisoformat(data['last_updated']),
            clusters={
                cluster_id: AuroraCluster.from_dict(cluster_data)
                for cluster_id, cluster_data in data['clusters'].items()
            }
        )
    
    def to_json(self) -> str:
        """Convert state to JSON string."""
        return json.dumps(self.to_dict(), indent=2)
    
    @classmethod
    def from_json(cls, json_str: str) -> 'ClusterState':
        """Create state from JSON string."""
        data = json.loads(json_str)
        return cls.from_dict(data)


@dataclass
class ClusterCredentials:
    """Represents database credentials for an Aurora cluster."""
    endpoint: str
    port: int
    username: str
    password: str
    database: Optional[str] = None
    
    def get_mysql_dsn(self) -> str:
        """Get MySQL data source name for mysqld_exporter.
        
        Go MySQL driver does NOT automatically URL decode passwords.
        Add explicit query parameter to prevent password's ? from being parsed as query start.
        
        Database name is optional for server-level metrics collection.
        
        Returns:
            DSN in format: username:password@tcp(host:port)/?param=value
        """
        # Don't specify database name, but add ? to mark query parameter start
        # This allows exporter to append its parameters correctly
        return f"{self.username}:{self.password}@tcp({self.endpoint}:{self.port})/?"
    
    def get_postgresql_dsn(self) -> str:
        """Get PostgreSQL data source name for postgres_exporter.
        
        URL encodes username and password to handle special characters safely.
        Uses 'postgres' as default database if not specified.
        
        Returns:
            DSN in format: postgresql://username:password@host:port/database?sslmode=require
        """
        # URL encode both username and password to handle special characters
        encoded_username = quote(self.username, safe='')
        encoded_password = quote(self.password, safe='')
        db_name = self.database or "postgres"
        return f"postgresql://{encoded_username}:{encoded_password}@{self.endpoint}:{self.port}/{db_name}?sslmode=require"