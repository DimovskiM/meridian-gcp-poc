resource "random_password" "db_password" {
  length  = 24
  special = false # avoid characters that need escaping in a DB connection URL
}

resource "google_secret_manager_secret" "db_password" {
  project   = var.project_id
  secret_id = "db-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db_password.result
}

# Stand-in for a real third-party provider credential Meridian would supply.
resource "google_secret_manager_secret" "third_party_token" {
  project   = var.project_id
  secret_id = "third-party-api-token"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "third_party_token" {
  secret      = google_secret_manager_secret.third_party_token.id
  secret_data = var.third_party_api_token
}

# Least privilege: the app's identity can read exactly these two secrets,
# nothing project-wide.
resource "google_secret_manager_secret_iam_member" "app_reads_db_password" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app.email}"
}

resource "google_secret_manager_secret_iam_member" "app_reads_third_party_token" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.third_party_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.app.email}"
}
