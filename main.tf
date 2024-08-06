provider "google" {
  project     = "sit724"
  region      = "us-central1"
}

resource "google_compute_instance" "filecoin_instance" {
  count        = 2
  name         = "filecoin-node-${count.index + 1}"
  machine_type = "e2-standard-16"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2004-lts"
      size  = 50
    }
  }

  network_interface {
    network = google_compute_network.vpc_network.name

    access_config {
      # Allocates a public IP address
    }
  }

  tags = ["filecoin-node"]

  metadata_startup_script = file("setup.sh")

  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

resource "google_compute_network" "vpc_network" {
  name = "filecoin-network"
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] # Open to the world; consider restricting for security
}

resource "google_compute_firewall" "allow_filecoin" {
  name    = "allow-filecoin"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["1234", "1347"] # Replace with actual ports used by Lotus
  }

  source_ranges = ["0.0.0.0/0"] # Adjust to specific IP ranges for better security
}

output "instance_ips" {
  value = google_compute_instance.filecoin_instance[*].network_interface[0].access_config[0].nat_ip
}
