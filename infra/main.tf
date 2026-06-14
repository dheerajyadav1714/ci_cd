terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
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
  description = "The GCP region to deploy resources into."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone to deploy resources into."
  type        = string
  default     = "us-central1-c"
}

# --- Random Resources for Unique Naming ---

resource "random_id" "suffix" {
  byte_length = 4
}

resource "random_password" "db_password" {
  length  = 16
  special = true
}

# --- Networking ---

resource "google_compute_network" "main_vpc" {
  name                    = "app-vpc-${random_id.suffix.hex}"
  auto_create_subnetworks = false
  mtu                     = 1460
}

resource "google_compute_subnetwork" "main_subnet" {
  name          = "app-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.main_vpc.id
}

# --- Firewall Rules ---

resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "${google_compute_network.main_vpc.name}-allow-ssh-iap"
  network = google_compute_network.main_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["35.235.240.0/20"] # Allows SSH via IAP
  target_tags   = ["web-server"]
}

resource "google_compute_firewall" "allow_lb_health_check" {
  name    = "${google_compute_network.main_vpc.name}-allow-lb-health-check"
  network = google_compute_network.main_vpc.name
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"] # Google's LB health checkers
  target_tags   = ["web-server"]
}

# --- Compute Engine ---

# Service account for compute instances
resource "google_service_account" "vm_sa" {
  account_id   = "vm-sa-${random_id.suffix.hex}"
  display_name = "Service Account for Web Server VMs"
}

# Instance template for the MIG
resource "google_compute_instance_template" "web_server_template" {
  name_prefix  = "web-server-template-"
  machine_type = "e2-micro"
  region       = var.region
  tags         = ["web-server", "http"]

  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network    = google_compute_network.main_vpc.id
    subnetwork = google_compute_subnetwork.main_subnet.id
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    apt-get update
    apt-get install -y nginx
    echo "<h1>Welcome - Served by $(hostname)</h1>" > /var/www/html/index.html
  EOT

  service_account {
    email  = google_service_account.vm_sa.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Managed Instance Group
resource "google_compute_instance_group_manager" "web_server_mig" {
  name               = "web-server-mig-${random_id.suffix.hex}"
  base_instance_name = "web-server"
  zone               = var.zone
  target_size        = 2

  version {
    instance_template = google_compute_instance_template.web_server_template.id
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.http_health_check.id
    initial_delay_sec = 60
  }
}

# --- Load Balancer ---

resource "google_compute_global_address" "lb_ip" {
  name = "lb-static-ip-${random_id.suffix.hex}"
}

resource "google_compute_health_check" "http_health_check" {
  name                = "http-health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2

  http_health_check {
    port         = 80
    request_path = "/"
  }
}

resource "google_compute_backend_service" "web_backend_service" {
  name                  = "web-backend-service"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 10
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_health_check.http_health_check.id]

  backend {
    group = google_compute_instance_group_manager.web_server_mig.instance_group
  }
}

resource "google_compute_url_map" "default_url_map" {
  name            = "default-url-map"
  default_service = google_compute_backend_service.web_backend_service.id
}

resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "http-proxy"
  url_map = google_compute_url_map.default_url_map.id
}

resource "google_compute_global_forwarding_rule" "http_forwarding_rule" {
  name                  = "http-forwarding-rule"
  ip_protocol           = "TCP"
  port_range            = "80"
  target                = google_compute_target_http_proxy.http_proxy.id
  ip_address            = google_compute_global_address.lb_ip.address
  load_balancing_scheme = "EXTERNAL"
}

# --- Cloud SQL for PostgreSQL (Private IP) ---

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.sql_private_range.name]
}

resource "google_compute_global_address" "sql_private_range" {
  name          = "sql-private-range-${random_id.suffix.hex}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main_vpc.id
}

resource "google_sql_database_instance" "main_db" {
  name             = "main-db-instance-${random_id.suffix.hex}"
  database_version = "POSTGRES_14"
  region           = var.region
  depends_on       = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier = "db-g1-small"
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.main_vpc.id
    }
    backup_configuration {
      enabled = true
    }
  }

  deletion_protection = false # Set to true for production environments
}

resource "google_sql_database" "app_db" {
  name     = "appdb"
  instance = google_sql_database_instance.main_db.name
}

resource "google_sql_user" "app_user" {
  name     = "appuser"
  instance = google_sql_database_instance.main_db.name
  password = random_password.db_password.result
}

# --- Cloud Storage ---

resource "google_storage_bucket" "app_storage_bucket" {
  name          = "app-storage-bucket-${random_id.suffix.hex}"
  location      = var.region
  force_destroy = true # Set to false for production environments

  uniform_bucket_level_access = true

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

# --- Outputs ---

output "load_balancer_ip" {
  description = "The public IP address of the load balancer."
  value       = google_compute_global_forwarding_rule.http_forwarding_rule.ip_address
}

output "cloud_storage_bucket_name" {
  description = "The name of the GCS bucket."
  value       = google_storage_bucket.app_storage_bucket.name
}

output "database_instance_name" {
  description = "The name of the Cloud SQL database instance."
  value       = google_sql_database_instance.main_db.name
}

output "database_private_ip" {
  description = "The private IP address of the Cloud SQL instance."
  value       = google_sql_database_instance.main_db.private_ip_address
}

output "database_user_password" {
  description = "The generated password for the database user."
  value       = random_password.db_password.result
  sensitive   = true
}