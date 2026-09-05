# Custom VPC — not the default network. The default VPC ships with permissive
# auto-created firewall rules (SSH/RDP/ICMP open to 0.0.0.0/0), which is exactly
# what an auditor at a payments company would flag, and it conflicts with
# Meridian's own request that this "reflect the production target." This
# objection was raised in the clarification email; Meridian deferred to our
# judgment on it.
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
  private_ip_google_access = true # lets INTERNAL-only instances reach Secret Manager / Cloud SQL Admin API
}

# Private Services Access: reserves a range for Google-managed services (Cloud
# SQL private IP) to peer into this VPC. This is peering, not literal
# co-location — the Cloud SQL instance lives in a Google-managed tenant
# network, reachable only via this peering connection. Peering is
# non-transitive: anything else that later needs to reach Cloud SQL (a future
# VPN-connected AWS network, a separately-peered VPC) must be a genuine member
# of THIS VPC's subnets, not bridged through a second peering hop.
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

# Custom VPCs default-deny all ingress — no explicit rule needed to keep the
# database (or anything else) unreachable from the internet. Only what's
# explicitly allowed below can get in.

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

# No health-check ingress rule needed: Cloud Run instances aren't VMs in this
# VPC. Direct VPC egress gives them an outbound route to private ranges (which
# is how they reach Cloud SQL); inbound traffic and health checks are handled
# by Cloud Run's own front end, outside the VPC entirely.
