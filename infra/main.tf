provider "google" {
  project = var.project_id
  region  = var.primary_region
}

provider "google-beta" {
  project = var.project_id
  region  = var.primary_region
}

variable "project_id" {
  description = "The GCP project ID."
  type        = string
  default     = "your-gcp-project-id" # CHANGE ME
}

variable "primary_region" {
  description = "Primary GCP region for GKE and AlloyDB."
  type        = string
  default     = "us-central1"
}

variable "secondary_region" {
  description = "Secondary GCP region for GKE and AlloyDB DR."
  type        = string
  default     = "europe-west1"
}

variable "gke_machine_type" {
  description = "Machine type for GKE nodes."
  type        = string
  default     = "e2-medium"
}

variable "gke_node_count" {
  description = "Number of nodes per GKE cluster."
  type        = number
  default     = 2
}

variable "network_name" {
  description = "Name of the VPC network."
  type        = string
  default     = "healthcare-analytics-vpc"
}

variable "gke_service_account_id" {
  description = "ID for the GKE service account."
  type        = string
  default     = "gke-sa"
}

variable "lb_ip_name" {
  description = "Name for the Global Load Balancer IP address."
  type        = string
  default     = "healthcare-platform-lb-ip"
}

variable "lb_hostname" {
  description = "Hostname for the Load Balancer (for SSL certs)."
  type        = string
  default     = "analytics.example.com" # CHANGE ME for managed SSL cert
}

# --- Shared Networking (VPC) ---
resource "google_compute_network" "vpc_network" {
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  project                 = var.project_id
}

# Primary Region Subnets
resource "google_compute_subnetwork" "primary_subnet" {
  name          = "${var.primary_region}-subnet"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.primary_region
  network       = google_compute_network.vpc_network.id
  project       = var.project_id
}

resource "google_compute_subnetwork" "primary_gke_pods_subnet" {
  name                     = "${var.primary_region}-gke-pods-subnet"
  ip_cidr_range            = "10.20.0.0/16"
  region                   = var.primary_region
  network                  = google_compute_network.vpc_network.id
  private_ip_google_access = true # Required for private GKE nodes to reach Google APIs
  project                  = var.project_id

  secondary_ip_range {
    range_name    = "gke-pods-range"
    ip_cidr_range = "10.20.0.0/16"
  }
}

