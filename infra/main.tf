terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Variables ---
variable "project_id" {
  description = "The GCP project ID."
  type        = string
}

variable "region" {
  description = "The GCP region for resources."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone for single-zone resources (e.g., Memorystore, Cloud SQL HA primary)."
  type        = string
  default     = "us-central1-a"
}

variable "env_prefix" {
  description = "A prefix for resource names to denote environment (e.g., 'dev', 'prod')."
  type        = string
  default     = "prod"
}

# --- Networking ---
resource "google_compute_network" "main_vpc" {
  name                    = "${var.env_prefix}-main-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL" # For regional GKE and other services
  description             = "Main VPC network for greenfield deployment."
}

resource "google_compute_subnetwork" "main_subnet" {
  name          = "${var.env_prefix}-main-subnet"
  ip_cidr_range = "10.10.0.0/20" # Primary IP range for instances/nodes
  region        = var.region
  network       = google_compute_network.main_vpc.id
  description   = "Primary subnet for GKE nodes, internal VMs."
}

# IP range for GKE Pods
resource "google_compute_subnetwork" "gke_pods_subnet" {
  ip_cidr_range = "10.12.0.0/14" # Larger range for pods
  name          = "${var.env_prefix}-gke-pods-subnet"
  network       = google_compute_network.main_vpc.id
  project       = var.project_id
  region        = var.region
  secondary_ip_range {
    range_name    = "gke-pods-range"
    ip_cidr_range = "10.12.0.0/14"
  }
}

# IP range for GKE Services
resource "google_compute_subnetwork" "gke_services_subnet" {
  ip_cidr_range = "10.13.0.0/20" # Smaller range for services
  name          = "${var.env_prefix}-gke-services-subnet"
  network       = google_compute_network.main_vpc.id
  project       = var.project_id
  region        = var.region
  secondary_ip_range {
    range_name    = "gke-services-range"
    ip_cidr_range = "10.13.0.0/20"
  }
}

# Allocate a private IP range for Google-managed services (e.g., Cloud SQL, Memorystore)
resource "google_compute_address" "private_service_connection_range" {
  name          = "${var.env_prefix}-psc-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20 # Can adjust based on expected service growth
  network       = google_compute_network.main_vpc.id
  region        = var.region
  description   = "Dedicated IP range for private service access."
}

# Establish the private service connection (VPC Peering for managed services)
resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_address.private_service_connection_range.name]
}

# --- Cloud Router & NAT Gateway (for private GKE egress) ---
resource "google_compute_router" "nat_router" {
  name    = "${var.env_prefix}-nat-router"
  region  = var.region
  network = google_compute_network.main_vpc.id
  project = var.project_id
}

resource "google_compute_router_nat" "nat_gateway" {
  name                               = "${var.env_prefix}-nat-gateway"
  router                             = google_compute_router.nat_router.name
  region                             = google_compute_router.nat_router.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES" # Apply to all IPs in subnet
  log_config {
    enable = true
    filter = "ERRORS_ONLY" # FinOps: Log errors only to reduce cost
  }
  depends_on = [
    google_compute_router.nat_router
  ]
}

# --- GKE Cluster ---
resource "google_service_account" "gke_node_sa" {
  account_id   = "${var.env_prefix}-gke-node-sa"
  display_name = "${var.env_prefix} GKE Node Service Account"
  project      = var.project_id
}

# Grant minimal permissions to GKE Node Service Account
resource "google_project_iam_member" "gke_node_sa_logging_monitoring" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

resource "google_project_iam_member" "gke_node_sa_monitoring_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

resource "google_project_iam_member" "gke_node_sa_gke_viewer" {
  project = var.project_id
  role    = "roles/container.viewer" # Necessary for some cluster operations/monitoring
  member  = "serviceAccount:${google_service_account.gke_node_sa.email}"
}

