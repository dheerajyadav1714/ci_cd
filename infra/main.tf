variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
}

variable "region" {
  description = "The GCP region to deploy primary resources into (e.g., us-central1)."
  type        = string
  default     = "us-central1"
}

variable "gke_node_machine_type" {
  description = "Machine type for GKE nodes."
  type        = string
  default     = "e2-standard-4" # Cost-effective, good balance for general purpose workloads
}

variable "gke_min_node_count" {
  description = "Minimum number of nodes in GKE node pool."
  type        = number
  default     = 3 # For High Availability, ensuring at least 3 nodes across zones
}

variable "gke_max_node_count" {
  description = "Maximum number of nodes in GKE node pool."
  type        = number
  default     = 10 # Adjust based on expected peak load and cost optimization
}

variable "db_tier" {
  description = "Cloud SQL database tier (machine type)."
  type        = string
  default     = "db-custom-4-16384" # 4 vCPU, 16GB RAM as a starting point for 20k concurrent users
}

variable "db_disk_size_gb" {
  description = "Cloud SQL database disk size in GB."
  type        = number
  default     = 100
}

variable "environment" {
  description = "Environment name (e.g., 'prod', 'non-prod'). Used for naming conventions and labels."
  type        = string
  default     = "prod"
}

# Provider Configuration
provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Enable Required GCP APIs ---
# Ensures all necessary APIs are enabled for the project before resources are created.
resource "google_project_service" "compute_api" {
  project = var.project_id
  service = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "container_api" {
  project = var.project_id
  service = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sqladmin_api" {
  project = var.project_id
  service = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "servicenetworking_api" {
  project = var.project_id
  service = "servicenetworking.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "secretmanager_api" {
  project = var.project_id
  service = "secretmanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dns_api" {
  project = var.project_id
  service = "dns.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam_api" {
  project = var.project_id
  service = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudresourcemanager_api" {
  project = var.project_id
  service = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage_api" {
  project = var.project_id
  service = "storage.googleapis.com"
  disable_on_destroy = false
}

# --- Networking Resources (VPC, Subnets, NAT) ---
# A custom VPC network for strong isolation, essential for HIPAA compliance.
resource "google_compute_network" "vpc_network" {
  name                    = "${var.environment}-telemed-vpc"
  auto_create_subnetworks = false # Custom subnets for granular control
  routing_mode            = "REGIONAL" # Regional routing for efficient traffic within the region
  project                 = var.project_id
  depends_on              = [google_project_service.compute_api]
}

# Private subnet for GKE nodes and other internal services.
resource "google_compute_subnetwork" "private_subnet" {
  name          = "${var.environment}-telemed-private-subnet"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.region
  network       = google_compute_network.vpc_network.id
  # Enables private access to Google APIs (e.g., Artifact Registry, Cloud Monitoring) for GKE nodes
  private_ip_google_access = true
  project                  = var.project_id
}

# Secondary IP range for GKE Pods
resource "google_compute_subnetwork" "pods_subnet" {
  name          = "${var.environment}-telemed-pods-subnet"
  ip_cidr_range = "10.20.0.0/16" # A larger range for anticipated pod scale
  region        = var.region
  network       = google_compute_network.vpc_network.id
  project       = var.project_id
  secondary_ip_range {
    range_name    = "gke-pods-range"
    ip_cidr_range = "10.20.0.0/16"
  }
}

# Secondary IP range for GKE Services
resource "google_compute_subnetwork" "services_subnet" {
  name          = "${var.environment}-telemed-services-subnet"
  ip_cidr_range = "10.30.0.0/20" # Sufficient range for cluster services
  region        = var.region
  network       = google_compute_network.vpc_network.id
  project       = var.project_id
  secondary_ip_range {
    range_name    = "gke-services-range"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# Cloud Router required for Cloud NAT
resource "google_compute_router" "nat_router" {
  name    = "${var.environment}-telemed-nat-router"
  region  = var.region
  network = google_compute_network.vpc_network.id
  project = var.project_id
}

# Cloud NAT for private GKE nodes to securely access external services (e.g., container registries, external APIs)
resource "google_compute_router_nat" "gke_nat" {
  name                          = "${var.environment}-telemed-gke-nat"
  router                        = google_compute_router.nat_router.name
  region                        = google_compute_router.nat_router.region
  nat_ip_allocate_option        = "AUTO_ONLY" # Automatically allocate external IP addresses
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES" # NAT traffic from all IPs in the configured subnets
  log_config {
    enable = true
    filter = "ERRORS_ONLY" # Log NAT translation errors
  }
  project = var.project_id
}

# Firewall rules for secure network communication
# Allow internal VPC communication (GKE nodes, pods, services, Cloud SQL, etc.)
resource "google_compute_firewall" "allow_internal_to_all" {
  name    = "${var.environment}-allow-internal-to-all"
  network = google_compute_network.vpc_network.name
  project = var.project_id

  allow {
    protocol = "icmp"
  }
  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  source_ranges = [
    google_compute_subnetwork.private_subnet.ip_cidr_range,
    google_compute_subnetwork.pods_subnet.secondary_ip_range[0].ip_cidr_range,
    google_compute_subnetwork.services_subnet.secondary_ip_range[0].ip_cidr_range,
    # Add Cloud SQL private IP range if specific or just rely on VPC internal ranges
  ]
  target_tags = ["gke-nodes"] # Target GKE nodes and pods, assuming default K8s service accounts use these tags
}

# Allow external HTTP/S ingress to the Load Balancer. GKE Ingress will configure the LB target.
# This rule primarily allows Google Front End (GFE) to perform health checks and forward traffic.
resource "google_compute_firewall" "allow_lb_ingress" {
  name    = "${var.environment}-allow-lb-ingress"
  network = google_compute_network.vpc_network.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "30000-32767"] # Standard HTTP/S ports + GKE NodePort range for Ingress
  }
  # Source ranges for Google's Load Balancer health checks and traffic forwarding
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["gke-nodes"] # Ensure this tag is applied to your GKE nodes
}

# --- Cloud SQL for PostgreSQL (Highly Available and Private) ---
# Allocate an internal IP range for Private Service Access to Cloud SQL.
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "${var.environment}-telemed-sql-private-ip-alloc"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20 # /20 provides 4096 IP addresses, ample for Cloud SQL and other services
  network       = google_compute_network.vpc_network.id
  project       = var.project_id
}

# Establish a private connection between your VPC and Google's service networking.
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
  project                 = var.project_id
  depends_on              = [google_project_service.servicenetworking_api]
}

# High-availability Cloud SQL PostgreSQL instance.
resource "google_sql_database_instance" "postgres_instance" {
  database_version = "POSTGRES_14" # Using a recent, stable PostgreSQL version
  name             = "${var.environment}-telemed-db"
  region           = var.region
  project          = var.project_id
  depends_on       = [google_service_networking_connection.private_vpc_connection, google_project_service.sqladmin_api]

  settings {
    tier              = var.db_tier
    disk_size         = var.db_disk_size_gb
    disk_type         = "SSD" # SSD for performance-critical databases
    disk_autoresize   = true # Automatically increase disk size as needed
    activation_policy = "ALWAYS"
    availability_type = "REGIONAL" # Configures for high availability with automatic failover

    ip_configuration {
      ipv4_enabled    = false # Disable public IP for enhanced security and HIPAA compliance
      private_network = google_compute_network.vpc_network.id
      # For HIPAA, consider explicitly authorizing specific GKE pod CIDR blocks or using Cloud SQL Proxy.
    }

    backup_configuration {
      enabled            = true
      binary_log_enabled = true # Required for point-in-time recovery
      start_time         = "03:00" # Example daily backup window (UTC)
      location           = var.region # Backup location within the region
    }

    maintenance_window {
      day  = 7 # Sunday
      hour = 2 # 2 AM UTC
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "On" # Enable IAM authentication for secure access from GKE Workload Identity
    }
  }
}

# Generate a strong random password for the database user.
resource "random_password" "db_password" {
  length  = 16
  special = true
  numeric = true
  upper   = true
  lower   = true
  keepers = {
    # This ensures the password is only regenerated if the environment name changes.
    environment = var.environment
  }
}

# Store the database password securely in Google Secret Manager.
resource "google_secret_manager_secret" "db_password_secret" {
  secret_id = "${var.environment}-telemed-db-password"
  project   = var.project_id
  depends_on = [google_project_service.secretmanager_api]

  replication {
    automatic = true # Automatic replication across regions
  }

  labels = {
    environment = var.environment
    application = "telemedicine"
  }
}

resource "google_secret_manager_secret_version" "db_password_secret_version" {
  secret      = google_secret_manager_secret.db_password_secret.id
  secret_data = random_password.db_password.result
}

# Cloud SQL Database user for the application.
# If using IAM authentication for Cloud SQL, applications can connect using their service accounts.
# A traditional user might still be needed for management tasks or specific application requirements.
resource "google_sql_user" "telemed_app_user" {
  name     = "telemed_app_user"
  instance = google_sql_database_instance.postgres_instance.name
  host     = "%" # Allows connections from any private IP within the VPC. For HIPAA, consider stricter authorization.
  password = random_password.db_password.result
  project  = var.project_id
  depends_on = [google_sql_database_instance.postgres_instance, google_secret_manager_secret_version.db_password_secret_version]
}


# --- GKE Cluster (Regional, Private, and Secure) ---
# Dedicated Service Account for GKE nodes with minimized permissions (HIPAA best practice).
resource "google_service_account" "gke_node_sa" {
  account_id   = "${var.environment}-gke-node-sa"
  display_name = "Service Account for GKE Nodes in ${var.environment}"
  project      = var.project_id
  depends_on   = [google_project_service.iam_api]
}

# Grant necessary IAM roles to the GKE Node Service Account.
resource "google_project_iam_member" "gke_node_sa_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

resource "google_project_iam_member" "gke_node_sa_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

resource "google_project_iam_member" "gke_node_sa_devstorage_reader" {
  project = var.project_id
  role    = "roles/storage.objectViewer" # For pulling container images from GCR/Artifact Registry
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

# Essential role for GKE nodes to operate correctly.
resource "google_project_iam_member" "gke_node_sa_container_node_service_account" {
  project = var.project_id
  role    = "roles/container.nodeServiceAgent"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

# Regional GKE cluster for High Availability (99.99%) and private for HIPAA compliance.
resource "google_container_cluster" "gke_cluster" {
  name               = "${var.environment}-telemed-gke"
  location           = var.region # Regional cluster for HA across multiple zones
  project            = var.project_id
  initial_node_count = 1 # We manage node pools separately
  depends_on         = [google_project_service.container_api, google_service_account.gke_node_sa_container_node_service_account]

  # Private cluster configuration for enhanced security (HIPAA)
  private_cluster_config {
    enable_private_endpoint = true # GKE Control Plane accessible only via private IP
    enable_private_nodes    = true # GKE Nodes do not have public IPs
    master_ipv4_cidr_block  = "172.16.0.0/28" # Dedicated small CIDR for master
  }

  network    = google_compute_network.vpc_network.id
  subnetwork = google_compute_subnetwork.private_subnet.id

  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.pods_subnet.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.services_subnet.secondary_ip_range[0].range_name
  }

  enable_binary_authorization = false # Highly recommended for HIPAA in production, for enforcing image policies
  network_policy {
    enabled = true # Enable Kubernetes Network Policies for granular pod-level security
  }

  workload_identity_config {
    workload_pool_id = "${var.project_id}.svc.id.goog" # Enable Workload Identity for secure access to GCP services
  }

  cluster_autoscaling {
    enabled = true # Automatically scales cluster nodes based on demand
    resource_limits {
      resource_type = "cpu"
      minimum       = var.gke_min_node_count * 2 # Example: 2 vCPU per e2-standard-4
      maximum       = var.gke_max_node_count * 2
    }
    resource_limits {
      resource_type = "memory"
      minimum       = var.gke_min_node_count * 16384 # Example: 16GB per e2-standard-4
      maximum       = var.gke_max_node_count * 16384
    }
  }

  remove_default_node_pool = true # Manage node pools explicitly
  
  # Enable Stackdriver Logging and Monitoring for GKE
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  release_channel {
    channel = "REGULAR" # Provides a balance of stability and access to new features
  }

  node_config {
    # Shielded VMs for GKE nodes for enhanced security
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
    # Tags applied to GKE nodes for firewall rules.
    tags = ["gke-nodes"]
  }
}

# GKE Primary Node Pool, distributed across multiple zones within the region for HA.
resource "google_container_node_pool" "primary_node_pool" {
  name       = "${var.environment}-primary-pool"
  location   = var.region
  cluster    = google_container_cluster.gke_cluster.name
  project    = var.project_id
  depends_on = [google_container_cluster.gke_cluster] # Ensure cluster is created first

  node_config {
    machine_type    = var.gke_node_machine_type
    disk_size_gb    = 100 # Default disk size for nodes
    disk_type       = "pd-ssd" # SSD for better performance
    preemptible     = false # Non-preemptible instances for production workloads
    service_account = google_service_account.gke_node_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",  # For pulling container images
      "https://www.googleapis.com/auth/logging.write",        # For sending logs to Cloud Logging
      "https://www.googleapis.com/auth/monitoring",           # For sending metrics to Cloud Monitoring
      "https://www.googleapis.com/auth/service.management.readonly", # Needed for some GCP service integrations
      "https://www.googleapis.com/auth/servicecontrol",       # Needed for some GCP service integrations
      "https://www.googleapis.com/auth/trace.append",         # For Cloud Trace integration
      "https://www.googleapis.com/auth/sqlservice.admin"      # Required if Cloud SQL Proxy runs on nodes
    ]
    metadata = {
      disable-legacy-endpoints = "true" # Best practice for security
    }
    tags = ["gke-nodes"] # Apply tags for firewall rules targeting nodes
  }

  autoscaling {
    min_node_count = var.gke_min_node_count
    max_node_count = var.gke_max_node_count
  }

  management {
    auto_repair  = true # Automatically repair unhealthy nodes
    auto_upgrade = true # Automatically upgrade node versions
  }

  # Distribute nodes across multiple zones for High Availability
  node_locations = [
    "${var.region}-a",
    "${var.region}-b",
    "${var.region}-c"
  ]
}

# --- IAM Bindings for Workload Identity (GKE Pods to GCP Services) ---
# This GCP Service Account will be bound to a Kubernetes Service Account (KSA)
# for the telemedicine application pods. This enables fine-grained permissions for pods.
resource "google_service_account" "telemed_app_sa" {
  account_id   = "${var.environment}-telemed-app-sa"
  display_name = "Service Account for Telemedicine Application Pods"
  project      = var.project_id
}

# Grant the application Service Account permission to access database passwords from Secret Manager.
resource "google_project_iam_member" "telemed_app_sa_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.telemed_app_sa.email}"
}

# Allow the application Service Account to connect to Cloud SQL (e.g., via Cloud SQL Proxy or IAM authentication).
resource "google_project_iam_member" "telemed_app_sa_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.telemed_app_sa.email}"
}

