resource "google_sql_database_instance" "postgres" {
  project             = var.project_id
  name                = "meridian-postgres"
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = false # torn down after review

  settings {
    # Postgres 16 defaults to ENTERPRISE_PLUS, which rejects shared-core tiers;
    # ENTERPRISE keeps db-g1-small available (the smallest supporting private
    # IP). PoC sizing — production would size from traffic and use REGIONAL.
    edition           = "ENTERPRISE"
    tier              = "db-g1-small"
    disk_size         = 10 # GB, the minimum
    disk_type         = "PD_HDD"
    availability_type = "ZONAL"

    ip_configuration {
      ipv4_enabled                                 = false
      private_network                              = google_compute_network.vpc.id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled = false # production would enable
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
