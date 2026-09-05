locals {
  # Shared by the service and the migration job — both run the same image and
  # need the same connection details.
  app_env = {
    GCP_PROJECT = var.project_id
    DB_HOST     = google_sql_database_instance.postgres.private_ip_address
    DB_PORT     = "5432"
    DB_NAME     = var.db_name
    DB_USER     = var.db_user
    REGION      = var.region
    # GIT_COMMIT is deliberately absent — it's baked into the image at build
    # time (app/Dockerfile) so it travels with the artifact.
  }
}

# The API service.
#
# Terraform owns the whole configuration — env vars, VPC egress, runtime
# identity, scaling, probes. The one field it does NOT own is the image:
# `gcloud run deploy --image` updates that on every app deploy, and the
# lifecycle block below stops Terraform from reverting it. This is the split
# that App Engine couldn't express: its versions are immutable, so any change
# meant recreating the whole version through Terraform. A Cloud Run service
# is a mutable resource, so config-in-Terraform and image-updated-by-gcloud
# coexist cleanly.
resource "google_cloud_run_v2_service" "api" {
  project             = var.project_id
  name                = "meridian-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.app.email

    # Scale to zero: nothing runs (and nothing bills) when idle. Trade-off is
    # a ~1-3s cold start on the first request after an idle period; requests
    # pend rather than fail. For a production payments API we'd set
    # min_instance_count = 1 with startup CPU boost instead.
    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    # Direct VPC egress — no connector VM to run or pay for. This is what
    # gives the service a route to Cloud SQL's private IP.
    vpc_access {
      network_interfaces {
        network    = google_compute_network.vpc.id
        subnetwork = google_compute_subnetwork.app_subnet.id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = var.container_image

      ports {
        container_port = 8080
      }

      dynamic "env" {
        for_each = local.app_env
        content {
          name  = env.key
          value = env.value
        }
      }

      # Both secrets are injected by Cloud Run from Secret Manager at instance
      # start, under this service's own identity — the values never pass
      # through Terraform state or the deploy pipeline, and application code
      # never calls the Secret Manager API itself.
      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "THIRD_PARTY_API_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.third_party_token.secret_id
            version = "latest"
          }
        }
      }

      startup_probe {
        http_get {
          path = "/health"
        }
      }
    }
  }

  lifecycle {
    # Owned by `gcloud run deploy` in .github/workflows/deploy-app.yml.
    ignore_changes = [template[0].containers[0].image]
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.app_cloudsql_client,
    google_secret_manager_secret_iam_member.app_reads_db_password,
    google_secret_manager_secret_iam_member.app_reads_third_party_token,
  ]
}

# The exercise requires /health on a public URL, so the service is invokable
# unauthenticated. Note this exposes only the API itself — the database stays
# unreachable from the internet, which is the actual stated constraint. A real
# deployment would put Cloud Armor / an external load balancer in front and
# authenticate anything beyond a health endpoint.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Migrations run here, not at app startup.
#
# Decoupling them from the service means a cold start never pays for a
# migration check, and a bad migration surfaces as a visibly failed job
# execution instead of a degraded or crash-looping service. Same image as the
# service, different entrypoint.
resource "google_cloud_run_v2_job" "migrate" {
  project             = var.project_id
  name                = "meridian-migrate"
  location            = var.region
  deletion_protection = false

  template {
    template {
      service_account = google_service_account.app.email
      max_retries     = 0

      vpc_access {
        network_interfaces {
          network    = google_compute_network.vpc.id
          subnetwork = google_compute_subnetwork.app_subnet.id
        }
        egress = "PRIVATE_RANGES_ONLY"
      }

      containers {
        image   = var.container_image
        command = ["python", "migrate.py"]

        dynamic "env" {
          for_each = local.app_env
          content {
            name  = env.key
            value = env.value
          }
        }

        # Same injection as the service — the job connects to the same
        # database. It doesn't need the third-party token at all.
        env {
          name = "DB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.db_password.secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    # Same as the service: the deploy workflow points this at the new image.
    ignore_changes = [template[0].template[0].containers[0].image]
  }

  depends_on = [
    google_project_service.apis,
    google_project_iam_member.app_cloudsql_client,
    google_secret_manager_secret_iam_member.app_reads_db_password,
  ]
}
