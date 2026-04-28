# Terraform configuration for an approved security-hardened and FinOps-optimized e-commerce microservices architecture on GCP.
# This deploys a private Google Kubernetes Engine (GKE) cluster, Cloud SQL, Memorystore, Pub/Sub, Cloud Run,
# and essential networking and security components, with considerations for high availability, scalability, and cost management.

# --- Variables for Configuration ---
variable "project_id" {
  description = "The GCP project ID where resources will be deployed."
  type        = string
}

variable "region" {
  description = "The GCP region for deploying regional resources."
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "A list of zones within the specified region for high availability deployments (e.g., GKE node pools)."
  type        = list(string)
  default     = ["us-central1-a", "us-central1-b", "us-central1-c"]
}

variable "gke_num_nodes_default" {
  description = "The initial number of nodes for the default GKE node pool."
  type        = number
  default     = 2
}

variable "gke_min_nodes_default" {
  description = "The minimum number of nodes for the default GKE node pool (for autoscaling). FinOps: Scale down to save costs."
  type        = number
  default     = 1
}

variable "gke_max_nodes_default" {
  description = "The maximum number of nodes for the default GKE node pool (for autoscaling). FinOps: Cap growth to control costs."
  type        = number
  default     = 5
}

variable "gke_num_nodes_spot" {
  description = "The initial number of nodes for the spot GKE node pool. FinOps: Use for fault-tolerant workloads."
  type        = number
  default     = 1
}

variable "gke_min_nodes_spot" {
  description = "The minimum number of nodes for the spot GKE node pool (autoscaling). FinOps: Can scale to zero."
  type        = number
  default     = 0
}

variable "gke_max_nodes_spot" {
  description = "The maximum number of nodes for the spot GKE node pool (autoscaling). FinOps: Allows burst capacity at lower cost."
  type        = number
  default     = 10
}

variable "db_password" {
  description = "Password for the Cloud SQL database user. Security: Should be managed via a secrets manager or externalized."
  type        = string
  sensitive   = true # Mark as sensitive to prevent logging
}

variable "vpc_sc_enabled" {
  description = "Whether to enable VPC Service Controls. Security: Highly recommended for data exfiltration protection. Requires an existing Access Policy at the organization level."
  type        = bool
  default     = true
}

variable "dns_zone_name" {
  description = "The name for the private DNS managed zone for internal service discovery."
  type        = string
  default     = "ecommerce-internal-dns"
}

variable "internal_domain_name" {
  description = "The internal domain name suffix for private DNS records (e.g., 'internal.local.')."
  type        = string
  default     = "internal.local"
}

variable "cloud_run_image" {
  description = "Container image for the example Cloud Run service."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello" # Example image for demonstration
}

variable "cloud_armor_policy_enabled" {
  description = "Whether to enable Cloud Armor policy for the external load balancer. Security: Recommended for WAF capabilities."
  type        = bool
  default     = true
}

# --- Provider Configuration ---
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" { # Used for newer features like VPC Service Controls access levels, or specific GKE/Cloud Run features
  project = var.project_id
  region  = var.region
}

# --- Service API Enables ---
# Explicitly enable necessary APIs for the project
resource "google_project_service" "enabled_apis" {
  for_each = toset([
    "compute.googleapis.com",             # Required for network, VMs, load balancers
    "container.googleapis.com",           # Required for GKE
    "sqladmin.googleapis.com",            # Required for Cloud SQL
    "servicenetworking.googleapis.com",   # Required for Private IP for Cloud SQL/Memorystore
    "redis.googleapis.com",               # Required for Memorystore Redis
    "pubsub.googleapis.com",              # Required for Cloud Pub/Sub
    "storage.googleapis.com",             # Required for Cloud Storage
    "secretmanager.googleapis.com",       # Required for Secret Manager
    "cloudkms.googleapis.com",            # Required for KMS
    "run.googleapis.com",                 # Required for Cloud Run
    "vpcaccess.googleapis.com",           # Required for Cloud Run VPC Access Connector
    "dns.googleapis.com",                 # Required for Cloud DNS
    "cloudresourcemanager.googleapis.com",# Required for IAM binding
    "monitoring.googleapis.com",          # Required for Cloud Monitoring
    "logging.googleapis.com",             # Required for Cloud Logging
    "artifactregistry.googleapis.com",    # For container image storage
    "accesscontextmanager.googleapis.com",# Required for VPC Service Controls
  ])
  project = var.project_id
  service = each.value
  # FinOps: Disable on destroy can save costs by cleaning up resources if not needed
  disable_on_destroy = false
}