# Bind the GCP Service Account to a Kubernetes Service Account (KSA) using Workload Identity.
# The KSA (e.g., `telemed-app-ksa` in namespace `telemed-app`) must be created in Kubernetes YAML.
# Example K8s Service Account definition:
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: telemed-app-ksa
#   namespace: telemed-app
#   annotations:
#     iam.gke.io/gcp-service-account: ${google_service_account.telemed_app_sa.email}
resource "google_service_account_iam_member" "telemed_app_ksa_iam_binding" {
  service_account_id = google_service_account.telemed_app_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[telemed-app/telemed-app-ksa]"
}

# --- Load Balancing (External IP for GKE Ingress) ---
# Reserve a global static external IP address for the application's external Load Balancer.
# This IP will be utilized by the GKE Ingress controller to provision a Global HTTP(S) Load Balancer.
resource "google_compute_global_address" "telemed_lb_ip" {
  name        = "${var.environment}-telemed-lb-ip"
  project     = var.project_id
  address_type = "EXTERNAL"
  depends_on = [google_project_service.compute_api]
}

# --- Cloud Storage (for static assets, backups, audit logs) ---
# Secure Cloud Storage bucket for application static assets, user uploads, or backups.
# Features like versioning and lifecycle rules are critical for data management and HIPAA compliance.
resource "google_storage_bucket" "telemed_assets_bucket" {
  name          = "${var.project_id}-${var.environment}-telemed-assets" # Must be globally unique
  location      = var.region # Regional for lower latency, or MULTI_REGIONAL for higher availability if required
  project       = var.project_id
  force_destroy = false # Prevents accidental deletion if bucket contains objects
  depends_on    = [google_project_service.storage_api]

  labels = {
    environment = var.environment
    application = "telemedicine"
  }

  versioning {
    enabled = true # For data recovery and audit trail
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 90 # Example: Delete objects older than 90 days. Adjust as per data retention policies.
    }
  }

  uniform_bucket_level_access = true # Enforces consistent access control, simplifies permissions
  public_access_prevention    = "enforced" # Ensures no public access by default, crucial for HIPAA
}