resource "google_container_cluster" "main_gke_cluster" {
  name               = "${var.env_prefix}-gke-cluster"
  location           = var.region
  project            = var.project_id
  initial_node_count = 1 # Managed by node_pool, but required for initial state

  # FinOps: Enable cost management
  cost_management_config {
    enabled = true
  }

  # Security: Private cluster configuration
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true # Control plane accessible only via VPC internal IPs
    master_ipv4_cidr_block  = "10.10.1.0/28" # Dedicated IP range for GKE master
  }

  ip_allocation_policy {
    cluster_secondary_range_name = google_compute_subnetwork.gke_pods_subnet.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.gke_services_subnet.secondary_ip_range[0].range_name
  }

  network    = google_compute_network.main_vpc.name
  subnetwork = google_compute_subnetwork.main_subnet.name

  # Security: Enable Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Security: Enable Pod Security Policy (optional, GKE Autopilot handles this automatically, GKE Standard uses Gatekeeper/Admission Controllers)
  # Security: Enable Network Policy
  network_policy {
    enabled = true
  }

  # Security: Shielded GKE Nodes
  node_config {
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
    # Service account for nodes, NOT for application workloads
    service_account = google_service_account.gke_node_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform" # Broader scope for GKE features, Workload Identity is preferred for app access.
    ]
  }

  # Remove default node pool as we will manage it separately
  remove_default_node_pool = true

  depends_on = [
    google_compute_subnetwork.gke_pods_subnet,
    google_compute_subnetwork.gke_services_subnet
  ]
}

resource "google_container_node_pool" "default_node_pool" {
  name       = "${var.env_prefix}-default-node-pool"
  location   = var.region
  cluster    = google_container_cluster.main_gke_cluster.name
  node_count = 1 # Initial node count

  # FinOps: Auto-scaling for cost optimization
  autoscaling {
    min_node_count = 1
    max_node_count = 5 # Adjust based on expected load
  }

  node_config {
    machine_type = "e2-medium" # FinOps: Start with smaller machine types
    disk_size_gb = 100         # Default disk size for nodes
    disk_type    = "pd-ssd"    # SSD for better performance

    # Security: Shielded GKE Nodes
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Service account for nodes
    service_account = google_service_account.gke_node_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/devstorage.read_only", # For pulling images
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append"
    ]
  }
}

# --- Cloud SQL (PostgreSQL Example) ---
resource "google_sql_database_instance" "app_database" {
  name             = "${var.env_prefix}-app-db-instance"
  database_version = "POSTGRES_14"
  region           = var.region
  project          = var.project_id

  # FinOps: Start with a small tier, scale as needed
  settings {
    tier = "db-f1-micro" # Smallest tier for testing/dev, scale up for production
    disk_type = "SSD"
    disk_size = 20 # FinOps: start small, enable auto_resize
    disk_autoresize = true
    disk_autoresize_limit = 100 # Max disk size for auto-resize

    backup_configuration {
      enabled            = true
      start_time         = "03:00" # Example backup window
      binary_log_enabled = true
      location           = var.region
    }

    ip_configuration {
      ipv4_enabled    = false # Disable public IP for security
      private_network = google_compute_network.main_vpc.id
      # Authorized networks (VPC subnet) if specific IPs need access (e.g., admin workstation via IAP)
      # For GKE, private IP access implies the entire VPC can access.
    }

    # Security: High Availability
    availability_type = "REGIONAL" # For HA, uses primary_zone and secondary_zone automatically in region

    # Security: Database Flags
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "cloudsql.logical_decoding"
      value = "on" # If using logical replication for data movement
    }
    # Add other security flags as needed (e.g., pgaudit, force_ssl)

    # Maintenance Window
    maintenance_window {
      day  = 7 # Sunday
      hour = 2 # 2 AM UTC
    }
  }
  depends_on = [google_service_networking_connection.private_vpc_connection]
}

resource "google_sql_database" "app_db" {
  name     = "app_db"
  instance = google_sql_database_instance.app_database.name
  charset  = "UTF8"
  collation = "en_US.UTF8"
}

resource "google_sql_user" "app_user" {
  name     = "app_user"
  instance = google_sql_database_instance.app_database.name
  host     = "%" # Allow connections from any host (private IP only, still secure)
  password = "changeme_secure_password" # In production, use Secret Manager
}