# --- Networking Setup ---

# VPC Network (Custom Mode for granular control)
resource "google_compute_network" "ecommerce_vpc" {
  name                    = "ecommerce-vpc"
  auto_create_subnetworks = false # FinOps/Security: Custom subnets for strict control and cost management
  routing_mode            = "REGIONAL"
  project                 = var.project_id
  description             = "VPC for e-commerce microservices, optimized for security and cost."

  labels = { # FinOps: Labels for cost allocation and resource management
    environment = "production"
    application = "ecommerce"
    owner       = "finops-team"
  }

  depends_on = [google_project_service.enabled_apis]
}

# Private Subnet for application resources (GKE, Cloud SQL, Memorystore, Cloud Run)
resource "google_compute_subnetwork" "ecommerce_app_subnet" {
  name                     = "ecommerce-app-subnet"
  ip_cidr_range            = "10.10.0.0/20" # Define a sufficiently large private CIDR block
  region                   = var.region
  network                  = google_compute_network.ecommerce_vpc.id
  private_ip_google_access = true # Security: Allows private access to Google APIs from instances in this subnet
  project                  = var.project_id
  description              = "Primary private subnet for e-commerce applications and managed services."

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    tier        = "application"
  }
}

# Cloud Router for NAT
resource "google_compute_router" "ecommerce_router" {
  name    = "ecommerce-router"
  region  = var.region
  network = google_compute_network.ecommerce_vpc.id
  project = var.project_id
  description = "Cloud Router for Cloud NAT service, enabling outbound internet access for private resources."

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "router"
  }
}

# Cloud NAT for outbound internet access from private instances (GKE nodes, Cloud Run, etc.)
resource "google_compute_router_nat" "ecommerce_nat" {
  name                          = "ecommerce-nat"
  router                        = google_compute_router.ecommerce_router.name
  region                        = google_compute_router.ecommerce_router.region
  nat_ip_allocate_option        = "AUTO_ONLY" # FinOps: Automatic IP allocation, scale as needed
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  log_config {
    enable = true
    filter = "ERRORS_ONLY" # FinOps: Log errors only to reduce logging costs
  }
  project = var.project_id

  depends_on = [
    google_compute_subnetwork.ecommerce_app_subnet
  ]
}

# Firewall Rules (Security: Least privilege principle, only open necessary ports)

# Allow internal VPC communication
resource "google_compute_firewall" "allow_internal_vpc" {
  name        = "ecommerce-allow-internal-vpc"
  network     = google_compute_network.ecommerce_vpc.name
  project     = var.project_id
  description = "Allows all TCP, UDP, ICMP traffic within the e-commerce VPC. Security: Can be further restricted by tags/service accounts."
  priority    = 65534 # Lower priority than GKE-specific rules

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [google_compute_subnetwork.ecommerce_app_subnet.ip_cidr_range, "10.11.0.0/18", "10.11.64.0/20", "10.10.15.0/28"] # Main subnet, GKE Pods, GKE Services, Cloud Run Connector
  # For GKE, the cluster's internal IP ranges for pods and services also need to be included.
  # The GKE cluster will add its own firewall rules (e.g., for health checks).
  target_tags   = ["ecommerce-app-instance"] # Apply to relevant instances/nodes, GKE nodes get specific tags
}

# Allow SSH to GKE nodes (Security: Restrict source_ranges to specific admin IPs in production)
resource "google_compute_firewall" "allow_ssh_gke" {
  name        = "ecommerce-allow-ssh-gke"
  network     = google_compute_network.ecommerce_vpc.name
  project     = var.project_id
  description = "Allows SSH access to GKE nodes from specific IP ranges. Security: MUST BE RESTRICTED IN PRODUCTION!"
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # IMPORTANT: Restrict source_ranges to specific admin/bastion host IPs for production environments.
  source_ranges = ["0.0.0.0/0"] # Placeholder: **CHANGE THIS IN PRODUCTION TO YOUR SECURE ADMIN IP RANGE!**
  target_tags   = ["gke-${google_container_cluster.ecommerce_cluster.name}-node"] # Tag applied by GKE for its nodes
}

