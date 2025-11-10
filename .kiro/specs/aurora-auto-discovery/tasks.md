# Implementation Plan

- [x] 1. Create Aurora Discovery CronJob foundation
  - Create directory structure for Aurora Discovery component in helm chart
  - Define Helm chart templates for CronJob, ServiceAccount, and RBAC resources
  - Implement basic CronJob configuration with proper scheduling and resource limits
  - _Requirements: 6.1, 6.2, 7.4_

- [x] 1.1 Set up Aurora Discovery Helm chart structure
  - Create `helm-charts/db-monitoring/charts/aurora-discovery/` directory
  - Create Chart.yaml with component metadata and dependencies
  - Create values.yaml with configuration options for schedule, resources, and AWS settings
  - _Requirements: 6.1, 7.4_

- [x] 1.2 Implement CronJob template
  - Create `templates/cronjob.yaml` with proper scheduling and concurrency policy
  - Configure resource requests and limits based on design specifications
  - Set up environment variables for AWS region and namespace configuration
  - _Requirements: 6.1, 6.2, 6.3_

- [x] 1.3 Create RBAC and ServiceAccount templates
  - Create `templates/rbac.yaml` with ClusterRole for required Kubernetes permissions
  - Create `templates/serviceaccount.yaml` with IRSA annotations for AWS access
  - Implement proper role binding between ServiceAccount and ClusterRole
  - _Requirements: 7.1, 7.2, 7.3, 7.4_

- [x] 1.4 Write unit tests for Helm templates
  - Create test cases for CronJob template rendering with different values
  - Test RBAC template generation with proper permissions
  - Validate ServiceAccount template with IRSA annotations
  - _Requirements: 6.1, 7.4_

- [x] 2. Implement Aurora cluster discovery logic
  - Create Python application for Aurora cluster discovery using boto3
  - Implement RDS API integration to query Aurora clusters by engine type
  - Add error handling for AWS API rate limits and permission issues
  - _Requirements: 1.1, 1.2, 1.5, 7.1, 8.5_

- [x] 2.1 Create Python application structure
  - Set up Python project with requirements.txt including boto3 and kubernetes client
  - Create main application entry point with command-line argument parsing
  - Implement logging configuration with structured output and configurable levels
  - _Requirements: 8.1, 8.2_

- [x] 2.2 Implement AWS RDS client integration
  - Create RDS client wrapper with proper error handling and retry logic
  - Implement `discover_aurora_clusters()` method to query MySQL and PostgreSQL clusters
  - Add filtering logic to only process Aurora clusters with associated Secrets Manager ARNs
  - _Requirements: 1.1, 1.2, 1.4, 1.5, 8.5_

- [x] 2.3 Add AWS Secrets Manager integration
  - Implement Secrets Manager client with credential retrieval functionality
  - Create `get_cluster_credentials()` method to extract endpoint, username, and password
  - Add error handling for missing secrets and malformed secret content
  - _Requirements: 2.1, 2.2, 2.3, 8.5_

- [ ]* 2.4 Write unit tests for AWS integration
  - Mock boto3 clients for RDS and Secrets Manager testing
  - Test cluster discovery with various cluster states and configurations
  - Test error handling for AWS API failures and permission issues
  - _Requirements: 1.1, 1.2, 2.1, 2.2_

- [x] 3. Implement state management with Kubernetes ConfigMap
  - Create ConfigMap-based state tracking for cluster comparison
  - Implement serialization/deserialization of cluster state data
  - Add logic to detect new, modified, and deleted clusters
  - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5_

- [x] 3.1 Create state management classes
  - Implement `ClusterState` and `AuroraCluster` data classes with JSON serialization
  - Create `StateManager` class for ConfigMap read/write operations
  - Add timestamp tracking for state updates and cluster last-seen times
  - _Requirements: 5.1, 5.2_

- [x] 3.2 Implement cluster comparison logic
  - Create `compare_cluster_states()` method to identify changes between current and stored state
  - Implement logic to detect new clusters requiring exporter creation
  - Add detection for removed clusters requiring resource cleanup
  - _Requirements: 5.2, 5.3_

- [x] 3.3 Add ConfigMap error handling
  - Implement recovery logic for missing or corrupted ConfigMaps
  - Add optimistic locking using resource versions for concurrent access protection
  - Create fallback mechanism to rebuild state from current AWS cluster discovery
  - _Requirements: 5.4, 5.5_

- [ ]* 3.4 Write unit tests for state management
  - Test ConfigMap serialization and deserialization with various cluster configurations
  - Test cluster comparison logic with different state change scenarios
  - Test error recovery mechanisms for ConfigMap corruption and conflicts
  - _Requirements: 5.1, 5.2, 5.3_

- [x] 4. Create dynamic exporter resource management
  - Implement Kubernetes client integration for resource CRUD operations
  - Create template-based generation of Deployment, Service, and Secret resources
  - Add resource lifecycle management for exporter creation and cleanup
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

- [x] 4.1 Implement Kubernetes resource templates
  - Create `ExporterResourceManager` class for managing exporter resources
  - Implement template methods for MySQL and PostgreSQL exporter Deployments
  - Create Service templates with proper Service Discovery labels and annotations
  - _Requirements: 3.1, 3.2, 3.4, 3.5_

