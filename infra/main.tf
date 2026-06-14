provider "google" {
  project = var.project_id
  region  = var.region
}

variable "project_id" {
  description = "The GCP project ID to deploy resources into."
  type        = string
  default     = "your-gcp-project-id" # <-- REPLACE ME: Set your actual GCP project ID
}

variable "region" {
  description = "The GCP region to deploy resources into."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "The GCP zone to deploy compute resources into."
  type        = string
  default     = "us-central1-a"
}

# 1. VPC Network
resource "google_compute_network" "main_vpc" {
  name                    = "main-vpc-network"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# 2. Subnet
resource "google_compute_subnet" "main_subnet" {
  name          = "main-subnet"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.main_vpc.id
}

# 3. Firewall Rules
# Allow SSH from specific IP ranges or IAP (for security)
resource "google_compute_firewall" "allow_ssh_ingress" {
  name    = "allow-ssh-ingress"
  network = google_compute_network.main_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # WARNING: 0.0.0.0/0 allows SSH from anywhere.
  # For production, restrict this to your specific IP range,
  # a VPN IP range, or Google Cloud IAP (35.235.240.0/20).
  source_ranges = ["0.0.0.0/0"] 
  target_tags   = ["ssh"]
}

# Allow HTTP from anywhere (if the VM hosts a web server)
resource "google_compute_firewall" "allow_http_ingress" {
  name    = "allow-http-ingress"
  network = google_compute_network.main_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server"]
}

# 4. Compute Engine VM Instance
resource "google_compute_instance" "web_server_instance" {
  name         = "web-server-instance"
  machine_type = "e2-medium"
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 20 # GB
    }
  }

  network_interface {
    network    = google_compute_network.main_vpc.name
    subnetwork = google_compute_subnet.main_subnet.name

    # Assign a public IP for external access (e.g., web server, SSH)
    # Remove this access_config block if only internal access is desired.
    access_config {
      // Ephemeral public IP address
    }
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    sudo apt update && sudo apt install -y apache2
    echo "<h1>Hello from Terraform-deployed VM!</h1>" | sudo tee /var/www/html/index.html
    sudo systemctl enable apache2
    sudo systemctl start apache2
  EOF

  tags = ["ssh", "http-server"] # Tags used by firewall rules
}

# 5. GCS Bucket for application data/logs
resource "google_storage_bucket" "app_data_bucket" {
  # Bucket name must be globally unique
  name          = "${var.project_id}-app-data-bucket-${random_id.bucket_suffix.hex}"
  location      = var.region
  project       = var.project_id
  storage_class = "STANDARD"

  # Recommended for security; prevents ACLs from being used on objects
  uniform_bucket_level_access = true

  # Optional: Versioning for data recovery
  versioning {
    enabled = true
  }
}

# Helper resource to generate a unique suffix for the bucket name
resource "random_id" "bucket_suffix" {
  byte_length = 8
}

# Output the external IP address of the VM
output "instance_external_ip" {
  description = "The external IP address of the web server instance."
  value       = google_compute_instance.web_server_instance.network_interface[0].access_config[0].nat_ip
}

# Output the GCS bucket name
output "gcs_bucket_name" {
  description = "The name of the Google Cloud Storage bucket."
  value       = google_storage_bucket.app_data_bucket.name
}