# Allow external HTTP/HTTPS to load balancer (managed by GKE Ingress mostly)
resource "google_compute_firewall" "allow_lb_ingress" {
  name        = "ecommerce-allow-lb-ingress"
  network     = google_compute_network.ecommerce_vpc.name
  project     = var.project_id
  description = "Allows ingress from GCP load balancers and health checks to GKE nodes."
  priority    = 1000

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = [
    "130.211.0.0/22", # Google Cloud Load Balancer
    "35.191.0.0/16",  # Google Cloud Load Balancer Health Checks
  ]
  target_tags = ["gke-${google_container_cluster.ecommerce_cluster.name}-node"] # Apply to GKE nodes receiving LB traffic

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "firewall"
  }
}

# Cloud DNS Private Managed Zone for internal service discovery
resource "google_dns_managed_zone" "internal_dns_zone" {
  name        = var.dns_zone_name
  dns_name    = "${var.internal_domain_name}." # Must end with a dot
  description = "Private DNS zone for internal microservices communication, crucial for secure inter-service resolution."
  visibility  = "private"
  project     = var.project_id

  private_visibility_config {
    network {
      network_url = google_compute_network.ecommerce_vpc.id
    }
  }

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "dns"
  }
}


# --- Security: VPC Service Controls (Perimeter) ---
# VPC Service Controls are critical for data exfiltration protection.
# This resource defines a perimeter. It requires an existing Access Policy at the organization level.
# The project specified in `var.project_id` must be added as a member of this perimeter.
data "google_access_context_manager_access_policy" "policy" {
  count = var.vpc_sc_enabled ? 1 : 0
  # Attempts to find the Access Policy for the organization.
  # For new organizations, an Access Policy might need manual creation first.
  # If you have multiple policies, you might need to specify its `name`.
}

resource "google_access_context_manager_service_perimeter" "ecommerce_perimeter" {
  count = var.vpc_sc_enabled ? 1 : 0

  name       = "accessPolicies/${data.google_access_context_manager_access_policy.policy[0].name}/servicePerimeters/ecommerce_perimeter"
  parent     = "accessPolicies/${data.google_access_context_manager_access_policy.policy[0].name}"
  title      = "eCommerceMicroservicesPerimeter"
  perimeter_type = "REGULAR"

  # Security: Restrict allowed services within the perimeter to prevent unauthorized API calls
  restricted_services = [
    "bigquery.googleapis.com",        # If BigQuery is used for analytics
    "cloudfunctions.googleapis.com",  # If Cloud Functions are used
    "cloudkms.googleapis.com",        # For KMS
    "cloudsql.googleapis.com",        # For Cloud SQL
    "compute.googleapis.com",         # For GKE nodes, networking
    "container.googleapis.com",       # For GKE cluster management
    "dns.googleapis.com",             # For Cloud DNS
    "logging.googleapis.com",         # For Cloud Logging
    "monitoring.googleapis.com",      # For Cloud Monitoring
    "pubsub.googleapis.com",          # For Pub/Sub
    "run.googleapis.com",             # For Cloud Run
    "secretmanager.googleapis.com",   # For Secret Manager
    "servicenetworking.googleapis.com", # For private connectivity to managed services
    "storage.googleapis.com",         # For Cloud Storage
    "artifactregistry.googleapis.com",# For Artifact Registry (if used for images)
  ]

  status {
    # Security: Ensure the project is a member of the perimeter
    members = ["projects/${var.project_id}"]
    # Optional: Ingress/Egress policies can be defined here for fine-grained cross-perimeter communication
    # For a strict perimeter, these might be empty or very restrictive.
  }

  depends_on = [google_project_service.enabled_apis]
}

# --- Service Accounts for Infrastructure Components ---

# GKE Node Service Account (Security: Follows least privilege principle)
resource "google_service_account" "gke_node_sa" {
  account_id   = "ecommerce-gke-node-sa"
  display_name = "Service Account for GKE Nodes (ecommerce)"
  project      = var.project_id

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "gke-nodes"
  }
}

