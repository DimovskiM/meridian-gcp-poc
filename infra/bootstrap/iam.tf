# The CI/CD identity lives here, not in the main module, deliberately: the
# main module is what CI applies, so CI must not be able to recreate or
# rotate the identity it is currently authenticating as. Bootstrap is applied
# once, by hand, by a human.
#
# Documented deviation from Meridian's brief: their platform team asked for a
# service account JSON key stored as a GitHub secret, to match the rest of
# their estate. This uses Workload Identity Federation instead — GitHub's
# OIDC token is exchanged for a short-lived (1 hour) GCP access token per
# run, and no key exists to leak, rotate, or expire. Reasons, in order:
#
#   1. The exercise states "no long-lived credentials anywhere in the
#      repository" as a hard requirement.
#   2. Google is progressively disabling service account key creation via
#      organization policy defaults (disableServiceAccountKeyCreation); the
#      estate pattern Meridian asked us to match is on its way out, and would
#      break outright under that constraint.
#   3. google_service_account_key writes the private key material into
#      Terraform state in plaintext — so "the key is not in the repo" would
#      have been true while the key sat in the state bucket regardless.
#   4. Meridian's own reply invited this: "if you think there is a better way,
#      do it your way but write down why, so I can take it to them."
#
# See ASSUMPTIONS.md for the full tradeoff, including what was given up.

resource "google_project_service" "iam" {
  project            = var.project_id
  service            = "iam.googleapis.com"
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

  # Without this condition, ANY GitHub repository on github.com could exchange
  # its OIDC token for credentials in this project. Scoping to the one repo is
  # the whole security boundary — never widen it to a bare "true".
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Only tokens from the named repository may impersonate the CI service
# account. principalSet scopes the binding to that repository's identities.
resource "google_service_account_iam_member" "ci_workload_identity_user" {
  service_account_id = google_service_account.ci.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

# roles/editor is the broad baseline: it covers creating the VPC, Cloud SQL,
# the Cloud Run service and job, the Artifact Registry repo, service accounts,
# etc. It deliberately does NOT include any setIamPolicy permission, on any
# resource type — that's a real, documented exclusion (Editor can't grant
# itself more access). This config sets IAM policy in three shapes, so exactly
# three narrow roles are added on top — not a defensive broad grant:
resource "google_project_iam_member" "ci_editor" {
  project = var.project_id
  role    = "roles/editor"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# For the project-level binding in the main module's iam.tf
# (roles/cloudsql.client on the app's service account).
resource "google_project_iam_member" "ci_project_iam_admin" {
  project = var.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# For the two secret-level bindings in the main module's secrets.tf.
# Project-scoped rather than bound to just those two secrets — narrower
# scoping would need a hand-rolled custom role, not worth it for two secrets.
resource "google_project_iam_member" "ci_secret_manager_admin" {
  project = var.project_id
  role    = "roles/secretmanager.admin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# For the run.invoker binding granting allUsers access to the Cloud Run
# service (main module's cloudrun.tf) — roles/editor cannot set IAM policy.
resource "google_project_iam_member" "ci_run_admin" {
  project = var.project_id
  role    = "roles/run.admin"
  member  = "serviceAccount:${google_service_account.ci.email}"
}

# No artifactregistry.admin: nothing in this config sets IAM policy on the
# registry, and roles/editor already covers repository creation plus image
# push/pull.
