# The CI/CD identity lives here, not in the main module, deliberately.
#
# GitHub Actions needs this service account's key to run `terraform apply` on
# the main module at all — if the key were instead defined as a resource
# inside the main module, CI would be managing its own credential as part of
# the same apply it's using that credential to run. Any future drift, taint,
# or provider-driven replacement of that key resource would rotate the
# credential mid-run, and nothing updates the GitHub secret automatically —
# the next CI run would simply fail to authenticate. Keeping it in bootstrap
# (applied once, by hand, by a human) means the main module never has a path
# to regenerate the key it's currently running under.
#
# Documented reversal from the clarification email: that email told Meridian
# this would use Workload Identity Federation instead of a static key. This
# builds the key exactly as Meridian's platform team originally asked,
# matching their existing estate pattern — see ASSUMPTIONS.md for the full
# reasoning and the known tradeoff (a key with this much scope, with no
# expiry, stored in Terraform state in plaintext via google_service_account_key).

resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "ci" {
  project      = var.project_id
  account_id   = "meridian-ci-cd"
  display_name = "GitHub Actions CI/CD"
  depends_on   = [google_project_service.iam]
}

resource "google_service_account_key" "ci_key" {
  service_account_id = google_service_account.ci.name
}

resource "google_project_iam_member" "ci_editor" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

resource "google_project_iam_member" "ci_security_admin" {
  project = var.project_id
  role    = "roles/iam.securityAdmin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

resource "google_project_iam_member" "ci_artifact_registry_admin" {
  project = var.project_id
  role    = "roles/artifactregistry.admin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}