# IAM Bindings for GKE Node Service Account (minimal required roles)
resource "google_project_iam_member" "gke_node_sa_roles" {
  for_each = toset([
    "roles/logging.logWriter",          # To write logs to Cloud Logging
    "roles/monitoring.metricWriter",    # To write metrics to Cloud Monitoring
    "roles/container.nodeServiceAgent", # Required for GKE node operation and Workload Identity
    "roles/compute.networkViewer",      # To view network configuration (e.g., for Ingress)
    "roles/artifactregistry.reader",    # To pull images from Artifact Registry
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

# Workload Identity Service Account (Security: For K8s pods to access GCP services securely)
resource "google_service_account" "k8s_workload_sa" {
  account_id   = "ecommerce-k8s-workload-sa"
  display_name = "Service Account for K8s Workloads (ecommerce)"
  project      = var.project_id

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "k8s-workloads"
  }
}

# IAM Bindings for K8s Workload Service Account (example roles - adjust as needed for microservices)
resource "google_project_iam_member" "k8s_workload_sa_roles" {
  for_each = toset([
    "roles/secretmanager.secretAccessor", # To access secrets from Secret Manager
    "roles/pubsub.editor",                # To publish/subscribe to Pub/Sub topics
    "roles/storage.objectViewer",         # To read from GCS buckets (e.g., static assets)
    "roles/cloudsql.client",              # To connect to Cloud SQL instances
    "roles/cloudtrace.agent",             # For distributed tracing
    "roles/cloudrun.invoker",             # If Cloud Run services are invoked internally by GKE
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.k8s_workload_sa.email}"
}

# --- Google Kubernetes Engine (GKE) Cluster ---

# GKE Pod IP Range (Security: Private IP range for pods)
resource "google_compute_subnetwork_secondary_ip_range" "gke_pods_range" {
  name          = "gke-pods-range"
  ip_cidr_range = "10.11.0.0/18" # Sufficiently large range for pods
  subnetwork    = google_compute_subnetwork.ecommerce_app_subnet.name
  region        = var.region
  project       = var.project_id
}

# GKE Services IP Range (Security: Private IP range for services)
resource "google_compute_subnetwork_secondary_ip_range" "gke_services_range" {
  name          = "gke-services-range"
  ip_cidr_range = "10.11.64.0/20" # Sufficiently large range for services
  subnetwork    = google_compute_subnetwork.ecommerce_app_subnet.name
  region        = var.region
  project       = var.project_id
}

# Private GKE Cluster (Security: Control plane and nodes use private IPs only)
resource "google_container_cluster" "ecommerce_cluster" {
  name     = "ecommerce-cluster"
  location = var.region # Regional cluster for high availability
  project  = var.project_id

  # Security: Release Channels for automatic updates and security patches.
  # FinOps: Reduces operational overhead and ensures security hygiene.
  release_channel {
    channel = "REGULAR"
  }

  # Security: Private cluster configuration
  private_cluster_config {
    enable_private_endpoint = true # Control plane has internal IP only
    enable_private_nodes    = true # Nodes have internal IPs only
    master_ipv4_cidr_block  = "172.16.0.0/28" # Small CIDR for the master's internal IP
  }

  # IP Allocation for GKE
  ip_allocation_policy {
    cluster_secondary_range_name = google_compute_subnetwork_secondary_ip_range.gke_pods_range.name
    services_secondary_range_name = google_compute_subnetwork_secondary_ip_range.gke_services_range.name
  }

  network    = google_compute_network.ecommerce_vpc.name
  subnetwork = google_compute_subnetwork.ecommerce_app_subnet.name
  networking_mode = "VPC_NATIVE" # Recommended for performance, security, and scalability

  # Security: Workload Identity (best practice for K8s to GCP authentication)
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Security: Shielded GKE Nodes (integrity monitoring, secure boot)
  enable_shielded_nodes = true

  # Security: Master authorized networks (restrict access to the control plane endpoint)
  # IMPORTANT: Configure this to allow access ONLY from your trusted admin networks/IPs.
  master_authorized_networks_config {
    cidr_blocks {
      display_name = "Admin Network"
      cidr_block   = "0.0.0.0/0" # Placeholder: **REPLACE WITH YOUR SECURE ADMIN IP RANGE!**
    }
  }

  # Remove the default node pool to manage node pools explicitly
  remove_default_node_pool = true
  initial_node_count       = 1 # Required by Terraform for cluster creation, but immediately replaced by custom node pools

  # Monitoring and Logging (FinOps: Essential for operations and cost management insights)
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  labels = { # FinOps: Labels for cost allocation and operational insight
    environment = "production"
    application = "ecommerce"
    component   = "gke-cluster"
  }

  depends_on = [
    google_compute_subnetwork.ecommerce_app_subnet,
    google_compute_subnetwork_secondary_ip_range.gke_pods_range,
    google_compute_subnetwork_secondary_ip_range.gke_services_range,
  ]
}

# GKE Node Pool - Default Workloads (e.g., core microservices)
resource "google_container_node_pool" "default_node_pool" {
  name       = "default-node-pool"
  location   = var.region
  cluster    = google_container_cluster.ecommerce_cluster.name
  project    = var.project_id

  # FinOps: Auto-scaling for cost and elasticity
  autoscaling {
    min_node_count = var.gke_min_nodes_default
    max_node_count = var.gke_max_nodes_default
  }

  node_count = var.gke_num_nodes_default # Initial size, autoscaler will adjust

  node_config {
    machine_type    = "e2-standard-2" # FinOps: Select cost-effective machine types suitable for workloads
    service_account = google_service_account.gke_node_sa.email # Security: Least privilege SA
    oauth_scopes = [ # Minimal OAuth scopes for the node SA
      "https://www.googleapis.com/auth/cloud-platform", # Required for GKE node operation and Workload Identity
      # Workload Identity handles fine-grained permissions for pods, so node scopes can be broader.
    ]
    disk_type    = "pd-ssd" # FinOps: SSD for performance, adjust size for cost
    disk_size_gb = 50
    shielded_instance_config { # Security: Shielded GKE Nodes for VM integrity
      enable_integrity_monitoring = true
      enable_secure_boot          = true
    }
    workload_metadata_config { # Security: Prevent metadata server access from containers
      mode = "GKE_METADATA"
    }

    labels = { # FinOps: Labels for cost allocation and identification
      environment = "production"
      application = "ecommerce"
      pool        = "default"
    }
  }

  management {
    auto_repair  = true # FinOps: Reduce operational overhead
    auto_upgrade = true # FinOps: Reduce operational overhead and maintain security patches
  }

  node_locations = var.zones # Distribute nodes across zones for high availability

  depends_on = [
    google_container_cluster.ecommerce_cluster,
  ]
}

# GKE Node Pool - Spot Instances (FinOps: for fault-tolerant, batch, or non-critical workloads to save costs)
resource "google_container_node_pool" "spot_node_pool" {
  name       = "spot-node-pool"
  location   = var.region
  cluster    = google_container_cluster.ecommerce_cluster.name
  project    = var.project_id

  # FinOps: Auto-scaling for cost and elasticity, can scale down to zero
  autoscaling {
    min_node_count = var.gke_min_nodes_spot
    max_node_count = var.gke_max_nodes_spot
  }

  node_count = var.gke_num_nodes_spot

  node_config {
    machine_type = "e2-standard-2" # FinOps: Choose cost-effective machine type
    service_account = google_service_account.gke_node_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
    disk_type    = "pd-standard" # FinOps: Use cheaper disk type for Spot instances
    disk_size_gb = 30
    spot         = true # FinOps: Enable Spot VMs for significant cost savings
    shielded_instance_config {
      enable_integrity_monitoring = true
      enable_secure_boot          = true
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = { # FinOps: Labels for cost allocation and identification
      environment = "production"
      application = "ecommerce"
      pool        = "spot"
      preemptible = "true" # Custom label for easy identification/cost analysis
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_locations = var.zones # Distribute nodes across zones for high availability

  depends_on = [
    google_container_cluster.ecommerce_cluster,
  ]
}

# --- Cloud SQL (PostgreSQL) ---

# Allocate a private IP range for Cloud SQL Service Networking (Security: Private IP connectivity)
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "google-managed-services-private-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20 # Adjust prefix length based on expected managed services
  network       = google_compute_network.ecommerce_vpc.id
  project       = var.project_id

  depends_on = [google_project_service.enabled_apis]
}

# Create a private VPC connection for managed services (Cloud SQL, Memorystore)
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.ecommerce_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
  project                 = var.project_id

  depends_on = [google_compute_global_address.private_ip_alloc]
}

resource "google_sql_database_instance" "ecommerce_db" {
  name             = "ecommerce-db"
  database_version = "POSTGRES_14" # FinOps: Choose appropriate version for needs
  region           = var.region
  project          = var.project_id

  settings {
    tier              = "db-f1-micro" # FinOps: Start small, scale up as needed. Use appropriate tier for production.
    availability_type = "REGIONAL"    # High Availability: Ensures failover to another zone in the region.

    ip_configuration {
      ipv4_enabled    = false # Security: Disable public IP access
      private_network = google_compute_network.ecommerce_vpc.id # Security: Enable private IP access only
    }

    backup_configuration {
      enabled            = true
      start_time         = "03:00" # FinOps: Schedule backups during low traffic
      location           = "us"    # Multi-region backup location for disaster recovery
      transaction_log_retention_days = 7 # FinOps: Adjust based on recovery point objective (RPO)
    }

    disk_autoresize       = true # FinOps: Automatic disk resizing to avoid downtime and manual intervention
    disk_autoresize_limit = 0    # No limit, grows as needed (monitor costs)
    disk_size             = 20   # FinOps: Small initial disk size
    disk_type             = "SSD" # FinOps: SSD for performance

    insights_config { # FinOps/Monitoring: Enable query insights for performance tuning and cost optimization
      query_insights_enabled = true
      record_application_tags = false
      record_client_address = false
    }

    database_flags { # Example database flags (Security/Performance)
      name  = "cloudsql.enable_pglogical"
      value = "off"
    }

    maintenance_window { # FinOps: Schedule maintenance during off-peak hours
      day          = 7 # Sunday
      hour         = 2 # 2 AM
      update_track = "stable"
    }
  }

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "database"
    tier        = "backend"
  }

  depends_on = [
    google_service_networking_connection.private_vpc_connection
  ]
}

resource "google_sql_database" "ecommerce_app_db" {
  name     = "ecommerce-app-db"
  instance = google_sql_database_instance.ecommerce_db.name
  charset  = "UTF8"
  collation = "en_US.UTF8"
  project  = var.project_id
}

# Database user with password from Secret Manager (Security: Avoid hardcoding passwords)
resource "google_sql_user" "ecommerce_app_user" {
  name     = "appuser"
  instance = google_sql_database_instance.ecommerce_db.name
  host     = "%" # Security: Restrict host if possible (e.g., GKE internal IP range or Workload Identity)
  password = var.db_password # Password provided via Terraform variable, ideally from a secure vault.
  project  = var.project_id
}

# --- Cloud Memorystore (Redis) ---
resource "google_redis_instance" "ecommerce_redis" {
  name           = "ecommerce-cache"
  tier           = "BASIC" # FinOps: Start with BASIC, upgrade to STANDARD_HA if high availability/performance needed
  memory_size_gb = 1       # FinOps: Small initial size, scale up as needed
  region         = var.region
  project        = var.project_id

  connect_mode      = "DIRECT_PEERING" # Security: Recommended for private network connections
  location_id       = var.zones[0]     # For BASIC tier, single zone. For STANDARD_HA, multiple zones.
  transit_encryption_mode = "SERVER_AUTHENTICATION" # Security: In-transit encryption

  authorized_network = google_compute_network.ecommerce_vpc.id # Security: Connects via private network

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "cache"
  }

  depends_on = [
    google_service_networking_connection.private_vpc_connection
  ]
}

# --- Cloud Pub/Sub ---
resource "google_pubsub_topic" "order_events_topic" {
  name    = "order-events"
  project = var.project_id

  # Security: Enable server-side encryption with CMEK if sensitive data.
  # kms_key_name = google_kms_crypto_key.pubsub_key.id

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "messaging"
  }
}

resource "google_pubsub_topic" "dead_letter_topic" {
  name    = "order-events-dead-letter"
  project = var.project_id

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "messaging"
    type        = "dead-letter"
  }
}

