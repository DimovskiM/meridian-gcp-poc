resource "google_sql_database_instance" "postgres" {
  project             = var.project_id
  name                = "meridian-postgres"
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = false # PoC: this environment is torn down after review

  settings {
    tier              = "db-custom-1-3840"
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
