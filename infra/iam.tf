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

# Read-only access for the Commit reviewers.
#
# Caveat worth knowing before granting: roles/viewer includes storage read
# access, and the Terraform state bucket holds the generated database password
# in plaintext. Reviewer access therefore implies access to that password. It
# is acceptable here because this is a throwaway PoC whose credentials die with
# the project. In production the state bucket belongs in a separate project so
# that granting Viewer on the workload project does not expose state.
resource "google_project_iam_member" "reviewers" {
  for_each = toset(var.reviewer_principals)
  project  = var.project_id
  role     = "roles/viewer"
  member   = each.value
}

# The CI/CD identity lives in infra/bootstrap, not here — CI must not be able
# to recreate the identity it authenticates as.
