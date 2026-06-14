terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.0.0"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

resource "google_compute_network" "main_vpc" {
  name                    = "${var.project_id}-main-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "app_subnet" {
  name          = "${var.project_id}-app-subnet"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.region
  network       = google_compute_network.main_vpc.id
}

resource "google_compute_subnetwork" "db_subnet" {
  name          = "${var.project_id}-db-subnet"
  ip_cidr_range = "10.20.0.0/20"
  region        = var.region
  network       = google_compute_network.main_vpc.id
}

resource "google_compute_firewall" "allow_ssh_ingress" {
  name    = "${var.project_id}-allow-ssh"
  network = google_compute_network.main_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh-allowed"]
}

resource "google_compute_firewall" "allow_http_ingress" {
  name    = "${var.project_id}-allow-http"
  network = google_compute_network.main_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-allowed"]
}

# -----------------------------------------------------------------------------
# Compute (GKE Cluster)
# -----------------------------------------------------------------------------

resource "google_container_cluster" "primary_cluster" {
  name                     = "${var.project_id}-gke-cluster"
  location                 = var.region
  initial_node_count       = 1
  network                  = google_compute_network.main_vpc.self_link
  subnetwork               = google_compute_subnetwork.app_subnet.self_link
  logging_service          = "logging.googleapis.com/kubernetes"
  monitoring_service       = "monitoring.googleapis.com/kubernetes"
  release_channel {
    channel = "REGULAR"
  }
  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 100
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
    tags = ["gke-node", "http-allowed"]
  }
  private_cluster_config {
    enable_private_endpoint = false
    enable_private_nodes    = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }
  master_authorized_networks_config {
    cidr_blocks {
      display_name = "Allow All Ingress"
      cidr_block   = "0.0.0.0/0"
    }
  }
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }
  addons_config {
    http_load_balancing {
      disabled = false
    }
    kubernetes_dashboard {
      disabled = true
    }
  }
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "${google_container_cluster.primary_cluster.name}-node-pool"
  location   = var.region
  cluster    = google_container_cluster.primary_cluster.name
  node_count = 2

  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 100
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
    tags = ["gke-node", "http-allowed"]
  }
  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# -----------------------------------------------------------------------------
# Database (Cloud SQL PostgreSQL)
# -----------------------------------------------------------------------------

resource "google_sql_database_instance" "main_db_instance" {
  database_version = "POSTGRES_14"
  name             = "${var.project_id}-main-db"
  region           = var.region
  settings {
    tier = "db-f1-micro"
    backup_configuration {
      enabled            = true
      binary_log_enabled = true
      start_time         = "03:00"
    }
    ip_configuration {
      ipv4_enabled = true
      # This example allows all IPs for simplicity.
      # In production, restrict to GKE egress IPs or specific IP ranges.
      dynamic "authorized_networks" {
        for_each = var.db_authorized_networks
        content {
          value = authorized_networks.value
        }
      }
    }
    disk_autoresize     = true
    disk_size           = 20
    disk_type           = "PD_SSD"
    availability_type   = "REGIONAL" # For High Availability
  }
}

resource "google_sql_database" "app_database" {
  name     = "app_database"
  instance = google_sql_database_instance.main_db_instance.name
  charset  = "UTF8"
  collation = "en_US.UTF8"
}

resource "google_sql_user" "app_user" {
  name     = "app_user"
  instance = google_sql_database_instance.main_db_instance.name
  host     = "%" # Allow connections from any host (adjust for production)
  password = var.db_user_password
}

# -----------------------------------------------------------------------------
# Storage (Cloud Storage Bucket for Static Assets/Backups)
# -----------------------------------------------------------------------------

resource "google_storage_bucket" "static_assets_bucket" {
  name          = "${var.project_id}-static-assets"
  location      = "US" # Often set to multi-region for static assets
  storage_class = "STANDARD"
  uniform_bucket_level_access = true
  versioning {
    enabled = true
  }
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 365
    }
  }
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "project_id" {
  description = "The GCP project ID."
  type        = string
}

variable "region" {
  description = "The GCP region for deploying resources."
  type        = string
  default     = "us-central1"
}

variable "db_user_password" {
  description = "Password for the Cloud SQL application user."
  type        = string
  sensitive   = true
}

variable "db_authorized_networks" {
  description = "List of CIDR blocks to authorize for Cloud SQL access. Use [\"0.0.0.0/0\"] for open access (not recommended for production)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "vpc_name" {
  description = "Name of the main VPC network."
  value       = google_compute_network.main_vpc.name
}

output "gke_cluster_name" {
  description = "Name of the GKE cluster."
  value       = google_container_cluster.primary_cluster.name
}

output "gke_cluster_endpoint" {
  description = "Endpoint of the GKE cluster."
  value       = google_container_cluster.primary_cluster.endpoint
}

output "sql_instance_connection_name" {
  description = "Connection name for the Cloud SQL instance."
  value       = google_sql_database_instance.main_db_instance.connection_name
}

output "static_assets_bucket_url" {
  description = "URL of the static assets Cloud Storage bucket."
  value       = google_storage_bucket.static_assets_bucket.self_link
}