resource "google_pubsub_subscription" "order_events_subscription" {
  name  = "order-processing-subscription"
  topic = google_pubsub_topic.order_events_topic.name
  project = var.project_id

  ack_deadline_seconds = 600 # FinOps: Adjust based on message processing time
  message_retention_duration = "604800s" # 7 days (FinOps: Adjust for cost/compliance)
  expiration_policy {
    ttl = "" # No expiration (keep subscription active)
  }

  dead_letter_policy { # Security: Dead-lettering for unprocessable messages
    dead_letter_topic     = google_pubsub_topic.dead_letter_topic.id
    max_delivery_attempts = 5
  }

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "messaging"
  }
}

# --- Cloud Storage (GCS) for static assets / logs / backups ---
resource "google_storage_bucket" "static_assets_bucket" {
  name          = "${var.project_id}-ecommerce-static-assets" # Must be globally unique
  location      = var.region
  project       = var.project_id
  force_destroy = false # Security: Prevent accidental deletion of contents

  storage_class = "STANDARD" # FinOps: Choose appropriate storage class (STANDARD, NEARLINE, COLDLINE, ARCHIVE)

  uniform_bucket_level_access = true # Security: Simplified and recommended access control model

  versioning { # Security: Versioning for recovery from accidental deletions/overwrites
    enabled = true
  }

  # FinOps: Lifecycle rules for cost optimization
  lifecycle_rule {
    action {
      type = "SetStorageClass"
      storage_class = "NEARLINE"
    }
    condition {
      age = 30 # Move objects to NEARLINE after 30 days
    }
  }
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age                = 365 # Delete objects after 365 days
      num_newer_versions = 1   # Keep at least 1 newer version before deleting
    }
  }

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "storage"
  }
}

