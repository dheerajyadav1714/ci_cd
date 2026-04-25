provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  description = "The GCP project ID."
  type        = string
}

variable "region" {
  description = "The GCP region to deploy resources in."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone to deploy the VM in."
  type        = string
  default     = "us-central1-c"
}

# 1. VPC Network for the application
resource "google_compute_network" "app_vpc" {
  name                    = "my-app-vpc"
  auto_create_subnetworks = false # Best practice for custom subnets and granular control
  routing_mode            = "REGIONAL"
}

# 2. Subnet within the VPC for application resources
resource "google_compute_subnetwork" "app_subnet" {
  name          = "my-app-subnet"
  ip_cidr_range = "10.0.0.0/24" # Example CIDR block
  region        = var.region
  network       = google_compute_network.app_vpc.id
}

# 3. Firewall Rule: Allow SSH (Port 22) to web server instances
resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh-to-web-servers"
  network = google_compute_network.app_vpc.id
  # In a production environment, source_ranges should be more restrictive (e.g., corporate VPN IP, IAP range).
  # For this general design, we allow from anywhere for ease of access.
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  # Apply this rule to instances tagged with 'web-server'
  target_tags = ["web-server"]
}

# 4. Firewall Rule: Allow HTTP (Port 80) to web server instances
resource "google_compute_firewall" "allow_http" {
  name    = "allow-http-to-web-servers"
  network = google_compute_network.app_vpc.id
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
  # Apply this rule to instances tagged with 'web-server'
  target_tags = ["web-server"]
}

# 5. Static External IP Address for the web server
resource "google_compute_address" "web_server_ip" {
  name         = "web-server-external-ip"
  address_type = "EXTERNAL"
  network_tier = "STANDARD" # Can be PREMIUM for better performance/lower latency
  region       = var.region
}

# 6. Compute Engine Instance acting as a web server
resource "google_compute_instance" "web_server" {
  name         = "my-web-server-instance"
  machine_type = "e2-medium" # A general-purpose machine type
  zone         = var.zone
  tags         = ["web-server"] # Tags used by firewall rules

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11" # A stable Debian image
      size  = 20                       # Default 20GB disk size
    }
  }

  network_interface {
    network    = google_compute_network.app_vpc.id
    subnetwork = google_compute_subnetwork.app_subnet.id
    # Assign the reserved static external IP address
    access_config {
      nat_ip = google_compute_address.web_server_ip.address
    }
  }

  # Metadata startup script to install and configure Apache web server
  metadata_startup_script = <<-EOF
    #!/bin/bash
    sudo apt update -y
    sudo apt install -y apache2
    sudo systemctl enable apache2
    sudo systemctl start apache2
    echo "<h1>Hello from Terraform on Google Cloud!</h1>" | sudo tee /var/www/html/index.html
  EOF

  # Service account with default scopes for the VM
  # For production, consider creating a custom service account with minimal necessary permissions.
  service_account {
    email  = "default" # Uses the Compute Engine default service account
    scopes = ["https://www.googleapis.com/auth/devstorage.read_only", "https://www.googleapis.com/auth/logging.write", "https://www.googleapis.com/auth/monitoring.write", "https://www.googleapis.com/auth/servicecontrol", "https://www.googleapis.com/auth/service.management.readonly", "https://www.googleapis.com/auth/trace.append"]
  }
}

# Outputs: Useful information about the deployed resources
output "instance_external_ip" {
  description = "The external IP address of the web server instance."
  value       = google_compute_address.web_server_ip.address
}

output "instance_name" {
  description = "The name of the web server instance."
  value       = google_compute_instance.web_server.name
}

output "instance_zone" {
  description = "The zone where the web server instance is deployed."
  value       = google_compute_instance.web_server.zone
}