- [x] 4.2 Add Secret management for database credentials
  - Implement `create_exporter_secret()` method to store database connection strings
  - Create proper Secret templates with base64 encoding for credentials
  - Add Secret update logic for credential rotation scenarios
  - _Requirements: 2.4, 2.5, 3.5_

- [x] 4.3 Implement resource lifecycle operations
  - Create `create_exporter_resources()` method for new cluster onboarding
  - Implement `delete_exporter_resources()` method for cluster cleanup
  - Add resource existence checking to prevent duplicate creation attempts
  - _Requirements: 3.1, 3.2, 3.3, 3.6_

- [x] 4.4 Add Kubernetes API error handling
  - Implement retry logic with exponential backoff for transient failures
  - Add specific error handling for RBAC permission issues
  - Create graceful degradation for resource quota exceeded scenarios
  - _Requirements: 7.3, 8.2_

- [ ]* 4.5 Write unit tests for resource management
  - Mock Kubernetes client for testing resource creation and deletion
  - Test template generation with various cluster configurations
  - Test error handling scenarios for Kubernetes API failures
  - _Requirements: 3.1, 3.2, 3.3_

- [x] 5. Update ADOT Collector for Service Discovery
  - Modify ADOT Collector ConfigMap to use Kubernetes Service Discovery
  - Replace static exporter targets with dynamic service discovery configuration
  - Add proper relabeling rules for Aurora exporter identification
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_

- [x] 5.1 Update ADOT Collector ConfigMap template
  - Modify `helm-charts/db-monitoring/charts/adot-collector/templates/configmap.yaml`
  - Replace static MySQL and PostgreSQL scrape configs with Service Discovery
  - Add kubernetes_sd_configs for service-based target discovery
  - _Requirements: 4.1, 4.2, 4.3_

- [x] 5.2 Implement Service Discovery relabeling rules
  - Create relabel_configs to filter Aurora exporter services by labels
  - Add target address rewriting based on service annotations
  - Implement proper metric labeling for cluster identification
  - _Requirements: 4.4, 4.5_

- [x] 5.3 Add backward compatibility support
  - Ensure existing static exporters continue to work during migration
  - Create conditional configuration based on Aurora Discovery enablement
  - Add migration documentation for smooth transition
  - _Requirements: 4.1, 4.2_

- [ ]* 5.4 Write integration tests for Service Discovery
  - Test ADOT Collector configuration rendering with Service Discovery enabled
  - Validate relabeling rules with mock service configurations
  - Test metric collection from dynamically discovered exporters
  - _Requirements: 4.1, 4.2, 4.5_

- [x] 6. Build and package Aurora Discovery container image
  - Create Dockerfile for Aurora Discovery Python application
  - Set up container image build process with proper base image and dependencies
  - Add health check and proper signal handling for graceful shutdown
  - _Requirements: 6.1, 6.2_

- [x] 6.1 Create Dockerfile and build configuration
  - Create Dockerfile with Python base image and required system dependencies
  - Install Python requirements and copy application code
  - Set up proper user permissions and working directory
  - _Requirements: 6.1_

- [x] 6.2 Add container health checks and signal handling
  - Implement health check endpoint for container liveness probes
  - Add proper signal handling for graceful shutdown on SIGTERM
  - Create container entrypoint script with proper error handling
  - _Requirements: 6.2, 6.3_

- [ ]* 6.3 Write container integration tests
  - Create test cases for container startup and health check functionality
  - Test signal handling and graceful shutdown behavior
  - Validate container runs successfully with required environment variables
  - _Requirements: 6.1, 6.2_

- [x] 7. Integrate Aurora Discovery into main Helm chart
  - Add Aurora Discovery as dependency in main db-monitoring chart
  - Update main values.yaml with Aurora Discovery configuration options
  - Create deployment documentation and migration guide
  - _Requirements: 6.1, 7.4_

- [x] 7.1 Update main Helm chart dependencies
  - Add aurora-discovery dependency to `helm-charts/db-monitoring/Chart.yaml`
  - Update main `values.yaml` with Aurora Discovery configuration section
  - Set proper default values for schedule, resources, and AWS settings
  - _Requirements: 6.1, 7.4_

- [x] 7.2 Create deployment and configuration documentation
  - Write deployment guide for Aurora Discovery feature enablement
  - Document required AWS IAM permissions and IRSA setup
  - Create troubleshooting guide for common deployment issues
  - _Requirements: 7.1, 7.2, 7.3, 7.4_

- [x] 7.3 Add monitoring and observability features
  - Implement Prometheus metrics exposure for Aurora Discovery operations
  - Add structured logging with proper log levels and context
  - Create alerting rules for CronJob failures and high error rates
  - _Requirements: 8.1, 8.2, 8.3, 8.4_

- [ ]* 7.4 Write end-to-end integration tests
  - Create test scenarios for full Aurora Discovery workflow
  - Test integration with existing ADOT Collector and exporters
  - Validate metric collection from dynamically created exporters
  - _Requirements: 1.1, 3.1, 4.1_