# --- Secret Manager ---
resource "google_secret_manager_secret" "db_password_secret" {
  secret_id = "db-password"
  project   = var.project_id

  replication {
    automatic = true # Automatically replicate secret across regions for availability
  }

  labels = { # Security: Labels for classification and access control
    environment = "production"
    application = "ecommerce"
    type        = "credential"
  }
}

resource "google_secret_manager_secret_version" "db_password_secret_version" {
  secret      = google_secret_manager_secret.db_password_secret.id
  secret_data = var.db_password # Stores the database password
}

# --- Key Management Service (KMS) ---
resource "google_kms_key_ring" "ecommerce_keyring" {
  name     = "ecommerce-keyring"
  location = var.region
  project  = var.project_id

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "security"
  }
}

resource "google_kms_crypto_key" "ecommerce_crypto_key" {
  name          = "ecommerce-app-key"
  key_ring      = google_kms_key_ring.ecommerce_keyring.id
  rotation_period = "100000s" # Security: Auto-rotate keys for enhanced security

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "security"
    type        = "encryption"
  }
}

# --- Cloud Run (for simpler microservices) ---

# VPC Access Connector for Cloud Run (Security: Private access to VPC resources like Cloud SQL)
resource "google_vpc_access_connector" "cloud_run_connector" {
  name          = "ecommerce-cloudrun-connector"
  location      = var.region
  project       = var.project_id
  ip_cidr_range = "10.10.15.0/28" # Small, dedicated subnet range for the connector
  network       = google_compute_network.ecommerce_vpc.name
  # Use existing subnet and a dedicated small CIDR for the connector.
  # subnet = google_compute_subnetwork.ecommerce_app_subnet.name # Cannot directly attach to a subnetwork, must use `ip_cidr_range`.

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "cloudrun-connector"
  }

  depends_on = [
    google_project_service.enabled_apis
  ]
}