# --- Memorystore Redis ---
resource "google_redis_instance" "app_cache_redis" {
  name            = "${var.env_prefix}-app-redis-cache"
  tier            = "BASIC" # FinOps: Start with BASIC, scale to STANDARD_HA if needed
  memory_size_gb  = 1        # FinOps: Start with 1GB, scale as needed
  region          = var.region
  location_id     = var.zone # Specific zone for BASIC tier
  connect_mode    = "DIRECT_PEERING"
  transit_encryption_mode = "SERVER_AUTHENTICATION" # Security: Client-server encryption

  # Security: Private IP connectivity only
  auth_enabled    = true # Security: Require authentication
  # redis_auth_string is populated by GCP automatically when auth_enabled = true

  project         = var.project_id
  network         = google_compute_network.main_vpc.id
  reserved_ip_range = google_compute_address.private_service_connection_range.self_link # Use the allocated range

  # Maintenance Window
  maintenance_policy {
    daily_maintenance_window {
      start_time {
        hours   = 4
        minutes = 0
        seconds = 0
        nanos   = 0
      }
    }
  }
  depends_on = [google_service_networking_connection.private_vpc_connection]
}

# --- Firewall Rules (minimal essential) ---
# Allow internal traffic within VPC
resource "google_compute_firewall" "allow_internal_vpc" {
  name    = "${var.env_prefix}-allow-internal-vpc"
  network = google_compute_network.main_vpc.name
  project = var.project_id

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

  source_ranges = ["10.0.0.0/8"] # Allow all internal VPC ranges (including GKE pod/service ranges)
  direction     = "INGRESS"
  priority      = 65534 # Low priority, can be overridden by more specific rules
  description   = "Allow all internal VPC traffic for service communication."
}

# Allow SSH to GKE nodes (via IAP recommended, or specific admin ranges)
resource "google_compute_firewall" "allow_ssh_gke_nodes" {
  name    = "${var.env_prefix}-allow-ssh-gke-nodes"
  network = google_compute_network.main_vpc.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  # Source ranges should be highly restricted in production, e.g., corporate VPN or IAP
  # For now, placeholder for common SSH. In a real scenario, use IAP or specific IP blocks.
  source_ranges = ["0.0.0.0/0"] # WARNING: Insecure for production, restrict this.
  target_tags   = ["gke-${google_container_cluster.main_gke_cluster.name}-node"] # Target GKE nodes
  direction     = "INGRESS"
  priority      = 1000
  description   = "Allow SSH to GKE nodes (WARNING: Restrict source_ranges in production)."
}

# Allow external traffic to GKE Load Balancers (if using external LBs)
# This is a generic example. In practice, you'd target specific GKE Ingress/Service ports.
resource "google_compute_firewall" "allow_http_https_ingress" {
  name    = "${var.env_prefix}-allow-http-https"
  network = google_compute_network.main_vpc.name
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
  source_ranges = ["0.0.0.0/0"] # Allow all internet traffic for external LBs
  target_tags   = ["gke-${google_container_cluster.main_gke_cluster.name}"] # Target GKE-managed LBs if they apply tags
  direction     = "INGRESS"
  priority      = 1000
  description   = "Allow HTTP/HTTPS traffic from internet to GKE (via Load Balancers)."
}


# --- Outputs ---
output "vpc_name" {
  description = "The name of the VPC network."
  value       = google_compute_network.main_vpc.name
}

output "gke_cluster_name" {
  description = "The name of the GKE cluster."
  value       = google_container_cluster.main_gke_cluster.name
}

output "gke_cluster_endpoint" {
  description = "The private endpoint of the GKE cluster master."
  value       = google_container_cluster.main_gke_cluster.endpoint
}

output "cloud_sql_instance_connection_name" {
  description = "The connection name for the Cloud SQL instance."
  value       = google_sql_database_instance.app_database.connection_name
}

output "memorystore_redis_host" {
  description = "The host IP address of the Memorystore Redis instance."
  value       = google_redis_instance.app_cache_redis.host
}

output "memorystore_redis_port" {
  description = "The port of the Memorystore Redis instance."
  value       = google_redis_instance.app_cache_redis.port
}

output "gke_node_service_account_email" {
  description = "The email of the service account used by GKE nodes."
  value       = google_service_account.gke_node_sa.email
}