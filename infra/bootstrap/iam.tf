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

resource "google_project_service" "secretmanager" {
  project            = var.project_id
  service            = "secretmanager.googleapis.com"
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

# Stored here for easy hand-off: `gcloud secrets versions access latest
# --secret=ci-sa-key --project=<project_id>` (or the Console) gives you the
# raw JSON to paste straight into the GitHub repo's GCP_SA_KEY secret — no
# `terraform output -raw | base64 -d` step needed.
resource "google_secret_manager_secret" "ci_key" {
  project   = var.project_id
  secret_id = "ci-sa-key"

  replication {
    auto {}
  }

  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "ci_key" {
  secret      = google_secret_manager_secret.ci_key.id
  secret_data = base64decode(google_service_account_key.ci_key.private_key)
}

# roles/editor is the broad baseline: it covers creating the VPC, Cloud SQL,
# App Engine version, Artifact Registry repo, service accounts, etc. It
# deliberately does NOT include any setIamPolicy permission, on any resource
# type — that's a real, documented exclusion (Editor can't grant itself more
# access). This config sets IAM policy in exactly two shapes, so exactly two
# narrow roles are added on top — not a defensive broad grant:
resource "google_project_iam_member" "ci_editor" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# Needed for the one project-level binding this config makes:
# google_project_iam_member.app_cloudsql_client (roles/cloudsql.client on the
# app's service account, in the main module's iam.tf).
resource "google_project_iam_member" "ci_project_iam_admin" {
  project = var.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# Needed for the two secret-level bindings this config makes:
# google_secret_manager_secret_iam_member on db-password and
# third-party-api-token (in the main module's secrets.tf). Project-scoped
# rather than bound to just those two secrets — narrower scoping would need a
# hand-rolled custom role, not worth it for a PoC with two secrets total.
resource "google_project_iam_member" "ci_secret_manager_admin" {
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# No artifactregistry.admin: nothing in this config sets IAM policy on the
# registry, and roles/editor already covers repository creation plus image
# push/pull (artifactregistry.repositories.uploadArtifacts and friends).