resource "google_cloud_run_service" "example_microservice" {
  name     = "example-microservice"
  location = var.region
  project  = var.project_id

  template {
    spec {
      service_account_name = google_service_account.k8s_workload_sa.email # Security: Use least-privilege SA
      containers {
        image = var.cloud_run_image # Container image for the microservice
        resources {
          limits = {
            cpu    = "1000m" # FinOps: Set CPU/memory limits to control cost and performance
            memory = "512Mi"
          }
        }
      }
      scaling { # FinOps: Scale to zero for cost savings when idle
        min_instance_count = 0
        max_instance_count = 5 # FinOps: Max instances to control cost and capacity
      }
      vpc_access { # Security: Access VPC resources via the connector
        connector = google_vpc_access_connector.cloud_run_connector.id
        egress    = "ALL_TRAFFIC" # Or PRIVATE_RANGES_ONLY for stricter control
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }

  # Security: Autogenerate revision name is good practice for immutable deployments.
  autogenerate_revision_name = true
  # For internal services, disable unauthenticated access. This makes it accessible via IAM or from within the VPC.
  # The Cloud Run IAM policy is usually defined separately if authenticated access from external clients is needed.

  metadata {
    labels = { # FinOps: Labels for cost allocation
      environment = "production"
      application = "ecommerce"
      component   = "cloudrun-microservice"
    }
  }

  depends_on = [
    google_vpc_access_connector.cloud_run_connector
  ]
}

# --- Cloud Armor (Web Application Firewall for external facing services) ---
resource "google_compute_security_policy" "ecommerce_waf_policy" {
  count = var.cloud_armor_policy_enabled ? 1 : 0 # Optional enablement via variable

  name        = "ecommerce-waf-policy"
  description = "Cloud Armor policy for e-commerce frontend. Security: Provides WAF and DDoS protection."
  project     = var.project_id

  rule { # Example: Block a specific IP address
    action   = "deny(403)"
    priority = "1000"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["9.9.9.9/32"] # Replace with actual malicious IPs if known
      }
    }
    description = "Block known malicious IP address"
  }

  rule { # Example: Block specific user agents
    action   = "deny(403)"
    priority = "1001"
    match {
      expr {
        expression = "request.headers['User-Agent'].contains('badbot')"
      }
    }
    description = "Block requests from 'badbot' user agent"
  }

  rule { # Default allow rule (lowest priority)
    action   = "allow"
    priority = "2147483647" # Default rule, lowest priority
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["0.0.0.0/0"]
      }
    }
    description = "Default allow all legitimate traffic"
  }

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "waf"
  }
}

