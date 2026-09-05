# Custom VPC rather than the default network, which ships with SSH/RDP/ICMP
# open to 0.0.0.0/0. Meridian asked for the default VPC; objected to in the
# clarification round and they deferred.
resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "meridian-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "app_subnet" {
  project                  = var.project_id
  name                     = "meridian-app-subnet"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.app_subnet_cidr
  private_ip_google_access = true
}

# Private Services Access: reserves a range for Cloud SQL to peer into this
# VPC. Peering is non-transitive — anything that later needs to reach Cloud
# SQL must be a member of this VPC's subnets, not bridged via a second hop.
resource "google_compute_global_address" "private_service_range" {
  project       = var.project_id
  name          = "meridian-private-service-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_range.name]
  depends_on              = [google_project_service.apis]
}

# Custom VPCs default-deny all ingress. Nothing here governs access to the API:
# Cloud Run's front end sits outside the VPC (see cloudrun.tf).
resource "google_compute_firewall" "allow_internal" {
  project       = var.project_id
  name          = "meridian-allow-internal"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = [var.vpc_cidr]

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}
