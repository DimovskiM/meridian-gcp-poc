# --- App's own runtime identity ---

resource "google_service_account" "app" {
  project      = var.project_id
  account_id   = "meridian-app"
  display_name = "Meridian API runtime identity"
}

resource "google_project_iam_member" "app_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.app.email}"
}

# The CI/CD service account (and its key) is intentionally NOT defined here.
# It lives in infra/bootstrap, applied by a human outside of what this module
# manages — see infra/bootstrap/iam.tf for why.
