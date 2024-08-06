provider "google" {
  project     = "sit724"
  region      = "us-central1"
}

resource "google_compute_network" "vpc_network" {
  name = "filecoin-network"
}

resource "google_compute_instance" "filecoin_instance" {
  count        = 2
  name         = "filecoin-node-${count.index + 1}"
  machine_type = "e2-standard-4"
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
      # Include this section to allocate a public IP address
    }
  }

  metadata_startup_script = file("setup.sh")

  tags = ["filecoin-node"]

  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

output "instance_ips" {
  value = google_compute_instance.filecoin_instance[*].network_interface[0].access_config[0].nat_ip
}
