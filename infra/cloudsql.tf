resource "google_sql_database_instance" "postgres" {
  project             = var.project_id
  name                = "meridian-postgres"
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = false # PoC: this environment is torn down after review

  settings {
    # Edition pinned explicitly: Postgres 16 now defaults to ENTERPRISE_PLUS,
    # which rejects custom/shared-core tiers ("Invalid Tier for
    # (ENTERPRISE_PLUS) Edition") and only offers larger performance-optimized
    # machine types. ENTERPRISE keeps the small tiers available.
    #
    # db-g1-small is the smallest tier that supports private IP (db-f1-micro
    # does not). Sized for a PoC, not for load — production would size from
    # real traffic and use REGIONAL for HA.
    edition           = "ENTERPRISE"
    tier              = "db-g1-small"
    disk_size         = 10 # GB, the minimum
    disk_type         = "PD_HDD"
    availability_type = "ZONAL" # single zone — PoC scope; production would use REGIONAL

    ip_configuration {
      ipv4_enabled                                 = false # no public IP, ever
      private_network                              = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled = false # PoC scope — production would enable this
    }
  }

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

resource "google_sql_database" "app_db" {
  project  = var.project_id
  name     = var.db_name
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "app_user" {
  project  = var.project_id
  name     = var.db_user
  instance = google_sql_database_instance.postgres.name
  password = random_password.db_password.result
}
