locals {
  # GIT_COMMIT is absent by design — baked into the image at build time
  # (app/Dockerfile) so it travels with the artifact.
  app_env = {
    GCP_PROJECT = var.project_id
    DB_HOST     = google_sql_database_instance.postgres.private_ip_address
    DB_PORT     = "5432"
    DB_NAME     = var.db_name
    DB_USER     = var.db_user
    REGION      = var.region
  }
}

# Terraform owns every field except the image, which `gcloud run deploy` sets
# per app deploy (see the lifecycle block). A Cloud Run service is mutable, so
# the two coexist; App Engine's immutable versions could not express this.
resource "google_cloud_run_v2_service" "api" {
  project             = var.project_id
  name                = "meridian-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  # Service-wide scaling floor, distinct from template.scaling below (which is
  # per-revision). Declared explicitly at its default rather than omitted: the
  # provider writes this block into state on create either way, so omitting it
  # makes every subsequent plan propose removing it.
  scaling {
    min_instance_count = 0
  }

  template {
    service_account = google_service_account.app.email

    # Costs nothing idle, at the price of a ~1-3s cold start. Production would
    # use min_instance_count = 1 with startup CPU boost.
    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    # Direct VPC egress: the route to Cloud SQL's private IP, no connector VM.
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

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle = true
      }

      dynamic "env" {
        for_each = local.app_env
        content {
          name  = env.key
          value = env.value
        }
      }

      # Injected by Cloud Run under this service's identity: the values never
      # reach Terraform state or the deploy pipeline.
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
    ignore_changes = [template[0].containers[0].image]
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_iam_member.app_reads_db_password,
    google_secret_manager_secret_iam_member.app_reads_third_party_token,
  ]
}

# Unauthenticated because the exercise requires /health on a public URL. Only
# the API is exposed; the database has no public IP. Production would front
# this with a load balancer and Cloud Armor, and authenticate everything else.
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Migrations run here rather than at app startup, so cold starts stay fast and
# a bad migration fails the deploy visibly instead of degrading the service.
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

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        dynamic "env" {
          for_each = local.app_env
          content {
            name  = env.key
            value = env.value
          }
        }

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
    ignore_changes = [template[0].template[0].containers[0].image]
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_iam_member.app_reads_db_password,
  ]
}