resource "google_compute_subnetwork" "primary_gke_services_subnet" {
  name                     = "${var.primary_region}-gke-services-subnet"
  ip_cidr_range            = "10.30.0.0/20"
  region                   = var.primary_region
  network                  = google_compute_network.vpc_network.id
  private_ip_google_access = true
  project                  = var.project_id

  secondary_ip_range {
    range_name    = "gke-services-range"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# Secondary Region Subnets
resource "google_compute_subnetwork" "secondary_subnet" {
  name          = "${var.secondary_region}-subnet"
  ip_cidr_range = "10.11.0.0/20"
  region        = var.secondary_region
  network       = google_compute_network.vpc_network.id
  project       = var.project_id
}

resource "google_compute_subnetwork" "secondary_gke_pods_subnet" {
  name                     = "${var.secondary_region}-gke-pods-subnet"
  ip_cidr_range            = "10.21.0.0/16"
  region                   = var.secondary_region
  network                  = google_compute_network.vpc_network.id
  private_ip_google_access = true
  project                  = var.project_id

  secondary_ip_range {
    range_name    = "gke-pods-range"
    ip_cidr_range = "10.21.0.0/16"
  }
}

resource "google_compute_subnetwork" "secondary_gke_services_subnet" {
  name                     = "${var.secondary_region}-gke-services-subnet"
  ip_cidr_range            = "10.31.0.0/20"
  region                   = var.secondary_region
  network                  = google_compute_network.vpc_network.id
  private_ip_google_access = true
  project                  = var.project_id

  secondary_ip_range {
    range_name    = "gke-services-range"
    ip_cidr_range = "10.31.0.0/20"
  }
}

# --- Private Service Access for AlloyDB ---
resource "google_compute_global_address" "private_ip_alloc" {
  name          = "alloydb-private-ip-alloc"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc_network.id
  project       = var.project_id
}

resource "google_service_networking_connection" "alloydb_private_vpc_connection" {
  network                 = google_compute_network.vpc_network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_alloc.name]
  project                 = var.project_id
}

# --- Service Accounts ---
resource "google_service_account" "gke_sa" {
  account_id   = var.gke_service_account_id
  display_name = "Service Account for GKE nodes"
  project      = var.project_id
}

resource "google_project_iam_member" "gke_sa_logs_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

resource "google_project_iam_member" "gke_sa_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

resource "google_project_iam_member" "gke_sa_container_node" {
  project = var.project_id
  role    = "roles/container.nodeServiceAccount"
  member  = "serviceAccount:${google_service_account.gke_sa.email}"
}

# --- AlloyDB for PostgreSQL ---
resource "random_password" "alloydb_password" {
  length  = 16
  special = true
  override_special = "!#$%&*()_+-=[]{}|:?"
}

# Primary AlloyDB Cluster in us-central1
resource "google_alloydb_cluster" "primary_alloydb_cluster" {
  cluster_id  = "primary-alloydb-cluster"
  location    = var.primary_region
  network     = google_compute_network.vpc_network.id
  project     = var.project_id
  annotations = { "terraform" = "true" }
  depends_on  = [google_service_networking_connection.alloydb_private_vpc_connection]

  initial_user {
    user     = "alloydb_admin"
    password = random_password.alloydb_password.result
  }

  continuous_backup_config {
    enabled                = true
    recovery_window_days   = 7
    point_in_time_recovery_enabled = true
  }

  network_config {
    network_connection_mode = "PRIVATE_SERVICE_ACCESS"
  }
}

resource "google_alloydb_instance" "primary_alloydb_instance" {
  cluster           = google_alloydb_cluster.primary_alloydb_cluster.name
  instance_id       = "primary-instance"
  instance_type     = "PRIMARY"
  location          = var.primary_region
  project           = var.project_id
  machine_cpu_count = 2
  database_flags = {
    "log_connections"    = "on"
    "log_disconnections" = "on"
  }
  labels = {
    "env"  = "production"
    "tier" = "database"
  }
}

# Secondary (DR) AlloyDB Cluster in europe-west1
# NOTE ON HIPAA & Data Residency: If data must remain in the US, this secondary
# cluster should be in another US region (e.g., us-east1). The current setup
# uses europe-west1 as per requirement.
resource "google_alloydb_cluster" "secondary_alloydb_cluster" {
  cluster_id           = "secondary-alloydb-cluster"
  location             = var.secondary_region
  network              = google_compute_network.vpc_network.id
  project              = var.project_id
  cluster_type         = "SECONDARY"
  primary_cluster_name = google_alloydb_cluster.primary_alloydb_cluster.name
  annotations          = { "terraform" = "true" }
  depends_on           = [google_service_networking_connection.alloydb_private_vpc_connection]

  continuous_backup_config {
    enabled                = true
    recovery_window_days   = 7
    point_in_time_recovery_enabled = true
  }

  network_config {
    network_connection_mode = "PRIVATE_SERVICE_ACCESS"
  }
}

resource "google_alloydb_instance" "secondary_alloydb_instance" {
  cluster           = google_alloydb_cluster.secondary_alloydb_cluster.name
  instance_id       = "secondary-instance"
  instance_type     = "READ_POOL" # Can be a read pool for DR or just a primary if failover occurs
  location          = var.secondary_region
  project           = var.project_id
  machine_cpu_count = 2
  database_flags = {
    "log_connections"    = "on"
    "log_disconnections" = "on"
  }
  labels = {
    "env"  = "dr"
    "tier" = "database"
  }
}

# --- GKE Clusters (Regional, Private, HIPAA-friendly) ---
# Primary GKE Cluster in us-central1
resource "google_container_cluster" "primary_gke_cluster" {
  name                     = "primary-gke-cluster"
  location                 = var.primary_region
  project                  = var.project_id
  initial_node_count       = 1
  remove_default_node_pool = true
  network                  = google_compute_network.vpc_network.id
  subnetwork               = google_compute_subnetwork.primary_subnet.id

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.primary_gke_pods_subnet.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.primary_gke_services_subnet.secondary_ip_range[0].range_name
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  vertical_pod_autoscaling {
    enabled = true
  }
  node_locations = [
    "${var.primary_region}-a",
    "${var.primary_region}-b",
  ]
}

resource "google_container_node_pool" "primary_gke_node_pool" {
  name       = "primary-gke-node-pool"
  location   = var.primary_region
  cluster    = google_container_cluster.primary_gke_cluster.name
  project    = var.project_id
  node_count = var.gke_node_count

  node_config {
    machine_type    = var.gke_machine_type
    service_account = google_service_account.gke_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
    disk_size_gb = 100
    shielded_instance_config {
      enable_integrity_monitoring = true
      enable_secure_boot          = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# Secondary GKE Cluster in europe-west1
resource "google_container_cluster" "secondary_gke_cluster" {
  name                     = "secondary-gke-cluster"
  location                 = var.secondary_region
  project                  = var.project_id
  initial_node_count       = 1
  remove_default_node_pool = true
  network                  = google_compute_network.vpc_network.id
  subnetwork               = google_compute_subnetwork.secondary_subnet.id

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "172.17.0.0/28"
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = google_compute_subnetwork.secondary_gke_pods_subnet.secondary_ip_range[0].range_name
    services_secondary_range_name = google_compute_subnetwork.secondary_gke_services_subnet.secondary_ip_range[0].range_name
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  vertical_pod_autoscaling {
    enabled = true
  }
  node_locations = [
    "${var.secondary_region}-b",
    "${var.secondary_region}-c",
  ]
}

resource "google_container_node_pool" "secondary_gke_node_pool" {
  name       = "secondary-gke-node-pool"
  location   = var.secondary_region
  cluster    = google_container_cluster.secondary_gke_cluster.name
  project    = var.project_id
  node_count = var.gke_node_count

  node_config {
    machine_type    = var.gke_machine_type
    service_account = google_service_account.gke_sa.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
    disk_size_gb = 100
    shielded_instance_config {
      enable_integrity_monitoring = true
      enable_secure_boot          = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# --- Global HTTP(S) Load Balancer ---
resource "google_compute_global_address" "lb_global_ip" {
  name       = var.lb_ip_name
  ip_version = "IPV4"
  project    = var.project_id
}

resource "google_compute_health_check" "http_health_check" {
  name                = "http-health-check"
  request_path        = "/healthz" # Adjust to your application's health endpoint
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 10
  project             = var.project_id
  http_health_check {
    port = 8080 # Example application port
  }
}

resource "google_compute_region_network_endpoint_group" "primary_neg" {
  name                  = "${var.primary_region}-backend-neg"
  network               = google_compute_network.vpc_network.id
  subnetwork            = google_compute_subnetwork.primary_subnet.id # Or the GKE node subnet
  region                = var.primary_region
  network_endpoint_type = "GCE_VM_IP_PORT"
  default_port          = 8080 # Example port for your application
  project               = var.project_id
}

resource "google_compute_region_network_endpoint_group" "secondary_neg" {
  name                  = "${var.secondary_region}-backend-neg"
  network               = google_compute_network.vpc_network.id
  subnetwork            = google_compute_subnetwork.secondary_subnet.id
  region                = var.secondary_region
  network_endpoint_type = "GCE_VM_IP_PORT"
  default_port          = 8080
  project               = var.project_id
}

resource "google_compute_backend_service" "web_backend_service" {
  name                  = "web-backend-service"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 10
  load_balancing_scheme = "EXTERNAL"
  project               = var.project_id

  backend {
    group          = google_compute_region_network_endpoint_group.primary_neg.id
    balancing_mode = "RATE"
    max_rate_per_instance = 100
  }

  backend {
    group          = google_compute_region_network_endpoint_group.secondary_neg.id
    balancing_mode = "RATE"
    max_rate_per_instance = 100
  }

  health_checks = [google_compute_health_check.http_health_check.id]
  enable_cdn    = false
}

resource "google_compute_url_map" "url_map" {
  name            = "web-url-map"
  default_service = google_compute_backend_service.web_backend_service.id
  project         = var.project_id
}

resource "google_compute_managed_ssl_certificate" "managed_cert" {
  name        = "managed-ssl-certificate"
  managed {
    domains = [var.lb_hostname]
  }
  project     = var.project_id
}

resource "google_compute_target_https_proxy" "https_proxy" {
  name             = "web-https-proxy"
  url_map          = google_compute_url_map.url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.managed_cert.id]
  project          = var.project_id
}

resource "google_compute_global_forwarding_rule" "https_forwarding_rule" {
  name                  = "web-https-forwarding-rule"
  ip_address            = google_compute_global_address.lb_global_ip.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.https_proxy.id
  load_balancing_scheme = "EXTERNAL"
  project               = var.project_id
}

resource "google_compute_url_map" "http_to_https_redirect" {
  name        = "http-to-https-redirect"
  default_url_redirect {
    host_redirect        = var.lb_hostname
    https_redirect       = true
    strip_query          = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
  project     = var.project_id
}

resource "google_compute_target_http_proxy" "http_proxy_redirect" {
  name        = "http-proxy-redirect"
  url_map     = google_compute_url_map.http_to_https_redirect.id
  project     = var.project_id
}

resource "google_compute_global_forwarding_rule" "http_forwarding_rule_redirect" {
  name                  = "http-forwarding-rule-redirect"
  ip_address            = google_compute_global_address.lb_global_ip.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.http_proxy_redirect.id
  load_balancing_scheme = "EXTERNAL"
  project               = var.project_id
}

# --- Outputs ---
output "primary_gke_cluster_name" {
  description = "Name of the primary GKE cluster."
  value       = google_container_cluster.primary_gke_cluster.name
}

output "secondary_gke_cluster_name" {
  description = "Name of the secondary GKE cluster."
  value       = google_container_cluster.secondary_gke_cluster.name
}

output "primary_alloydb_cluster_name" {
  description = "Name of the primary AlloyDB cluster."
  value       = google_alloydb_cluster.primary_alloydb_cluster.name
}

output "primary_alloydb_instance_ip" {
  description = "IP address of the primary AlloyDB instance."
  value       = google_alloydb_instance.primary_alloydb_instance.ip_address
}

output "secondary_alloydb_cluster_name" {
  description = "Name of the secondary AlloyDB cluster."
  value       = google_alloydb_cluster.secondary_alloydb_cluster.name
}

output "secondary_alloydb_instance_ip" {
  description = "IP address of the secondary AlloyDB instance."
  value       = google_alloydb_instance.secondary_alloydb_instance.ip_address
}

output "load_balancer_ip_address" {
  description = "The external IP address of the Global Load Balancer."
  value       = google_compute_global_address.lb_global_ip.address
}

output "alloydb_admin_password" {
  description = "The generated password for the AlloyDB admin user. Store this securely!"
  value       = random_password.alloydb_password.result
  sensitive   = true
}