# --- Frontend Load Balancer (Global External HTTP(S)) ---
# This static IP is typically used by GKE Ingress or a Cloud Run Load Balancer setup.
# The GKE Ingress Controller automatically provisions most of the LB infrastructure
# (URL maps, target proxies, backend services) and can use a pre-reserved static IP.

resource "google_compute_global_address" "frontend_ip" {
  name        = "ecommerce-frontend-ip"
  project     = var.project_id
  purpose     = "SHARED_LOADBALANCER_VIP"
  address_type = "EXTERNAL"
  description = "Static IP for e-commerce frontend Global External Load Balancer. High Availability."

  labels = { # FinOps: Labels for cost allocation
    environment = "production"
    application = "ecommerce"
    component   = "loadbalancer"
  }
}

# For managing SSL certificates (e.g., for 'your-ecommerce-domain.com')
# resource "google_compute_managed_ssl_certificate" "default_cert" {
#   name = "ecommerce-managed-cert"
#   managed {
#     domains = ["your-ecommerce-domain.com"]
#   }
#   project = var.project_id
#   depends_on = [google_compute_global_address.frontend_ip]
# }

# Example of how to create a backend service if directly exposing Cloud Run via LB
# (GKE Ingress would handle this for GKE-based services automatically)
/*
resource "google_compute_backend_service" "cloud_run_backend" {
  name        = "cloudrun-backend-service"
  project     = var.project_id
  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 30

  # For Cloud Run, backend is often a Serverless NEG
  # This part is more complex and typically set up via K8s Ingress or specific GCP Load Balancer configs.
  # As an example, if using an Internet NEG for a specific service:
  # backend {
  #   group = "projects/${var.project_id}/zones/${var.zones[0]}/networkEndpointGroups/cloud-run-neg" # Example placeholder
  # }

  # Security: Attach Cloud Armor policy
  security_policy = var.cloud_armor_policy_enabled ? google_compute_security_policy.ecommerce_waf_policy[0].self_link : null

  labels = {
    environment = "production"
    application = "ecommerce"
    component   = "loadbalancer-backend"
  }
}
*/


# --- Outputs ---
output "vpc_network_name" {
  description = "The name of the VPC network."
  value       = google_compute_network.ecommerce_vpc.name
}

output "ecommerce_app_subnet_self_link" {
  description = "The self_link of the e-commerce application subnet."
  value       = google_compute_subnetwork.ecommerce_app_subnet.self_link
}

output "gke_cluster_name" {
  description = "The name of the GKE cluster."
  value       = google_container_cluster.ecommerce_cluster.name
}

output "gke_cluster_endpoint" {
  description = "The private endpoint of the GKE cluster master. Security: This is a private IP."
  value       = google_container_cluster.ecommerce_cluster.endpoint
  sensitive   = true # Sensitive as it's a critical endpoint
}

output "cloudsql_instance_connection_name" {
  description = "The connection name of the Cloud SQL instance for private connectivity."
  value       = google_sql_database_instance.ecommerce_db.connection_name
}

output "redis_instance_host" {
  description = "The host IP address of the Memorystore Redis instance for internal access."
  value       = google_redis_instance.ecommerce_redis.host
}

output "static_assets_bucket_name" {
  description = "The name of the GCS bucket for static assets and general storage."
  value       = google_storage_bucket.static_assets_bucket.name
}

output "cloud_run_service_url" {
  description = "The URL of the example Cloud Run service (internal if no public access)."
  value       = google_cloud_run_service.example_microservice.status[0].url
}

output "frontend_ip_address" {
  description = "The static IP address reserved for the frontend Global External Load Balancer."
  value       = google_compute_global_address.frontend_ip.address
}

output "gke_k8s_workload_service_account_email" {
  description = "Email of the GCP Service Account used by GKE K8s workloads via Workload Identity."
  value       = google_service_account.k8s_workload_sa.email
}

output "vpc_sc_perimeter_name" {
  description = "The name of the VPC Service Controls perimeter (if enabled)."
  value       = var.vpc_sc_enabled ? google_access_context_manager_service_perimeter.ecommerce_perimeter[0].name : "VPC SC not enabled"
}