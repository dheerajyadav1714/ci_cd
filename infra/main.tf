terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Variables ---
variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
}

variable "region" {
  description = "The GCP region to deploy regional resources (e.g., subnets, Cloud SQL)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone for zonal resources (e.g., Managed Instance Group). Should be within the chosen region."
  type        = string
  default     = "us-central1-a"
}

variable "network_name" {
  description = "Name for the VPC network."
  type        = string
  default     = "app-vpc-network"
}

variable "app_subnet_cidr" {
  description = "CIDR range for the application subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "db_subnet_cidr" {
  description = "CIDR range for the database subnet."
  type        = string
  default     = "10.0.2.0/24"
}

variable "instance_machine_type" {
  description = "Machine type for the GCE instances in the MIG."
  type        = string
  default     = "e2-medium"
}

variable "instance_disk_image" {
  description = "Disk image for the GCE instances."
  type        = string
  default     = "debian-cloud/debian-11"
}

variable "sql_tier" {
  description = "Machine type for the Cloud SQL instance."
  type        = string
  default     = "db-f1-micro" # Smallest tier for testing
}

variable "sql_database_version" {
  description = "Cloud SQL database version (e.g., POSTGRES_14, MYSQL_8_0)."
  type        = string
  default     = "POSTGRES_14"
}

variable "sql_db_name" {
  description = "Name of the SQL database to create inside the instance."
  type        = string
  default     = "webapp_db"
}

variable "sql_user_name" {
  description = "Username for the SQL database."
  type        = string
  default     = "webapp_user"
}

variable "sql_user_password" {
  description = "Password for the SQL database user."
  type        = string
  sensitive   = true # Mark as sensitive to prevent logging
  default     = "StrongPassword!123" # CHANGE THIS IN PRODUCTION!
}


# --- Networking ---
resource "google_compute_network" "app_network" {
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "app_subnet" {
  name          = "app-subnet"
  ip_cidr_range = var.app_subnet_cidr
  region        = var.region
  network       = google_compute_network.app_network.id
}

resource "google_compute_subnetwork" "db_subnet" {
  name          = "db-subnet"
  ip_cidr_range = var.db_subnet_cidr
  region        = var.region
  network       = google_compute_network.app_network.id
  # Enable private IP Google Access for services like Cloud SQL from this subnet
  private_ip_google_access = true
}

# Firewall rule to allow SSH from IAP (Identity-Aware Proxy)
resource "google_compute_firewall" "allow_ssh_from_iap" {
  name    = "allow-ssh-from-iap"
  network = google_compute_network.app_network.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  # Source ranges for Google's IAP (Identity-Aware Proxy)
  # This is a secure way to allow SSH without opening to the world.
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["app-server"]
}

# Firewall rule to allow HTTP (port 80) from anywhere (for load balancer and public access)
resource "google_compute_firewall" "allow_http_ingress" {
  name    = "allow-http-ingress"
  network = google_compute_network.app_network.name
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["app-server"]
}


# --- Service Account for GCE Instances ---
resource "google_service_account" "instance_sa" {
  account_id   = "app-instance-sa"
  display_name = "Service Account for App GCE Instances"
  project      = var.project_id
}

# Grant necessary IAM roles to the service account
resource "google_project_iam_member" "instance_sa_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.instance_sa.email}"
}

resource "google_project_iam_member" "instance_sa_monitoring_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.instance_sa.email}"
}

resource "google_project_iam_member" "instance_sa_storage_object_viewer" {
  # Example: If instances need to read from GCS bucket
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.instance_sa.email}"
}


# --- GCE Instances (Managed Instance Group) ---
resource "google_compute_instance_template" "app_instance_template" {
  name_prefix    = "app-template-"
  machine_type   = var.instance_machine_type
  can_ip_forward = false # Typically false for web servers
  tags           = ["app-server"]

  disk {
    source_image = var.instance_disk_image
    auto_delete  = true
    boot         = true
    disk_size_gb = 20
  }

  network_interface {
    network    = google_compute_network.app_network.id
    subnetwork = google_compute_subnetwork.app_subnet.id
    # A real application often needs an external IP for outbound internet access,
    # or should use Cloud NAT. For simplicity and allowing outbound, we attach an ephemeral IP.
    access_config {
      # Empty access_config block means an ephemeral external IP.
    }
  }

  service_account {
    email  = google_service_account.instance_sa.email
    # Scopes define what APIs the instance can access.
    # 'cloud-platform' is broad; in production, use minimal specific scopes.
    scopes = ["cloud-platform"]
  }

  metadata = {
    # Basic startup script to install Nginx and serve a "Hello World" page
    startup-script = <<-EOF
      #!/bin/bash
      sudo apt-get update
      sudo apt-get install -y nginx
      echo "Hello World from $(hostname)!" | sudo tee /var/www/html/index.nginx-debian.html
      sudo systemctl enable nginx
      sudo systemctl start nginx
    EOF
  }

  labels = {
    environment = "development"
    app         = "webapp"
  }
}

