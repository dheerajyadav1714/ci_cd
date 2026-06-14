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
  description = "The GCP zone to deploy the VM instance into."
  type        = string
  default     = "us-central1-a"
}

resource "google_compute_network" "main_vpc" {
  name                    = "my-app-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "main_subnet" {
  name          = "my-app-subnet"
  ip_cidr_range = "10.10.0.0/20"
  region        = var.region
  network       = google_compute_network.main_vpc.self_link
}

resource "google_service_account" "instance_sa" {
  account_id   = "my-app-instance-sa"
  display_name = "Service Account for my-app-instance"
  project      = var.project_id
}

resource "google_project_iam_member" "sa_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.instance_sa.email}"
}

resource "google_project_iam_member" "sa_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.instance_sa.email}"
}

resource "google_compute_instance" "my_app_instance" {
  name         = "my-app-instance"
  machine_type = "e2-medium"
  zone         = var.zone
  tags         = ["http-server", "ssh"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }

  network_interface {
    network    = google_compute_network.main_vpc.self_link
    subnetwork = google_compute_subnetwork.main_subnet.self_link
    access_config {
      // Ephemeral IP
    }
  }

  service_account {
    email  = google_service_account.instance_sa.email
    scopes = ["cloud-platform"] # Broad scope for demonstration, fine-tune as needed
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install -y apache2
    echo "Hello from Terraform on Google Cloud!" | sudo tee /var/www/html/index.html
    sudo systemctl enable apache2
    sudo systemctl start apache2
  EOF
}

resource "google_compute_firewall" "allow_ssh" {
  name        = "allow-ssh-from-iap" # Name suggests IAP, but allows all by default. Adjust source_ranges for specific IAP IPs.
  network     = google_compute_network.main_vpc.self_link
  description = "Allow SSH from anywhere (0.0.0.0/0)"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh"]
}

resource "google_compute_firewall" "allow_http" {
  name        = "allow-http"
  network     = google_compute_network.main_vpc.self_link
  description = "Allow HTTP from anywhere (0.0.0.0/0)"

  allow {
    protocol = "tcp"
    ports    = ["80"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["http-server"]
}

output "instance_external_ip" {
  description = "The external IP address of the Compute Engine instance."
  value       = google_compute_instance.my_app_instance.network_interface[0].access_config[0].nat_ip
}

output "instance_internal_ip" {
  description = "The internal IP address of the Compute Engine instance."
  value       = google_compute_instance.my_app_instance.network_interface[0].network_ip
}

output "vpc_self_link" {
  description = "The self link of the created VPC network."
  value       = google_compute_network.main_vpc.self_link
}

output "subnet_self_link" {
  description = "The self link of the created subnetwork."
  value       = google_compute_subnetwork.main_subnet.self_link
}

output "service_account_email" {
  description = "The email of the service account created for the instance."
  value       = google_service_account.instance_sa.email
}