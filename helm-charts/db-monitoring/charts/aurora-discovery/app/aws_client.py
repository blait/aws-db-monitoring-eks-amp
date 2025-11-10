"""
AWS client for Aurora cluster discovery and Secrets Manager integration.
"""

import logging
import time
from datetime import datetime
from typing import Dict, List, Optional
import json

import boto3
from botocore.exceptions import ClientError, BotoCoreError
from botocore.config import Config

from models import AuroraCluster, ClusterCredentials


class AWSClient:
    """AWS client wrapper for RDS and Secrets Manager operations."""
    
    def __init__(self, region: str):
        """Initialize AWS client with retry configuration.
        
        Args:
            region: AWS region for API calls
        """
        self.logger = logging.getLogger(__name__)
        self.region = region
        
        # Configure retry behavior for AWS API calls
        retry_config = Config(
            region_name=region,
            retries={
                'max_attempts': 3,
                'mode': 'adaptive'
            }
        )
        
        try:
            self.rds_client = boto3.client('rds', config=retry_config)
            self.secrets_client = boto3.client('secretsmanager', config=retry_config)
            
            self.logger.info("AWS clients initialized", extra={
                "region": region
            })
            
        except Exception as e:
            self.logger.error("Failed to initialize AWS clients", extra={
                "region": region,
                "error": str(e),
                "error_type": type(e).__name__
            })
            raise
    
    def discover_aurora_clusters(self) -> Dict[str, AuroraCluster]:
        """Discover all Aurora clusters in the configured region.
        
        Returns:
            Dictionary mapping cluster identifiers to AuroraCluster objects
            
        Raises:
            Exception: If cluster discovery fails
        """
        self.logger.info("Starting Aurora cluster discovery", extra={
            "region": self.region
        })
        
        clusters = {}
        
        try:
            # Discover Aurora MySQL clusters
            mysql_clusters = self._discover_clusters_by_engine('aurora-mysql')
            clusters.update(mysql_clusters)
            
            # Discover Aurora PostgreSQL clusters  
            postgresql_clusters = self._discover_clusters_by_engine('aurora-postgresql')
            clusters.update(postgresql_clusters)
            
            self.logger.info("Aurora cluster discovery completed", extra={
                "total_clusters": len(clusters),
                "mysql_clusters": len(mysql_clusters),
                "postgresql_clusters": len(postgresql_clusters)
            })
            
            return clusters
            
        except Exception as e:
            self.logger.error("Aurora cluster discovery failed", extra={
                "error": str(e),
                "error_type": type(e).__name__
            })
            raise
    
    def _discover_clusters_by_engine(self, engine: str) -> Dict[str, AuroraCluster]:
        """Discover Aurora clusters for a specific engine type.
        
        Args:
            engine: Engine type ('aurora-mysql' or 'aurora-postgresql')
            
        Returns:
            Dictionary mapping cluster identifiers to AuroraCluster objects
        """
        clusters = {}
        paginator = self.rds_client.get_paginator('describe_db_clusters')
        
        try:
            # Use paginator to handle large numbers of clusters
            page_iterator = paginator.paginate(
                Filters=[
                    {
                        'Name': 'engine',
                        'Values': [engine]
                    }
                ]
            )
            
            for page in page_iterator:
                for cluster_data in page.get('DBClusters', []):
                    try:
                        cluster = self._parse_cluster_data(cluster_data, engine)
                        if cluster:
                            clusters[cluster.identifier] = cluster
                            
                    except Exception as e:
                        cluster_id = cluster_data.get('DBClusterIdentifier', 'unknown')
                        self.logger.warning("Failed to parse cluster data", extra={
                            "cluster_id": cluster_id,
                            "engine": engine,
                            "error": str(e)
                        })
                        continue
            
            self.logger.debug("Engine-specific cluster discovery completed", extra={
                "engine": engine,
                "cluster_count": len(clusters)
            })
            
        except ClientError as e:
            error_code = e.response.get('Error', {}).get('Code', 'Unknown')
            
            if error_code == 'AccessDenied':
                self.logger.error("Access denied for RDS cluster discovery", extra={
                    "engine": engine,
                    "error_code": error_code,
                    "required_permission": "rds:DescribeDBClusters"
                })
            elif error_code == 'Throttling':
                self.logger.warning("RDS API throttling encountered", extra={
                    "engine": engine,
                    "error_code": error_code
                })
                # Implement exponential backoff for throttling
                time.sleep(2 ** 1)  # Start with 2 second delay
            else:
                self.logger.error("RDS API error during cluster discovery", extra={
                    "engine": engine,
                    "error_code": error_code,
                    "error_message": str(e)
                })
            raise
            
        except BotoCoreError as e:
            self.logger.error("AWS SDK error during cluster discovery", extra={
                "engine": engine,
                "error": str(e),
                "error_type": type(e).__name__
            })
            raise
            
        return clusters
    
    def _parse_cluster_data(self, cluster_data: Dict, engine: str) -> Optional[AuroraCluster]:
        """Parse RDS cluster data into AuroraCluster object.
        
        Args:
            cluster_data: Raw cluster data from RDS API
            engine: Engine type for validation
            
        Returns:
            AuroraCluster object or None if parsing fails
        """
        try:
            cluster_id = cluster_data['DBClusterIdentifier']
            status = cluster_data['Status']
            
            # Skip clusters that are not available
            if status not in ['available', 'backing-up', 'modifying']:
                self.logger.debug("Skipping cluster with non-available status", extra={
                    "cluster_id": cluster_id,
                    "status": status
                })
                return None
            
            # Extract endpoint information
            endpoint = cluster_data.get('Endpoint')
            port = cluster_data.get('Port')
            
            if not endpoint or not port:
                self.logger.warning("Cluster missing endpoint or port", extra={
                    "cluster_id": cluster_id,
                    "endpoint": endpoint,
                    "port": port
                })
                return None
            
            # Extract Secrets Manager ARN from MasterUserSecret
            secrets_arn = None
            master_user_secret = cluster_data.get('MasterUserSecret')
            if master_user_secret:
                secrets_arn = master_user_secret.get('SecretArn')
            
            # Log if no Secrets Manager ARN is found
            if not secrets_arn:
                self.logger.debug("Cluster has no Secrets Manager ARN", extra={
                    "cluster_id": cluster_id,
                    "engine": engine
                })
            
            cluster = AuroraCluster(
                identifier=cluster_id,
                engine=engine,
                endpoint=endpoint,
                port=port,
                secrets_arn=secrets_arn or "",
                status=status,
                last_seen=datetime.utcnow()
            )
            
            self.logger.debug("Successfully parsed cluster", extra={
                "cluster_id": cluster_id,
                "engine": engine,
                "endpoint": endpoint,
                "port": port,
                "has_secrets_arn": bool(secrets_arn)
            })
            
            return cluster
            
        except KeyError as e:
            self.logger.error("Missing required field in cluster data", extra={
                "missing_field": str(e),
                "cluster_data_keys": list(cluster_data.keys())
            })
            return None
        except Exception as e:
            self.logger.error("Unexpected error parsing cluster data", extra={
                "error": str(e),
                "error_type": type(e).__name__
            })
            return None
    
    def get_cluster_by_id(self, cluster_id: str) -> Optional[AuroraCluster]:
        """Get a specific cluster by identifier.
        
        Args:
            cluster_id: Aurora cluster identifier
            
        Returns:
            AuroraCluster object or None if not found
        """
        try:
            response = self.rds_client.describe_db_clusters(
                DBClusterIdentifier=cluster_id
            )
            
            clusters = response.get('DBClusters', [])
            if not clusters:
                return None
            
            cluster_data = clusters[0]
            engine = cluster_data.get('Engine', '')
            
            return self._parse_cluster_data(cluster_data, engine)
            
        except ClientError as e:
            error_code = e.response.get('Error', {}).get('Code', 'Unknown')
            if error_code == 'DBClusterNotFoundFault':
                self.logger.debug("Cluster not found", extra={"cluster_id": cluster_id})
                return None
            else:
                self.logger.error("Error retrieving cluster", extra={
                    "cluster_id": cluster_id,
                    "error_code": error_code,
                    "error": str(e)
                })
                raise
        except Exception as e:
            self.logger.error("Unexpected error retrieving cluster", extra={
                "cluster_id": cluster_id,
                "error": str(e),
                "error_type": type(e).__name__
            })
            raise
    
    def get_cluster_credentials(self, secrets_arn: str) -> Optional[ClusterCredentials]:
        """Retrieve database credentials from AWS Secrets Manager.
        
        Args:
            secrets_arn: ARN of the secret containing database credentials
            
        Returns:
            ClusterCredentials object or None if retrieval fails
        """
        if not secrets_arn:
            self.logger.warning("Empty secrets ARN provided")
            return None
        
        try:
            self.logger.debug("Retrieving cluster credentials", extra={
                "secrets_arn": secrets_arn
            })
            
            response = self.secrets_client.get_secret_value(SecretId=secrets_arn)
            secret_string = response.get('SecretString')
            
            if not secret_string:
                self.logger.error("Secret contains no string value", extra={
                    "secrets_arn": secrets_arn
                })
                return None
            
            # Parse the secret JSON
            try:
                secret_data = json.loads(secret_string)
            except json.JSONDecodeError as e:
                self.logger.error("Failed to parse secret JSON", extra={
                    "secrets_arn": secrets_arn,
                    "error": str(e)
                })
                return None
            
            # Extract required fields
            required_fields = ['host', 'port', 'username', 'password']
            missing_fields = [field for field in required_fields if field not in secret_data]
            
            if missing_fields:
                self.logger.error("Secret missing required fields", extra={
                    "secrets_arn": secrets_arn,
                    "missing_fields": missing_fields,
                    "available_fields": list(secret_data.keys())
                })
                return None
            
            # Create credentials object
            credentials = ClusterCredentials(
                endpoint=secret_data['host'],
                port=int(secret_data['port']),
                username=secret_data['username'],
                password=secret_data['password'],
                database=secret_data.get('dbname')  # Optional field
            )
            
            self.logger.debug("Successfully retrieved cluster credentials", extra={
                "secrets_arn": secrets_arn,
                "endpoint": credentials.endpoint,
                "port": credentials.port,
                "username": credentials.username,
                "has_database": bool(credentials.database)
            })
            
            return credentials
            
        except ClientError as e:
            error_code = e.response.get('Error', {}).get('Code', 'Unknown')
            
            if error_code == 'ResourceNotFoundException':
                self.logger.error("Secret not found", extra={
                    "secrets_arn": secrets_arn,
                    "error_code": error_code
                })
            elif error_code == 'AccessDenied':
                self.logger.error("Access denied for secret retrieval", extra={
                    "secrets_arn": secrets_arn,
                    "error_code": error_code,
                    "required_permission": "secretsmanager:GetSecretValue"
                })
            elif error_code == 'InvalidRequestException':
                self.logger.error("Invalid secret ARN format", extra={
                    "secrets_arn": secrets_arn,
                    "error_code": error_code
                })
            elif error_code == 'Throttling':
                self.logger.warning("Secrets Manager API throttling", extra={
                    "secrets_arn": secrets_arn,
                    "error_code": error_code
                })
                # Implement exponential backoff for throttling
                time.sleep(2 ** 1)  # Start with 2 second delay
            else:
                self.logger.error("Secrets Manager API error", extra={
                    "secrets_arn": secrets_arn,
                    "error_code": error_code,
                    "error_message": str(e)
                })
            
            return None
            
        except BotoCoreError as e:
            self.logger.error("AWS SDK error during secret retrieval", extra={
                "secrets_arn": secrets_arn,
                "error": str(e),
                "error_type": type(e).__name__
            })
            return None
            
        except ValueError as e:
            self.logger.error("Invalid port value in secret", extra={
                "secrets_arn": secrets_arn,
                "error": str(e)
            })
            return None
            
        except Exception as e:
            self.logger.error("Unexpected error retrieving secret", extra={
                "secrets_arn": secrets_arn,
                "error": str(e),
                "error_type": type(e).__name__
            })
            return None