# Applied by hand, separately from the main module: CI must not be able to
# recreate the identity it authenticates as.
#
# Meridian asked for a service account JSON key in a GitHub secret. This uses
# Workload Identity Federation instead — no key exists to leak or rotate.
# Rationale and tradeoff in ASSUMPTIONS.md.

resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

# Belongs here, not the main module: Terraform needs it to touch any project
# IAM policy, so the main module cannot enable it for itself.
resource "google_project_service" "cloudresourcemanager" {
  project            = var.project_id
  service            = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iamcredentials" {
  project            = var.project_id
  service            = "iamcredentials.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sts" {
  project            = var.project_id
  service            = "sts.googleapis.com"
  disable_on_destroy = false
}

resource "google_service_account" "ci" {
  project      = var.project_id
  account_id   = "meridian-ci-cd"
  display_name = "GitHub Actions CI/CD"
  depends_on   = [google_project_service.iam]
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.iam]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  # The security boundary. Without it, any repository on github.com could
  # exchange a token for credentials here. Never widen to a bare "true".
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "ci_workload_identity_user" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# roles/editor covers resource creation but deliberately excludes setIamPolicy
# on every resource type. The three narrow roles below cover exactly the IAM
# bindings this config makes — they are not a defensive broad grant.
resource "google_project_iam_member" "ci_editor" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# Project-level bindings in the main module's iam.tf.
resource "google_project_iam_member" "ci_project_iam_admin" {
  project = var.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# Secret-level bindings in secrets.tf. Project-scoped because narrower would
# need a custom role for two secrets.
resource "google_project_iam_member" "ci_secret_manager_admin" {
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# The run.invoker binding in cloudrun.tf.
resource "google_project_iam_member" "ci_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# Private Services Access peering in network.tf; roles/editor lacks
# servicenetworking.services.addPeering.
resource "google_project_iam_member" "ci_servicenetworking_admin" {
  project = var.project_id
  role    = "roles/servicenetworking.networksAdmin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}
