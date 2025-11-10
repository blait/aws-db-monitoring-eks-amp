#!/usr/bin/env python3
"""
Simple integration test for ExporterResourceManager.
This test validates the resource templates and basic functionality.
"""

import sys
import os
from datetime import datetime

# Add the app directory to the Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from models import AuroraCluster, ClusterCredentials
from resource_manager import ExporterResourceManager


def test_resource_templates():
    """Test resource template generation."""
    print("Testing resource template generation...")
    
    # Create test cluster
    cluster = AuroraCluster(
        identifier="test-cluster-1",
        engine="aurora-mysql",
        endpoint="test-cluster-1.cluster-xyz.us-east-1.rds.amazonaws.com",
        port=3306,
        secrets_arn="arn:aws:secretsmanager:us-east-1:123456789012:secret:test-cluster-1-AbCdEf",
        status="available",
        last_seen=datetime.now()
    )
    
    # Create test credentials
    credentials = ClusterCredentials(
        endpoint=cluster.endpoint,
        port=cluster.port,
        username="testuser",
        password="testpass",
        database="testdb"
    )
    
    # Initialize resource manager (this will fail if not in k8s cluster, but templates should work)
    try:
        manager = ExporterResourceManager(namespace="test")
        
        # Test deployment template
        deployment = manager._create_deployment_template(cluster)
        assert deployment.metadata.name == "aurora-mysql-test-cluster-1"
        assert deployment.metadata.namespace == "test"
        assert deployment.metadata.labels["app.kubernetes.io/name"] == "aurora-exporter"
        assert deployment.metadata.labels["app.kubernetes.io/component"] == "mysql-exporter"
        assert deployment.metadata.labels["aurora.aws/cluster-identifier"] == "test-cluster-1"
        print("✓ Deployment template generation successful")
        
        # Test service template
        service = manager._create_service_template(cluster)
        assert service.metadata.name == "aurora-mysql-test-cluster-1"
        assert service.metadata.namespace == "test"
        assert service.metadata.annotations["prometheus.io/scrape"] == "true"
        assert service.metadata.annotations["prometheus.io/port"] == "9104"
        print("✓ Service template generation successful")
        
        # Test secret template
        secret = manager.create_exporter_secret(cluster, credentials)
        assert secret.metadata.name == "aurora-mysql-test-cluster-1-credentials"
        assert secret.metadata.namespace == "test"
        assert "data-source-name" in secret.data
        print("✓ Secret template generation successful")
        
        # Test PostgreSQL cluster
        pg_cluster = AuroraCluster(
            identifier="test-pg-cluster",
            engine="aurora-postgresql",
            endpoint="test-pg-cluster.cluster-xyz.us-east-1.rds.amazonaws.com",
            port=5432,
            secrets_arn="arn:aws:secretsmanager:us-east-1:123456789012:secret:test-pg-cluster-AbCdEf",
            status="available",
            last_seen=datetime.now()
        )
        
        pg_deployment = manager._create_deployment_template(pg_cluster)
        assert pg_deployment.metadata.name == "aurora-postgresql-test-pg-cluster"
        assert pg_deployment.metadata.labels["app.kubernetes.io/component"] == "postgresql-exporter"
        print("✓ PostgreSQL template generation successful")
        
        print("All resource template tests passed!")
        return True
        
    except Exception as e:
        print(f"✗ Template test failed: {str(e)}")
        return False


def test_dsn_generation():
    """Test DSN generation for different database engines."""
    print("\nTesting DSN generation...")
    
    credentials = ClusterCredentials(
        endpoint="test.cluster-xyz.us-east-1.rds.amazonaws.com",
        port=3306,
        username="testuser",
        password="testpass",
        database="testdb"
    )
    
    # Test MySQL DSN
    mysql_dsn = credentials.get_mysql_dsn()
    expected_mysql = "testuser:testpass@tcp(test.cluster-xyz.us-east-1.rds.amazonaws.com:3306)/"
    assert mysql_dsn == expected_mysql, f"Expected {expected_mysql}, got {mysql_dsn}"
    print("✓ MySQL DSN generation successful")
    
    # Test PostgreSQL DSN
    pg_dsn = credentials.get_postgresql_dsn()
    expected_pg = "postgresql://testuser:testpass@test.cluster-xyz.us-east-1.rds.amazonaws.com:3306/testdb?sslmode=require"
    assert pg_dsn == expected_pg, f"Expected {expected_pg}, got {pg_dsn}"
    print("✓ PostgreSQL DSN generation successful")
    
    print("All DSN generation tests passed!")
    return True


def main():
    """Run all tests."""
    print("Running ExporterResourceManager tests...\n")
    
    success = True
    
    # Run template tests
    if not test_resource_templates():
        success = False
    
    # Run DSN tests
    if not test_dsn_generation():
        success = False
    
    if success:
        print("\n🎉 All tests passed!")
        return 0
    else:
        print("\n❌ Some tests failed!")
        return 1


if __name__ == "__main__":
    sys.exit(main())