resource "google_compute_health_check" "app_health_check" {
  name                = "app-health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2
  request_path        = "/"
  port                = 80
  protocol            = "HTTP"
}

resource "google_compute_backend_service" "app_backend_service" {
  name        = "app-backend-service"
  protocol    = "HTTP"
  port_name   = "http" # Corresponds to named_port in MIG
  timeout_sec = 10

  health_checks = [google_compute_health_check.app_health_check.id]

  backend {
    group          = google_compute_instance_group_manager.app_mig.instance_group
    balancing_mode = "UTILIZATION" # Balance based on CPU utilization
    capacity_scaler = 1.0          # Use 100% of capacity
  }
}

resource "google_compute_instance_group_manager" "app_mig" {
  name               = "app-mig"
  base_instance_name = "app-instance"
  zone               = var.zone # Using a single zone for simplicity; regional MIGs offer better HA
  target_size        = 2        # Desired number of instances

  version {
    instance_template = google_compute_instance_template.app_instance_template.id
    name              = "primary"
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.app_health_check.id
    initial_delay_sec = 300 # Wait 5 minutes after boot before checking health
  }

  named_port {
    name = "http"
    port = 80
  }
}


# --- HTTP Load Balancer ---
resource "google_compute_global_address" "lb_ip_address" {
  name = "app-lb-ip"
}

resource "google_compute_url_map" "app_url_map" {
  name            = "app-url-map"
  default_service = google_compute_backend_service.app_backend_service.id
}

resource "google_compute_target_http_proxy" "app_http_proxy" {
  name    = "app-http-proxy"
  url_map = google_compute_url_map.app_url_map.id
}

resource "google_compute_global_forwarding_rule" "app_http_forwarding_rule" {
  name       = "app-http-forwarding-rule"
  ip_protocol = "TCP"
  port_range = "80"
  target     = google_compute_target_http_proxy.app_http_proxy.id
  ip_address = google_compute_global_address.lb_ip_address.id
}


# --- Cloud SQL (PostgreSQL Example) ---
resource "google_sql_database_instance" "app_db_instance" {
  name             = "app-db-instance"
  database_version = var.sql_database_version
  region           = var.region
  project          = var.project_id

  settings {
    tier            = var.sql_tier
    disk_autoresize = true
    disk_size       = 20 # GB
    backup_configuration {
      enabled            = true
      binary_log_enabled = true # Required for point-in-time recovery
      start_time         = "03:00"
    }
    ip_configuration {
      ipv4_enabled    = true
      private_network = google_compute_network.app_network.id # Connect to VPC privately
      require_ssl     = true # Enforce SSL/TLS connections

      # Authorize private IP range of the application subnet
      authorized_networks {
        value = google_compute_subnetwork.app_subnet.ip_cidr_range
        name  = "app-subnet-access"
      }
    }
    # For production: configure `availability_type = "REGIONAL"` for high availability
    # and `maintenance_window`
  }
}

resource "google_sql_database" "app_database" {
  name       = var.sql_db_name
  instance   = google_sql_database_instance.app_db_instance.name
  charset    = "UTF8"
  collation  = "en_US.UTF8"
}

resource "google_sql_user" "app_db_user" {
  name     = var.sql_user_name
  instance = google_sql_database_instance.app_db_instance.name
  # Host set to '%' allows connection from any host, which is needed for private IP within the VPC
  host     = "%"
  password = var.sql_user_password
}


# --- Cloud Storage Bucket ---
resource "google_storage_bucket" "app_bucket" {
  name          = "${var.project_id}-webapp-assets" # Must be globally unique
  location      = var.region
  project       = var.project_id
  storage_class = "STANDARD"
  uniform_bucket_level_access = true # Recommended for simplified IAM
  versioning {
    enabled = true
  }
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 365 # Delete objects older than 365 days
    }
  }
}


# --- Outputs ---
output "load_balancer_ip" {
  description = "The external IP address of the HTTP Load Balancer."
  value       = google_compute_global_address.lb_ip_address.address
}

output "instance_group_manager_name" {
  description = "The name of the Managed Instance Group."
  value       = google_compute_instance_group_manager.app_mig.name
}

output "cloud_sql_instance_connection_name" {
  description = "The connection name for the Cloud SQL instance (used by Cloud SQL Proxy)."
  value       = google_sql_database_instance.app_db_instance.connection_name
}

output "cloud_sql_private_ip_address" {
  description = "The private IP address of the Cloud SQL instance."
  value       = google_sql_database_instance.app_db_instance.private_ip_address
}

output "storage_bucket_url" {
  description = "The URL of the Cloud Storage bucket."
  value       = google_storage_bucket.app_bucket.url
}