# --- Cloud DNS (Optional, but highly recommended for custom domains) ---
# Managed public DNS zone for the telemedicine application's domain.
resource "google_dns_managed_zone" "telemed_zone" {
  name        = "${var.environment}-telemed-zone"
  dns_name    = "telemedapp.com." # IMPORTANT: Replace with your actual domain name. The trailing dot is crucial.
  description = "Public managed zone for telemedicine application"
  project     = var.project_id
  visibility  = "public"
  depends_on  = [google_project_service.dns_api]
}

# DNS A record pointing the application's domain to the external Load Balancer IP.
resource "google_dns_record_set" "telemed_a_record" {
  name         = "app.${google_dns_managed_zone.telemed_zone.dns_name}"
  type         = "A"
  ttl          = 300 # Time to live in seconds
  managed_zone = google_dns_managed_zone.telemed_zone.name
  rrdatas      = [google_compute_global_address.telemed_lb_ip.address]
  project      = var.project_id
}

# --- Outputs ---
# Provides important information about the deployed infrastructure.
output "gke_cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.gke_cluster.name
}

output "gke_cluster_endpoint" {
  description = "Endpoint of the GKE cluster's control plane (private)."
  value       = google_container_cluster.gke_cluster.endpoint
}

output "gke_node_pool_name" {
  description = "Name of the primary GKE node pool."
  value       = google_container_node_pool.primary_node_pool.name
}

