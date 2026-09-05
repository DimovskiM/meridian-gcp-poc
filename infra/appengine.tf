# NOTE (flagged for explicit confirmation before first apply): creating the
# App Engine "application" resource is a one-way decision — its region
# (location_id) cannot be changed afterward, and the application itself
# cannot be deleted except by deleting the entire GCP project. Since this
# project was created fresh for this PoC and is meant to be torn down
# entirely after review, that's an acceptable one-way door here, but it's
# worth pausing on before the first apply.
resource "google_app_engine_application" "app" {
  project     = var.project_id
  location_id = var.region

  depends_on = [google_project_service.apis]
}

# All app configuration lives here in Terraform — env vars, VPC placement,
# runtime service account, health checks. The only thing a deploy changes is
# var.container_image (the new tag). The commit SHA isn't a Terraform input
# at all: it's baked into the image at build time as a Docker ENV, so it
# travels with the artifact rather than being plumbed through infra config.
#
# On the provider's documented env_variables quirk (GCP's API doesn't return
# env_variables on read, so Terraform can't detect drift in them): not a
# concern here, because version_id is derived from the image tag — every
# deploy creates a brand-new version resource rather than updating one in
# place, so there's never an existing resource to drift against.
resource "google_app_engine_flexible_app_version" "app" {
  project = var.project_id
  service = "default"
  runtime = "custom"

  # Derived from the image tag (the short SHA), so each deploy is a distinct,
  # traceable version. Sanitized: version ids must be lowercase alphanumeric
  # with hyphens.
  version_id = "v-${lower(replace(regex("[^:]+$", var.container_image), "/[^a-z0-9-]/", "-"))}"

  deployment {
    container {
      image = var.container_image
    }
  }

  env_variables = {
    GCP_PROJECT = var.project_id
    DB_HOST     = google_sql_database_instance.postgres.private_ip_address
    DB_PORT     = "5432"
    DB_NAME     = var.db_name
    DB_USER     = var.db_user
    REGION      = var.region
  }

  service_account = google_service_account.app.email

  # Manual, single instance: "one service is enough to prove the pattern" —
  # no autoscaling complexity for a PoC, and it keeps the cost predictable.
  manual_scaling {
    instances = 1
  }

  network {
    name       = google_compute_network.vpc.name
    subnetwork = google_compute_subnetwork.app_subnet.name
    # NOTE: this provider's google_app_engine_flexible_app_version has no
    # typed field to force internal-only instances (no "instance_ip_mode"
    # attribute exists in this resource — confirmed against the provider
    # schema directly, not assumed; app.yaml's own schema does support
    # network.instance_ip_mode, but it isn't exposed through this Terraform
    # resource type). Doesn't violate any stated requirement — only Cloud SQL
    # was required to be unreachable from the internet, and it is — but it's
    # a real gap vs. the more defensible internal-only posture, flagged in
    # ASSUMPTIONS.md rather than silently accepted.
  }

  liveness_check {
    path = "/health"
  }

  readiness_check {
    path = "/health"
  }

  noop_on_destroy = true

  depends_on = [
    google_app_engine_application.app,
    google_project_iam_member.app_cloudsql_client,
    google_secret_manager_secret_iam_member.app_reads_db_password,
    google_secret_manager_secret_iam_member.app_reads_third_party_token,
  ]
}
