provider "google" {
  project = var.project_id
  region  = var.region
}

# --- Networking ---
resource "google_compute_network" "vpc_network" {
  name                    = "app-vpc-network"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "app_subnet" {
  name          = "app-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.vpc_network.id
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "app-allow-ssh"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server"] # Apply to app instances
}

resource "google_compute_firewall" "allow_http" {
  name    = "app-allow-http"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"] # Can be restricted to LB health check ranges if desired
  target_tags   = ["http-server"]
}

resource "google_compute_firewall" "allow_lb_health_checks" {
  name    = "app-allow-lb-health-checks"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"] # Google Cloud Load Balancer health check IP ranges
  target_tags   = ["http-server"]
}

# --- Service Account for Compute Instances ---
resource "google_service_account" "instance_service_account" {
  account_id   = "app-instance-sa"
  display_name = "Service Account for App Instances"
  project      = var.project_id
}

resource "google_project_iam_member" "instance_sa_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.instance_service_account.email}"
}

resource "google_project_iam_member" "instance_sa_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.instance_service_account.email}"
}

resource "google_project_iam_member" "instance_sa_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client" # Required for connecting to Cloud SQL
  member  = "serviceAccount:${google_service_account.instance_service_account.email}"
}

# --- Compute Instances (Managed Instance Group) ---
resource "google_compute_instance_template" "app_instance_template" {
  name_prefix    = "app-template-"
  machine_type   = var.machine_type
  can_ip_forward = false
  tags           = ["http-server"]

  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network    = google_compute_network.vpc_network.id
    subnetwork = google_compute_subnetwork.app_subnet.id
    access_config {
      // Ephemeral public IP address to allow outbound internet access and inbound LB traffic
    }
  }

  service_account {
    email  = google_service_account.instance_service_account.email
    scopes = ["cloud-platform"] # Broad scope for example; refine for production
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install -y nginx
    echo "Hello from $(hostname) - Application instance!" | sudo tee /var/www/html/index.nginx-debian.html
    sudo systemctl start nginx
    sudo systemctl enable nginx
  EOT
}

resource "google_compute_region_instance_group_manager" "app_mig" {
  name               = "app-instance-group"
  base_instance_name = "app-instance"
  region             = var.region
  target_size        = var.instance_count

  version {
    instance_template = google_compute_instance_template.app_instance_template.id
    name              = "primary"
  }

  auto_healing_policies {
    initial_delay_sec = 300
    health_check      = google_compute_health_check.http_health_check.id
  }
}

# --- HTTP Load Balancer ---
resource "google_compute_health_check" "http_health_check" {
  name               = "app-http-health-check"
  request_path       = "/"
  port               = 80
  check_interval_sec = 5
  timeout_sec        = 5
  unhealthy_threshold = 2
  healthy_threshold  = 2
}

resource "google_compute_region_backend_service" "app_backend_service" {
  name                            = "app-backend-service"
  protocol                        = "HTTP"
  port_name                       = "http"
  load_balancing_scheme           = "EXTERNAL"
  health_checks                   = [google_compute_health_check.http_health_check.id]
  timeout_sec                     = 30

  backend {
    group = google_compute_region_instance_group_manager.app_mig.instance_group
  }
}

resource "google_compute_url_map" "app_url_map" {
  name            = "app-url-map"
  default_service = google_compute_region_backend_service.app_backend_service.id
}

resource "google_compute_target_http_proxy" "app_http_proxy" {
  name    = "app-http-proxy"
  url_map = google_compute_url_map.app_url_map.id
}

resource "google_compute_global_forwarding_rule" "app_http_forwarding_rule" {
  name        = "app-http-forwarding-rule"
  target      = google_compute_target_http_proxy.app_http_proxy.id
  port_range  = "80"
  ip_protocol = "TCP"
}

# --- Cloud SQL (PostgreSQL) ---
resource "google_sql_database_instance" "main_db_instance" {
  name             = "app-db-instance"
  database_version = "POSTGRES_14"
  region           = var.region
  settings {
    tier = "db-f1-micro"
    backup_configuration {
      enabled = true
    }
    ip_configuration {
      ipv4_enabled = true
      # In production, restrict authorized_networks to your application's subnet CIDR or specific IPs.
      # For example: authorized_networks { value = google_compute_subnetwork.app_subnet.ip_cidr_range }
      # Allowing 0.0.0.0/0 means accessible from any public IP, assuming correct credentials.
      # authorized_networks {
      #   value = "0.0.0.0/0"
      #   name  = "Allow All for testing (harden in prod)"
      # }
    }
    database_flags {
      name  = "cloudsql.enable_pgaudit" # Example flag
      value = "off"
    }
  }
  root_password = var.db_password # For initial setup; use Secret Manager in production
}

resource "google_sql_database" "app_database" {
  name     = "app-database"
  instance = google_sql_database_instance.main_db_instance.name
  charset  = "UTF8"
  collation = "en_US.UTF8"
}

# --- Cloud Storage Bucket ---
resource "google_storage_bucket" "app_static_assets_bucket" {
  name          = "${var.project_id}-app-static-assets" # Must be globally unique
  location      = var.gcs_bucket_location
  storage_class = "STANDARD"
  uniform_bucket_level_access = true
  versioning {
    enabled = true
  }
}

# --- Variables ---
variable "project_id" {
  description = "The GCP project ID."
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources."
  type        = string
  default     = "us-central1"
}

variable "db_password" {
  description = "Root password for the Cloud SQL instance."
  type        = string
  sensitive   = true
}

variable "machine_type" {
  description = "Machine type for the compute instances."
  type        = string
  default     = "e2-medium"
}

variable "instance_count" {
  description = "Number of instances in the Managed Instance Group."
  type        = number
  default     = 2
}

variable "gcs_bucket_location" {
  description = "Location for the Cloud Storage Bucket (e.g., US, EU, or a specific region like us-central1)."
  type        = string
  default     = "US-CENTRAL1" # Default to regional for consistency
}

# --- Outputs ---
output "vpc_network_name" {
  description = "Name of the created VPC Network."
  value       = google_compute_network.vpc_network.name
}

output "load_balancer_ip_address" {
  description = "The IP address of the HTTP(S) Load Balancer."
  value       = google_compute_global_forwarding_rule.app_http_forwarding_rule.ip_address
}

output "cloud_sql_instance_connection_name" {
  description = "The connection name of the Cloud SQL instance."
  value       = google_sql_database_instance.main_db_instance.connection_name
}

output "cloud_storage_bucket_name" {
  description = "The name of the Cloud Storage bucket."
  value       = google_storage_bucket.app_static_assets_bucket.name
}