output "cloud_sql_instance_connection_name" {
  description = "Connection name for the Cloud SQL instance (used by Cloud SQL Proxy)."
  value       = google_sql_database_instance.postgres_instance.connection_name
}

output "cloud_sql_instance_private_ip" {
  description = "Private IP address of the Cloud SQL instance."
  value       = google_sql_database_instance.postgres_instance.private_ip_address
}

output "telemed_app_gcp_service_account_email" {
  description = "GCP Service Account email for the telemedicine application pods to use with Workload Identity."
  value       = google_service_account.telemed_app_sa.email
}

output "external_lb_ip_address" {
  description = "External IP address reserved for the Global HTTP(S) Load Balancer."
  value       = google_compute_global_address.telemed_lb_ip.address
}

output "db_password_secret_id" {
  description = "ID of the Secret Manager secret holding the database password (used if traditional user/pass auth is needed)."
  value       = google_secret_manager_secret.db_password_secret.id
}

output "telemed_assets_bucket_name" {
  description = "Name of the Cloud Storage bucket for telemedicine application assets."
  value       = google_storage_bucket.telemed_assets_bucket.name
}

output "dns_domain_name_managed_zone" {
  description = "The name of the Cloud DNS managed zone."
  value       = google_dns_managed_zone.telemed_zone.dns_name
}

output "app_dns_record" {
  description = "The fully qualified domain name (FQDN) for the application frontend."
  value       = google_dns_record_set.telemed_a_record.name
}