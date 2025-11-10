"""
Data models for Aurora Discovery Service.
"""

from dataclasses import dataclass, asdict
from datetime import datetime
from typing import Dict, Optional
import json


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
    
    def to_dict(self) -> Dict:
        """Convert cluster to dictionary for JSON serialization."""
        data = asdict(self)
        data['last_seen'] = self.last_seen.isoformat()
        return data
    
    @classmethod
    def from_dict(cls, data: Dict) -> 'AuroraCluster':
        """Create cluster from dictionary."""
        data = data.copy()
        data['last_seen'] = datetime.fromisoformat(data['last_seen'])
        return cls(**data)


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
        """Get MySQL data source name."""
        return f"{self.username}:{self.password}@tcp({self.endpoint}:{self.port})/"
    
    def get_postgresql_dsn(self) -> str:
        """Get PostgreSQL data source name."""
        db_name = self.database or "postgres"
        return f"postgresql://{self.username}:{self.password}@{self.endpoint}:{self.port}/{db_name}?sslmode=require"